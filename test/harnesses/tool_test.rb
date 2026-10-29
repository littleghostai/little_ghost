# frozen_string_literal: true

require "test_helper"

class HarnessToolTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/claude_code/success.jsonl", __dir__)

  class RecordingRun
    def initialize
      @events = []
    end

    attr_reader :events

    def run_scoped
      @shared = {}
      @closers = []
      define_singleton_method(:shared_resource) { |key, &block| @shared.key?(key) ? @shared[key] : (@shared[key] = block.call) }
      define_singleton_method(:register) { |&block| @closers << block }
      define_singleton_method(:close) { @closers.reverse_each(&:call) }
      self
    end

    def publish(type, **data)
      event = LittleGhost::StreamEvent.build(type, **data)
      @events << event
      event
    end
  end

  class FixtureSandbox
    def initialize(workspace: nil)
      @workspace = workspace
      @homes = []
    end

    attr_reader :command, :options, :workspace, :homes

    def capabilities = LittleGhost::Sandbox::Capabilities.new(features: [], network_modes: [:none], isolation: :namespace)

    def effective_policy = LittleGhost::Sandbox::Policy.new(runtime_paths: {scratch: :read_write}, network: :none)

    def start_program(command, **options)
      @command = command
      @options = options
      @homes << options.dig(:environment, "HOME")
      FixtureSession.new(File.read(FIXTURE))
    end
  end

  class FixtureSession
    def initialize(output)
      @output = output
    end

    def read(timeout: 0)
      output, @output = @output, ""
      LittleGhost::Sandbox::ProcessSession::Chunk.new(stdout: output, stderr: "", eof: output.empty?)
    end

    def wait(timeout: nil) = Struct.new(:exitstatus).new(0)

    def terminate = nil

    def close_write = nil

    def close = nil
  end

  class DelegateCodingTask < LittleGhost::Harnesses::Tool
    harnesses claude_code: {executable: "/opt/harnesses/bin/claude", home: "/home/agent", defaults: {base_url: "http://127.0.0.1:3130"}}
    budget default: 2, maximum: 10
    timeout default: 900, maximum: 3600
  end

  def bound(tool_class, sandbox: FixtureSandbox.new, run: RecordingRun.new)
    [tool_class.new(binding: LittleGhost::Tool::Binding.new(sandbox:, run:)), sandbox, run]
  end

  def test_runs_the_configured_harness_and_publishes_its_events
    tool, sandbox, run = bound(DelegateCodingTask)

    result = tool.execute({"task" => "Show the current commit.", "budget_usd" => 0, "timeout_seconds" => 0})
    value = JSON.parse(result.content)

    assert result.success?
    assert_equal "completed", value.fetch("status")
    assert_equal "The current commit is 3f9c2ab.", value.fetch("text")
    assert_equal "7f0c2b8e-4a1d-4b9e-9c35-2f6d1e8a9b10", value.fetch("session_id")
    assert_equal 8438, value.dig("usage", "total_tokens")
    refute value.key?("stderr_tail")
    assert_equal "/opt/harnesses/bin/claude", sandbox.command.first
    assert_equal ["--max-budget-usd", "2"], sandbox.command.each_cons(2).find { |flag, _| flag == "--max-budget-usd" }
    assert_equal %i[start text tool_call tool_result text usage stop], run.events.map { |event| event.data[:event][:kind] }
    assert(run.events.all? { |event| event.type == :harness })
    tool_call, tool_result = run.events.map { |event| event.data[:event] }.values_at(2, 3)
    assert_equal({kind: :tool_call, id: "toolu_01Example", name: "Bash"}, tool_call)
    assert_equal({kind: :tool_result, id: "toolu_01Example", error: false}, tool_result)
  end

  def test_event_data_hook_can_publish_tool_inputs
    verbose = Class.new(DelegateCodingTask) do
      define_method(:harness_event_data) { |event| event.data }
    end
    tool, _, run = bound(verbose)

    tool.execute({"task" => "Show the current commit."})

    assert_includes run.events[2].data.dig(:event, :input), "git rev-parse"
  end

  def test_only_sessions_started_in_this_run_can_be_resumed
    tool, sandbox, = bound(DelegateCodingTask)
    session_id = "7f0c2b8e-4a1d-4b9e-9c35-2f6d1e8a9b10"

    refused = tool.execute({"task" => "Continue.", "session_id" => session_id})
    started = tool.execute({"task" => "Show the current commit."})
    resumed = tool.execute({"task" => "Continue.", "session_id" => session_id})
    other, = bound(DelegateCodingTask)

    assert refused.error?
    assert_includes refused.content, "Only sessions started earlier in this run"
    assert started.success?
    assert resumed.success?
    assert_includes sandbox.command, session_id
    assert other.execute({"task" => "Continue.", "session_id" => session_id}).error?
  end

  def test_each_harness_gets_one_private_home_per_run
    scoped = Class.new(DelegateCodingTask) do
      harnesses claude_code: {executable: "/opt/harnesses/bin/claude", home_root: :scratch}
    end
    Dir.mktmpdir do |directory|
      workspace = LittleGhost::Workspace.new(root: directory, paths: {scratch: "scratch"}).open
      sandbox = FixtureSandbox.new(workspace:)
      run = RecordingRun.new.run_scoped
      tool, = bound(scoped, sandbox:, run:)

      tool.execute({"task" => "Show the current commit."})
      tool.execute({"task" => "Show the current commit again."})
      home = sandbox.homes.first

      assert_equal [home, home], sandbox.homes
      assert_equal File.join(directory, "scratch"), File.dirname(home)
      assert_equal 0o700, File.stat(home).mode & 0o777
      run.close
      refute File.exist?(home)
    end
  end

  def test_long_final_text_is_shortened_for_the_model
    tool, = bound(DelegateCodingTask)
    result = LittleGhost::Harnesses::Result.new(harness: :claude_code, status: :completed, text: "a" * 20_000)

    value = tool.send(:result_value, result)

    assert_equal 16_001, value.fetch(:text).length
    assert value.fetch(:text_truncated)
  end

  def test_schema_and_description_follow_configuration
    schema = DelegateCodingTask.input_schema

    assert_equal ["task"], schema.fetch("required")
    assert_equal ["claude_code"], schema.dig("properties", "harness", "enum")
    assert_equal 10, schema.dig("properties", "budget_usd", "maximum")
    assert_equal 3600, schema.dig("properties", "timeout_seconds", "maximum")
    assert_includes DelegateCodingTask.description, "claude_code"
    assert DelegateCodingTask.exclusive
    assert_equal "delegate_to_harness", DelegateCodingTask.tool_name
  end

  def test_unknown_harness_and_invalid_session_are_model_visible_errors
    multiple = Class.new(DelegateCodingTask) { harnesses :claude_code, codex: {home: "/home/agent"} }
    tool, = bound(multiple)

    unknown = tool.execute({"task" => "Show the current commit.", "harness" => "other"})
    invalid = tool.execute({"task" => "Show the current commit.", "harness" => "claude_code", "session_id" => "--resume"})

    assert unknown.error?
    assert_includes unknown.content, "codex"
    assert invalid.error?
    assert_includes invalid.content, "session_id"
  end

  def test_served_tools_are_reachable_only_while_the_harness_works
    lookup = Class.new(LittleGhost::Tool) do
      tool_name "policy_lookup"
      description "Looks up a policy."
      define_method(:call) { |_input| "Refunds take five days." }
    end
    Dir.mktmpdir("lg", "/tmp") do |directory|
      socket = File.join(directory, "tools.sock")
      serving = Class.new(DelegateCodingTask) { serve_tools lookup, socket:, url: "http://127.0.0.1:3133/mcp", name: "support" }
      sandbox = FixtureSandbox.new
      listed = nil
      sandbox.define_singleton_method(:start_program) do |command, **options|
        listed = UNIXSocket.open(socket) do |client|
          body = JSON.generate({jsonrpc: "2.0", id: 1, method: "tools/list"})
          client.write("POST /mcp HTTP/1.1\r\ncontent-length: #{body.bytesize}\r\n\r\n#{body}")
          JSON.parse(client.read.split("\r\n\r\n", 2).last).dig("result", "tools").map { |tool| tool.fetch("name") }
        end
        super(command, **options)
      end
      tool, = bound(serving, sandbox:)

      assert tool.execute({"task" => "Show the current commit."}).success?
      assert_equal ["policy_lookup"], listed
      assert_equal({"mcpServers" => {"support" => {"type" => "http", "url" => "http://127.0.0.1:3133/mcp"}}},
        JSON.parse(sandbox.command[sandbox.command.index("--mcp-config") + 1]))
      refute File.exist?(socket)
    end
  end

  def test_configuration_is_validated
    assert_raises(ArgumentError) { Class.new(LittleGhost::Harnesses::Tool) { serve_tools socket: "tools.sock", url: "http://127.0.0.1:3133/mcp" } }
    assert_raises(ArgumentError) { Class.new(LittleGhost::Harnesses::Tool) { serve_tools socket: "/run/tools.sock", url: "unix:/run/tools.sock" } }
    assert_raises(LittleGhost::ConfigurationError) { Class.new(LittleGhost::Harnesses::Tool) { harnesses :unknown } }
    assert_raises(ArgumentError) { Class.new(LittleGhost::Harnesses::Tool) { budget default: 20, maximum: 10 } }
    assert_raises(ArgumentError) { Class.new(LittleGhost::Harnesses::Tool) { timeout default: 0, maximum: 10 } }
    assert_raises(ArgumentError) { Class.new(LittleGhost::Harnesses::Tool) { harnesses claude_code: {homedir: "/home/agent"} } }
  end

  def test_publish_event_reaches_the_bound_run
    tool_class = Class.new(LittleGhost::Tool) do
      tool_name "help_center_sync"
      description "Sync help center articles."
      input_schema type: "object"

      def call(_input)
        publish_event(:help_center_sync, phase: "fetching", article_count: 12)
        "synced"
      end
    end
    run = RecordingRun.new
    tool = tool_class.new(binding: LittleGhost::Tool::Binding.new(run:))

    assert tool.execute({}).success?
    assert_equal [[:help_center_sync, {phase: "fetching", article_count: 12}]], run.events.map { |event| [event.type, event.data] }
    assert_nil tool_class.new.publish_event(:help_center_sync, phase: "idle")
    %i[subagent run_cancel run_partial text_delta invocation_stop harness].each do |type|
      assert_raises(ArgumentError, type.inspect) { tool.publish_event(type) }
    end
    assert_raises(ArgumentError) { tool.publish_event(:assembly_step_start, step_id: "a") }
  end
end
