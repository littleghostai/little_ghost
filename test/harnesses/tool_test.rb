# frozen_string_literal: true

require "test_helper"

class HarnessToolTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/claude_code/success.jsonl", __dir__)

  class RecordingRun
    def initialize
      @events = []
    end

    attr_reader :events

    def publish(type, **data)
      event = LittleGhost::StreamEvent.build(type, **data)
      @events << event
      event
    end
  end

  class FixtureSandbox
    attr_reader :command, :options

    def start_program(command, **options)
      @command = command
      @options = options
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

  def test_configuration_is_validated
    assert_raises(LittleGhost::ConfigurationError) { Class.new(LittleGhost::Harnesses::Tool) { harnesses :unknown } }
    assert_raises(ArgumentError) { Class.new(LittleGhost::Harnesses::Tool) { budget default: 20, maximum: 10 } }
    assert_raises(ArgumentError) { Class.new(LittleGhost::Harnesses::Tool) { timeout default: 0, maximum: 10 } }
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
    assert_raises(ArgumentError) { tool.publish_event(:subagent, event: nil) }
    assert_raises(ArgumentError) { tool.publish_event(:assembly_step_start, step_id: "a") }
  end
end
