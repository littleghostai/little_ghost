# frozen_string_literal: true

require "json"

module LittleGhost
  module Harnesses
    # Runs one coding-agent command-line tool as a bounded Sandbox process and
    # turns its JSON-lines output into StreamEvent values and a Result.
    #
    # A harness instance holds trusted settings: the Sandbox (or Sandbox::Scope)
    # that runs the tool, the executable path, a writable +home+ directory as
    # the child sees it, and harness-specific +defaults+. Requests carry the
    # task and its limits.
    #
    # A subclass implements four hooks:
    #
    #   class SupportAgentHarness < LittleGhost::Harnesses::Base
    #     harness_id :support_agent
    #     default_executable "support-agent"
    #     supported_versions ">= 1.2"
    #
    #     def command(request)
    #       [executable, "run", "--json", request.prompt]
    #     end
    #
    #     def environment(request)
    #       {"SUPPORT_AGENT_HOME" => home}
    #     end
    #
    #     def parse_line(line, state)
    #       data = JSON.parse(line)
    #       state.text = data["answer"] if data["type"] == "answer"
    #       state.text ? [{kind: :text, text: state.text}] : []
    #     end
    #   end
    #
    # #parse_line returns event Hashes whose +:kind+ is +:start+, +:text+,
    # +:tool_call+, +:tool_result+, or +:usage+. #run wraps each in
    # <tt>StreamEvent.build(:harness, harness:, session_id:, event:)</tt> and
    # adds one final +:stop+ event. Lines that are not valid JSON are counted
    # in State#malformed_lines and skipped. #finalize builds the Result and may
    # be overridden to adjust it.
    #
    # #run stops the process when the request's +timeout+ elapses, when the
    # reported cost exceeds +budget_usd+, or when reported turns exceed
    # +max_turns+, even if the tool does not enforce those limits itself.
    # Cancellation and run deadlines from +context+ raise after the process is
    # stopped. The process is always closed before #run returns.
    #
    # Placeholder credentials and base URLs come from +defaults+ or the
    # request's +environment+. Real provider keys belong in a network gateway
    # that replaces the placeholder, never in the harness.
    class Base
      PLACEHOLDER_API_KEY = "little-ghost-placeholder" # :nodoc:
      EVENT_TEXT_LIMIT = 4_000 # :nodoc:
      STDERR_TAIL_BYTES = 4_096 # :nodoc:
      DEFAULT_OUTPUT_BYTES = 64 * 1024 * 1024 # :nodoc:
      POLL_INTERVAL = 0.1 # :nodoc:
      EXIT_WAIT = 5 # :nodoc:
      EVENT_KINDS = %i[start text tool_call tool_result usage].freeze # :nodoc:

      class << self
        # :call-seq:
        #   harness_id()       -> Symbol
        #   harness_id(value)  -> value
        #
        # Identifier used in events and results.
        def harness_id(*values)
          return @harness_id || superclass_value(:harness_id) if values.empty?

          @harness_id = values.fetch(0).to_sym
        end

        # :call-seq:
        #   default_executable()       -> String
        #   default_executable(value)  -> value
        #
        # Command name used when an application does not configure a path.
        def default_executable(*values)
          return @default_executable || superclass_value(:default_executable) if values.empty?

          @default_executable = String(values.fetch(0)).freeze
        end

        # :call-seq:
        #   supported_versions()                 -> Gem::Requirement
        #   supported_versions(*requirements)    -> Gem::Requirement
        #
        # Tool versions whose command line and output this harness understands.
        def supported_versions(*requirements)
          return @supported_versions || superclass_value(:supported_versions) || Gem::Requirement.default if requirements.empty?

          @supported_versions = Gem::Requirement.new(*requirements)
        end

        private

        def superclass_value(name)
          superclass.public_send(name) if superclass.respond_to?(name)
        end
      end

      # Builds a harness. +sandbox+ is a Sandbox or Sandbox::Scope that runs the
      # tool. +home+ is the tool's writable home directory as the child sees
      # it. +defaults+ holds harness-specific settings such as +:base_url+,
      # +:api_key+, +:model+, +:environment+, and +:output_bytes+.
      def initialize(sandbox:, home:, executable: self.class.default_executable, defaults: {})
        raise ArgumentError, "harness executable is required" if executable.nil? || String(executable).empty?
        raise ArgumentError, "harness home must be an absolute path" unless String(home).start_with?("/")

        @sandbox = sandbox
        @executable = String(executable).dup.freeze
        @home = String(home).dup.freeze
        @defaults = defaults.to_h.transform_keys(&:to_sym).freeze
      end

      # Sandbox or Sandbox::Scope that runs the tool.
      attr_reader :sandbox
      # Executable path or command name.
      attr_reader :executable
      # Writable home directory as the child sees it.
      attr_reader :home
      # Frozen harness-specific settings.
      attr_reader :defaults

      # Identifier used in events and results.
      def harness_id = self.class.harness_id

      # Runs <tt>executable --version</tt> in the sandbox and returns a Hash
      # with +:available+, +:version+, +:supported+, and +:reason+.
      def probe(context: nil, timeout: 30)
        result = sandbox.execute_program(
          [executable, "--version"],
          timeout:,
          context:,
          max_output_bytes: 16_384,
          environment: base_environment
        )
        unless result.success?
          return {available: false, version: nil, supported: false, reason: "#{executable} --version exited with #{result.exit_code.inspect}"}
        end

        version = result.stdout[/\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.]+)?/]
        return {available: true, version: nil, supported: false, reason: "version was not reported"} unless version

        supported = self.class.supported_versions.satisfied_by?(Gem::Version.new(version))
        {available: true, version:, supported:, reason: supported ? nil : "version #{version} is not supported"}
      rescue ArgumentError
        {available: true, version:, supported: false, reason: "version #{version} could not be compared"}
      rescue ToolError => error
        {available: false, version: nil, supported: false, reason: error.message}
      end

      # Runs +request+ and returns a Result, yielding each +:harness+
      # StreamEvent to the optional block.
      #
      # Raises CancelledError or DeadlineExceededError when +context+ stops
      # the run; the process is stopped first.
      def run(request, context: nil, &block)
        raise ArgumentError, "harness request must be a LittleGhost::Harnesses::Request" unless request.is_a?(Request)

        state = State.new
        timeout = context ? context.remaining_time(request.timeout) : request.timeout
        deadline = monotonic_time + timeout
        session = sandbox.start_program(
          command(request),
          context:,
          environment: process_environment(request),
          cwd: request.cwd,
          output_bytes: defaults.fetch(:output_bytes, DEFAULT_OUTPUT_BYTES)
        )
        outcome, stderr_tail = consume(session, request, state, deadline, context, block)
        exit_code = session.wait(timeout: EXIT_WAIT)&.exitstatus
        result = finalize(state, exit_code:, stderr_tail:, outcome:)
        emit(block, state, {
          kind: :stop,
          status: result.status,
          stop_reason: result.stop_reason,
          cost_usd: result.cost_usd,
          turns: result.turns,
          exit_code:
        })
        result
      ensure
        session&.close
      end

      # Returns the command line for +request+, beginning with #executable.
      def command(request)
        raise AbstractMethodError, "#{self.class} must implement #command"
      end

      # Returns child-process variables for +request+. Defaults and the
      # request's own +environment+ are merged over this Hash.
      def environment(request) = {}

      # Records progress from one output +line+ in +state+ and returns an
      # Array of event Hashes.
      def parse_line(line, state)
        raise AbstractMethodError, "#{self.class} must implement #parse_line"
      end

      # Builds the Result. +outcome+ is +:timed_out+, +:budget_exceeded+,
      # +:turns_exceeded+, or +:failed+ when #run stopped the process, and nil
      # when the process ended on its own.
      def finalize(state, exit_code:, stderr_tail:, outcome:)
        status = outcome || state.status || (exit_code&.zero? ? :completed : :failed)
        Result.new(
          harness: harness_id,
          status:,
          text: state.text,
          session_id: state.session_id,
          cost_usd: state.cost_usd,
          usage: state.usage,
          turns: state.turns,
          exit_code:,
          stop_reason: state.stop_reason,
          stderr_tail:
        )
      end

      private

      def consume(session, request, state, deadline, context, block)
        pending = String.new(encoding: Encoding::BINARY)
        stderr = String.new(encoding: Encoding::BINARY)
        outcome = nil
        loop do
          context&.check!
          remaining = deadline - monotonic_time
          if remaining <= 0
            outcome = :timed_out
            break
          end

          begin
            chunk = session.read(timeout: [remaining, POLL_INTERVAL].min)
          rescue ToolError
            state.stop_reason ||= "output_limit"
            outcome = :failed
            break
          end
          stderr = tail(stderr + chunk.stderr.b)
          pending << chunk.stdout.b
          while (index = pending.index("\n"))
            handle_line(pending.slice!(0..index).chomp, state, block)
            outcome = limit_outcome(request, state)
            break if outcome
          end
          break if outcome || chunk.eof
        end
        handle_line(pending, state, block) if outcome.nil? && !pending.strip.empty?
        session.terminate if outcome
        [outcome, stderr.force_encoding(Encoding::UTF_8).scrub]
      rescue
        session.terminate
        raise
      end

      def handle_line(line, state, block)
        line = line.dup.force_encoding(Encoding::UTF_8).scrub
        return if line.strip.empty?

        events = begin
          parse_line(line, state)
        rescue JSON::ParserError
          state.malformed_lines += 1
          []
        end
        Array(events).each { |event| emit(block, state, event) }
      end

      def limit_outcome(request, state)
        return :budget_exceeded if request.budget_usd && state.cost_usd && state.cost_usd > request.budget_usd
        return :turns_exceeded if request.max_turns && state.turns && state.turns > request.max_turns

        nil
      end

      def emit(block, state, event)
        return unless block

        event = event.to_h { |key, value| [key.to_sym, bounded(value)] }
        kind = event[:kind]
        unless kind == :stop || EVENT_KINDS.include?(kind)
          raise ProtocolError, "#{self.class} produced an unknown harness event kind: #{kind.inspect}"
        end

        block.call(StreamEvent.build(:harness, harness: harness_id, session_id: state.session_id, event: event.freeze))
      end

      def bounded(value)
        case value
        when String then (value.length > EVENT_TEXT_LIMIT) ? "#{value[0, EVENT_TEXT_LIMIT]}…" : value
        when Hash, Array then bounded(JSON.generate(value))
        else value
        end
      end

      def tail(value)
        (value.bytesize > STDERR_TAIL_BYTES) ? value.byteslice(-STDERR_TAIL_BYTES, STDERR_TAIL_BYTES) : value
      end

      def base_environment
        {"HOME" => home}.merge(defaults.fetch(:environment, {}).to_h { |name, value| [String(name), String(value)] })
      end

      def process_environment(request)
        {"HOME" => home}
          .merge(environment(request))
          .merge(defaults.fetch(:environment, {}).to_h { |name, value| [String(name), String(value)] })
          .merge(request.environment)
      end

      def api_key = defaults.fetch(:api_key, PLACEHOLDER_API_KEY)

      def prompt_with_instructions(request)
        return request.prompt unless request.instructions

        "#{request.instructions}\n\n#{request.prompt}"
      end

      def positional(value)
        value.start_with?("-") ? ["--", value] : [value]
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
