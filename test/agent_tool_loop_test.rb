# frozen_string_literal: true

require "test_helper"

class AgentToolLoopTest < Minitest::Test
  def test_warns_then_terminates_identical_tool_loop
    agent = build_agent
    context = LittleGhost::RunContext.new
    run_callback(agent, :before_invocation, {}, context)
    tool_use = LittleGhost::Content::ToolUse.new(id: "1", name: "search", input: {"q" => "same"})
    tool = LittleGhost::Tool.define(name: "search", description: "Search") { "same result" }.new
    result = LittleGhost::Tool::ExecutionResult.new(content: "same result", status: :success)

    first = call_tool(agent, tool_use, tool, result, context)
    second = call_tool(agent, tool_use.with(id: "2"), tool, result, context)
    third = call_tool(agent, tool_use.with(id: "3"), tool, result, context)
    fourth_before = run_callback(agent, :before_tool, {tool_use: tool_use.with(id: "4"), tool: tool}, context)

    assert first.continue?
    assert_includes second.value.fetch(:result).content, framework_prompt("tools/loop/notices/warning")
    assert_includes third.value.fetch(:result).content, framework_prompt("tools/loop/notices/final_warning")
    assert fourth_before.cancel?
    assert_raises(LittleGhost::ToolLoopError) { run_callback(agent, :before_model, {}, context) }
  end

  def test_changed_result_resets_repeat_count
    agent = build_agent
    context = LittleGhost::RunContext.new
    run_callback(agent, :before_invocation, {}, context)
    tool_use = LittleGhost::Content::ToolUse.new(id: "1", name: "search", input: {})
    tool = LittleGhost::Tool.define(name: "search", description: "Search") { "result" }.new

    first = call_tool(agent, tool_use, tool, execution("one"), context)
    second = call_tool(agent, tool_use.with(id: "2"), tool, execution("two"), context)

    assert first.continue?
    assert second.continue?
  end

  def test_false_and_nil_tool_arguments_do_not_collide
    agent = build_agent
    context = LittleGhost::RunContext.new
    run_callback(agent, :before_invocation, {}, context)
    tool = LittleGhost::Tool.define(name: "search", description: "Search") { "result" }.new
    false_use = LittleGhost::Content::ToolUse.new(id: "1", name: "search", input: {"enabled" => false})
    nil_use = LittleGhost::Content::ToolUse.new(id: "2", name: "search", input: {"enabled" => nil})

    first = call_tool(agent, false_use, tool, execution("same"), context)
    second = call_tool(agent, nil_use, tool, execution("same"), context)

    assert first.continue?
    assert second.continue?
  end

  def test_concurrent_invocations_have_independent_loop_state
    agent = build_agent
    first_context = LittleGhost::RunContext.new
    second_context = LittleGhost::RunContext.new
    run_callback(agent, :before_invocation, {}, first_context)
    run_callback(agent, :before_invocation, {}, second_context)
    tool = LittleGhost::Tool.define(name: "search", description: "Search") { "result" }.new
    use = LittleGhost::Content::ToolUse.new(id: "1", name: "search", input: {})

    call_tool(agent, use, tool, execution("same"), first_context)
    first_repeat = call_tool(agent, use.with(id: "2"), tool, execution("same"), first_context)
    second_first = call_tool(agent, use.with(id: "3"), tool, execution("same"), second_context)

    assert first_repeat.replace?
    assert second_first.continue?
  end

  def test_active_invocation_loop_state_survives_garbage_collection
    agent = build_agent
    context = LittleGhost::RunContext.new
    run_callback(agent, :before_invocation, {}, context)
    tool = LittleGhost::Tool.define(name: "search", description: "Search") { "result" }.new
    use = LittleGhost::Content::ToolUse.new(id: "1", name: "search", input: {})

    assert call_tool(agent, use, tool, execution("same"), context).continue?
    GC.start
    warning = call_tool(agent, use.with(id: "2"), tool, execution("same"), context)

    assert warning.replace?
    assert_includes warning.value.fetch(:result).content, framework_prompt("tools/loop/notices/warning")
  end

  def test_bounds_invocation_state_left_by_failed_runs
    agent = build_agent
    limit = LittleGhost::Agent::ToolLoop::TRACKED_INVOCATION_LIMIT

    (limit + 1).times do
      run_callback(agent, :before_invocation, {}, LittleGhost::RunContext.new)
    end

    states = agent.instance_variable_get(:@tool_loop_runs)
    assert_equal limit, states.length
  end

  def test_parallel_identical_calls_count_as_one_repetition
    agent = build_agent
    context = LittleGhost::RunContext.new
    run_callback(agent, :before_invocation, {}, context)
    tool = LittleGhost::Tool.define(name: "search", description: "Search") { "result" }.new
    first = LittleGhost::Content::ToolUse.new(id: "1", name: "search", input: {"q" => "same"})
    second = first.with(id: "2")

    assert run_callback(agent, :before_tool, {tool_use: first, tool: tool}, context).continue?
    assert run_callback(agent, :before_tool, {tool_use: second, tool: tool}, context).continue?
    assert run_callback(agent, :after_tool, {tool_use: second, tool: tool, result: execution("same")}, context).continue?
    assert run_callback(agent, :after_tool, {tool_use: first, tool: tool, result: execution("same")}, context).continue?

    next_call = call_tool(agent, first.with(id: "3"), tool, execution("same"), context)
    assert next_call.replace?
    assert_includes next_call.value.fetch(:result).content, framework_prompt("tools/loop/notices/warning")
  end

  def test_still_working_subagent_waits_do_not_count_as_repetitions
    agent = build_agent
    context = LittleGhost::RunContext.new
    run_callback(agent, :before_invocation, {}, context)
    tool = LittleGhost::Tool.define(name: "wait_for_subagents", description: "Wait") { "result" }.new
    use = LittleGhost::Content::ToolUse.new(id: "1", name: "wait_for_subagents", input: {})
    working = execution(JSON.generate(status: "still_working"))

    4.times do |index|
      assert call_tool(agent, use.with(id: index.to_s), tool, working, context).continue?
    end

    finished = execution(JSON.generate(status: "finished"))
    assert call_tool(agent, use.with(id: "finished-1"), tool, finished, context).continue?
    warning = call_tool(agent, use.with(id: "finished-2"), tool, finished, context)
    assert warning.replace?
  end

  def test_emits_only_one_termination_decision_for_parallel_calls
    events = []
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new
    instrumentation.subscribe(TestTelemetryRecorder.new(events))
    agent_class = Class.new(LittleGhost::Agent) do
      detect_tool_loops warning_at: 2, terminate_at: 4
    end
    agent = agent_class.new(model: Object.new)
    context = LittleGhost::RunContext.new
    run_callback(agent, :before_invocation, {}, context)
    tool = LittleGhost::Tool.define(name: "search", description: "Search") { "result" }.new
    use = LittleGhost::Content::ToolUse.new(id: "1", name: "search", input: {})
    3.times { |index| call_tool(agent, use.with(id: index.to_s), tool, execution("same"), context) }

    decisions = 2.times.map do |index|
      run_callback(agent, :before_tool, {tool_use: use.with(id: "terminal-#{index}"), tool: tool}, context)
    end

    assert decisions.all?(&:cancel?)
    terminations = events.select { |name, attributes| name == :tool_loop && attributes[:action] == :terminate }
    assert_equal 1, terminations.length
  end

  def test_emits_tool_operation_ids_with_loop_events
    events = []
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new
    instrumentation.subscribe(TestTelemetryRecorder.new(events))
    agent = build_agent
    context = LittleGhost::RunContext.new
    run_callback(agent, :before_invocation, {}, context)
    tool = LittleGhost::Tool.define(name: "search", description: "Search") { "result" }.new
    use = LittleGhost::Content::ToolUse.new(id: "1", name: "search", input: {})

    call_tool(agent, use, tool, execution("same"), context, operation_id: "tool-1", parent_operation_id: "turn")
    call_tool(agent, use.with(id: "2"), tool, execution("same"), context,
      operation_id: "tool-2", parent_operation_id: "turn")

    attributes = events.find { |name, _attributes| name == :tool_loop }.last
    assert_equal "tool-2", attributes[:operation_id]
    assert_equal "turn", attributes[:parent_operation_id]
  end

  def test_feedback_mode_suppresses_repeated_calls_and_keeps_the_agent_running
    executed = []
    search = LittleGhost::Tool.define(name: "search", description: "Search", input_schema: {
      type: "object", properties: {q: {type: "string"}}, required: ["q"]
    }) do |input|
      executed << input.fetch("q")
      "unchanged"
    end
    agent_class = Class.new(LittleGhost::Agent) do
      detect_tool_loops warning_at: 2, terminate_at: 4, on_limit: :feedback
    end
    requests = []
    model = Object.new.extend(LittleGhost::ModelInterface)
    model.define_singleton_method(:stream) do |request|
      requests << request
      turn = requests.length
      content = if turn <= 7
        LittleGhost::Content::ToolUse.new(id: turn.to_s, name: "search", input: {"q" => (turn == 6) ? "changed" : "same"})
      else
        "Finished after changing approach."
      end
      response = LittleGhost::ModelResponse.new(message: LittleGhost::Message.new(role: :assistant, content:),
        stop_reason: (turn <= 7) ? :tool_use : :end_turn, usage: LittleGhost::Usage.new)
      [LittleGhost::StreamEvent.build(:message_stop, response:)].each
    end
    agent = agent_class.new(model:, tools: [search])

    assert_equal "Finished after changing approach.", agent.call("Search").text
    assert_equal %w[same same same changed same], executed
    assert_includes requests.fetch(4).messages.last.content.first.content, "was not executed"
    refute_includes requests.fetch(3).messages.last.content.first.content, "stop the run"
  ensure
    agent&.close
  end

  def test_rejects_an_unknown_loop_limit_action
    assert_raises(ArgumentError) do
      Class.new(LittleGhost::Agent) { detect_tool_loops on_limit: :unknown }
    end
  end

  def test_failed_intervening_tool_does_not_release_suppressed_calls
    agent_class = Class.new(LittleGhost::Agent) do
      detect_tool_loops warning_at: 2, terminate_at: 4, on_limit: :feedback
    end
    agent = agent_class.new(model: Object.new)
    context = LittleGhost::RunContext.new
    run_callback(agent, :before_invocation, {}, context)
    search = LittleGhost::Tool.define(name: "search", description: "Search") { "unchanged" }.new
    use = LittleGhost::Content::ToolUse.new(id: "1", name: "search", input: {})
    3.times { |index| call_tool(agent, use.with(id: index.to_s), search, execution("unchanged"), context) }
    assert run_callback(agent, :before_tool, {tool_use: use.with(id: "blocked"), tool: search}, context).cancel?

    edit = LittleGhost::Tool.define(name: "edit", description: "Edit") { "failed" }.new
    edit_use = LittleGhost::Content::ToolUse.new(id: "edit", name: "edit", input: {})
    failed = LittleGhost::Tool::ExecutionResult.new(content: "permission denied", status: :error)
    call_tool(agent, edit_use, edit, failed, context)

    assert run_callback(agent, :before_tool, {tool_use: use.with(id: "still-blocked"), tool: search}, context).cancel?
    assert run_callback(agent, :before_model, {}, context).continue?
  ensure
    agent&.close
    search&.close
    edit&.close
  end

  def test_successful_changed_work_after_final_warning_allows_the_original_call
    agent_class = Class.new(LittleGhost::Agent) do
      detect_tool_loops warning_at: 2, terminate_at: 4, on_limit: :feedback
    end
    agent = agent_class.new(model: Object.new)
    context = LittleGhost::RunContext.new
    run_callback(agent, :before_invocation, {}, context)
    search = LittleGhost::Tool.define(name: "search", description: "Search") { "unchanged" }.new
    use = LittleGhost::Content::ToolUse.new(id: "search", name: "search", input: {})
    3.times { |index| call_tool(agent, use.with(id: index.to_s), search, execution("unchanged"), context) }

    edit = LittleGhost::Tool.define(name: "edit", description: "Edit") { "updated" }.new
    edit_use = LittleGhost::Content::ToolUse.new(id: "edit", name: "edit", input: {})
    call_tool(agent, edit_use, edit, execution("updated"), context)

    assert run_callback(agent, :before_tool, {tool_use: use.with(id: "retry"), tool: search}, context).continue?
  ensure
    agent&.close
    search&.close
    edit&.close
  end

  private

  def framework_prompt(key)
    LittleGhost::FrameworkPrompts.new.render(key)
  end

  def build_agent
    agent_class = Class.new(LittleGhost::Agent) do
      detect_tool_loops warning_at: 2, terminate_at: 4
    end
    agent_class.new(model: Object.new)
  end

  def call_tool(agent, tool_use, tool, result, context, **telemetry)
    payload = {tool_use: tool_use, tool: tool, **telemetry}
    before = run_callback(agent, :before_tool, payload, context)
    return before unless before.continue?

    run_callback(agent, :after_tool, payload.merge(result: result), context)
  end

  def run_callback(agent, name, payload, context)
    agent.send(:run_callbacks, name, payload, context:)
  end

  def execution(content)
    LittleGhost::Tool::ExecutionResult.new(content: content, status: :success)
  end
end
