# frozen_string_literal: true

require "uri"

module LittleGhost
  module MCP
    # Connects one MCP server to an Agent as a reusable Tool provider. Each Agent
    # run gets its own official MCP client. +map_tool+ chooses and configures the
    # generated Tool classes; +map_result+ converts results that need
    # application-specific handling.
    #
    #   class HelpCenterTools < LittleGhost::MCP::Toolset
    #     connection url: "https://mcp.example/rpc", timeout: 20
    #   end
    #
    #   class CustomerSupportAgent < LittleGhost::Agent
    #     tools HelpCenterTools
    #   end
    class Toolset
      extend Support::ClassAttributes

      CONNECTION_OPTIONS = %i[
        url command args env headers timeout signer allow_insecure_http
        max_response_bytes max_reconnection_wait oauth protocol_version capabilities
        inherit_env
      ].freeze # :nodoc:
      HTTP_ONLY_OPTIONS = %i[
        headers signer allow_insecure_http max_reconnection_wait oauth
      ].freeze # :nodoc:
      STDIO_ONLY_OPTIONS = %i[args env inherit_env].freeze # :nodoc:
      DEFAULT_TIMEOUT = 60 # :nodoc:
      DEFAULT_MAX_RESPONSE_BYTES = 10 * 1024 * 1024 # :nodoc:
      UNSET = Object.new.freeze # :nodoc:

      class CallbackFailure < Error # :nodoc:
        attr_reader :original

        def initialize(original)
          @original = original
          super(original.message)
        end
      end

      class_attribute :connection_value
      class_attribute :client_configuration_value
      class_attribute :tool_mapping_value
      class_attribute :result_mapping_value
      class_attribute :optional_value, default: false
      class_attribute :error_callback_value

      class << self
        # Declares a static connection Hash or a block called with the current
        # Tool::Binding. A Hash supplies either +url+ for Streamable HTTP or
        # +command+ for stdio. A block may instead return a new official or
        # custom MCP transport for the current run.
        #
        # :call-seq:
        #   connection() -> Hash, Proc, nil
        #   connection(values) -> Hash
        #   connection { |binding| ... } -> Proc
        def connection(value = UNSET, &resolver)
          return connection_value if value.equal?(UNSET) && !resolver
          raise ArgumentError, "provide a connection or a block, not both" unless value.equal?(UNSET) || !resolver
          if !value.equal?(UNSET) && transport_candidate?(value)
            raise ArgumentError, "an MCP transport must be created in a connection block so it is run-scoped"
          end

          configured = resolver || value
          unless configured.is_a?(Hash) || configured.respond_to?(:call)
            raise ArgumentError, "connection must be a hash or callable"
          end

          self.connection_value = configured.is_a?(Hash) ? normalize_connection(configured) : configured
        end

        # Configures the run-scoped official client before LittleGhost connects
        # it. Register elicitation, sampling, or roots handlers here. The
        # connection's +capabilities+ Hash is sent during negotiation.
        #
        # :call-seq:
        #   configure_client() -> Proc, nil
        #   configure_client { |client, binding:| ... } -> Proc
        def configure_client(&configuration)
          return client_configuration_value unless configuration

          self.client_configuration_value = configuration
        end

        # Maps each generated Tool class. The block receives +definition:+ and
        # +binding:+ keywords. Return the configured Tool class, or nil to omit
        # it. Changing Tool#tool_name does not change the operation name sent to
        # the MCP server.
        def map_tool(&mapping)
          return tool_mapping_value unless mapping

          self.tool_mapping_value = mapping
        end

        # Maps each immutable MCP::Result. The block receives +call:+ and
        # +binding:+ keywords and returns any Ruby value or Tool::Result.
        def map_result(&mapping)
          return result_mapping_value unless mapping

          self.result_mapping_value = mapping
        end

        # Makes expected provider and protocol discovery failures produce no
        # tools. Configuration, dependency, cancellation, deadline, and callback
        # failures still propagate.
        def optional(value = UNSET)
          return optional_value if value.equal?(UNSET)

          self.optional_value = !!value
        end

        # Observes an expected discovery failure caught by <tt>optional true</tt>.
        # Exceptions raised by this callback propagate.
        def on_error(&callback)
          return error_callback_value unless callback

          self.error_callback_value = callback
        end

        # Generates Tool classes for an Agent's current binding.
        def tools(binding)
          resolved = resolved_connection(binding)
          options = resolved.is_a?(Hash) ? connection_with_wrapped_signer(resolved) : nil
          context = binding.run&.context
          options = options_with_deadline(options, context:)
          connection = build_connection(resolved, options:)
          configure_official_client(connection.client, binding:)
          connect_official_client(connection.client, options:, context:)
          binding.run&.register(connection)
          mapper = tool_mapping_value
          result_mapper = result_mapping_value

          Instrumentation.instrument(:mcp_discovery, toolset: toolset_name) do |telemetry|
            adapter = Adapter.new(
              client: connection.client,
              connection:,
              capture: connection.capture,
              name: toolset_name,
              tool_mapper: mapper && lambda do |tool_class, definition:, binding:|
                invoke_application_callback do
                  mapper.call(tool_class, definition:, binding:)
                end
              end,
              result_mapper: result_mapper && lambda do |result, call:, binding:|
                invoke_application_callback do
                  result_mapper.call(result, call:, binding:)
                end
              end
            )
            discovered = adapter.tools(context:, binding:)
            connection.close if discovered.empty? && !binding.run
            telemetry[:outcome] = :success
            telemetry[:tool_count] = discovered.length
            discovered
          end
        rescue CallbackFailure => error
          connection&.close
          raise error.original
        rescue ProviderError, ProtocolError, ToolError => error
          connection&.close
          raise unless optional_value

          error_callback_value&.call(error, binding:)
          []
        rescue
          connection&.close
          raise
        end

        private

        def resolved_connection(binding)
          configured = connection_value
          raise ConfigurationError, "#{toolset_name} must declare an MCP connection" unless configured

          value = if configured.respond_to?(:call)
            invoke_application_callback { configured.call(binding) }
          else
            configured
          end
          if value.is_a?(::MCP::Client)
            raise ConfigurationError,
              "#{toolset_name} connection must return an MCP transport; configure the run-scoped client with configure_client"
          end
          return validate_transport!(value) if transport_candidate?(value)

          normalize_connection(value)
        end

        def normalize_connection(value)
          hash = Hash.try_convert(value)
          raise ConfigurationError, "#{toolset_name} connection must resolve to a hash or MCP::Client" unless hash

          normalized = hash.each_with_object({}) do |(name, child), result|
            key = name.to_sym
            raise ConfigurationError, "#{toolset_name} connection contains duplicate #{key}" if result.key?(key)

            result[key] = child
          end
          unknown = normalized.keys - CONNECTION_OPTIONS
          unless unknown.empty?
            raise ConfigurationError, "#{toolset_name} connection contains unknown option #{unknown.first.inspect}"
          end

          url = normalized[:url]
          command = normalized[:command]
          if present?(url) == present?(command)
            raise ConfigurationError, "#{toolset_name} connection must include exactly one of url or command"
          end

          if present?(url)
            normalize_http_connection(normalized)
          else
            normalize_stdio_connection(normalized)
          end
        rescue NoMethodError
          raise ConfigurationError, "#{toolset_name} connection keys must be strings or symbols"
        end

        def normalize_http_connection(values)
          invalid = STDIO_ONLY_OPTIONS.select { |name| values.key?(name) }
          unless invalid.empty?
            raise ConfigurationError, "#{toolset_name} HTTP connection contains stdio option #{invalid.first.inspect}"
          end

          url = String(values.fetch(:url))
          uri = URI(url)
          unless %w[http https].include?(uri.scheme) && uri.host
            raise ConfigurationError, "MCP URL must be an HTTP(S) URL"
          end
          if uri.scheme == "http" && !values[:allow_insecure_http]
            raise ConfigurationError, "MCP URL must use HTTPS unless allow_insecure_http is enabled"
          end

          values.merge(
            url: url.freeze,
            headers: normalize_headers(values.fetch(:headers, {})),
            timeout: positive_number(values.fetch(:timeout, DEFAULT_TIMEOUT), :timeout),
            max_response_bytes: positive_integer(
              values.fetch(:max_response_bytes, DEFAULT_MAX_RESPONSE_BYTES),
              :max_response_bytes
            ),
            capabilities: normalize_capabilities(values.fetch(:capabilities, {})),
            protocol_version: optional_string(values[:protocol_version])
          ).freeze
        rescue URI::InvalidURIError
          raise ConfigurationError, "MCP URL must be an HTTP(S) URL"
        end

        def normalize_stdio_connection(values)
          invalid = HTTP_ONLY_OPTIONS.select { |name| values.key?(name) }
          unless invalid.empty?
            raise ConfigurationError, "#{toolset_name} stdio connection contains HTTP option #{invalid.first.inspect}"
          end

          command = String(values.fetch(:command))
          raise ConfigurationError, "#{toolset_name} connection command cannot be empty" if command.empty?

          values.merge(
            command: command.freeze,
            args: Array(values.fetch(:args, [])).map { |value| String(value).freeze }.freeze,
            env: normalize_env(values[:env]),
            inherit_env: values.fetch(:inherit_env, true) != false,
            timeout: positive_number(values.fetch(:timeout, DEFAULT_TIMEOUT), :timeout),
            max_response_bytes: positive_integer(
              values.fetch(:max_response_bytes, DEFAULT_MAX_RESPONSE_BYTES),
              :max_response_bytes
            ),
            capabilities: normalize_capabilities(values.fetch(:capabilities, {})),
            protocol_version: optional_string(values[:protocol_version])
          ).freeze
        end

        def normalize_headers(headers)
          headers.each_with_object({}) do |(name, value), normalized|
            normalized[String(name).dup.freeze] = String(value).dup.freeze
          end.freeze
        rescue NoMethodError
          raise ConfigurationError, "#{toolset_name} connection headers must be a hash"
        end

        def normalize_env(env)
          return if env.nil?

          env.each_with_object({}) do |(name, value), normalized|
            normalized[String(name).dup.freeze] = value.nil? ? nil : String(value).dup.freeze
          end.freeze
        rescue NoMethodError
          raise ConfigurationError, "#{toolset_name} connection env must be a hash"
        end

        def normalize_capabilities(capabilities)
          hash = Hash.try_convert(capabilities)
          raise ConfigurationError, "#{toolset_name} connection capabilities must be a hash" unless hash

          hash.dup.freeze
        end

        def build_connection(resolved, options:)
          transport = if !resolved.is_a?(Hash)
            resolved
          elsif resolved[:url]
            build_http_transport(options)
          else
            ::MCP::Client::Stdio.new(
              command: options.fetch(:command),
              args: options.fetch(:args),
              env: stdio_env(options),
              read_timeout: options.fetch(:timeout),
              max_line_bytes: options.fetch(:max_response_bytes)
            )
          end
          capture = CapturingTransport.new(transport)
          client = ::MCP::Client.new(transport: capture, max_pages: 100)
          serialize_requests = !resolved.is_a?(Hash) || resolved[:command]
          Connection.new(client:, capture:, serialize_requests:)
        rescue LoadError => error
          Dependencies.raise_for(error)
        rescue ArgumentError => error
          raise ConfigurationError, "MCP connection is invalid: #{error.message}"
        end

        def build_http_transport(options)
          transport_options = {
            url: options.fetch(:url),
            headers: options.fetch(:headers),
            oauth: oauth_provider(options[:oauth]),
            max_message_bytes: options.fetch(:max_response_bytes)
          }
          if options[:max_reconnection_wait]
            transport_options[:max_reconnection_wait] = positive_number(
              options[:max_reconnection_wait],
              :max_reconnection_wait
            )
          end

          timeout = options.fetch(:timeout)
          signer = options[:signer]
          ::MCP::Client::HTTP.new(**transport_options) do |faraday|
            faraday.options.timeout = timeout
            faraday.options.open_timeout = timeout
            faraday.use(SignerMiddleware, signer) if signer
          end
        end

        def oauth_provider(value)
          return if value.nil?
          return value if value.respond_to?(:authorization_flow)

          hash = Hash.try_convert(value)
          raise ConfigurationError, "#{toolset_name} oauth must be a hash or official provider" unless hash

          options = hash.each_with_object({}) { |(key, child), result| result[key.to_sym] = child }
          grant = options.delete(:grant)&.to_sym
          provider = case grant
          when :authorization_code then ::MCP::Client::OAuth::Provider
          when :client_credentials then ::MCP::Client::OAuth::ClientCredentialsProvider
          when :jwt_bearer then ::MCP::Client::OAuth::CrossAppAccessProvider
          else
            raise ConfigurationError,
              "#{toolset_name} oauth grant must be authorization_code, client_credentials, or jwt_bearer"
          end
          provider.new(**options)
        rescue ArgumentError => error
          raise ConfigurationError, "#{toolset_name} oauth configuration is invalid: #{error.message}"
        end

        def configure_official_client(client, binding:)
          return unless client_configuration_value

          invoke_application_callback do
            client_configuration_value.call(client, binding:)
          end
        end

        def connect_official_client(client, options:, context:)
          context&.check!
          return if client.connected?

          client.connect(
            client_info: {name: "little_ghost", version: LittleGhost::VERSION},
            protocol_version: options && options[:protocol_version],
            capabilities: options ? options.fetch(:capabilities) : {}
          )
          context&.check!
        rescue LoadError => error
          Dependencies.raise_for(error)
        rescue ::MCP::Client::ServerError, ::MCP::Client::ValidationError => error
          raise ProtocolError, "MCP client rejected the server handshake: #{error.message}"
        rescue ::MCP::Client::RequestHandlerError => error
          raise ProviderError, "MCP transport failed (#{error.error_type})"
        rescue ArgumentError => error
          raise ConfigurationError, "MCP connection is invalid: #{error.message}"
        end

        def connection_with_wrapped_signer(options)
          signer = options[:signer]
          return options unless signer

          options.merge(
            signer: ->(request) { invoke_application_callback { signer.call(request) } }
          ).freeze
        end

        def options_with_deadline(options, context:)
          return options unless options && context

          options.merge(timeout: context.remaining_time(options.fetch(:timeout))).freeze
        end

        def stdio_env(options)
          configured = options[:env]
          return configured if options.fetch(:inherit_env)

          ENV.each_key.to_h { |name| [name, nil] }.merge(configured || {})
        end

        def transport_candidate?(value)
          value.respond_to?(:send_request)
        end

        def validate_transport!(value)
          missing = %i[send_notification close].reject { |name| value.respond_to?(name) }
          unless missing.empty?
            value.close if value.respond_to?(:close)
            raise ConfigurationError,
              "#{toolset_name} MCP transport must respond to #{missing.join(" and ")}"
          end

          value
        end

        def invoke_application_callback
          yield
        rescue ProviderError, ProtocolError, ToolError => error
          raise CallbackFailure.new(error)
        end

        def positive_integer(value, name)
          integer = Integer(value)
          raise ArgumentError, "#{name} must be positive" unless integer.positive?

          integer
        rescue ArgumentError, TypeError
          raise ConfigurationError, "#{toolset_name} connection #{name} must be a positive integer"
        end

        def positive_number(value, name)
          number = Float(value)
          raise ArgumentError unless number.positive?

          number
        rescue ArgumentError, TypeError
          raise ConfigurationError, "#{toolset_name} connection #{name} must be positive"
        end

        def optional_string(value)
          return if value.nil?

          string = String(value)
          raise ConfigurationError, "#{toolset_name} protocol_version cannot be empty" if string.empty?

          string.freeze
        end

        def present?(value)
          !value.nil? && !value.to_s.empty?
        end

        def toolset_name
          name || "MCP Toolset"
        end
      end
    end
  end
end
