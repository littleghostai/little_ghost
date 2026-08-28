# frozen_string_literal: true

require "base64"
require "digest"
require "json"

module LittleGhost
  # Connects Agents to Tools published by Model Context Protocol servers through
  # an application-provided official MCP Ruby client.
  # See the {MCP guide}[rdoc-ref:docs/guides/mcp.md] to build a client, choose a
  # transport, manage its lifecycle, and decide which operations and application
  # data the server may access.
  module MCP
    class CatalogValidatingTransport # :nodoc:
      MAX_SCHEMA_DEPTH = 128
      MAX_SCHEMA_NODES = 100_000

      attr_reader :transport

      def initialize(transport)
        @transport = transport
        @catalog_schema_nodes = 0
        @catalog_mutex = Mutex.new
        define_connect if transport.respond_to?(:connect)
      end

      def send_request(request:, &sent)
        method = request[:method] || request["method"]
        response = transport.send_request(request:, &sent)
        validate_catalog(response, reset: first_catalog_page?(request)) if method == "tools/list"
        response
      rescue SystemStackError
        raise unless method == "tools/list"

        raise ::MCP::Client::ValidationError, "tools/list inputSchema exceeds the SDK nesting limit"
      end

      def method_missing(name, ...)
        return super unless transport.respond_to?(name)

        transport.public_send(name, ...)
      end

      def respond_to_missing?(name, include_private = false)
        transport.respond_to?(name, include_private) || super
      end

      private

      def define_connect
        accepts_mode = transport.method(:connect).parameters.any? do |kind, name|
          %i[key keyreq].include?(kind) && name == :mode
        end
        if accepts_mode
          define_singleton_method(:connect) do |client_info: nil, protocol_version: nil, capabilities: {}, mode: :legacy|
            transport.connect(client_info:, protocol_version:, capabilities:, mode:)
          end
        else
          define_singleton_method(:connect) do |client_info: nil, protocol_version: nil, capabilities: {}|
            transport.connect(client_info:, protocol_version:, capabilities:)
          end
        end
      end

      def first_catalog_page?(request)
        params = request[:params] || request["params"]
        !params.is_a?(Hash) || !(params.key?(:cursor) || params.key?("cursor"))
      end

      def validate_catalog(response, reset:)
        raise ::MCP::Client::ValidationError, "tools/list response must be an object" unless response.is_a?(Hash)
        if response.key?("error")
          error = response["error"]
          unless error.is_a?(Hash) && error["code"].is_a?(Integer) && error["message"].is_a?(String)
            raise ::MCP::Client::ValidationError, "tools/list error must be a JSON-RPC error object"
          end
          return
        end

        result = response["result"]
        raise ::MCP::Client::ValidationError, "tools/list result must be an object" unless result.is_a?(Hash)

        tools = result["tools"]
        unless tools.is_a?(Array) && tools.all? { |tool| tool.is_a?(Hash) }
          raise ::MCP::Client::ValidationError, "tools/list tools must be an array of objects"
        end
        @catalog_mutex.synchronize do
          @catalog_schema_nodes = 0 if reset
          tools.each do |tool|
            @catalog_schema_nodes = validate_schema_complexity(
              tool["inputSchema"],
              nodes: @catalog_schema_nodes
            )
          end
        end
        cursor = result["nextCursor"]
        unless cursor.nil? || cursor.is_a?(String)
          raise ::MCP::Client::ValidationError, "tools/list nextCursor must be a string"
        end
      end

      def validate_schema_complexity(schema, nodes:)
        return nodes unless schema.is_a?(Hash) || schema.is_a?(Array)

        pending = [[schema, 1]]
        until pending.empty?
          value, depth = pending.pop
          if depth > MAX_SCHEMA_DEPTH
            raise ::MCP::Client::ValidationError,
              "tools/list inputSchema exceeds the #{MAX_SCHEMA_DEPTH}-level depth limit"
          end
          nodes += 1
          if nodes > MAX_SCHEMA_NODES
            raise ::MCP::Client::ValidationError,
              "tools/list inputSchema exceeds the #{MAX_SCHEMA_NODES}-node limit"
          end

          children = value.is_a?(Hash) ? value.values : value
          children.each do |child|
            pending << [child, depth + 1] if child.is_a?(Hash) || child.is_a?(Array)
          end
        end
        nodes
      end
    end

    class Session # :nodoc:
      attr_reader :client

      def initialize(client)
        @client = client
        @closed = false
        @unavailable = false
        @close_mutex = Mutex.new
        @request_mutex = Mutex.new if stdio?
      end

      def request(context: nil)
        ensure_available!
        return yield unless @request_mutex

        until @request_mutex.try_lock
          context&.check!
          sleep 0.01
        end
        ensure_available!
        yield
      rescue ::MCP::CancelledError
        invalidate! if stdio?
        raise
      ensure
        @request_mutex&.unlock if @request_mutex&.owned?
      end

      def close
        should_close = @close_mutex.synchronize do
          next false if @closed

          @closed = true
          true
        end
        client.transport.close if should_close && client.transport.respond_to?(:close)
      end

      private

      def invalidate!
        @close_mutex.synchronize { @unavailable = true }
        close
      end

      def ensure_available!
        unavailable = @close_mutex.synchronize { @unavailable }
        raise ProviderError, "MCP stdio session is unavailable after cancellation" if unavailable
      end

      def stdio?
        transport = client.transport
        transport = transport.transport if transport.is_a?(CatalogValidatingTransport)
        defined?(::MCP::Client::Stdio) && transport.is_a?(::MCP::Client::Stdio)
      end
    end

    class Adapter # :nodoc:
      MAX_TOOL_NAME_LENGTH = 64
      ALIAS_DIGEST_LENGTH = 12
      MAX_TOOLS = 1_000
      MAX_TOOL_PAGES = 100
      CONTEXT_POLL_INTERVAL = 0.05

      def initialize(client:, session:, name: "mcp", tool_mapper: nil, result_mapper: nil)
        @client = client
        @session = session
        @name = String(name)
        @tool_mapper = tool_mapper
        @result_mapper = result_mapper
      end

      def tools(context: nil, binding: Tool::Binding.new)
        context&.check!
        generated = discover_tools(context:).filter_map do |mcp_tool|
          context&.check!
          build_tool(mcp_tool, binding:)
        end
        validate_tool_names!(generated, context:)
        generated.freeze
      rescue ::MCP::CancelledError
        context&.check!
        raise CancelledError, "The MCP request was cancelled"
      rescue ::MCP::Client::ServerError => error
        raise ToolError, error.message.to_s.empty? ? framework_prompt(binding, "mcp/errors/request_failed") : error.message
      rescue ::MCP::Client::PaginationLimitError => error
        raise ProtocolError, "MCP tools/list exceeded the pagination limit: #{error.message}"
      rescue ::MCP::Client::ValidationError, ::MCP::Client::InputRequiredError => error
        raise ProtocolError, "MCP client rejected the response: #{error.message}"
      rescue ::MCP::Client::RequestHandlerError => error
        raise ProviderError, "MCP transport failed (#{error.error_type})"
      end

      def call(mcp_tool, arguments, context:, binding:)
        context&.check!
        response = request(context:) do |cancellation|
          @client.call_tool(name: mcp_tool.name, arguments:, cancellation:)
        end
        result = response.is_a?(Hash) && response["result"]
        raise ProtocolError, "MCP tools/call did not return a result object" unless result.is_a?(Hash)

        content = result.fetch("content", [])
        validate_content!(content)
        value = default_value(result, content:)
        mapped = if @result_mapper
          @result_mapper.call(value, result:, mcp_tool:, arguments:, binding:)
        else
          value
        end
        context&.check!
        tool_result(mapped, result:, content:, binding:)
      rescue ::MCP::CancelledError
        context&.check!
        raise CancelledError, "The MCP request was cancelled"
      rescue ::MCP::Client::ServerError => error
        raise ToolError, error.message.to_s.empty? ? framework_prompt(binding, "mcp/errors/request_failed") : error.message
      rescue ::MCP::Client::ValidationError, ::MCP::Client::InputRequiredError => error
        raise ProtocolError, "MCP client rejected the response: #{error.message}"
      rescue ::MCP::Client::RequestHandlerError => error
        raise ProviderError, "MCP transport failed (#{error.error_type})"
      end

      private

      def discover_tools(context:)
        request(context:) do |cancellation|
          cursor = nil
          discovered = []
          pages = 0
          loop do
            pages += 1
            if pages > MAX_TOOL_PAGES
              raise ProtocolError, "MCP tools/list exceeded the #{MAX_TOOL_PAGES}-page limit"
            end
            page = @client.list_tools(cursor:, cancellation:)
            if discovered.length + page.tools.length > MAX_TOOLS
              raise ProtocolError, "MCP tools/list exceeded the #{MAX_TOOLS}-tool limit"
            end

            discovered.concat(page.tools)
            cursor = page.next_cursor
            break unless cursor

            context&.check!
          end
          discovered
        end
      end

      def request(context:)
        @session.request(context:) do
          request_with_cancellation(context:) { |cancellation| yield(cancellation) }
        end
      end

      def request_with_cancellation(context:)
        return yield(nil) unless context

        context.check!
        cancellation = ::MCP::Cancellation.new
        finished = false
        watcher_mutex = Mutex.new
        watcher_condition = ConditionVariable.new
        watcher = Thread.new do
          loop do
            done = watcher_mutex.synchronize do
              watcher_condition.wait(watcher_mutex, CONTEXT_POLL_INTERVAL) unless finished
              finished
            end
            break if done
            if context.cancellation_token.cancelled?
              cancellation.cancel(reason: "LittleGhost run cancelled")
              break
            end
            if context.deadline && Time.now >= context.deadline
              cancellation.cancel(reason: "LittleGhost run deadline reached")
              break
            end
          end
        end
        watcher.report_on_exception = false
        yield(cancellation).tap { context.check! }
      ensure
        if watcher
          watcher_mutex.synchronize do
            finished = true
            watcher_condition.broadcast
          end
          watcher.join
        end
      end

      def build_tool(mcp_tool, binding:)
        validate_mcp_tool!(mcp_tool)
        adapter = self
        session = @session
        tool_class = Class.new(Tool) do
          tool_name adapter.send(:safe_name, mcp_tool.name)
          description adapter.send(:description_for, mcp_tool, binding:)
          input_schema mcp_tool.input_schema || {"type" => "object"}
          self.validate_input_schema_value = false

          define_singleton_method(:mcp_tool) { mcp_tool }
          define_method(:call) do |input|
            adapter.call(mcp_tool, input, context:, binding: self.binding)
          end
          define_method(:close) { session.close }
        end
        return tool_class unless @tool_mapper

        mapped = @tool_mapper.call(tool_class, mcp_tool:, binding:)
        return if mapped.nil?
        unless mapped.is_a?(Class) && mapped <= tool_class
          raise ConfigurationError, "MCP tool mapper must return the generated Tool class, a subclass, or nil"
        end

        mapped
      end

      def validate_mcp_tool!(mcp_tool)
        unless mcp_tool.is_a?(::MCP::Client::Tool)
          raise ProtocolError, "MCP tools/list returned an unsupported tool value"
        end
        unless mcp_tool.name.is_a?(String) && !mcp_tool.name.empty?
          raise ProtocolError, "MCP tool definition must include a name"
        end
        unless mcp_tool.input_schema.nil? || mcp_tool.input_schema.is_a?(Hash)
          raise ProtocolError, "MCP tool inputSchema must be an object"
        end
      end

      def safe_name(name)
        normalized = name.gsub(/[^a-zA-Z0-9_-]/, "_")
        raise ConfigurationError, "MCP tool name cannot be empty" if normalized.empty?
        return normalized if normalized.length <= MAX_TOOL_NAME_LENGTH

        digest = Digest::SHA256.hexdigest(normalized)[0, ALIAS_DIGEST_LENGTH]
        prefix_length = MAX_TOOL_NAME_LENGTH - ALIAS_DIGEST_LENGTH - 1
        "#{normalized[0, prefix_length]}_#{digest}"
      end

      def description_for(mcp_tool, binding:)
        description = mcp_tool.description.to_s
        return description unless description.empty?

        framework_prompt(binding, "mcp/tools/fallback/description", server_name: @name)
      end

      def validate_tool_names!(tools, context:)
        indexed = {}
        tools.each do |tool_class|
          context&.check!
          name = tool_class.tool_name
          existing = indexed[name]
          if existing && existing.mcp_tool.name != tool_class.mcp_tool.name
            raise ConfigurationError,
              "MCP tools #{existing.mcp_tool.name.inspect} and #{tool_class.mcp_tool.name.inspect} map to #{name.inspect}"
          end
          indexed[name] = tool_class
        end
      end

      def validate_content!(content)
        raise ProtocolError, "MCP tool result content must be an array" unless content.is_a?(Array)

        content.each do |block|
          raise ProtocolError, "MCP tool result content blocks must be objects" unless block.is_a?(Hash)
          raise ProtocolError, "MCP tool result content blocks must include a type" unless block["type"].is_a?(String)
          if block["type"] == "text" && !block["text"].is_a?(String)
            raise ProtocolError, "MCP text content must include text"
          end
        end
      end

      def tool_result(mapped, result:, content:, binding:)
        error = result["isError"]
        unless error.nil? || error == true || error == false
          raise ProtocolError, "MCP tool result isError must be boolean"
        end

        media = image_artifacts(content)
        value, artifacts = if mapped.is_a?(Tool::Result)
          [mapped.value, [*mapped.artifacts, *media]]
        else
          [mapped, media]
        end
        raise ToolError, serialize_value(value, binding:) if error

        Tool::Result.new(value:, artifacts:)
      end

      def default_value(result, content:)
        return result["structuredContent"] if result.key?("structuredContent")

        text = content.filter_map { |block| block["text"] if block["type"] == "text" }.join("\n")
        return text unless text.empty?

        visible = content.reject { |block| block["type"] == "image" }
        return visible unless visible.empty?

        {
          "images" => content.filter_map do |block|
            next unless block["type"] == "image"

            {
              "mediaType" => block["mimeType"],
              "name" => block["name"],
              "bytes" => strict_base64_bytesize(block["data"])
            }.compact
          end
        }
      rescue ArgumentError
        raise ProtocolError, "MCP image content data must use strict base64"
      end

      def image_artifacts(content)
        content.filter_map do |block|
          next unless block["type"] == "image"

          data = block["data"]
          media_type = block["mimeType"]
          unless data.is_a?(String) && media_type.is_a?(String) && media_type.start_with?("image/")
            raise ProtocolError, "MCP image content is invalid"
          end
          strict_base64_bytesize(data)
          Artifact.new(data: Base64.strict_decode64(data), media_type:, name: block["name"])
        rescue ArgumentError
          raise ProtocolError, "MCP image content data must use strict base64"
        end
      end

      def strict_base64_bytesize(data)
        raise ArgumentError unless data.is_a?(String) && (data.bytesize % 4).zero?
        unless /\A(?:[A-Za-z0-9+\/]{4})*(?:[A-Za-z0-9+\/]{2}==|[A-Za-z0-9+\/]{3}=)?\z/.match?(data)
          raise ArgumentError
        end

        padding = if data.end_with?("==")
          2
        elsif data.end_with?("=")
          1
        else
          0
        end
        (data.bytesize / 4 * 3) - padding
      end

      def serialize_value(value, binding:)
        case value
        when String then value
        when nil then ""
        when Hash, Array then JSON.generate(value)
        else value.to_s
        end
      rescue JSON::GeneratorError
        raise ToolError, framework_prompt(binding, "mcp/errors/transformation_unserializable")
      end

      def framework_prompt(binding, key, **locals)
        return binding.agent.render_framework_prompt(key, **locals) if binding.agent.is_a?(Agent)

        FrameworkPrompts.for_runtime(binding.runtime).render(key, locals:)
      end
    end
  end
end
