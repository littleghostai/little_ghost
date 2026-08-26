# frozen_string_literal: true

module LittleGhost
  module MCP
    # Connects one MCP server to an Agent through an application-created
    # official MCP::Client. LittleGhost owns the client for the current run.
    #
    #   class HelpCenterTools < LittleGhost::MCP::Toolset
    #     client do |_binding|
    #       transport = MCP::Client::HTTP.new(url: "https://mcp.example/rpc")
    #       MCP::Client.new(transport:)
    #     end
    #   end
    class Toolset
      extend Support::ClassAttributes

      UNSET = Object.new.freeze # :nodoc:

      class CallbackFailure < Error # :nodoc:
        attr_reader :original

        def initialize(original)
          @original = original
          super(original.message)
        end
      end

      class_attribute :client_factory_value
      class_attribute :connect_options_value, default: {}.freeze
      class_attribute :tool_mapping_value
      class_attribute :result_mapping_value
      class_attribute :optional_value, default: false
      class_attribute :error_callback_value

      class << self
        # Declares a factory for a fresh, unconnected official MCP::Client.
        # Keyword arguments are forwarded to MCP::Client#connect.
        def client(**connect_options, &factory)
          return client_factory_value if !factory && connect_options.empty?
          raise ArgumentError, "client requires a factory block" unless factory

          self.connect_options_value = connect_options.dup.freeze
          self.client_factory_value = factory
        end

        # Maps each generated Tool class. Return the class, a subclass, or nil
        # to omit it. +mcp_tool+ is the official MCP::Client::Tool.
        def map_tool(&mapping)
          return tool_mapping_value unless mapping

          self.tool_mapping_value = mapping
        end

        # Maps the default converted value. +result+ is the raw tools/call
        # result object and +mcp_tool+ is the official MCP::Client::Tool.
        def map_result(&mapping)
          return result_mapping_value unless mapping

          self.result_mapping_value = mapping
        end

        # Makes expected provider and protocol discovery failures produce no
        # tools. Configuration, cancellation, deadline, and callback failures
        # still propagate.
        def optional(value = UNSET)
          return optional_value if value.equal?(UNSET)

          self.optional_value = !!value
        end

        # Observes an expected discovery failure caught by <tt>optional true</tt>.
        def on_error(&callback)
          return error_callback_value unless callback

          self.error_callback_value = callback
        end

        # Generates Tool classes for an Agent's current binding.
        def tools(binding)
          context = binding.run&.context
          context&.check!
          official_client = build_client(binding)
          session = Session.new(official_client)
          connect_client(official_client, context:)
          binding.run&.register(session)

          Instrumentation.instrument(:mcp_discovery, toolset: toolset_name) do |telemetry|
            adapter = Adapter.new(
              client: official_client,
              session:,
              name: toolset_name,
              tool_mapper: wrapped_tool_mapper,
              result_mapper: wrapped_result_mapper
            )
            discovered = adapter.tools(context:, binding:)
            session.close if discovered.empty? && !binding.run
            telemetry[:outcome] = :success
            telemetry[:tool_count] = discovered.length
            discovered
          end
        rescue CallbackFailure => error
          session&.close
          raise error.original
        rescue ProviderError, ProtocolError, ToolError => error
          session&.close
          raise unless optional_value

          error_callback_value&.call(error, binding:)
          []
        rescue
          session&.close
          raise
        end

        private

        def build_client(binding)
          factory = client_factory_value
          raise ConfigurationError, "#{toolset_name} must declare an MCP client factory" unless factory

          value = invoke_application_callback { factory.call(binding) }
          unless value.is_a?(::MCP::Client)
            close_transport(value)
            raise ConfigurationError, "#{toolset_name} client factory must return an MCP::Client"
          end
          if value.transport.respond_to?(:connected?) && value.connected?
            close_transport(value)
            raise ConfigurationError, "#{toolset_name} client factory must return an unconnected MCP::Client"
          end

          install_catalog_validation(value)
          value
        end

        def install_catalog_validation(client)
          validated = CatalogValidatingTransport.new(client.transport)
          client.instance_variable_set(:@transport, validated)
          unless client.transport.equal?(validated)
            validated.close if validated.respond_to?(:close)
            raise DependencyError, "The installed MCP client does not expose a compatible transport"
          end
        end

        def connect_client(client, context:)
          context&.check!
          client.connect(**connect_options_value)
          context&.check!
        rescue ::MCP::Client::ServerError, ::MCP::Client::ValidationError => error
          raise ProtocolError, "MCP client rejected the server handshake: #{error.message}"
        rescue ::MCP::Client::RequestHandlerError => error
          raise ProviderError, "MCP transport failed (#{error.error_type})"
        rescue ArgumentError => error
          raise ConfigurationError, "MCP connection is invalid: #{error.message}"
        end

        def wrapped_tool_mapper
          mapper = tool_mapping_value
          return unless mapper

          lambda do |tool_class, mcp_tool:, binding:|
            invoke_application_callback do
              mapper.call(tool_class, mcp_tool:, binding:)
            end
          end
        end

        def wrapped_result_mapper
          result_mapping_value
        end

        def close_transport(value)
          transport = value.respond_to?(:transport) ? value.transport : value
          transport.close if transport&.respond_to?(:close)
        end

        def invoke_application_callback
          yield
        rescue ProviderError, ProtocolError, ToolError => error
          raise CallbackFailure.new(error)
        end

        def toolset_name
          name || "MCP Toolset"
        end
      end
    end
  end
end
