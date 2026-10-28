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
    # The command is an Array of arguments. Its first element names the
    # executable, which is found through +PATH+, and no shell ever interprets
    # it, even when the Array holds a single String.
    #
    # The child starts with an empty environment unless +inherit_environment+
    # is true; +environment+ is merged on top either way. Each output stream is
    # captured up to +max_output_bytes+ (or without a limit when nil), and the
    # rest is discarded while the stream is still drained so the child cannot
    # block on a full pipe. Standard input is written while the command runs,
    # so a child that never reads it still stops at its timeout.
    #
    # #capture reports a timeout in its Result. Cancellation through +context+
    # raises CancelledError or DeadlineExceededError after the process group is
    # stopped. When the group or its output cannot be stopped, CleanupError is
    # raised instead.
    class ProcessRunner
      POLL_INTERVAL = 0.01 # :nodoc:
      TERMINATION_GRACE = 0.5 # :nodoc:
      READ_CHUNK_BYTES = 16_384 # :nodoc:

      Result = Data.define(:stdout, :stderr, :exit_code, :timed_out, :stdout_truncated, :stderr_truncated) do # :nodoc:
        def success? = !timed_out && exit_code == 0

        def output_truncated? = stdout_truncated || stderr_truncated

        alias_method :timed_out?, :timed_out
        alias_method :stdout_truncated?, :stdout_truncated
        alias_method :stderr_truncated?, :stderr_truncated
      end

      # The outcome of one ProcessRunner.capture call.
      class Result < Data # :doc:
        ##
        # :attr_reader: stdout
        # The captured standard output: scrubbed UTF-8, or binary data when
        # +binmode+ was requested.

        ##
        # :attr_reader: stderr
        # The captured standard error as scrubbed UTF-8.

        ##
        # :attr_reader: exit_code
        # The Integer exit status, or nil when the command timed out or was
        # stopped by a signal.

        ##
        # :attr_reader: timed_out
        # Whether the command was stopped because it exceeded its timeout.

        ##
        # :attr_reader: stdout_truncated
        # Whether standard output exceeded the output limit.

        ##
        # :attr_reader: stderr_truncated
        # Whether standard error exceeded the output limit.

        ##
        # :method: success?
        # Whether the process exited with status zero before its timeout.

        ##
        # :method: output_truncated?
        # Whether either stream exceeded the output limit.

        ##
        # :method: timed_out?
        # Alias for #timed_out.

        ##
        # :method: stdout_truncated?
        # Alias for #stdout_truncated.

        ##
        # :method: stderr_truncated?
        # Alias for #stderr_truncated.
      end

      # Runs +command+ and returns a Result. See the class documentation for
      # environment, output, timeout, and cancellation behavior.
      #
      # +stdin_data+ is written to the child's standard input, which is then
      # closed; a child that exits without reading it is not an error. With
      # +binmode+, standard output is returned as binary data instead of
      # scrubbed UTF-8.
      #
      # By default the command is finished only when the leader has exited and
      # every other member of its process group has gone, so a backgrounded
      # child cannot outlive a successful result. Pass +wait_for_group+ as
      # false to finish once the leader has exited and its output is closed,
      # leaving any background members running.
      #
      # A missing executable returns exit code 127 with a message on standard
      # error. A missing +chdir+ raises Errno::ENOENT. Raises ToolError for an
      # empty command and ArgumentError for a non-positive timeout or output
      # limit.
      def self.capture(command, timeout:, context: nil, environment: {}, inherit_environment: false,
        chdir: nil, stdin_data: nil, binmode: false, max_output_bytes: 1_000_000, wait_for_group: true)
        new(
          command:, timeout:, context:, environment:, inherit_environment:,
          chdir:, stdin_data:, binmode:, max_output_bytes:, wait_for_group:
        ).capture
      end

      # Runs +command+ for a Sandbox backend: returns a Sandbox::Execution whose
      # truncated streams carry a marker, and raises ToolError on timeout.
      # Background group members are left running once the leader finishes.
      def self.run(command:, **options) # :nodoc:
        timeout = options.fetch(:timeout)
        result = capture(command, wait_for_group: false, **options)
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
        inherit_environment: false, chdir: nil, stdin_data: nil, binmode: false, wait_for_group: true)
        @command = Array(command).map(&:to_s)
        @timeout = Float(timeout)
        @context = context
        @max_output_bytes = max_output_bytes.nil? ? nil : Integer(max_output_bytes)
        @environment = environment.to_h.transform_keys(&:to_s).transform_values(&:to_s)
        @inherit_environment = inherit_environment
        @chdir = chdir
        @stdin_data = stdin_data
        @binmode = binmode
        @wait_for_group = wait_for_group

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
        executable, *arguments = @command
        # The [command, argv0] pair keeps a lone String from being run through /bin/sh.
        Open3.popen3(@environment, [executable, executable], *arguments, **options) do |stdin, stdout, stderr, wait_thread|
          supervise(stdin, stdout, stderr, wait_thread)
        end
      rescue Errno::ENOENT
        raise if @chdir && !File.directory?(@chdir)

        Result.new(
          stdout: "", stderr: "#{executable}: command not found\n", exit_code: 127,
          timed_out: false, stdout_truncated: false, stderr_truncated: false
        )
      end

      private

      def supervise(stdin, stdout, stderr, wait_thread)
        readers = [
          Thread.new { drain(stdout, binary: @binmode) },
          Thread.new { drain(stderr, binary: false) }
        ]
        workers = readers + [Thread.new { write_input(stdin) }]
        streams = [stdin, stdout, stderr]
        begin
          timed_out = wait_for(wait_thread, readers)
        rescue
          stop(wait_thread, workers, streams)
          raise
        end
        timed_out ? stop(wait_thread, workers, streams) : settle(workers, streams)
        (out, out_truncated), (err, err_truncated) = readers.map(&:value)
        Result.new(
          stdout: out, stderr: err, exit_code: wait_thread.value.exitstatus, timed_out:,
          stdout_truncated: out_truncated, stderr_truncated: err_truncated
        )
      ensure
        workers&.each { |worker| worker.kill if worker.alive? }
      end

      def write_input(stdin)
        stdin.write(@stdin_data) if @stdin_data
      rescue Errno::EPIPE, IOError
        nil
      ensure
        begin
          stdin.close unless stdin.closed?
        rescue IOError
          nil
        end
      end

      def wait_for(wait_thread, readers)
        deadline = monotonic_time + @timeout
        until finished?(wait_thread, readers)
          @context&.check!
          return true if monotonic_time >= deadline

          # Thread#join returns at once for an exited leader, so sleep instead to avoid spinning.
          wait_thread.alive? ? wait_thread.join(POLL_INTERVAL) : sleep(POLL_INTERVAL)
        end
        false
      end

      def finished?(wait_thread, readers)
        return false if wait_thread.alive? || readers.any?(&:alive?)

        !@wait_for_group || !process_group_alive?(wait_thread.pid, leader_reaped: true)
      end

      def stop(wait_thread, workers, streams)
        terminate(wait_thread)
        settle(workers, streams)
      end

      def terminate(wait_thread)
        pid = wait_thread.pid
        return unless group_running?(wait_thread)

        signal_group("TERM", pid)
        wait_for_group(wait_thread)
        if group_running?(wait_thread)
          signal_group("KILL", pid)
          wait_for_group(wait_thread)
        end
        return unless group_running?(wait_thread)

        raise CleanupError, "command process group did not stop"
      end

      def group_running?(wait_thread)
        wait_thread.alive? || process_group_alive?(wait_thread.pid, leader_reaped: true)
      end

      def wait_for_group(wait_thread)
        deadline = monotonic_time + TERMINATION_GRACE
        sleep(POLL_INTERVAL) while group_running?(wait_thread) && monotonic_time < deadline
      end

      def signal_group(signal, pid)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def process_group_alive?(pgid, leader_reaped: false)
        reap_orphans(pgid) if leader_reaped
        Process.kill(0, -pgid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      # When this process is PID 1, orphaned group members are reparented to it
      # and stay zombies until reaped, which would keep the group looking alive.
      # Only called after the leader's own waiter has reaped it.
      def reap_orphans(pgid)
        nil while Process.waitpid(-pgid, Process::WNOHANG)
      rescue Errno::ECHILD
        nil
      end

      # Gives workers a short grace period, then closes the pipes so a
      # descendant that escaped the group cannot hold them open.
      def settle(workers, streams)
        deadline = monotonic_time + TERMINATION_GRACE
        workers.each { |worker| worker.join(POLL_INTERVAL) } while workers.any?(&:alive?) && monotonic_time < deadline
        return if workers.none?(&:alive?)

        streams.each do |stream|
          stream.close unless stream.closed?
        rescue IOError
          nil
        end
        workers.each { |worker| worker.join(TERMINATION_GRACE) }
        raise CleanupError, "command output readers did not stop" if workers.any?(&:alive?)
      end

      def drain(io, binary:)
        io.binmode
        captured = String.new(encoding: Encoding::BINARY)
        truncated = false
        begin
          loop do
            chunk = io.readpartial(READ_CHUNK_BYTES)
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
