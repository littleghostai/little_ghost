# frozen_string_literal: true

require "test_helper"

class HarnessParsersTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures", __dir__)

  def parse(harness_class, fixture)
    harness = harness_class.new(sandbox: Object.new, home: "/home/agent")
    state = LittleGhost::Harnesses::State.new
    events = File.readlines(File.join(FIXTURES, fixture), chomp: true).flat_map do |line|
      harness.parse_line(line, state)
    rescue JSON::ParserError
      state.malformed_lines += 1
      []
    end
    [events, state]
  end

  def test_claude_code_stream_json_success
    events, state = parse(LittleGhost::Harnesses::ClaudeCode, "claude_code/success.jsonl")

    assert_equal %i[start text tool_call tool_result text usage], events.map { |event| event[:kind] }
    assert_equal({kind: :start, model: "claude-sonnet-4-5", version: "2.1.4"}, events.first)
    assert_equal({kind: :tool_call, id: "toolu_01Example", name: "Bash", input: {"command" => "git rev-parse --short HEAD", "description" => "Show the current commit"}}, events[2])
    assert_equal({kind: :tool_result, id: "toolu_01Example", error: false, output: "3f9c2ab"}, events[3])
    assert_equal "7f0c2b8e-4a1d-4b9e-9c35-2f6d1e8a9b10", state.session_id
    assert_equal "The current commit is 3f9c2ab.", state.text
    assert_equal :completed, state.status
    assert_equal "success", state.stop_reason
    assert_in_delta 0.0218, state.cost_usd
    assert_equal 2, state.turns
    assert_equal({input_tokens: 9, output_tokens: 94, cache_read_tokens: 4120, cache_write_tokens: 4215, reasoning_tokens: 0, total_tokens: 8438},
      state.usage.to_h)
    assert_in_delta 0.0218, events.last[:cost_usd]
  end

  def test_claude_code_reports_budget_exhaustion
    events, state = parse(LittleGhost::Harnesses::ClaudeCode, "claude_code/budget_exceeded.jsonl")

    assert_equal :budget_exceeded, state.status
    assert_equal "error_max_budget_usd", state.stop_reason
    assert_nil state.text
    assert_equal 7, state.turns
    assert_equal "     1\tclass RefundPolicy\n     2\tend", events.find { |event| event[:kind] == :tool_result }[:output]
  end

  def test_claude_code_maps_turn_limits_and_unknown_errors
    harness = LittleGhost::Harnesses::ClaudeCode.new(sandbox: Object.new, home: "/home/agent")
    turns = LittleGhost::Harnesses::State.new
    failed = LittleGhost::Harnesses::State.new

    harness.parse_line('{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":5}', turns)
    harness.parse_line('{"type":"result","subtype":"error_during_execution","is_error":true}', failed)

    assert_equal :turns_exceeded, turns.status
    assert_equal :failed, failed.status
  end

  def test_codex_exec_json_success
    events, state = parse(LittleGhost::Harnesses::Codex, "codex/success.jsonl")

    assert_equal %i[start tool_call tool_result tool_call tool_result tool_call tool_result text usage],
      events.map { |event| event[:kind] }
    assert_equal "0199a213-81c0-7800-8aa1-bbab2a035a53", state.session_id
    assert_equal({kind: :tool_result, id: "item_3", error: true, output: "1 runs, 2 assertions, 1 failures, 0 errors, 0 skips\n"}, events[6])
    assert_equal "add test/models/refund_policy_test.rb", events[3][:input]
    assert_match(/RefundPolicy.lookup/, state.text)
    assert_nil state.status
    assert_equal 1, state.turns
    assert_nil state.cost_usd
    assert_equal 315, state.usage.input_tokens
    assert_equal 24_448, state.usage.cache_read_tokens
    assert_equal 122, state.usage.output_tokens
  end

  def test_codex_turn_failure_and_malformed_lines
    events, state = parse(LittleGhost::Harnesses::Codex, "codex/turn_failed.jsonl")

    assert_equal [:start], events.map { |event| event[:kind] }
    assert_equal :failed, state.status
    assert_equal "turn_failed", state.stop_reason
    assert_equal 1, state.malformed_lines
  end

  def test_open_code_run_json_success
    events, state = parse(LittleGhost::Harnesses::OpenCode, "open_code/success.jsonl")

    assert_equal %i[start tool_call tool_result usage text usage], events.map { |event| event[:kind] }
    assert_equal "ses_6a1f2b3c4d5eExample", state.session_id
    assert_equal({kind: :tool_result, id: "call_01", error: false, output: "3f9c2ab\n"}, events[2])
    assert_equal "The current commit is 3f9c2ab.", state.text
    assert_equal "stop", state.stop_reason
    assert_equal 2, state.turns
    assert_in_delta 0.0043, state.cost_usd
    assert_equal 10_511, state.usage.input_tokens
    assert_equal 5_120, state.usage.cache_read_tokens
  end

  def test_open_code_errors
    events, state = parse(LittleGhost::Harnesses::OpenCode, "open_code/error.jsonl")

    assert_equal %i[start tool_call tool_result], events.map { |event| event[:kind] }
    assert events.last[:error]
    assert_equal :failed, state.status
    assert_equal "APIError", state.stop_reason
  end

  def test_parsers_ignore_unknown_and_non_object_messages
    [LittleGhost::Harnesses::ClaudeCode, LittleGhost::Harnesses::Codex, LittleGhost::Harnesses::OpenCode].each do |harness_class|
      harness = harness_class.new(sandbox: Object.new, home: "/home/agent")
      state = LittleGhost::Harnesses::State.new

      assert_empty harness.parse_line('{"type":"future_event","value":1}', state)
      assert_empty harness.parse_line("[1, 2]", state)
      assert_empty harness.parse_line('{"type":"assistant","message":{"content":"text"}}', state)
    end
  end
end
