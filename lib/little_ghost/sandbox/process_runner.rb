# frozen_string_literal: true

require "open3"

module LittleGhost
  class Sandbox
    # Runs one bounded child process from trusted application code and
    # terminates its entire process group when the Run is cancelled or the
    # command exceeds its timeout.
    #
    # ProcessRunner is for setup work the application itself decides to run,
    # such as preparing a workspace or unpacking a cache. It applies no
    # isolation beyond the process group; send model-selected commands through a
    # Sandbox instead.
    #
    #   result = LittleGhost::Sandbox::ProcessRunner.capture(
    #     ["git", "fetch", "--prune"],
    #     timeout: 120,
    #     chdir: workspace.root,
    #     environment: {"GIT_TERMINAL_PROMPT" => "0"},
    #     inherit_environment: true,
    #     context:
    #   )
    #   raise "fetch failed: #{result.stderr}" unless result.success?
    #
    # The child starts with an empty environment unless +inherit_environment+
    # is true; +environment+ is merged on top either way. Each output stream is
    # captured up to +max_output_bytes+ (or without a limit when nil), and the
    # rest is discarded while the stream is still drained so the child cannot
    # block on a full pipe.
    #
    # #capture reports a timeout in its Result. Cancellation through +context+
    # raises CancelledError or DeadlineExceededError after the process group is
    # stopped. When the group cannot be stopped, CleanupError is raised.
    class ProcessRunner
      POLL_INTERVAL = 0.01 # :nodoc:
      TERMINATION_GRACE = 0.5 # :nodoc:
      READ_CHUNK_BYTES = 16_384 # :nodoc:

      # The outcome of one ProcessRunner.capture call.
      Result = Data.define(:stdout, :stderr, :exit_code, :timed_out, :stdout_truncated, :stderr_truncated) do
        # Whether the process exited with status zero before its timeout.
        def success? = !timed_out && exit_code == 0

        # Whether either stream exceeded the output limit.
        def output_truncated? = stdout_truncated || stderr_truncated

        alias_method :timed_out?, :timed_out
        alias_method :stdout_truncated?, :stdout_truncated
        alias_method :stderr_truncated?, :stderr_truncated
      end

      # Runs +command+ and returns a Result. See the class documentation for
      # environment, output, timeout, and cancellation behavior.
      #
      # +stdin_data+ is written to the child's standard input before it is
      # closed. With +binmode+, standard output is returned as binary data
      # instead of scrubbed UTF-8.
      #
      # A missing executable returns exit code 127 with a message on standard
      # error. Raises ArgumentError for an empty command or a non-positive
      # timeout or output limit.
      def self.capture(command, timeout:, context: nil, environment: {}, inherit_environment: false,
        chdir: nil, stdin_data: nil, binmode: false, max_output_bytes: 1_000_000)
        new(
          command:, timeout:, context:, environment:, inherit_environment:,
          chdir:, stdin_data:, binmode:, max_output_bytes:
        ).capture
      end

      # Runs +command+ for a Sandbox backend: returns a Sandbox::Execution whose
      # truncated streams carry a marker, and raises ToolError on timeout.
      def self.run(command:, **options) # :nodoc:
        timeout = options.fetch(:timeout)
        result = capture(command, **options)
        if result.timed_out
          raise ToolError, FrameworkPrompts.reference("sandbox/process/feedback/command_timed_out", timeout: Float(timeout))
        end

        Execution.new(
          stdout: marked(result.stdout, result.stdout_truncated),
          stderr: marked(result.stderr, result.stderr_truncated),
          exit_code: result.exit_code
        )
      end

      def self.marked(output, truncated) # :nodoc:
        truncated ? "#{output}\n[output truncated]" : output
      end
      private_class_method :marked

      def initialize(command:, timeout:, context: nil, max_output_bytes: 1_000_000, environment: {}, # :nodoc:
        inherit_environment: false, chdir: nil, stdin_data: nil, binmode: false)
        @command = Array(command).map(&:to_s)
        @timeout = Float(timeout)
        @context = context
        @max_output_bytes = max_output_bytes.nil? ? nil : Integer(max_output_bytes)
        @environment = environment.to_h.transform_keys(&:to_s).transform_values(&:to_s)
        @inherit_environment = inherit_environment
        @chdir = chdir
        @stdin_data = stdin_data
        @binmode = binmode

        if @command.empty? || @command.first.empty?
          raise ToolError, FrameworkPrompts.reference("sandbox/process/feedback/executable_required")
        end
        raise ArgumentError, "timeout must be positive" unless @timeout.positive? && @timeout.finite?
        if @max_output_bytes && !@max_output_bytes.positive?
          raise ArgumentError, "max_output_bytes must be positive"
        end
      end

      def capture # :nodoc:
        @context&.check!
        options = {pgroup: true, unsetenv_others: !@inherit_environment}
        options[:chdir] = @chdir if @chdir
        Open3.popen3(@environment, *@command, **options) do |stdin, stdout, stderr, wait_thread|
          supervise(stdin, stdout, stderr, wait_thread)
        end
      rescue Errno::ENOENT
        raise if @chdir && !File.directory?(@chdir)

        Result.new(
          stdout: "", stderr: "#{@command.first}: command not found\n", exit_code: 127,
          timed_out: false, stdout_truncated: false, stderr_truncated: false
        )
      end

      private

      def supervise(stdin, stdout, stderr, wait_thread)
        readers = [
          Thread.new { drain(stdout, binary: @binmode) },
          Thread.new { drain(stderr, binary: false) }
        ]
        write_input(stdin)
        timed_out = false
        begin
          timed_out = wait_for(wait_thread, readers)
          terminate(wait_thread) if timed_out
          settle(readers, [stdout, stderr])
        rescue
          terminate(wait_thread)
          settle(readers, [stdout, stderr])
          raise
        end
        (out, out_truncated), (err, err_truncated) = readers.map(&:value)
        Result.new(
          stdout: out, stderr: err, exit_code: wait_thread.value.exitstatus, timed_out:,
          stdout_truncated: out_truncated, stderr_truncated: err_truncated
        )
      ensure
        readers&.each { |reader| reader.kill if reader.alive? }
      end

      def write_input(stdin)
        stdin.write(@stdin_data) if @stdin_data
      rescue Errno::EPIPE
        nil
      ensure
        stdin.close unless stdin.closed?
      end

      # Waits for the leader, its output, and any surviving group members so a
      # backgrounded child cannot outlive a successful result.
      def wait_for(wait_thread, readers)
        deadline = monotonic_time + @timeout
        until !wait_thread.alive? && readers.none?(&:alive?) && !process_group_alive?(wait_thread.pid)
          @context&.check!
          return true if monotonic_time >= deadline

          wait_thread.join(POLL_INTERVAL)
        end
        false
      end

      def terminate(wait_thread)
        pid = wait_thread.pid
        signal_group("TERM", pid)
        wait_for_group(wait_thread)
        if process_group_alive?(pid)
          signal_group("KILL", pid)
          wait_for_group(wait_thread)
        end
        return unless wait_thread.alive? || process_group_alive?(pid)

        raise CleanupError, "command process group did not stop"
      end

      def wait_for_group(wait_thread)
        deadline = monotonic_time + TERMINATION_GRACE
        while (wait_thread.alive? || process_group_alive?(wait_thread.pid)) && monotonic_time < deadline
          sleep(POLL_INTERVAL)
        end
      end

      def signal_group(signal, pid)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def process_group_alive?(pid)
        Process.kill(0, -pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      # Gives readers a short grace period after the group stops, then closes
      # the pipes so a descendant that escaped the group cannot hold them open.
      def settle(readers, streams)
        deadline = monotonic_time + TERMINATION_GRACE
        readers.each { |reader| reader.join(POLL_INTERVAL) } while readers.any?(&:alive?) && monotonic_time < deadline
        return if readers.none?(&:alive?)

        streams.each { |stream| stream.close unless stream.closed? }
        readers.each { |reader| reader.join(TERMINATION_GRACE) }
        raise CleanupError, "command output readers did not stop" if readers.any?(&:alive?)
      end

      def drain(io, binary:)
        io.binmode
        captured = String.new(encoding: Encoding::BINARY)
        truncated = false
        begin
          while (chunk = io.read(READ_CHUNK_BYTES))
            if @max_output_bytes
              remaining = @max_output_bytes - captured.bytesize
              captured << chunk.byteslice(0, remaining) if remaining.positive?
              truncated ||= chunk.bytesize > remaining
            else
              captured << chunk
            end
          end
        rescue IOError
          nil
        end
        captured = captured.force_encoding(Encoding::UTF_8).scrub unless binary
        [captured, truncated]
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
