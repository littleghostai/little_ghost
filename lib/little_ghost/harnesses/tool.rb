# frozen_string_literal: true

module LittleGhost
  module Harnesses
    # Lets an Agent delegate a coding task to an external coding-agent tool.
    #
    # The application chooses which harnesses are available, where each
    # executable lives, where its home directory is created, and placeholder
    # settings. The model supplies only the task, the harness name, an
    # optional session to resume, and a budget and timeout within the
    # configured bounds.
    #
    #   class DelegateCodingTask < LittleGhost::Harnesses::Tool
    #     tool_name "delegate_coding_task"
    #     harnesses claude_code: {
    #       executable: "/opt/harnesses/bin/claude",
    #       home_root: :scratch,
    #       defaults: {base_url: "http://127.0.0.1:3130"}
    #     }
    #     budget default: 2, maximum: 10
    #     timeout default: 900, maximum: 3600
    #   end
    #
    #   class SupportEngineerAgent < LittleGhost::Agent
    #     tools DelegateCodingTask
    #   end
    #
    # The tool runs the harness in the Run's Sandbox, or on the host in
    # +:native_guards+ mode when the Tool has no Sandbox, and publishes each
    # +:harness+ StreamEvent to the Run while the harness works; by default
    # tool-call inputs and tool outputs are left out (see #harness_event_data).
    # The harness's tool calls also become +:tool+ Instrumentation operations
    # beneath this call, so traces show the harness's work step by step.
    # It returns a JSON object with the Result's status, final text (shortened
    # to 16,000 characters), session, cost, turns, and usage, plus the end of
    # standard error when the task did not complete. Calls are exclusive, so
    # two harnesses never edit the same workspace at once.
    #
    # Each harness gets one private home directory per Run, created on first
    # use beneath a Workspace path the Sandbox lets processes write and
    # removed when the Run closes. The model may resume only sessions that an
    # earlier call in the same Run started.
    #
    # #serve_tools lets the harness call tools of the application's own while
    # it works, through a ToolServer that lives only for that call.
    #
    # Override #build_harness to choose settings per run, and #build_request
    # to add instructions, a working directory, or a turn limit.
    class Tool < LittleGhost::Tool
      DEFAULT_TIMEOUT = 600 # :nodoc:
      RESULT_TEXT_LIMIT = 16_000 # :nodoc:
      SETTINGS = %i[executable home home_root defaults mode].freeze # :nodoc:

      class_attribute :harness_settings_value, default: {}.freeze
      class_attribute :budget_default_value
      class_attribute :budget_maximum_value
      class_attribute :timeout_default_value, default: DEFAULT_TIMEOUT
      class_attribute :timeout_maximum_value, default: DEFAULT_TIMEOUT
      class_attribute :tool_server_value

      tool_name "delegate_to_harness"
      exclusive true

      class << self
        # :call-seq:
        #   harnesses()                      -> Array of Symbol
        #   harnesses(*names, **settings)    -> Array of Symbol
        #
        # Declares the available harnesses. Each name must be registered with
        # Harnesses.register. +settings+ maps a name to a Hash with
        # +:executable+, +:home_root+, +:defaults+, and +:mode+ for Base.new; a bare name uses the harness's default executable and
        # the first writable runtime path for its home. +:home+ opts in to a
        # persistent home shared by every Run, as described in Base.new.
        def harnesses(*names, **settings)
          return harness_settings_value.keys if names.empty? && settings.empty?

          values = names.flatten.to_h { |name| [name.to_sym, {}] }
          settings.each do |name, options|
            options = options.to_h.transform_keys(&:to_sym)
            unknown = options.keys - SETTINGS
            raise ArgumentError, "unknown harness settings: #{unknown.join(", ")}" unless unknown.empty?

            values[name.to_sym] = options.freeze
          end
          values.each_key { |name| Harnesses.resolve(name) }
          self.harness_settings_value = values.freeze
          harnesses
        end

        # Settings declared for harness +name+.
        def harness_settings(name) = harness_settings_value.fetch(name.to_sym, {})

        # :call-seq:
        #   budget(default:, maximum:) -> Numeric
        #
        # Lets the model choose +budget_usd+ up to +maximum+ US dollars;
        # omitted, null, or zero values use +default+. Without a budget, the
        # harness runs without a spending limit.
        def budget(default:, maximum:)
          default = positive_number(default, "budget default")
          maximum = positive_number(maximum, "budget maximum")
          raise ArgumentError, "budget default must not exceed budget maximum" if default > maximum

          self.budget_maximum_value = maximum
          self.budget_default_value = default
        end

        # :call-seq:
        #   timeout(default:, maximum:) -> Integer
        #
        # Lets the model choose +timeout_seconds+ up to +maximum+; omitted,
        # null, or zero values use +default+. The default is 600 seconds.
        def timeout(default:, maximum:)
          unless [default, maximum].all? { |value| value.is_a?(Integer) && value.positive? }
            raise ArgumentError, "timeout default and maximum must be positive integers"
          end
          raise ArgumentError, "timeout default must not exceed timeout maximum" if default > maximum

          self.timeout_maximum_value = maximum
          self.timeout_default_value = default
        end

        # :call-seq:
        #   serve_tools(*tools, socket:, url:, name: "tools") -> Hash
        #
        # Serves +tools+ to the harness during each call. Entries are Tool
        # classes, Tool instances, or provider classes, as for Agent.tools,
        # bound to this Tool's binding; override #served_tools to choose them
        # per run. The ToolServer listens on +socket+, an absolute host path,
        # and the harness connects to +url+ as MCP server +name+, so the
        # application relays +url+ to +socket+ inside the Sandbox. Every tool
        # served this way runs with the Run's credentials, without Agent
        # callbacks such as +:before_tool+; see ToolServer. Concurrent Runs
        # need separate sockets: a call fails while another serves +socket+.
        def serve_tools(*tools, socket:, url:, name: "tools")
          raise ArgumentError, "serve_tools socket must be an absolute path" unless String(socket).start_with?("/")

          Request.new(prompt: "check", mcp_servers: {name => url})
          self.tool_server_value = {tools: tools.flatten.freeze, socket: String(socket).freeze, url: String(url).freeze, name: String(name).freeze}.freeze
        end

        def description(*values) # :nodoc:
          return super unless values.empty?

          description_value || FrameworkPrompts.new.render("tools/built_in/harness/description", locals: description_locals)
        end

        def input_schema(*values) # :nodoc:
          return super unless values.empty?

          input_schema_value || generated_input_schema
        end

        def description_locals # :nodoc:
          {
            harnesses: harnesses,
            budget_default: budget_default_value,
            budget_maximum: budget_maximum_value,
            timeout_default: timeout_default_value,
            timeout_maximum: timeout_maximum_value
          }
        end

        private

        def generated_input_schema
          properties = {
            task: {type: "string", minLength: 1, description: "Complete, self-contained instructions for the coding agent."},
            harness: {type: "string", enum: harnesses.map(&:to_s), description: "Coding agent to use."},
            session_id: {type: ["string", "null"], description: "Session to continue from an earlier result."},
            timeout_seconds: {
              type: ["integer", "null"],
              minimum: 0,
              maximum: timeout_maximum_value,
              description: "Seconds before the task is stopped. Null or 0 uses #{timeout_default_value}."
            }
          }
          if budget_maximum_value
            properties[:budget_usd] = {
              type: ["number", "null"],
              minimum: 0,
              maximum: budget_maximum_value,
              description: "Maximum spend in US dollars. Null or 0 uses #{budget_default_value}."
            }
          end
          required = (harnesses.length == 1) ? ["task"] : ["task", "harness"]
          deep_freeze({type: "object", properties:, required:, additionalProperties: false})
        end

        def positive_number(value, name)
          unless value.is_a?(Numeric) && value.positive? && value.to_f.finite?
            raise ArgumentError, "#{name} must be a positive number"
          end

          value
        end
      end

      def initialize(...) # :nodoc:
        super
        @session_ledger = SessionLedger.new
      end

      # Runs the selected harness and returns its result as a Hash.
      def call(input)
        name = selected_harness(input)
        request = begin
          build_request(input, harness: name)
        rescue ArgumentError => error
          raise ToolError, error.message
        end
        if request.session_id && !session_ledger.include?(name, request.session_id)
          raise ToolError, "Only sessions started earlier in this run can be resumed."
        end
        harness = build_harness(name)
        trace = Trace.new(harness: name, parent_operation_id: trace_parent_operation_id)
        result = with_tool_server(request) do |served_request|
          harness.run(served_request, context:) do |event|
            trace.record(event)
            data = harness_event_data(event)
            run&.publish(:harness, **data) if data
          end
        end
        session_ledger.record(name, result.session_id)
        result_value(result)
      ensure
        trace&.close
      end

      def description # :nodoc:
        self.class.description_value ||
          framework_prompt("tools/built_in/harness/description", **self.class.description_locals)
      end

      private

      # Builds the Harnesses::Base for +name+ from the declared settings and
      # the bound Sandbox. Override to choose settings per run.
      def build_harness(name) # :doc:
        settings = self.class.harness_settings(name)
        harness_class = Harnesses.resolve(name)
        options = {
          sandbox:,
          executable: settings.fetch(:executable, harness_class.default_executable),
          home_root: settings[:home_root],
          defaults: settings.fetch(:defaults, {}),
          mode: settings[:mode]
        }
        harness = harness_class.new(**options)
        home = settings[:home] || run_home(name, harness)
        home ? harness_class.new(**options, home:) : harness
      end

      def trace_parent_operation_id
        ExecutionState[:tool_execution]&.operation_id || Instrumentation.current&.operation_id
      end

      # Returns the data published to the Run for one +:harness+ StreamEvent,
      # or nil to skip it. The default publishes tool calls with only their
      # identifier and name, and tool results with only their identifier and
      # error flag, because tool inputs and outputs can contain repository
      # content and credentials. Override to publish more or to redact text.
      def harness_event_data(event) # :doc:
        activity = event.data.fetch(:event)
        case activity[:kind]
        when :tool_call then event.data.merge(event: activity.slice(:kind, :id, :name))
        when :tool_result then event.data.merge(event: activity.slice(:kind, :id, :error))
        else event.data
        end
      end

      # Builds the Harnesses::Request for validated model +input+. Override to
      # add trusted values such as +cwd+, +instructions+, or +max_turns+.
      # An ArgumentError becomes a model-visible tool error.
      def build_request(input, harness:) # :doc:
        Request.new(
          prompt: input.fetch("task"),
          session_id: input["session_id"],
          budget_usd: budget_for(input),
          timeout: timeout_for(input)
        )
      end

      # Returns the tool declarations served to the harness for this call.
      # Override to choose them per run; the default is the list given to
      # ::serve_tools.
      def served_tools # :doc:
        self.class.tool_server_value&.fetch(:tools) || []
      end

      # Converts a Harnesses::Result into the value returned to the model.
      def result_value(result) # :doc:
        value = result.to_h.except(:stderr_tail)
        if result.text && result.text.length > RESULT_TEXT_LIMIT
          value[:text] = "#{result.text[0, RESULT_TEXT_LIMIT]}…"
          value[:text_truncated] = true
        end
        value[:stderr_tail] = result.stderr_tail unless result.completed? || result.stderr_tail.empty?
        value
      end

      def with_tool_server(request)
        settings = self.class.tool_server_value
        return yield(request) unless settings

        registry = ToolRegistry.new(served_tools, binding:)
        return yield(request) if registry.names.empty?

        server = ToolServer.new(tools: registry, socket_path: settings.fetch(:socket), context:, name: settings.fetch(:name)).start
        yield Request.new(**request.to_h, mcp_servers: request.mcp_servers.merge(settings.fetch(:name) => settings.fetch(:url)))
      ensure
        server&.close
        registry&.close
      end

      def run_home(name, harness)
        return unless run.respond_to?(:shared_resource) && run.respond_to?(:register)

        run.shared_resource([:little_ghost_harness_home, self.class, name]) do
          paths = HomeDirectory.create(sandbox:, root: harness.home_root, host: !harness.isolated? && harness.home_root.nil?)
          run.register { HomeDirectory.remove(paths) }
          paths.fetch(:child)
        end
      end

      def session_ledger
        return @session_ledger unless run.respond_to?(:shared_resource)

        run.shared_resource([:little_ghost_harness_sessions, self.class]) { SessionLedger.new }
      end

      class SessionLedger # :nodoc:
        def initialize
          @mutex = Mutex.new
          @sessions = Hash.new { |hash, key| hash[key] = [] }
        end

        def include?(harness, session_id) = @mutex.synchronize { @sessions[harness].include?(session_id) }

        def record(harness, session_id)
          return unless session_id

          @mutex.synchronize { @sessions[harness] |= [session_id] }
        end
      end
      private_constant :SessionLedger

      def selected_harness(input)
        available = self.class.harnesses
        raise ConfigurationError, "#{self.class} declares no harnesses" if available.empty?

        name = input["harness"]
        return available.first if name.nil? && available.length == 1

        selected = available.find { |candidate| candidate.to_s == name.to_s }
        raise ToolError, "Unknown harness #{name.inspect}. Choose one of: #{available.join(", ")}." unless selected

        selected
      end

      def budget_for(input)
        return unless self.class.budget_maximum_value

        requested = input["budget_usd"]
        return self.class.budget_default_value if requested.nil? || requested.zero?

        [requested, self.class.budget_maximum_value].min
      end

      def timeout_for(input)
        requested = input["timeout_seconds"]
        return self.class.timeout_default_value if requested.nil? || requested.zero?

        [requested, self.class.timeout_maximum_value].min
      end
    end
  end
end
