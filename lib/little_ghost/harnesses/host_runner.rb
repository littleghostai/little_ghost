# frozen_string_literal: true

module LittleGhost
  module Harnesses
    # Starts harness processes directly on the host when a harness has no
    # Sandbox. Children inherit the host environment so a tool can find the
    # user's own credentials; LittleGhost never reads them.
    class HostRunner # :nodoc:
      DEFAULT_OUTPUT_BYTES = 1_000_000
      POLL_INTERVAL = 0.1
      EXIT_WAIT = 5

      def start_program(command, context: nil, environment: {}, cwd: nil, output_bytes: nil, **)
        context&.check!
        Sandbox::ProcessSession.new(
          command:,
          environment:,
          inherit_environment: true,
          chdir: cwd && File.expand_path(cwd),
          output_bytes: output_bytes || DEFAULT_OUTPUT_BYTES
        )
      rescue SystemCallError => error
        raise ToolError, "#{Array(command).first} could not be started: #{error.class}"
      end

      def execute_program(command, timeout:, context: nil, max_output_bytes: nil, environment: {}, **)
        session = start_program(command, context:, environment:, output_bytes: max_output_bytes)
        session.close_write
        stdout = +""
        stderr = +""
        deadline = monotonic_time + Float(timeout)
        loop do
          context&.check!
          remaining = deadline - monotonic_time
          raise ToolError, "#{Array(command).first} timed out" if remaining <= 0

          chunk = session.read(timeout: [remaining, POLL_INTERVAL].min)
          stdout << chunk.stdout
          stderr << chunk.stderr
          break if chunk.eof
        end
        status = session.wait(timeout: EXIT_WAIT)
        Sandbox::Execution.new(stdout:, stderr:, exit_code: status&.exitstatus)
      ensure
        session&.close
      end

      private

      def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
