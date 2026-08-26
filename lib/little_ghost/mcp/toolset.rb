# frozen_string_literal: true

module LittleGhost
  module MCP
    # Loads remote {Tool classes}[rdoc-ref:LittleGhost::Tool] through an
    # application-created official MCP::Client.
    # The client factory runs during Tool discovery with the current
    # Tool::Binding. It must return a fresh, unconnected client without starting
    # remote work. After the factory returns, LittleGhost connects the client,
    # shares it among the generated Tool instances, and calls +close+ on its
    # transport, when supported, as the owning run or ToolRegistry closes.
    #
    # Discovery and Tool calls carry the run's cancellation and deadline into
    # the SDK. The official SDK executes cancellable requests on worker threads.
    # Calls through the official HTTP transport may overlap. When the official
    # stdio transport is supplied directly, calls are serialized and cancelling
    # one invalidates that run's session. Custom or decorated transports own
    # their serialization, cancellation-safe invalidation, and cleanup. SDK
    # handlers may run on worker or listener threads, so application callbacks
    # must support concurrent use and must not depend on the calling fiber's
    # local state. Treat handler requests as untrusted and authorize any local
    # work or data they can reach.
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
        # Declares the factory for a fresh, unconnected official MCP::Client.
        # The factory receives the current Tool::Binding. LittleGhost forwards
        # +connect_options+ to MCP::Client#connect, then calls +close+ on the
        # returned transport when it exposes that method. Calling +client+
        # without a block or options returns the inherited factory, if one is
        # configured.
        #
        # :call-seq:
        #   client() -> Proc or nil
        #   client(**connect_options) { |binding| ... } -> Proc
        def client(**connect_options, &factory)
          return client_factory_value if !factory && connect_options.empty?
          raise ArgumentError, "client requires a factory block" unless factory

          self.connect_options_value = connect_options.dup.freeze
          self.client_factory_value = factory
        end

        # Maps each generated Tool class before it is bound to the Agent.
        # The block receives the generated class, the official
        # MCP::Client::Tool as +mcp_tool:+, and the current +binding:+. Return
        # the class, a subclass, or +nil+ to omit it. Renaming the class does not
        # change the operation name sent to the server. With no block, returns
        # the inherited mapping, if one is configured.
        #
        # :call-seq:
        #   map_tool() -> Proc or nil
        #   map_tool { |tool_class, mcp_tool:, binding:| ... } -> Proc
        def map_tool(&mapping)
          return tool_mapping_value unless mapping

          self.tool_mapping_value = mapping
        end

        # Maps the value produced by LittleGhost's default result conversion.
        # The block also receives the raw <tt>tools/call</tt> +result:+ Hash, the
        # official +mcp_tool:+, the submitted +arguments:+, and the current
        # +binding:+. Return any Ruby value or Tool::Result. With no block,
        # returns the inherited mapping, if one is configured.
        #
        # :call-seq:
        #   map_result() -> Proc or nil
        #   map_result { |value, result:, mcp_tool:, arguments:, binding:| ... } -> Proc
        def map_result(&mapping)
          return result_mapping_value unless mapping

          self.result_mapping_value = mapping
        end

        # Makes expected provider and protocol discovery failures produce no
        # tools. Configuration, cancellation, deadline, and callback failures
        # still propagate. With no argument, reports whether discovery is
        # optional.
        #
        # :call-seq:
        #   optional() -> true or false
        #   optional(value) -> true or false
        def optional(value = UNSET)
          return optional_value if value.equal?(UNSET)

          self.optional_value = !!value
        end

        # Observes an expected discovery failure caught by <tt>optional true</tt>.
        # The block receives the translated LittleGhost error and the current
        # +binding:+. Exceptions raised by the block propagate. With no block,
        # returns the inherited callback, if one is configured.
        #
        # :call-seq:
        #   on_error() -> Proc or nil
        #   on_error { |error, binding:| ... } -> Proc
        def on_error(&callback)
          return error_callback_value unless callback

          self.error_callback_value = callback
        end

        # Connects the configured client and returns Tool classes for +binding+.
        # When the binding has a run, the run owns the shared client session.
        # Otherwise, the ToolRegistry that resolves the returned classes closes
        # the session through its generated Tool instances. A caller that
        # bypasses ToolRegistry must instantiate and close a returned class.
        #
        # Expected discovery failures return an empty Array when
        # <tt>optional true</tt>. After the factory returns a client, later
        # failures call +close+ when its transport exposes that method; failures
        # then propagate unless they are optional.
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
