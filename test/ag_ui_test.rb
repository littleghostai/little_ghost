# frozen_string_literal: true

require "test_helper"
require "little_ghost/ag_ui"

class AGUITest < Minitest::Test
  def test_translates_generic_run_events
    result = LittleGhost::RunResult.new(
      message: LittleGhost::Message.new(role: :assistant, content: "hello"),
      stop_reason: :end_turn,
      usage: LittleGhost::Usage.new(input_tokens: 2, output_tokens: 1),
      messages: [],
      state: {}
    )
    events = [
      LittleGhost::StreamEvent.build(:run_start),
      agent_event(:message_start),
      agent_event(:text_delta, text: "hello"),
      agent_event(:message_stop),
      LittleGhost::StreamEvent.build(:invocation_stop, result:),
      LittleGhost::StreamEvent.build(:run_stop, response: "hello")
    ]

    translated = LittleGhost::AGUI::Adapter.new.stream(events, thread_id: "thread", run_id: "run").to_a

    assert_equal %w[RUN_STARTED TEXT_MESSAGE_START TEXT_MESSAGE_CONTENT TEXT_MESSAGE_END CUSTOM RUN_FINISHED],
      translated.map { |event| event[:type] }
    assert_equal "little_ghost.usage", translated[-2][:name]
    assert_equal 3, translated[-2].dig(:value, :usage, :total_tokens)
    assert_equal "hello", translated.last.dig(:result, :response)
  end

  def test_translates_tool_status_and_run_failure
    tool_use = LittleGhost::Content::ToolUse.new(id: "tool-1", name: "lookup", input: {})
    result = LittleGhost::Tool::ExecutionResult.new(content: "failed", status: :error)
    events = [
      LittleGhost::StreamEvent.build(:run_start),
      agent_event(:tool_stop, tool_use:, result:),
      LittleGhost::StreamEvent.build(:run_error, message: "Agent failed")
    ]

    translated = LittleGhost::AGUI::Adapter.new.stream(events, thread_id: "thread", run_id: "run").to_a

    assert_equal %w[RUN_STARTED TOOL_CALL_RESULT RUN_ERROR], translated.map { |event| event[:type] }
    assert_equal :error, translated[1][:status]
    assert_equal "Agent failed", translated.last[:message]
  end

  def test_tool_only_messages_do_not_reference_an_unannounced_text_message
    events = [
      agent_event(:message_start),
      agent_event(:tool_call_start, index: 0, id: "tool-1", name: "lookup")
    ]

    translated = LittleGhost::AGUI::Adapter.new.stream(events, thread_id: "thread", run_id: "run").to_a

    assert_equal ["TOOL_CALL_START"], translated.map { |event| event.fetch(:type) }
    refute translated.first.key?(:parentMessageId)
  end

  def test_translates_partial_and_cancelled_runs
    events = [
      LittleGhost::StreamEvent.build(:run_partial, response: "partial"),
      LittleGhost::StreamEvent.build(:run_cancel, error: LittleGhost::CancelledError.new("stopped"))
    ]

    translated = LittleGhost::AGUI::Adapter.new.stream(events, thread_id: "thread", run_id: "run").to_a

    assert_equal %w[CUSTOM RUN_FINISHED CUSTOM RUN_FINISHED], translated.map { |event| event[:type] }
    assert_equal %w[little_ghost.run.partial little_ghost.run.canceled],
      translated.select { |event| event[:type] == "CUSTOM" }.map { |event| event[:name] }
  end

  def test_emits_aggregate_usage_before_an_abnormal_terminal_event
    usage = LittleGhost::Usage.new(
      input_tokens: 4,
      output_tokens: 2,
      cache_read_tokens: 3,
      reasoning_tokens: 1
    )
    events = [
      LittleGhost::StreamEvent.build(:usage, usage:),
      LittleGhost::StreamEvent.build(:invocation_error, error: RuntimeError.new("failed"), usage:),
      LittleGhost::StreamEvent.build(:run_error, message: "Agent failed")
    ]

    translated = LittleGhost::AGUI::Adapter.new.stream(events, thread_id: "thread", run_id: "run").to_a

    assert_equal %w[CUSTOM RUN_ERROR], translated.map { |event| event[:type] }
    assert_equal "little_ghost.usage", translated.first[:name]
    assert_equal 10, translated.first.dig(:value, :usage, :total_tokens)
    assert_equal 1, translated.count { |event| event[:name] == "little_ghost.usage" }
  end

  def test_closes_partial_text_before_a_model_retry
    source = [
      agent_event(:text_delta, text: "Partial"),
      agent_event(:model_retry, attempt: 1, partial_text: true),
      agent_event(:text_delta, text: "Complete"),
      LittleGhost::StreamEvent.build(:run_stop, response: "Complete")
    ]

    events = LittleGhost::AGUI::Adapter.new.stream(source, thread_id: "thread", run_id: "run").to_a

    assert_equal(
      %w[
        TEXT_MESSAGE_START TEXT_MESSAGE_CONTENT TEXT_MESSAGE_END CUSTOM
        TEXT_MESSAGE_START TEXT_MESSAGE_CONTENT TEXT_MESSAGE_END RUN_FINISHED
      ],
      events.map { |event| event.fetch(:type) }
    )
    retry_event = events.fetch(3)
    assert_equal "little_ghost.model_retry", retry_event.fetch(:name)
    assert_equal true, retry_event.dig(:value, :partial_text)
    assert_equal events.first.fetch(:messageId), retry_event.dig(:value, :superseded_message_id)
  end

  def test_retry_without_partial_text_has_no_superseded_message
    source = [
      agent_event(:model_retry, attempt: 1, partial_text: false),
      agent_event(:text_delta, text: "Complete"),
      LittleGhost::StreamEvent.build(:run_stop, response: "Complete")
    ]

    events = LittleGhost::AGUI::Adapter.new.stream(source, thread_id: "thread", run_id: "run").to_a
    retry_event = events.first

    assert_equal "little_ghost.model_retry", retry_event.fetch(:name)
    assert_equal false, retry_event.dig(:value, :partial_text)
    refute retry_event.fetch(:value).key?(:superseded_message_id)
  end

  def test_translates_interject_delivery_boundary
    source = [
      agent_event(
        :agent_interjection_delivered,
        interjection_ids: ["interject-1", "interject-2"],
        batch_key: "conversation"
      ),
      agent_event(:text_delta, text: "Steered response")
    ]

    events = LittleGhost::AGUI::Adapter.new.stream(source, thread_id: "thread", run_id: "run").to_a

    assert_equal "little_ghost.agent_interjection_delivered", events.first.fetch(:name)
    assert_equal ["interject-1", "interject-2"], events.first.dig(:value, :interjection_ids)
    assert_equal "conversation", events.first.dig(:value, :batch_key)
    assert_equal "TEXT_MESSAGE_START", events.fetch(1).fetch(:type)
  end

  def test_translates_reasoning_separately_from_visible_text
    reasoning = "provider reasoning"
    result = LittleGhost::RunResult.new(
      message: LittleGhost::Message.new(role: :assistant, content: "Visible answer"),
      stop_reason: :end_turn,
      usage: LittleGhost::Usage.new(output_tokens: 2, reasoning_tokens: 7),
      messages: [],
      state: {}
    )
    source = [
      agent_event(:text_delta, text: "Visible "),
      agent_event(:reasoning_delta, text: reasoning),
      agent_event(:text_delta, text: "answer"),
      agent_event(:message_stop),
      LittleGhost::StreamEvent.build(:invocation_stop, result:),
      LittleGhost::StreamEvent.build(:run_stop, response: "Visible answer")
    ]

    translated = LittleGhost::AGUI::Adapter.new.stream(source, thread_id: "thread", run_id: "run").to_a

    assert_equal %w[
      TEXT_MESSAGE_START TEXT_MESSAGE_CONTENT TEXT_MESSAGE_END
      REASONING_START REASONING_MESSAGE_START REASONING_MESSAGE_CONTENT
      REASONING_MESSAGE_END REASONING_END
      TEXT_MESSAGE_START TEXT_MESSAGE_CONTENT TEXT_MESSAGE_END CUSTOM RUN_FINISHED
    ], translated.map { |event| event[:type] }
    assert_equal ["Visible ", "answer"], translated.select { |event|
      event[:type] == "TEXT_MESSAGE_CONTENT"
    }.map { |event| event[:delta] }
    assert_equal [reasoning], translated.select { |event|
      event[:type] == "REASONING_MESSAGE_CONTENT"
    }.map { |event| event[:delta] }
    assert_equal 7, translated.fetch(-2).dig(:value, :usage, :reasoning_tokens)
    assert_includes JSON.generate(translated), reasoning
  end

  def test_closes_open_messages_before_terminal_events
    error_events = [
      agent_event(:message_start),
      agent_event(:reasoning_delta, text: "Checking"),
      LittleGhost::StreamEvent.build(:run_error, message: "Provider failed")
    ]

    translated = LittleGhost::AGUI::Adapter.new.stream(error_events, thread_id: "thread", run_id: "run").to_a

    assert_equal [
      "REASONING_START",
      "REASONING_MESSAGE_START",
      "REASONING_MESSAGE_CONTENT",
      "REASONING_MESSAGE_END",
      "REASONING_END",
      "RUN_ERROR"
    ], translated.map { |event| event[:type] }

    %i[run_partial run_cancel run_stop].each do |type|
      data = (type == :run_partial || type == :run_stop) ? {response: "Partial"} : {}
      events = [
        agent_event(:text_delta, text: "Partial"),
        LittleGhost::StreamEvent.build(type, **data)
      ]
      types = LittleGhost::AGUI::Adapter.new.stream(events, thread_id: "thread", run_id: "run").map { |event| event[:type] }

      assert_operator types.index("TEXT_MESSAGE_END"), :<, types.index("RUN_FINISHED")
    end
  end

  def test_emits_only_aggregate_usage_and_unwraps_trace_context
    result = LittleGhost::RunResult.new(
      message: LittleGhost::Message.new(role: :assistant, content: "done"),
      stop_reason: :end_turn,
      usage: LittleGhost::Usage.new(input_tokens: 4, output_tokens: 2),
      messages: [],
      state: {}
    )
    events = [
      LittleGhost::StreamEvent.build(
        :usage,
        usage: LittleGhost::Usage.new(input_tokens: 4, output_tokens: 2),
        metadata: {model: "test"}
      ),
      LittleGhost::StreamEvent.build(:invocation_stop, result:),
      LittleGhost::StreamEvent.build(:trace_context, context: {trace_id: "abc"})
    ]

    translated = LittleGhost::AGUI::Adapter.new.stream(events, thread_id: "thread", run_id: "run").to_a

    assert_equal 1, translated.count { |event| event[:name] == "little_ghost.usage" }
    assert_equal 6, translated.first.dig(:value, :usage, :total_tokens)
    assert_equal({trace_id: "abc"}, translated.last[:value])
  end

  def test_default_source_selection_excludes_nested_participants_and_subagents
    nested = root_source.with(assembly_path: [LittleGhost::AgentStreamStep.build(
      assembly_id: "response_workflow", assembly_kind: :workflow, participant: "researcher", step_id: "step-1"
    )])
    subagent = root_source.with(agent_path: "/root/researcher")
    events = [
      LittleGhost::StreamEvent.build(:run_start),
      agent_event(:text_delta, source: nested, text: "private participant work"),
      agent_event(:text_delta, source: subagent, text: "private subagent work"),
      LittleGhost::StreamEvent.build(:run_stop, response: "done")
    ]

    translated = LittleGhost::AGUI::Adapter.new.stream(events, thread_id: "thread", run_id: "run").to_a

    assert_equal %w[RUN_STARTED RUN_FINISHED], translated.map { |event| event[:type] }
  end

  def test_source_filter_selects_a_participant_without_exposing_its_reviewer_or_children
    response_step = LittleGhost::AgentStreamStep.build(
      assembly_id: "response_workflow", assembly_kind: :workflow, participant: "response", step_id: "step-1"
    )
    response = root_source.with(assembly_path: [response_step])
    reviewer = response.with(assembly_path: [response_step.with(participant: "reviewer")])
    subagent = response.with(agent_path: "/root/researcher")
    nested = response.with(assembly_path: [response_step, response_step.with(step_id: "step-2")])
    adapter = LittleGhost::AGUI::Adapter.new(source_filter: lambda { |source|
      step = source.assembly_path.first
      source.agent_path == "/root" && source.assembly_path.length == 1 &&
        step.assembly_id == "response_workflow" && step.participant == "response"
    })
    events = [
      LittleGhost::StreamEvent.build(:run_start),
      *[reviewer, subagent, nested, root_source].map { |source|
        agent_event(:text_delta, source:, text: "private work")
      },
      agent_event(:text_delta, source: response, text: "Looking up your order."),
      agent_event(:message_stop, source: response),
      LittleGhost::StreamEvent.build(:run_stop, response: "Your order has shipped.")
    ]

    translated = adapter.stream(events, thread_id: "thread", run_id: "run").to_a

    assert_equal %w[RUN_STARTED TEXT_MESSAGE_START TEXT_MESSAGE_CONTENT TEXT_MESSAGE_END RUN_FINISHED],
      translated.map { |event| event[:type] }
    assert_equal "Looking up your order.", translated.fetch(2).fetch(:delta)
    assert_equal "Your order has shipped.", translated.last.dig(:result, :response)
    refute_includes JSON.generate(translated), "private work"
  end

  def test_ignores_raw_progress_and_wrapped_usage_or_terminal_events
    usage = LittleGhost::Usage.new(input_tokens: 5, output_tokens: 3)
    result = Struct.new(:usage).new(usage)
    events = [
      LittleGhost::StreamEvent.build(:run_start),
      agent_event(:text_delta, text: "Hello"),
      LittleGhost::StreamEvent.build(:text_delta, text: "Hello"),
      LittleGhost::StreamEvent.build(:reasoning_delta, text: "raw reasoning"),
      LittleGhost::StreamEvent.build(:tool_call_start, index: 0, id: "raw-tool", name: "lookup"),
      agent_event(:invocation_stop, result:),
      agent_event(:invocation_error, usage:),
      agent_event(:run_stop, response: "unapproved response"),
      agent_event(:run_error, message: "participant failure"),
      LittleGhost::StreamEvent.build(:invocation_stop, result:),
      LittleGhost::StreamEvent.build(:run_stop, response: "Approved response")
    ]

    translated = LittleGhost::AGUI::Adapter.new.stream(events, thread_id: "thread", run_id: "run").to_a

    assert_equal %w[RUN_STARTED TEXT_MESSAGE_START TEXT_MESSAGE_CONTENT CUSTOM TEXT_MESSAGE_END RUN_FINISHED],
      translated.map { |event| event[:type] }
    assert_equal 1, translated.count { |event| event[:type] == "TEXT_MESSAGE_CONTENT" }
    assert_equal 1, translated.count { |event| event[:name] == "little_ghost.usage" }
    assert_equal 8, translated.fetch(3).dig(:value, :usage, :total_tokens)
    assert_equal "Approved response", translated.last.dig(:result, :response)
  end

  def test_translates_tool_progress_and_subagent_lifecycle
    tool_use = LittleGhost::Content::ToolUse.new(id: "tool-1", name: "lookup", input: {order_id: "123"})
    result = LittleGhost::Tool::ExecutionResult.new(content: "shipped", status: :success)
    events = [
      agent_event(:tool_call_start, index: 0, id: tool_use.id, name: tool_use.name),
      agent_event(:tool_call_delta, index: 0, arguments: '{"order_id":"123"}'),
      agent_event(:tool_call_stop, tool_use:),
      agent_event(:tool_stop, tool_use:, result:),
      LittleGhost::StreamEvent.build(:subagent, event: {event: "turn_finished", subagent_id: "researcher"})
    ]

    translated = LittleGhost::AGUI::Adapter.new.stream(events, thread_id: "thread", run_id: "run").to_a

    assert_equal %w[TOOL_CALL_START TOOL_CALL_ARGS TOOL_CALL_END TOOL_CALL_RESULT CUSTOM],
      translated.map { |event| event[:type] }
    assert_equal "tool-1", translated.fetch(1).fetch(:toolCallId)
    assert_equal '{"order_id":"123"}', translated.fetch(1).fetch(:delta)
    assert_equal "shipped", translated.fetch(3).fetch(:content)
    assert_equal "little_ghost.subagent", translated.last.fetch(:name)
    assert_equal "turn_finished", translated.last.dig(:value, :event)
  end

  def test_requires_native_source_and_progress_values_even_with_a_custom_filter
    source = root_source
    progress = LittleGhost::StreamEvent.build(:text_delta, text: "not native")
    filter_calls = 0
    adapter = LittleGhost::AGUI::Adapter.new(source_filter: ->(_) { filter_calls += 1 })
    events = [
      LittleGhost::StreamEvent.build(:agent_stream, source: source.to_h, event: progress),
      LittleGhost::StreamEvent.build(:agent_stream, source:, event: progress.to_h),
      LittleGhost::StreamEvent.build(:agent_stream, source:, event: LittleGhost::StreamEvent.build(:run_stop, response: "hidden"))
    ]

    assert_empty adapter.stream(events, thread_id: "thread", run_id: "run").to_a
    assert_equal 0, filter_calls
  end

  def test_source_filter_requires_a_callable_and_propagates_filter_errors
    assert_raises(ArgumentError) { LittleGhost::AGUI::Adapter.new(source_filter: "response") }
    assert_raises(ArgumentError) { LittleGhost::AGUI::Adapter.new(source_filter: false) }
    failure = RuntimeError.new("source selection failed")
    adapter = LittleGhost::AGUI::Adapter.new(source_filter: ->(_) { raise failure })

    error = assert_raises(RuntimeError) do
      adapter.stream([agent_event(:text_delta, text: "Hello")], thread_id: "thread", run_id: "run").to_a
    end

    assert_same failure, error
  end

  private

  def agent_event(type, source: root_source, **data)
    LittleGhost::StreamEvent.build(:agent_stream, source:, event: LittleGhost::StreamEvent.build(type, **data))
  end

  def root_source
    LittleGhost::AgentStreamSource.build(
      agent_id: "customer_support", agent_path: "/root", operation_id: "agent-1",
      parent_operation_id: "run-1", assembly_path: []
    )
  end
end
