# frozen_string_literal: true

require "json"

module LittleGhost
  module Tools
    # Shell lets an agent run a command through the configured Sandbox.
    #
    # By default it accepts an argument vector, so model-supplied values are not
    # interpreted as shell syntax, and each command may run for 30 seconds.
    # Subclass it to accept a shell command string or to let the model choose a
    # bounded timeout:
    #
    #   class SupportShell < LittleGhost::Tools::Shell
    #     command_mode :string
    #     timeout default: 120, maximum: 900
    #     exclusive true
    #   end
    #
    # The child environment is cleared and each output stream is limited to
    # 1 MB unless #max_output_bytes is configured. Commands may spawn children
    # when the backend supports them. These defaults reduce accidental exposure
    # but do not create an isolation boundary; the configured Sandbox remains
    # responsible for security.
    class Shell < Tool
      COMMAND_MODES = %i[argv string].freeze # :nodoc:
      DEFAULT_TIMEOUT = 30 # :nodoc:
      MAX_OUTPUT_BYTES = 1_000_000 # :nodoc:

      class_attribute :command_mode_value, default: :argv
      class_attribute :timeout_default_value, default: DEFAULT_TIMEOUT
      class_attribute :timeout_maximum_value
      class_attribute :max_output_bytes_value, default: MAX_OUTPUT_BYTES

      tool_name "shell"

      class << self
        # :call-seq:
        #   command_mode()       -> :argv or :string
        #   command_mode(value)  -> value
        #
        # Selects how the model supplies a command. +:argv+ accepts an array of
        # arguments and runs the executable directly. +:string+ accepts one
        # command string and runs it with <tt>/bin/sh -c</tt>, so pipes,
        # redirection, and variable expansion apply inside the Sandbox.
        #
        # Raises ArgumentError for any other mode.
        def command_mode(*values)
          return command_mode_value if values.empty?

          mode = values.fetch(0).to_sym
          raise ArgumentError, "command_mode must be one of #{COMMAND_MODES.join(", ")}" unless COMMAND_MODES.include?(mode)

          self.command_mode_value = mode
        end

        # :call-seq:
        #   timeout(default:, maximum: nil) -> Integer
        #
        # Sets the command timeout in seconds. With +maximum+, the input schema
        # gains an optional +timeout_seconds+ argument the model may set between
        # 1 and +maximum+; omitted, null, or zero values use +default+. Without
        # +maximum+, every command uses +default+.
        #
        # Raises ArgumentError unless both values are positive integers and
        # +default+ does not exceed +maximum+.
        def timeout(default:, maximum: nil)
          default = positive_integer(default, "timeout default")
          maximum = positive_integer(maximum, "timeout maximum") unless maximum.nil?
          if maximum && default > maximum
            raise ArgumentError, "timeout default must not exceed timeout maximum"
          end

          self.timeout_maximum_value = maximum
          self.timeout_default_value = default
        end

        # :call-seq:
        #   max_output_bytes()       -> Integer
        #   max_output_bytes(value)  -> value
        #
        # The per-stream output limit passed to the Sandbox.
        def max_output_bytes(*values)
          return max_output_bytes_value if values.empty?

          self.max_output_bytes_value = positive_integer(values.fetch(0), "max_output_bytes")
        end

        def description(*values) # :nodoc:
          return super unless values.empty?

          description_value || FrameworkPrompts.new.render("tools/built_in/shell/description", locals: description_locals)
        end

        def input_schema(*values) # :nodoc:
          return super unless values.empty?

          input_schema_value || generated_input_schema
        end

        def description_locals # :nodoc:
          {
            command_mode: command_mode,
            timeout_default: timeout_default_value,
            timeout_maximum: timeout_maximum_value
          }
        end

        private

        def generated_input_schema
          command = if command_mode == :string
            {type: "string", minLength: 1, description: "Shell command to run with /bin/sh -c."}
          else
            {type: "array", items: {type: "string"}, minItems: 1, description: "Executable followed by its arguments."}
          end
          properties = {command:}
          if timeout_maximum_value
            properties[:timeout_seconds] = {
              type: ["integer", "null"],
              minimum: 0,
              maximum: timeout_maximum_value,
              description: "Seconds before the command is terminated. Null or 0 uses #{timeout_default_value}."
            }
          end
          deep_freeze({type: "object", properties:, required: ["command"], additionalProperties: false})
        end

        def positive_integer(value, name)
          unless value.is_a?(Integer) && value.positive?
            raise ArgumentError, "#{name} must be a positive integer"
          end

          value
        end
      end

      # Executes <tt>input["command"]</tt> and returns a JSON result containing
      # standard output, standard error, exit status, and success. When the
      # Sandbox reports an execution error, the result adds an +error+ message
      # that names only the exception class; the error's own message stays out
      # of model-visible output.
      def call(input)
        options = {
          timeout: timeout_for(input),
          context:,
          max_output_bytes: self.class.max_output_bytes,
          environment: {},
          inherit_environment: false
        }
        result = if self.class.command_mode == :string
          sandbox.execute(input.fetch("command"), **options)
        else
          sandbox.execute_program(input.fetch("command"), **options)
        end
        output = {
          stdout: result.stdout,
          stderr: result.stderr,
          exit_status: result.exit_code,
          success: result.success?
        }
        output[:error] = execution_error(result.error) if result.error
        JSON.generate(output)
      end

      def description
        self.class.description_value ||
          framework_prompt("tools/built_in/shell/description", **self.class.description_locals)
      end

      private

      def timeout_for(input)
        maximum = self.class.timeout_maximum_value
        requested = Integer(input["timeout_seconds"], exception: false) if maximum
        return self.class.timeout_default_value unless requested&.positive?

        [requested, maximum].min
      end

      def execution_error(error)
        error_class = error.class.name if error.is_a?(Exception)
        framework_prompt("tools/built_in/shell/feedback/execution_failed", error_class:)
      end
    end
  end
end
