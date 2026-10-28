# frozen_string_literal: true

module LittleGhost
  module Harnesses
    # Lets an Agent delegate a coding task to an external coding-agent tool.
    #
    # The application chooses which harnesses are available, where each
    # executable lives, its writable home, and placeholder settings. The model
    # supplies only the task, the harness name, an optional session to resume,
    # and a budget and timeout within the configured bounds.
    #
    #   class DelegateCodingTask < LittleGhost::Harnesses::Tool
    #     tool_name "delegate_coding_task"
    #     harnesses claude_code: {
    #       executable: "/opt/harnesses/bin/claude",
    #       home: "/home/agent",
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
    # The tool runs the harness in the Run's Sandbox and publishes each
    # +:harness+ StreamEvent to the Run while the harness works. It returns a
    # JSON object with the Result's status, final text, session, cost, turns,
    # and usage, plus the end of standard error when the task did not
    # complete. Calls are exclusive, so two harnesses never edit the same
    # workspace at once.
    #
    # Override #build_harness to choose settings per run, and #build_request
    # to add instructions, a working directory, or a turn limit.
    class Tool < LittleGhost::Tool
      DEFAULT_TIMEOUT = 600 # :nodoc:

      class_attribute :harness_settings_value, default: {}.freeze
      class_attribute :budget_default_value
      class_attribute :budget_maximum_value
      class_attribute :timeout_default_value, default: DEFAULT_TIMEOUT
      class_attribute :timeout_maximum_value, default: DEFAULT_TIMEOUT

      tool_name "delegate_to_harness"
      exclusive true

      class << self
        # :call-seq:
        #   harnesses()                      -> Array of Symbol
        #   harnesses(*names, **settings)    -> Array of Symbol
        #
        # Declares the available harnesses. Each name must be registered with
        # Harnesses.register. +settings+ maps a name to a Hash with
        # +:executable+, +:home+, and +:defaults+ for Base.new; a bare name
        # uses the harness's default executable and requires #build_harness
        # to supply a home.
        def harnesses(*names, **settings)
          return harness_settings_value.keys if names.empty? && settings.empty?

          values = names.flatten.to_h { |name| [name.to_sym, {}] }
          settings.each { |name, options| values[name.to_sym] = options.to_h.transform_keys(&:to_sym).freeze }
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

      # Runs the selected harness and returns its result as a Hash.
      def call(input)
        name = selected_harness(input)
        request = begin
          build_request(input, harness: name)
        rescue ArgumentError => error
          raise ToolError, error.message
        end
        harness = build_harness(name)
        result = harness.run(request, context:) { |event| publish_event(event.type, **event.data) }
        result_value(result)
      end

      def description # :nodoc:
        self.class.description_value ||
          framework_prompt("tools/built_in/harness/description", **self.class.description_locals)
      end

      private

      # Builds the Harnesses::Base for +name+ from the declared settings and
      # the bound Sandbox. Override to choose settings per run.
      def build_harness(name) # :doc:
        raise ConfigurationError, "#{self.class} requires a sandbox" unless sandbox

        settings = self.class.harness_settings(name)
        harness = Harnesses.resolve(name)
        home = settings.fetch(:home) { raise ConfigurationError, "#{self.class} has no home configured for #{name}" }
        harness.new(
          sandbox:,
          executable: settings.fetch(:executable, harness.default_executable),
          home:,
          defaults: settings.fetch(:defaults, {})
        )
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

      # Converts a Harnesses::Result into the value returned to the model.
      def result_value(result) # :doc:
        value = result.to_h.except(:stderr_tail)
        value[:stderr_tail] = result.stderr_tail unless result.completed? || result.stderr_tail.empty?
        value
      end

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
