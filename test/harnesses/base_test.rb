# frozen_string_literal: true

require "tmpdir"
require "test_helper"

class HarnessBaseTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures", __dir__)
  Status = Struct.new(:exitstatus)

  class FakeSession
    def initialize(chunks:, exit_code: 0, hang: false, stderr: "")
      @chunks = chunks.dup
      @exit_code = exit_code
      @hang = hang
      @stderr = stderr
      @terminated = false
      @closed = false
    end

    attr_reader :terminated, :closed

    def read(timeout: 0)
      if @terminated || (@chunks.empty? && !@hang)
        return LittleGhost::Sandbox::ProcessSession::Chunk.new(stdout: "", stderr: "", eof: true)
      end

      if @chunks.empty?
        sleep(timeout)
        return LittleGhost::Sandbox::ProcessSession::Chunk.new(stdout: "", stderr: "", eof: false)
      end

      stderr = @stderr
      @stderr = ""
      LittleGhost::Sandbox::ProcessSession::Chunk.new(stdout: @chunks.shift, stderr:, eof: false)
    end

    def wait(timeout: nil)
      Status.new(@terminated ? nil : @exit_code)
    end

    def terminate
      @terminated = true
    end

    def close
      @closed = true
    end
  end

  class FakeSandbox
    def initialize(session)
      @session = session
    end

    attr_reader :command, :options

    def start_program(command, **options)
      @command = command
      @options = options
      @session
    end
  end

  def fixture_chunks(path, size)
    File.binread(File.join(FIXTURES, path)).scan(/.{1,#{size}}/m)
  end

  def request(**values)
    LittleGhost::Harnesses::Request.new(prompt: "Add a test for the refund policy lookup.", **values)
  end

  def test_run_streams_events_across_split_lines_and_returns_a_result
    session = FakeSession.new(chunks: fixture_chunks("claude_code/success.jsonl", 37), stderr: "warming up\n")
    sandbox = FakeSandbox.new(session)
    harness = LittleGhost::Harnesses::ClaudeCode.new(sandbox:, home: "/home/agent", defaults: {base_url: "http://127.0.0.1:3130"})
    events = []

    result = harness.run(request(cwd: "repository", environment: {"SUPPORT_PORTAL_ENV" => "test"})) { |event| events << event }

    assert_equal :completed, result.status
    assert_equal :claude_code, result.harness
    assert_equal "The current commit is 3f9c2ab.", result.text
    assert_equal "7f0c2b8e-4a1d-4b9e-9c35-2f6d1e8a9b10", result.session_id
    assert_equal 0, result.exit_code
    assert_equal "warming up\n", result.stderr_tail
    assert_equal %i[start text tool_call tool_result text usage stop], events.map { |event| event.data[:event][:kind] }
    assert(events.all? { |event| event.type == :harness && event.data[:harness] == :claude_code })
    assert_equal({kind: :stop, status: :completed, stop_reason: "success", cost_usd: 0.0218, turns: 2, exit_code: 0}, events.last.data[:event])
    assert_equal '{"command":"git rev-parse --short HEAD","description":"Show the current commit"}', events[2].data[:event][:input]
    assert_equal "repository", sandbox.options[:cwd]
    assert_equal "http://127.0.0.1:3130", sandbox.options[:environment]["ANTHROPIC_BASE_URL"]
    assert_equal "test", sandbox.options[:environment]["SUPPORT_PORTAL_ENV"]
    assert session.closed
  end

  def test_timeout_stops_the_process
    session = FakeSession.new(chunks: [File.read(File.join(FIXTURES, "codex/success.jsonl")).lines.first], hang: true)
    harness = LittleGhost::Harnesses::Codex.new(sandbox: FakeSandbox.new(session), home: "/home/agent")

    result = harness.run(request(timeout: 0.2))

    assert_equal :timed_out, result.status
    assert_equal "0199a213-81c0-7800-8aa1-bbab2a035a53", result.session_id
    assert session.terminated
    assert session.closed
  end

  def test_reported_cost_over_budget_stops_the_process
    session = FakeSession.new(chunks: fixture_chunks("open_code/success.jsonl", 4096), hang: true)
    harness = LittleGhost::Harnesses::OpenCode.new(sandbox: FakeSandbox.new(session), home: "/home/agent")
    events = []

    result = harness.run(request(budget_usd: 0.002)) { |event| events << event.data[:event] }

    assert_equal :budget_exceeded, result.status
    assert_in_delta 0.0031, result.cost_usd
    assert_nil result.text
    assert_equal :budget_exceeded, events.last[:status]
    assert session.terminated
  end

  def test_reported_turns_over_the_limit_stop_the_process
    turn = '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5}}'
    session = FakeSession.new(chunks: ["#{turn}\n#{turn}\n#{turn}\n"], hang: true)
    harness = LittleGhost::Harnesses::Codex.new(sandbox: FakeSandbox.new(session), home: "/home/agent")

    result = harness.run(request(max_turns: 1))

    assert_equal :turns_exceeded, result.status
    assert_equal 2, result.turns
    assert session.terminated
  end

  def test_cancellation_stops_the_process_and_raises
    session = FakeSession.new(chunks: [], hang: true)
    harness = LittleGhost::Harnesses::Codex.new(sandbox: FakeSandbox.new(session), home: "/home/agent")
    token = LittleGhost::Support::CancellationToken.new
    context = LittleGhost::RunContext.new(cancellation_token: token)
    events = []

    canceller = Thread.new do
      sleep(0.05)
      token.cancel
    end
    assert_raises(LittleGhost::CancelledError) { harness.run(request, context:) { |event| events << event } }

    assert session.terminated
    assert session.closed
    assert_empty events
  ensure
    canceller&.join
  end

  def test_malformed_lines_and_nonzero_exit_fail_without_raising
    session = FakeSession.new(chunks: fixture_chunks("codex/turn_failed.jsonl", 4096), exit_code: 1)
    harness = LittleGhost::Harnesses::Codex.new(sandbox: FakeSandbox.new(session), home: "/home/agent")

    result = harness.run(request)

    assert_equal :failed, result.status
    assert_equal 1, result.exit_code
    assert_equal "turn_failed", result.stop_reason
  end

  def test_output_limit_fails_the_run
    session = FakeSession.new(chunks: ["{}\n"])
    def session.read(timeout: 0) = raise(LittleGhost::ToolError, "output exceeded")
    harness = LittleGhost::Harnesses::Codex.new(sandbox: FakeSandbox.new(session), home: "/home/agent")

    result = harness.run(request)

    assert_equal :failed, result.status
    assert_equal "output_limit", result.stop_reason
    assert session.terminated
  end

  def test_runs_a_real_process_through_an_unrestricted_sandbox
    fixture = File.join(FIXTURES, "open_code/success.jsonl")
    harness_class = Class.new(LittleGhost::Harnesses::OpenCode) do
      define_method(:command) { |_request| ["/bin/cat", fixture] }
    end
    Dir.mktmpdir do |directory|
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(workspace: LittleGhost::Workspace.new(root: directory))
      harness = harness_class.new(sandbox:, home: directory)

      result = harness.run(request)

      assert_equal :completed, result.status
      assert_equal "The current commit is 3f9c2ab.", result.text
      assert_equal 0, result.exit_code
    ensure
      sandbox&.close
    end
  end

  def test_probe_reports_version_support
    sandbox = Object.new
    def sandbox.execute_program(command, **)
      LittleGhost::Sandbox::Execution.new(stdout: "2.1.4 (Claude Code)\n", stderr: "", exit_code: 0)
    end
    old = Object.new
    def old.execute_program(command, **)
      LittleGhost::Sandbox::Execution.new(stdout: "codex-cli 0.40.0\n", stderr: "", exit_code: 0)
    end

    assert_equal({available: true, version: "2.1.4", supported: true, reason: nil},
      LittleGhost::Harnesses::ClaudeCode.new(sandbox:, home: "/home/agent").probe)
    refute LittleGhost::Harnesses::Codex.new(sandbox: old, home: "/home/agent").probe[:supported]
  end

  def test_claude_code_command_line
    harness = LittleGhost::Harnesses::ClaudeCode.new(
      sandbox: Object.new,
      executable: "/opt/harnesses/bin/claude",
      home: "/home/agent",
      defaults: {base_url: "http://127.0.0.1:3130"}
    )
    request = request(
      budget_usd: 0.25,
      max_turns: 30,
      add_dirs: ["/workspace/shared"],
      instructions: "Do not commit.",
      session_id: "7f0c2b8e-4a1d-4b9e-9c35-2f6d1e8a9b10"
    )

    assert_equal [
      "/opt/harnesses/bin/claude", "-p", "--bare",
      "--allowedTools", "Bash,Read,Edit,Write,Glob,Grep,Agent",
      "--disallowedTools", "WebFetch,WebSearch",
      "--permission-prompts", "none",
      "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
      "--max-budget-usd", "0.25", "--max-turns", "30",
      "--add-dir", "/workspace/shared",
      "--append-system-prompt", "Do not commit.",
      "--resume", "7f0c2b8e-4a1d-4b9e-9c35-2f6d1e8a9b10",
      "--output-format", "stream-json", "--verbose",
      "Add a test for the refund policy lookup."
    ], harness.command(request)
    assert_equal({
      "ANTHROPIC_API_KEY" => "little-ghost-placeholder",
      "CLAUDE_CONFIG_DIR" => "/home/agent/.claude",
      "DISABLE_AUTOUPDATER" => "1",
      "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1",
      "ANTHROPIC_BASE_URL" => "http://127.0.0.1:3130"
    }, harness.environment(request))
  end

  def test_codex_command_line
    harness = LittleGhost::Harnesses::Codex.new(
      sandbox: Object.new,
      home: "/home/agent",
      defaults: {base_url: "http://127.0.0.1:3131/v1", model: "gpt-5.2-codex"}
    )

    assert_equal [
      "codex", "exec", "--json", "-C", ".", "--sandbox", "danger-full-access",
      "-c", 'approval_policy="never"', "-c", "check_for_update_on_startup=false",
      "--skip-git-repo-check", "-o", "/home/agent/last-message.md",
      "-c", 'model_provider="little_ghost"',
      "-c", 'model_providers.little_ghost.name="LittleGhost"',
      "-c", 'model_providers.little_ghost.base_url="http://127.0.0.1:3131/v1"',
      "-c", 'model_providers.little_ghost.env_key="OPENAI_API_KEY"',
      "-c", 'model_providers.little_ghost.wire_api="responses"',
      "-m", "gpt-5.2-codex",
      "resume", "0199a213-81c0-7800-8aa1-bbab2a035a53",
      "Do not commit.\n\nAdd a test for the refund policy lookup."
    ], harness.command(request(session_id: "0199a213-81c0-7800-8aa1-bbab2a035a53", instructions: "Do not commit."))
    assert_equal({"CODEX_HOME" => "/home/agent/.codex", "OPENAI_API_KEY" => "little-ghost-placeholder"},
      harness.environment(request))
  end

  def test_open_code_command_line_and_configuration
    harness = LittleGhost::Harnesses::OpenCode.new(
      sandbox: Object.new,
      home: "/home/agent",
      defaults: {provider: "openrouter", base_url: "http://127.0.0.1:3132/api/v1", config: {"model" => "openrouter/example/coder"}}
    )

    assert_equal ["opencode", "run", "--format", "json", "--agent", "build", "--session", "ses_6a1f2b3c4d5eExample", "--", "-v please"],
      harness.command(LittleGhost::Harnesses::Request.new(prompt: "-v please", session_id: "ses_6a1f2b3c4d5eExample"))
    environment = harness.environment(request)
    configuration = JSON.parse(environment.fetch("OPENCODE_CONFIG_CONTENT"))

    assert_equal '{"*":"allow"}', environment.fetch("OPENCODE_PERMISSION")
    assert_equal "1", environment.fetch("OPENCODE_DISABLE_PROJECT_CONFIG")
    assert_equal "/home/agent/.config", environment.fetch("XDG_CONFIG_HOME")
    assert_equal false, configuration.fetch("autoupdate")
    assert_equal({}, configuration.fetch("mcp"))
    assert_equal "openrouter/example/coder", configuration.fetch("model")
    assert_equal({"apiKey" => "little-ghost-placeholder", "baseURL" => "http://127.0.0.1:3132/api/v1"},
      configuration.dig("provider", "openrouter", "options"))
  end

  def test_requests_reject_values_that_could_become_options
    assert_raises(ArgumentError) { request(session_id: "--dangerously-skip-permissions") }
    assert_raises(ArgumentError) { request(model: "-x") }
    assert_raises(ArgumentError) { request(add_dirs: ["relative"]) }
    assert_raises(ArgumentError) { request(budget_usd: 0) }
    assert_raises(ArgumentError) { request(max_turns: 1.5) }
    assert_raises(ArgumentError) { request(timeout: -1) }
    assert_raises(ArgumentError) { LittleGhost::Harnesses::Request.new(prompt: " ") }
  end

  def test_registry
    assert_equal LittleGhost::Harnesses::Codex, LittleGhost::Harnesses.resolve("codex")
    assert_includes LittleGhost::Harnesses.names, :open_code
    assert_raises(LittleGhost::ConfigurationError) { LittleGhost::Harnesses.resolve(:unknown) }
    assert_raises(ArgumentError) { LittleGhost::Harnesses.register(:invalid, String) }
  end
end
