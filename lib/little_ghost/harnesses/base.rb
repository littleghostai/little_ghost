# frozen_string_literal: true

require "json"

module LittleGhost
  module Harnesses
    # Runs one coding-agent command-line tool as a bounded Sandbox process and
    # turns its JSON-lines output into StreamEvent values and a Result.
    #
    # A harness instance holds trusted settings: the Sandbox (or Sandbox::Scope)
    # that runs the tool, the executable path, where the tool's home directory
    # lives, and harness-specific +defaults+. Requests carry the task and its
    # limits.
    #
    # By default each #run gets a new private home directory beneath a
    # Workspace path that the Sandbox lets processes write, and the directory
    # is removed when the run ends, so nothing one run writes there, such as
    # tool configuration, reaches a later run. Passing +home+ opts in to a
    # persistent home that the application owns; see #initialize.
    #
    # A subclass implements #command and #parse_line, usually #environment, and
    # may override #finalize:
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
    # Cost and turns are reported by the tool, which the model controls, so
    # +timeout+ and limits enforced by a network gateway are the bounds to
    # rely on. Cancellation and run deadlines from +context+ raise after the
    # process is stopped. The process is always closed before #run returns.
    #
    # Each run emits at most 1,000 events before its +:stop+ event, which
    # reports how many were dropped. Session identifiers that are not short
    # tokens are discarded.
    #
    # Placeholder credentials and base URLs come from +defaults+ or the
    # request's +environment+. Real provider keys belong in a network gateway
    # that replaces the placeholder, never in the harness.
    class Base
      PLACEHOLDER_API_KEY = "little-ghost-placeholder" # :nodoc:
      EVENT_TEXT_LIMIT = 4_000 # :nodoc:
      STDERR_TAIL_BYTES = 4_096 # :nodoc:
      DEFAULT_OUTPUT_BYTES = 16 * 1024 * 1024 # :nodoc:
      MAX_EVENTS = 1_000 # :nodoc:
      STOP_REASON_LIMIT = 200 # :nodoc:
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
      # tool, or nil to run it directly on the host. +defaults+ holds
      # harness-specific settings such as +:base_url+, +:api_key+, +:model+,
      # +:environment+, and +:output_bytes+. An +:api_key+ must be a
      # placeholder that begins with <tt>little-ghost-placeholder</tt>.
      #
      # +mode+ decides which safeguards apply:
      #
      # [+:isolated+]
      #   The Sandbox is the boundary, so the tool's own approval prompts and
      #   command sandbox are turned off and it receives the placeholder key.
      #   Requires a Sandbox that reports isolation and does not inherit the
      #   host network; any other Sandbox raises ConfigurationError.
      # [+:native_guards+]
      #   The tool keeps its own safeguards: a restricted tool and permission
      #   set, and its own command sandbox where it has one. The child inherits
      #   the environment, so the tool authenticates with the user's own
      #   credentials; LittleGhost never reads, stores, or forwards them.
      #
      # Without +mode+, an isolating Sandbox selects +:isolated+ and nil or
      # any other Sandbox selects +:native_guards+.
      #
      # Without +home+, each #run creates a private home beneath +home_root+,
      # the name of a Workspace path the Sandbox lets processes write
      # (+:root+ for the Workspace root), and removes it afterwards. When
      # +home_root+ is nil the first writable runtime path in the Sandbox
      # policy is used, or a host temporary directory when the Sandbox does
      # not isolate. +home+ instead names a persistent home directory as the
      # child sees it; the tool can change files there, including its own
      # configuration, and those changes affect every later run that uses the
      # same home.
      def initialize(sandbox: nil, home: nil, executable: self.class.default_executable, defaults: {}, home_root: nil,
        mode: nil)
        raise ArgumentError, "harness executable is required" if executable.nil? || String(executable).empty?
        raise ArgumentError, "harness home must be an absolute path" unless home.nil? || String(home).start_with?("/")

        @sandbox = sandbox
        @executable = String(executable).dup.freeze
        @home = home && String(home).dup.freeze
        @home_root = home_root&.to_sym
        @mode = resolve_mode(mode)
        @defaults = defaults.to_h.transform_keys(&:to_sym).freeze
        if @defaults.key?(:api_key) && !String(@defaults[:api_key]).start_with?(PLACEHOLDER_API_KEY)
          raise ConfigurationError, "harness api_key must be a placeholder beginning with #{PLACEHOLDER_API_KEY}"
        end
      end

      # Sandbox or Sandbox::Scope that runs the tool, or nil for the host.
      attr_reader :sandbox
      # +:isolated+ or +:native_guards+.
      attr_reader :mode
      # Executable path or command name.
      attr_reader :executable
      # Home directory as the child sees it: the persistent home, the run's
      # temporary home while #run or #probe works, or nil.
      attr_reader :home
      # Workspace path name for temporary homes, or nil.
      attr_reader :home_root
      # Frozen harness-specific settings.
      attr_reader :defaults

      # Identifier used in events and results.
      def harness_id = self.class.harness_id

      # Whether the Sandbox is the boundary and the tool's own safeguards are off.
      def isolated? = mode == :isolated

      # Runs <tt>executable --version</tt> in the sandbox and returns a Hash
      # with +:available+, +:version+, +:supported+, and +:reason+.
      def probe(context: nil, timeout: 30)
        return with_temporary_home { |harness| harness.probe(context:, timeout:) } unless home

        result = runner.execute_program(
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

        return with_temporary_home { |harness| harness.run(request, context:, &block) } unless home

        state = State.new
        timeout = context ? context.remaining_time(request.timeout) : request.timeout
        deadline = monotonic_time + timeout
        session = runner.start_program(
          command(request),
          context:,
          environment: process_environment(request),
          inherit_environment: !isolated?,
          cwd: request.cwd,
          output_bytes: defaults.fetch(:output_bytes, DEFAULT_OUTPUT_BYTES)
        )
        session.close_write
        outcome, stderr_tail = consume(session, request, state, deadline, context, block)
        exit_code = session.wait(timeout: EXIT_WAIT)&.exitstatus
        result = finalize(state, exit_code:, stderr_tail:, outcome:)
        stop = {
          kind: :stop,
          status: result.status,
          stop_reason: result.stop_reason,
          cost_usd: result.cost_usd,
          turns: result.turns,
          exit_code:
        }
        stop[:dropped_events] = state.values[:dropped_events] if state.values[:dropped_events]
        emit(block, state, stop)
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
          stop_reason: state.stop_reason&.to_s&.[](0, STOP_REASON_LIMIT),
          stderr_tail:
        )
      end

      private

      MODES = %i[isolated native_guards].freeze # :nodoc:

      def resolve_mode(requested)
        isolating = isolating_sandbox?
        return isolating ? :isolated : :native_guards if requested.nil?

        requested = requested.to_sym
        raise ConfigurationError, "harness mode must be :isolated or :native_guards" unless MODES.include?(requested)
        if requested == :isolated && !isolating
          raise ConfigurationError,
            "harness mode :isolated requires a Sandbox that reports isolation and does not inherit the host network"
        end

        requested
      end

      def isolating_sandbox?
        return false unless sandbox.respond_to?(:capabilities)

        network = sandbox.network if sandbox.respond_to?(:network)
        network ||= sandbox.effective_policy.network if sandbox.respond_to?(:effective_policy)
        sandbox.capabilities.isolation != :none && !network.nil? && !network.inherit?
      end

      def runner = sandbox || HostRunner.new

      def with_temporary_home
        paths = HomeDirectory.create(sandbox:, root: home_root, host: !isolated? && home_root.nil?)
        harness = dup
        harness.instance_variable_set(:@home, paths.fetch(:child))
        yield harness
      ensure
        HomeDirectory.remove(paths) if paths
      end

      def consume(session, request, state, deadline, context, block)
        pending = String.new(encoding: Encoding::BINARY)
        stderr = String.new(encoding: Encoding::BINARY)
        outcome = nil
        settled = false
        loop do
          context&.check!
          remaining = deadline - monotonic_time
          if remaining <= 0
            outcome = :timed_out
            break
          end

          started = monotonic_time
          begin
            chunk = session.read(timeout: [remaining, POLL_INTERVAL].min)
          rescue ToolError
            session.alive? if session.respond_to?(:alive?)
            state.stop_reason ||= "output_limit"
            outcome = :failed
            break
          end
          idle = POLL_INTERVAL - (monotonic_time - started)
          if chunk.stdout.empty? && chunk.stderr.empty? && !chunk.eof && idle > POLL_INTERVAL / 2
            # Output pipes are closed but a descendant keeps the process group alive.
            if state.status
              settled = true
              break
            end
            sleep([idle, remaining].min)
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
        session.terminate if outcome || settled
        context&.check! if outcome == :timed_out
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
        state.session_id = nil unless state.session_id.nil? || Request::IDENTIFIER.match?(state.session_id.to_s)
        Array(events).each do |event|
          emitted = state.values.fetch(:emitted_events, 0)
          if emitted >= MAX_EVENTS
            state.values[:dropped_events] = state.values.fetch(:dropped_events, 0) + 1
            next
          end

          state.values[:emitted_events] = emitted + 1
          emit(block, state, event)
        end
      end

      def limit_outcome(request, state)
        return if state.status
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
