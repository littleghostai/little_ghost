# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "net/http"

module LittleGhost
  module MCP
    JSON_SCHEMA_2020_12_URI = "https://json-schema.org/draft/2020-12/schema" # :nodoc:

    module Dependencies # :nodoc:
      REQUIREMENTS = {
        "faraday" => "`gem \"faraday\", \"~> 2.0\"`",
        "event_stream_parser" => "`gem \"event_stream_parser\", \"~> 1.0\"`",
        "aws-sigv4" => "`gem \"aws-sigv4\"`"
      }.freeze

      module_function

      def raise_for(error)
        dependency = REQUIREMENTS.keys.find do |name|
          error.path == name || error.message.include?(name)
        end
        raise error unless dependency

        raise DependencyError,
          "MCP integration requires the optional #{dependency} gem for this configuration. " \
            "Add #{REQUIREMENTS.fetch(dependency)} to your bundle.",
          cause: error
      end
    end

    class CapturingTransport # :nodoc:
      attr_reader :transport

      def initialize(transport)
        @transport = transport
        @captured_tools = []
        @capture_mutex = Mutex.new
      end

      def connect(client_info: nil, protocol_version: nil, capabilities: {}, mode: :legacy)
        return unless transport.respond_to?(:connect)

        values = {client_info:, protocol_version:, capabilities:, mode:}
        parameters = transport.method(:connect).parameters
        unless parameters.any? { |kind, _name| kind == :keyrest }
          accepted = parameters.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }
          values.select! { |name, _value| accepted.include?(name) }
        end
        transport.connect(**values)
      end

      def send_request(request:, &sent)
        response = transport.send_request(request:, &sent)
        capture_tools(request, response)
        response
      end

      def reset_tool_capture
        @capture_mutex.synchronize { @captured_tools.clear }
      end

      def captured_tools
        @capture_mutex.synchronize { @captured_tools.dup }
      end

      def method_missing(name, ...)
        return super unless transport.respond_to?(name)

        transport.public_send(name, ...)
      end

      def respond_to_missing?(name, include_private = false)
        transport.respond_to?(name, include_private) || super
      end

      private

      def capture_tools(request, response)
        method = request[:method] || request["method"]
        return unless method == "tools/list"
        unless response.is_a?(Hash)
          raise ::MCP::Client::ValidationError, "tools/list response must be an object"
        end

        return if response.key?("error") || response.key?(:error)

        result = response["result"] || response[:result]
        unless result.is_a?(Hash)
          raise ::MCP::Client::ValidationError, "tools/list result must be an object"
        end

        tools = result["tools"] || result[:tools]
        unless tools.is_a?(Array) && tools.all? { |tool| tool.is_a?(Hash) }
          raise ::MCP::Client::ValidationError, "tools/list tools must be an array of objects"
        end

        @capture_mutex.synchronize { @captured_tools.concat(tools) }
      end
    end

    class Connection # :nodoc:
      attr_reader :client, :capture

      def initialize(client:, capture: nil, serialize_requests: false)
        @client = client
        @capture = capture
        @closed = false
        @mutex = Mutex.new
        @request_mutex = serialize_requests ? Mutex.new : nil
      end

      def synchronize_request(context: nil)
        return yield unless @request_mutex

        until @request_mutex.try_lock
          context&.check!
          sleep 0.01
        end
        yield
      ensure
        @request_mutex&.unlock if @request_mutex&.owned?
      end

      def close
        should_close = @mutex.synchronize do
          next false if @closed

          @closed = true
          true
        end
        client.transport.close if should_close && client.transport.respond_to?(:close)
      end
    end

    class Adapter # :nodoc:
      PreparedDefinition = Data.define(
        :definition,
        :input_schema,
        :input_schemer,
        :output_schemer
      )

      MAX_TOOL_NAME_LENGTH = 64
      ALIAS_DIGEST_LENGTH = 12
      DEFAULT_MAX_TOOLS = 1_000
      DEFAULT_MAX_DISCOVERY_BYTES = 10 * 1024 * 1024
      DEFAULT_MAX_DISCOVERY_NODES = 100_000
      DEFAULT_MAX_DEFINITION_DEPTH = 64
      DEFAULT_MAX_DEFINITION_NODES = 10_000
      DEFAULT_MAX_SCHEMA_PATTERNS = 1_000
      DEFAULT_MAX_SCHEMA_PATTERN_BYTES = 1024 * 1024
      DEFAULT_MAX_SCHEMA_PATTERN_SOURCE_BYTES = 64 * 1024
      DEFAULT_MAX_IMAGES = 20
      DEFAULT_MAX_IMAGE_BYTES = 16 * 1024 * 1024
      DEFAULT_MAX_TOTAL_IMAGE_BYTES = 64 * 1024 * 1024
      CONTEXT_POLL_INTERVAL = 0.05
      ECMA_REGEXP_RESOLVER = lambda do |pattern|
        source = JSONSchemer::EcmaRegexp.ruby_equivalent(pattern)
        Regexp.new(source, timeout: Tool::SchemaValidator::REGEXP_TIMEOUT)
      end

      def initialize(client:, connection:, capture: nil, name: "mcp", tool_mapper: nil, result_mapper: nil)
        validate_callback(tool_mapper, :tool_mapper)
        validate_callback(result_mapper, :result_mapper)

        @client = client
        @connection = connection
        @capture = capture
        @name = String(name)
        @tool_mapper = tool_mapper
        @result_mapper = result_mapper
      end

      def tools(context: nil, binding: Tool::Binding.new)
        context&.check!
        @capture&.reset_tool_capture
        sdk_tools = request(context:) { |cancellation| @client.tools(cancellation:) }
        raw_by_name = raw_definitions_by_name(@capture&.captured_tools || [])
        discovery_bytes = 0
        discovery_nodes = 0
        prepared = sdk_tools.map do |sdk_tool|
          context&.check!
          raw = raw_by_name[sdk_tool.name]&.shift || sdk_tool_value(sdk_tool)
          bytes, nodes = definition_complexity(raw, context:)
          discovery_bytes += bytes
          discovery_nodes += nodes
          if discovery_bytes > DEFAULT_MAX_DISCOVERY_BYTES
            raise ProtocolError, "MCP tools/list exceeded the #{DEFAULT_MAX_DISCOVERY_BYTES}-byte definition limit"
          end
          if discovery_nodes > DEFAULT_MAX_DISCOVERY_NODES
            raise ProtocolError, "MCP tools/list exceeded the #{DEFAULT_MAX_DISCOVERY_NODES}-node definition limit"
          end

          build_definition(raw:, context:)
        end
        if prepared.length > DEFAULT_MAX_TOOLS
          raise ProtocolError, "MCP tools/list exceeded #{DEFAULT_MAX_TOOLS} tools"
        end

        generated = prepared.filter_map do |definition|
          context&.check!
          build_tool(definition, binding:).tap { context&.check! }
        end
        validate_tool_names!(generated, context:)
        generated.freeze
      rescue LoadError => error
        Dependencies.raise_for(error)
      rescue ::MCP::CancelledError
        context&.check!
        raise CancelledError, "The MCP request was cancelled"
      rescue ::MCP::Client::ServerError => error
        raise ToolError, error.message.to_s.empty? ? "MCP request failed" : error.message
      rescue ::MCP::Client::PaginationLimitError => error
        raise ProtocolError, "MCP tools/list exceeded the pagination limit: #{error.message}"
      rescue ::MCP::Client::ValidationError, ::MCP::Client::InputRequiredError => error
        raise ProtocolError, "MCP client rejected the response: #{error.message}"
      rescue ::MCP::Client::RequestHandlerError => error
        raise ProviderError, "MCP transport failed (#{error.error_type})"
      end

      def call(prepared, arguments, context:, binding:)
        context&.check!
        call_value = Call.new(definition: prepared.definition, arguments:, context:, binding:)
        validate_arguments!(call_value.arguments, prepared:)
        response = request(context:) do |cancellation|
          @client.call_tool(
            name: prepared.definition.source_name,
            arguments: call_value.arguments.to_h,
            cancellation:
          )
        end
        raw = response.is_a?(Hash) && response["result"]
        raise ProtocolError, "MCP tools/call did not return a result object" unless raw.is_a?(Hash)

        result = build_result(raw, prepared:)
        context&.check!
        mapped = if @result_mapper
          @result_mapper.call(result, call: call_value, binding:)
        else
          default_value(result)
        end
        context&.check!
        tool_result(mapped, protocol_result: result)
      rescue LoadError => error
        Dependencies.raise_for(error)
      rescue ::MCP::CancelledError
        context&.check!
        raise CancelledError, "The MCP request was cancelled"
      rescue ::MCP::Client::ServerError => error
        raise ToolError, error.message.to_s.empty? ? "MCP request failed" : error.message
      rescue ::MCP::Client::ValidationError, ::MCP::Client::InputRequiredError => error
        raise ProtocolError, "MCP client rejected the response: #{error.message}"
      rescue ::MCP::Client::RequestHandlerError => error
        raise ProviderError, "MCP transport failed (#{error.error_type})"
      end

      private

      def request(context:)
        @connection.synchronize_request(context:) do
          request_with_cancellation(context:) { |cancellation| yield(cancellation) }
        end
      end

      def request_with_cancellation(context:)
        return yield(nil) unless context

        context.check!
        cancellation = ::MCP::Cancellation.new
        finished = false
        finish_mutex = Mutex.new
        watcher = Thread.new do
          loop do
            break if finish_mutex.synchronize { finished }
            if context.cancellation_token.wait(CONTEXT_POLL_INTERVAL)
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
          finish_mutex.synchronize { finished = true }
          watcher.join
        end
      end

      def raw_definitions_by_name(values)
        values.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |raw, indexed|
          next unless raw.is_a?(Hash)

          name = raw["name"] || raw[:name]
          indexed[name] << raw if name.is_a?(String)
        end
      end

      def sdk_tool_value(tool)
        {
          "name" => tool.name,
          "description" => tool.description,
          "inputSchema" => tool.input_schema || {"type" => "object"},
          "outputSchema" => tool.output_schema,
          "annotations" => tool.annotations
        }.compact
      end

      def build_definition(raw:, context:)
        context&.check!
        source_name = definition_name(raw)
        definition = Definition.new(
          source_name:,
          name: safe_name(source_name),
          description: present_description(raw["description"] || raw[:description]),
          input_schema: raw["inputSchema"] || raw[:inputSchema] || {"type" => "object"},
          output_schema: raw["outputSchema"] || raw[:outputSchema],
          annotations: raw["annotations"] || raw[:annotations] || {},
          title: raw["title"] || raw[:title],
          metadata: raw["_meta"] || raw[:_meta] || {},
          raw: stringify_keys(raw)
        )
        prepare_definition(definition, context:)
      rescue SystemStackError
        raise ProtocolError, "MCP tool definition exceeds the supported nesting limit"
      end

      def build_tool(prepared, binding:)
        definition = prepared.definition
        adapter = self
        connection = @connection
        tool_class = Class.new(Tool) do
          tool_name definition.name
          description definition.description
          input_schema prepared.input_schema
          self.validate_input_schema_value = false

          define_singleton_method(:mcp_definition) { definition }
          define_method(:call) do |input|
            adapter.call(prepared, input, context:, binding: self.binding)
          end
          define_method(:close) { connection.close }
        end
        tool_class.instance_variable_set(:@little_ghost_mcp_prepared_definition, prepared)
        return tool_class unless @tool_mapper

        mapped = @tool_mapper.call(tool_class, definition:, binding:)
        return if mapped.nil?
        unless mapped.is_a?(Class) && mapped <= tool_class
          raise ConfigurationError, "MCP tool mapper must return the generated Tool class, a subclass, or nil"
        end

        mapped.instance_variable_set(:@little_ghost_mcp_prepared_definition, prepared)
        mapped
      end

      def prepare_definition(definition, context:)
        input_schema = definition.input_schema.to_h
        normalized_input = normalized_input_schema(input_schema, context:)
        input_schemer = compile_schema(input_schema, field: "inputSchema", context:)
        output_schemer = if definition.output_schema
          compile_schema(definition.output_schema.to_h, field: "outputSchema", context:)
        end
        PreparedDefinition.new(
          definition:,
          input_schema: normalized_input,
          input_schemer:,
          output_schemer:
        )
      end

      def compile_schema(schema, field:, context:)
        schema_patterns(schema, field:, context:)
        context&.check!
        errors = JSONSchemer.validate_schema(schema, meta_schema: JSON_SCHEMA_2020_12_URI).take(10)
        unless errors.empty?
          details = errors.filter_map { |error| error["error"] }.join("; ")
          raise ProtocolError, "MCP tool #{field} is invalid: #{details}"
        end

        JSONSchemer.schema(
          schema,
          meta_schema: JSON_SCHEMA_2020_12_URI,
          regexp_resolver: ECMA_REGEXP_RESOLVER
        )
      rescue JSONSchemer::UnknownRef, JSONSchemer::InvalidRefResolution, JSONSchemer::InvalidRefPointer
        raise ProtocolError, "MCP tool #{field} contains an unresolved reference"
      rescue SystemStackError
        raise ProtocolError, "MCP tool #{field} contains unsupported recursive references"
      end

      def validate_arguments!(arguments, prepared:)
        errors = prepared.input_schemer.validate(arguments.to_h).take(10)
        return if errors.empty?

        details = errors.filter_map { |error| error["error"] }.join("; ")
        raise ToolError, "MCP tool arguments did not match inputSchema: #{details}"
      rescue JSONSchemer::UnknownRef, JSONSchemer::InvalidRefResolution, JSONSchemer::InvalidRefPointer
        raise ProtocolError, "MCP inputSchema contains an unresolved reference"
      rescue Regexp::TimeoutError
        raise ToolError, "MCP tool arguments exceeded the inputSchema pattern time limit"
      rescue SystemStackError
        raise ToolError, "MCP tool arguments exceeded the inputSchema recursion limit"
      end

      def build_result(raw, prepared:)
        values = {
          content: raw.fetch("content", []),
          error: raw["isError"],
          metadata: raw.fetch("_meta", {}),
          raw:
        }
        values[:structured_content] = raw["structuredContent"] if raw.key?("structuredContent")
        result = Result.new(**values)
        validate_result_blocks!(result.content)
        validate_structured_content!(result, prepared:)
        result
      end

      def validate_result_blocks!(content)
        content.each do |block|
          raise ProtocolError, "MCP tool result content blocks must be objects" unless block.is_a?(Hash)
          raise ProtocolError, "MCP tool result content blocks must include a type" unless block["type"].is_a?(String)
          if block["type"] == "text" && !block["text"].is_a?(String)
            raise ProtocolError, "MCP text content must include text"
          end
        end
      end

      def validate_structured_content!(result, prepared:)
        return unless prepared.output_schemer
        unless result.structured_content_provided?
          raise ProtocolError, "MCP tool result omitted structuredContent required by outputSchema"
        end

        errors = prepared.output_schemer.validate(result.structured_content).take(10)
        return if errors.empty?

        details = errors.filter_map { |error| error["error"] }.join("; ")
        raise ProtocolError, "MCP structuredContent did not match outputSchema: #{details}"
      rescue JSONSchemer::UnknownRef, JSONSchemer::InvalidRefResolution, JSONSchemer::InvalidRefPointer
        raise ProtocolError, "MCP outputSchema contains an unresolved reference"
      rescue Regexp::TimeoutError
        raise ProtocolError, "MCP structuredContent exceeded the outputSchema pattern time limit"
      rescue SystemStackError
        raise ProtocolError, "MCP structuredContent exceeded the outputSchema recursion limit"
      end

      def normalized_input_schema(schema, context:)
        normalized = JSON.parse(JSON.generate(schema))
        schema_patterns(normalized, field: "inputSchema", context:).each do |container, key, regexp|
          context&.check!
          container[key] = regexp.source if container
        end
        normalized
      rescue JSON::GeneratorError, JSON::ParserError
        raise ProtocolError, "MCP tool inputSchema is not valid JSON"
      end

      def schema_patterns(schema, field:, context:)
        patterns = []
        total_bytes = 0
        stack = [schema]
        until stack.empty?
          context&.check!
          value = stack.pop
          case value
          when Hash
            %w[$ref $dynamicRef].each do |reference_key|
              reference = value[reference_key]
              if reference.is_a?(String) && !reference.start_with?("#")
                raise ProtocolError, "MCP tool #{field} may only use same-document #{reference_key} values"
              end
            end
            if value.key?("pattern")
              pattern = value["pattern"]
              raise ProtocolError, "MCP tool #{field} pattern must be a string" unless pattern.is_a?(String)

              patterns << [value, "pattern", pattern]
            end
            pattern_properties = value["patternProperties"]
            if pattern_properties
              unless pattern_properties.is_a?(Hash)
                raise ProtocolError, "MCP tool #{field} patternProperties must be an object"
              end
              pattern_properties.each_key { |pattern| patterns << [nil, nil, pattern] }
            end
            value.each_value { |child| stack << child }
          when Array
            value.each { |child| stack << child }
          end
        end
        if patterns.length > DEFAULT_MAX_SCHEMA_PATTERNS
          raise ProtocolError, "MCP tool #{field} exceeded the #{DEFAULT_MAX_SCHEMA_PATTERNS}-pattern limit"
        end

        patterns.map do |container, key, pattern|
          context&.check!
          raise ProtocolError, "MCP tool #{field} pattern must be a string" unless pattern.is_a?(String)
          if pattern.bytesize > DEFAULT_MAX_SCHEMA_PATTERN_SOURCE_BYTES
            raise ProtocolError,
              "MCP tool #{field} pattern exceeded the #{DEFAULT_MAX_SCHEMA_PATTERN_SOURCE_BYTES}-byte limit"
          end
          total_bytes += pattern.bytesize
          if total_bytes > DEFAULT_MAX_SCHEMA_PATTERN_BYTES
            raise ProtocolError,
              "MCP tool #{field} patterns exceeded the #{DEFAULT_MAX_SCHEMA_PATTERN_BYTES}-byte total limit"
          end
          [container, key, ECMA_REGEXP_RESOLVER.call(pattern)]
        end
      rescue JSONSchemer::InvalidEcmaRegexp, RegexpError
        raise ProtocolError, "MCP tool #{field} contains an invalid pattern"
      end

      def definition_complexity(definition, context:)
        nodes = 0
        bytes = 0
        stack = [[definition, 1]]
        until stack.empty?
          value, depth = stack.pop
          if depth > DEFAULT_MAX_DEFINITION_DEPTH
            raise ProtocolError,
              "MCP tool definition exceeds the #{DEFAULT_MAX_DEFINITION_DEPTH}-level depth limit"
          end

          nodes += 1
          if nodes > DEFAULT_MAX_DEFINITION_NODES
            raise ProtocolError, "MCP tool definition exceeds the #{DEFAULT_MAX_DEFINITION_NODES}-node limit"
          end
          context&.check! if (nodes % 1_000).zero?
          case value
          when Hash
            bytes += 2
            value.each do |key, child|
              raise ProtocolError, "MCP tool definition keys must be strings" unless key.is_a?(String)

              bytes += key.bytesize + 3
              stack << [child, depth + 1]
            end
          when Array
            bytes += 2 + value.length
            value.each { |child| stack << [child, depth + 1] }
          when String
            bytes += value.bytesize + 2
          when Numeric
            bytes += value.to_s.bytesize
          when true, false
            bytes += value ? 4 : 5
          when nil
            bytes += 4
          else
            raise ProtocolError, "MCP tool definition contains a non-JSON value"
          end
        end
        [bytes, nodes]
      end

      def stringify_keys(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, child), result| result[String(key)] = stringify_keys(child) }
        when Array
          value.map { |child| stringify_keys(child) }
        else
          value
        end
      end

      def definition_name(definition)
        raise ProtocolError, "MCP tool definition must be an object" unless definition.is_a?(Hash)

        name = definition["name"] || definition[:name]
        raise ProtocolError, "MCP tool definition must include a name" unless name.is_a?(String) && !name.empty?

        name
      end

      def safe_name(name)
        normalized = name.gsub(/[^a-zA-Z0-9_-]/, "_")
        raise ConfigurationError, "MCP tool name cannot be empty" if normalized.empty?
        return normalized if normalized.length <= MAX_TOOL_NAME_LENGTH

        digest = Digest::SHA256.hexdigest(normalized)[0, ALIAS_DIGEST_LENGTH]
        prefix_length = MAX_TOOL_NAME_LENGTH - ALIAS_DIGEST_LENGTH - 1
        "#{normalized[0, prefix_length]}_#{digest}"
      end

      def present_description(description)
        value = description.to_s
        value.empty? ? "MCP tool from #{@name}" : value
      end

      def validate_tool_names!(tools, context:)
        indexed = {}
        tools.each do |tool_class|
          context&.check!
          definition = tool_class.mcp_definition
          name = tool_class.tool_name
          existing = indexed[name]
          if existing && existing.definition.source_name != definition.source_name
            raise ConfigurationError,
              "MCP tools #{existing.definition.source_name.inspect} and #{definition.source_name.inspect} map to #{name.inspect}"
          end
          indexed[name] = tool_class.instance_variable_get(:@little_ghost_mcp_prepared_definition)
        end
      end

      def tool_result(mapped, protocol_result:)
        media = image_artifacts(protocol_result.content)
        mapped = default_value(mapped) if mapped.is_a?(Result)
        value, artifacts = if mapped.is_a?(Tool::Result)
          [mapped.value, [*mapped.artifacts, *media]]
        else
          [mapped, media]
        end
        raise ToolError, serialize_value(value) if protocol_result.error?

        Tool::Result.new(value:, artifacts:)
      end

      def default_value(result)
        return result.structured_content if result.structured_content_provided?

        text = result.content.filter_map { |block| block["text"] if block["type"] == "text" }.join("\n")
        return text unless text.empty?

        visible = result.content.reject { |block| block["type"] == "image" }
        return visible unless visible.empty?

        ImmutableValue.mapping({
          "images" => result.content.filter_map do |block|
            next unless block["type"] == "image"

            {
              "mediaType" => block["mimeType"],
              "name" => block["name"],
              "bytes" => strict_base64_bytesize(block["data"])
            }.compact
          end
        }, field: "image result")
      end

      def image_artifacts(content)
        images = content.select { |block| block["type"] == "image" }
        if images.length > DEFAULT_MAX_IMAGES
          raise ProtocolError, "MCP image content exceeds the #{DEFAULT_MAX_IMAGES}-image limit"
        end

        total_bytes = 0
        images.map do |block|
          data = block["data"]
          media_type = block["mimeType"]
          unless data.is_a?(String) && media_type.is_a?(String) && media_type.start_with?("image/")
            raise ProtocolError, "MCP image content is invalid"
          end
          decoded_bytes = strict_base64_bytesize(data)
          if decoded_bytes > DEFAULT_MAX_IMAGE_BYTES
            raise ProtocolError, "MCP image content exceeds the #{DEFAULT_MAX_IMAGE_BYTES}-byte per-image limit"
          end
          total_bytes += decoded_bytes
          if total_bytes > DEFAULT_MAX_TOTAL_IMAGE_BYTES
            raise ProtocolError, "MCP image content exceeds the #{DEFAULT_MAX_TOTAL_IMAGE_BYTES}-byte total limit"
          end
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

      def serialize_value(value)
        case value
        when String then value
        when nil then ""
        when Hash, Array then JSON.generate(value)
        else value.to_s
        end
      rescue JSON::GeneratorError
        raise ToolError, "MCP result transformation could not be serialized"
      end

      def validate_callback(value, name)
        return unless value
        raise ArgumentError, "#{name} must respond to call" unless value.respond_to?(:call)
      end
    end

    class SignerMiddleware # :nodoc:
      def initialize(app, signer)
        @app = app
        @signer = signer
      end

      def call(environment)
        request = Net::HTTP::Post.new(environment.url)
        environment.request_headers.each { |name, value| request[name] = value }
        request.body = environment.body.to_s
        @signer.call(request)
        request.to_hash.each { |name, values| environment.request_headers[name] = Array(values).join(",") }
        @app.call(environment)
      end
    end

    # SigV4Signer adds AWS Signature Version 4 authentication to MCP requests.
    # Requires the application-provided +aws-sigv4+ gem and uses its normal AWS
    # credentials-provider chain unless one is supplied explicitly.
    class SigV4Signer
      # Configures signing for +service+ and +region+.
      def initialize(service:, region:, credentials_provider: nil)
        require "aws-sigv4"
        @signer = Aws::Sigv4::Signer.new(service:, region:, credentials_provider:)
      rescue LoadError => error
        Dependencies.raise_for(error)
      end

      # Signs +request+ in place immediately before transport.
      def call(request)
        signature = @signer.sign_request(
          http_method: request.method,
          url: request.uri,
          headers: request.to_hash.transform_values { |values| Array(values).join(",") },
          body: request.body
        )
        signature.headers.each { |name, value| request[name] = value }
      end
    end
  end
end
