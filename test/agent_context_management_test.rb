# frozen_string_literal: true

require "test_helper"

class AgentContextManagementTest < Minitest::Test
  class ScriptedModel
    include LittleGhost::ModelInterface

    attr_reader :requests

    def initialize(*responses, metadata: {})
      @responses = responses
      @requests = []
      @metadata = metadata
    end

    attr_reader :metadata

    def stream(request)
      @requests << request
      response = @responses.shift
      raise response if response.is_a?(Exception)

      [LittleGhost::StreamEvent.build(:message_stop, response: response)].each
    end
  end

  class CancellingSummaryModel
    include LittleGhost::ModelInterface

    attr_reader :requests

    def initialize
      @requests = []
    end

    def stream(request)
      requests << request
      request.cancellation_token.cancel
      [LittleGhost::StreamEvent.build(:message_start)].each
    end
  end

  def test_summarizes_old_context_and_includes_its_usage
    summary_usage = LittleGhost::Usage.new(input_tokens: 10, output_tokens: 2)
    final_usage = LittleGhost::Usage.new(input_tokens: 3, output_tokens: 1)
    model = ScriptedModel.new(response("summary", usage: summary_usage), response("done", usage: final_usage))
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 120, compression_threshold: 0.5,
        summary_ratio: 0.5, preserve_recent_messages: 2
    end
    history = 8.times.map do |index|
      LittleGhost::Message.new(role: index.even? ? :user : :assistant, content: "message-#{index}-#{"x" * 50}")
    end
    telemetry = []
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new
    instrumentation.subscribe(TestTelemetryRecorder.new(telemetry))

    result = agent_class.new(model:).call("current", history: history)

    assert_equal 2, model.requests.length
    assert_empty model.requests.first.tools
    assert_equal :system, model.requests.first.messages.first.role
    assert_equal "summary", model.requests.last.messages.first.text
    refute_includes model.requests.last.messages.map(&:text).join, "message-0-"
    assert_equal 16, result.usage.total_tokens
    assert_equal "done", result.text
    turn_id = telemetry.assoc(:agent_turn_start).last.fetch(:operation_id)
    model_parents = telemetry.filter_map do |name, attributes|
      attributes[:parent_operation_id] if name == :model_start
    end
    assert_equal [turn_id, turn_id], model_parents
  end

  def test_preserves_tool_calls_with_their_results_at_the_summary_boundary
    model = ScriptedModel.new(response("summary"), response("done"))
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 80, compression_threshold: 0.1,
        summary_ratio: 0.5, preserve_recent_messages: 2
    end
    tool_use = LittleGhost::Content::ToolUse.new(id: "call-1", name: "lookup", input: {})
    tool_result = LittleGhost::Content::ToolResult.new(tool_use_id: "call-1", content: "found", status: :success)
    history = [
      LittleGhost::Message.new(role: :user, content: "question"),
      LittleGhost::Message.new(role: :assistant, content: tool_use),
      LittleGhost::Message.new(role: :tool, content: tool_result),
      LittleGhost::Message.new(role: :assistant, content: "answer"),
      LittleGhost::Message.new(role: :user, content: "next")
    ]

    agent_class.new(model: model).call("current", history: history)

    remaining = model.requests.last.messages
    refute remaining.any? { |message| message.content.any? { |block| block.is_a?(LittleGhost::Content::ToolResult) } } ^
      remaining.any? { |message| message.content.any? { |block| block.is_a?(LittleGhost::Content::ToolUse) } }
  end

  def test_compacts_from_reported_input_usage_when_the_estimate_is_low
    model = ScriptedModel.new(
      tool_use_response("call-1", usage: LittleGhost::Usage.new(input_tokens: 40, cache_read_tokens: 500, cache_write_tokens: 60)),
      response("summary"),
      tool_use_response("call-2", usage: LittleGhost::Usage.new(input_tokens: 120)),
      response("done")
    )
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 1_000, compression_threshold: 0.5,
        summary_ratio: 0.5, preserve_recent_messages: 2
    end
    lookup = LittleGhost::Tool.define(name: "lookup", description: "Look up an order") { "found" }
    history = 8.times.map do |index|
      LittleGhost::Message.new(role: index.even? ? :user : :assistant, content: "message-#{index}")
    end

    result = agent_class.new(model:, tools: [lookup]).call("Refund order 42", history:)

    assert_equal "done", result.text
    assert_equal 4, model.requests.length
    summary_requests = model.requests.select { |request| request.tools.empty? }
    assert_equal [model.requests[1]], summary_requests
    assert_includes model.requests[2].messages.map(&:text), "summary"
    refute_includes model.requests[2].messages.map(&:text), "message-0"
  end

  def test_validates_context_management_configuration
    assert_raises(ArgumentError) { Class.new(LittleGhost::Agent) { manage_context context_window_tokens: 0 } }
    assert_raises(ArgumentError) { Class.new(LittleGhost::Agent) { manage_context compression_threshold: 2 } }
    assert_raises(ArgumentError) { Class.new(LittleGhost::Agent) { manage_context summary_ratio: 0.01 } }
    assert_raises(ArgumentError) { Class.new(LittleGhost::Agent) { manage_context preserve_recent_messages: 1 } }
  end

  def test_recovers_when_the_provider_reports_a_context_overflow
    model = ScriptedModel.new(
      LittleGhost::ContextWindowOverflowError.new("too large"),
      response("summary", usage: LittleGhost::Usage.new(input_tokens: 4, output_tokens: 2)),
      response("done", usage: LittleGhost::Usage.new(input_tokens: 3, output_tokens: 1))
    )
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 1_000_000, compression_threshold: 1,
        summary_ratio: 0.5, preserve_recent_messages: 2
    end
    history = 8.times.map do |index|
      LittleGhost::Message.new(role: index.even? ? :user : :assistant, content: "message-#{index}")
    end

    result = agent_class.new(model: model).call("current", history:)

    assert_equal 3, model.requests.length
    assert_equal "summary", model.requests.last.messages.first.text
    assert_equal "done", result.text
    assert_equal 10, result.usage.total_tokens
  end

  def test_context_compaction_propagates_cleanup_errors
    cleanup_error = LittleGhost::CleanupError.new("summary work is still running")
    model = ScriptedModel.new(cleanup_error, response("must not continue"))
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 120, compression_threshold: 0.5,
        summary_ratio: 0.5, preserve_recent_messages: 2
    end
    history = 8.times.map do |index|
      LittleGhost::Message.new(role: index.even? ? :user : :assistant, content: "message-#{index}-#{"x" * 50}")
    end

    raised = assert_raises(LittleGhost::CleanupError) do
      agent_class.new(model: model).call("current", history:)
    end

    assert_same cleanup_error, raised
    assert_equal 1, model.requests.length
  end

  def test_context_compaction_propagates_cancellation_from_the_summary_request
    model = CancellingSummaryModel.new
    token = LittleGhost::Support::CancellationToken.new
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 120, compression_threshold: 0.5,
        summary_ratio: 0.5, preserve_recent_messages: 2
    end
    history = 8.times.map do |index|
      LittleGhost::Message.new(role: index.even? ? :user : :assistant, content: "message-#{index}-#{"x" * 50}")
    end

    assert_raises(LittleGhost::CancelledError) do
      agent_class.new(model: model).call("current", history:, cancellation_token: token)
    end

    assert token.cancelled?
    assert_equal 1, model.requests.length
    assert_empty model.requests.first.tools
  end

  def test_pins_the_invocation_request_through_repeated_compactions
    model = ScriptedModel.new(
      response("summary-one"), tool_use_response("call-1"),
      response("summary-two"), tool_use_response("call-2"),
      response("summary-three"), tool_use_response("call-3"),
      response("summary-four"), response("done")
    )
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 1_000, compression_threshold: 0.01,
        summary_ratio: 0.5, preserve_recent_messages: 2
    end
    lookup = LittleGhost::Tool.define(name: "lookup", description: "Look up an order") { "found" }
    history = 4.times.map do |index|
      LittleGhost::Message.new(role: index.even? ? :user : :assistant, content: "message-#{index}")
    end

    result = agent_class.new(model:, tools: [lookup]).call("Refund order 42 if it shipped late", history:)

    assert_equal "done", result.text
    %w[summary-three summary-four].each do |summary|
      request, compacted = model.requests.find { |candidate| candidate.messages[1]&.text == summary }.messages.first(2)
      assert_equal :user, request.role
      assert_equal "Refund order 42 if it shipped late", request.text
      assert_equal :user, compacted.role
    end
    final = model.requests.last.messages
    assert_equal 1, final.count { |message| message.text.include?("Refund order 42") }
    assert_kind_of String, final.first.metadata[LittleGhost::Agent::ContextManagement::PINNED_METADATA_KEY]
    summarizer_inputs = model.requests.select { |request| request.tools.empty? }.map { |request| request.messages.map(&:text).join }
    assert_equal 4, summarizer_inputs.length
    summarizer_inputs.each { |input| refute_includes input, "Refund order 42" }
  end

  def test_summarizes_the_invocation_request_when_preservation_is_off
    model = ScriptedModel.new(
      response("summary-one"), tool_use_response("call-1"),
      response("summary-two"), tool_use_response("call-2"),
      response("summary-three"), response("done")
    )
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 1_000, compression_threshold: 0.01,
        summary_ratio: 0.5, preserve_recent_messages: 2, preserve_invocation_request: false
    end
    lookup = LittleGhost::Tool.define(name: "lookup", description: "Look up an order") { "found" }
    history = 4.times.map do |index|
      LittleGhost::Message.new(role: index.even? ? :user : :assistant, content: "message-#{index}")
    end

    agent_class.new(model:, tools: [lookup]).call("Refund order 42 if it shipped late", history:)

    assert_equal "summary-three", model.requests.last.messages.first.text
    refute_includes model.requests.last.messages.map(&:text).join, "Refund order 42"
  end

  def test_leaves_a_pinned_request_in_place_while_it_is_recent
    model = ScriptedModel.new(response("summary"), response("done"))
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 120, compression_threshold: 0.5,
        summary_ratio: 0.5, preserve_recent_messages: 2
    end
    history = 8.times.map do |index|
      LittleGhost::Message.new(role: index.even? ? :user : :assistant, content: "message-#{index}-#{"x" * 50}")
    end

    agent_class.new(model:).call("current", history:)

    assert_equal "summary", model.requests.last.messages.first.text
    assert_equal "current", model.requests.last.messages.last.text
    assert model.requests.last.messages.last.metadata[LittleGhost::Agent::ContextManagement::PINNED_METADATA_KEY]
  end

  def test_a_subclass_can_turn_off_invocation_request_pinning
    model = ScriptedModel.new(response("done"))
    parent = Class.new(LittleGhost::Agent) { manage_context }
    agent_class = Class.new(parent) { manage_context preserve_invocation_request: false }

    agent_class.new(model:).call("current")

    assert_nil model.requests.last.messages.last.metadata[LittleGhost::Agent::ContextManagement::PINNED_METADATA_KEY]
  end

  def test_summaries_record_the_scalar_metadata_of_every_message_they_replace
    model = ScriptedModel.new(
      response("summary-one"), tool_use_response("call-1"),
      response("summary-two"), response("done")
    )
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 1_000, compression_threshold: 0.01,
        summary_ratio: 0.5, preserve_recent_messages: 2
    end
    lookup = LittleGhost::Tool.define(name: "lookup", description: "Look up an order") { "found" }
    history = 4.times.map do |index|
      LittleGhost::Message.new(
        role: index.even? ? :user : :assistant,
        content: "message-#{index}",
        metadata: {external_id: "m-#{index}", committed_at: "2026-10-0#{index + 1}", detail: {nested: true}}
      )
    end

    agent_class.new(model:, tools: [lookup]).call("Refund order 42", history:)

    summaries = model.requests.filter_map do |request|
      request.messages.find { |message| message.metadata.key?(LittleGhost::Agent::ContextManagement::SUMMARIZED_METADATA_KEY) }
    end
    replaced = summaries.last.metadata[LittleGhost::Agent::ContextManagement::SUMMARIZED_METADATA_KEY].map(&:to_h)
    assert_equal %w[m-0 m-1 m-2 m-3], replaced.map { |metadata| metadata.fetch("external_id") }
    assert_equal "2026-10-01", replaced.first.fetch("committed_at")
    refute replaced.any? { |metadata| metadata.key?("detail") }
  end

  def test_summary_provenance_does_not_count_toward_the_compaction_threshold
    model = ScriptedModel.new(response("done"))
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 1_000, compression_threshold: 0.5,
        summary_ratio: 0.5, preserve_recent_messages: 2
    end
    provenance = 500.times.map { |index| {"external_id" => "m-#{index}"} }
    summary = LittleGhost::Message.new(
      role: :user,
      content: "Earlier work",
      metadata: {LittleGhost::Agent::ContextManagement::SUMMARIZED_METADATA_KEY => provenance}
    )

    result = agent_class.new(model:).call("current", history: [summary, LittleGhost::Message.new(role: :assistant, content: "ok")])

    assert_equal "done", result.text
    assert_equal 1, model.requests.length
  end

  def test_summary_provenance_omits_pins_from_earlier_invocations
    model = ScriptedModel.new(response("summary"), response("done"))
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 120, compression_threshold: 0.5,
        summary_ratio: 0.5, preserve_recent_messages: 2
    end
    earlier = LittleGhost::Message.new(
      role: :user,
      content: "message-0-#{"x" * 50}",
      metadata: {LittleGhost::Agent::ContextManagement::PINNED_METADATA_KEY => "earlier-operation", "external_id" => "m-0"}
    )
    history = [earlier] + (1...8).map do |index|
      LittleGhost::Message.new(role: index.even? ? :user : :assistant, content: "message-#{index}-#{"x" * 50}")
    end

    agent_class.new(model:).call("current", history:)

    replaced = model.requests.last.messages.first.metadata[LittleGhost::Agent::ContextManagement::SUMMARIZED_METADATA_KEY]
    assert_equal [{"external_id" => "m-0"}], replaced.map(&:to_h)
  end

  def test_summarizes_past_a_run_of_leading_pinned_messages
    model = ScriptedModel.new(response("summary"), response("done"))
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 1_000, compression_threshold: 0.01,
        summary_ratio: 0.5, preserve_recent_messages: 2
    end
    pinned = {LittleGhost::Agent::ContextManagement::PINNED_METADATA_KEY => true}
    history = 10.times.map do |index|
      LittleGhost::Message.new(
        role: index.even? ? :user : :assistant,
        content: "message-#{index}",
        metadata: (index < 6) ? pinned : {}
      )
    end

    agent_class.new(model:).call("current", history:)

    texts = model.requests.last.messages.map(&:text)
    assert_equal [*6.times.map { |index| "message-#{index}" }, "summary", "message-8", "message-9", "current"], texts
    refute_includes model.requests.first.messages.map(&:text), "message-0"
  end

  def test_summarizes_a_request_pinned_by_an_earlier_invocation
    model = ScriptedModel.new(response("summary"), response("done"))
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 120, compression_threshold: 0.5,
        summary_ratio: 0.5, preserve_recent_messages: 2
    end
    earlier = LittleGhost::Message.new(
      role: :user,
      content: "message-0-#{"x" * 50}",
      metadata: {LittleGhost::Agent::ContextManagement::PINNED_METADATA_KEY => "earlier-operation"}
    )
    history = [earlier] + (1...8).map do |index|
      LittleGhost::Message.new(role: index.even? ? :user : :assistant, content: "message-#{index}-#{"x" * 50}")
    end

    agent_class.new(model:).call("current", history:)

    assert_equal "summary", model.requests.last.messages.first.text
    refute_includes model.requests.last.messages.map(&:text).join, "message-0-"
  end

  def test_keeps_permanently_pinned_messages_with_their_tool_results
    model = ScriptedModel.new(response("summary"), response("done"))
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 1_000, compression_threshold: 0.01,
        summary_ratio: 0.5, preserve_recent_messages: 2
    end
    pinned = {LittleGhost::Agent::ContextManagement::PINNED_METADATA_KEY => true}
    history = [
      LittleGhost::Message.new(role: :user, content: "Always answer in French", metadata: pinned),
      LittleGhost::Message.new(
        role: :assistant,
        content: %w[call-1 call-2].map { |id| LittleGhost::Content::ToolUse.new(id:, name: "lookup", input: {}) }
      ),
      LittleGhost::Message.new(
        role: :tool,
        content: %w[call-1 call-2].map do |id|
          LittleGhost::Content::ToolResult.new(tool_use_id: id, content: "found", status: :success)
        end,
        metadata: pinned
      ),
      LittleGhost::Message.new(role: :assistant, content: "answer"),
      LittleGhost::Message.new(role: :user, content: "question"),
      LittleGhost::Message.new(role: :assistant, content: "reply"),
      LittleGhost::Message.new(role: :user, content: "follow-up"),
      LittleGhost::Message.new(role: :assistant, content: "reply")
    ]

    agent_class.new(model:).call("current", history:)

    messages = model.requests.last.messages
    assert_equal "Always answer in French", messages[0].text
    assert_equal %w[call-1 call-2], messages[1].content.grep(LittleGhost::Content::ToolUse).map(&:id)
    assert_equal %w[call-1 call-2], messages[2].content.grep(LittleGhost::Content::ToolResult).map(&:tool_use_id)
    assert_equal "summary", messages[3].text
    refute_includes messages.map(&:text), "answer"
  end

  def test_pins_the_invocation_request_when_compacting_after_an_overflow
    model = ScriptedModel.new(
      tool_use_response("call-1"),
      tool_use_response("call-2"),
      LittleGhost::ContextWindowOverflowError.new("too large"),
      response("summary"),
      response("done")
    )
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 1_000_000, compression_threshold: 1,
        summary_ratio: 0.5, preserve_recent_messages: 2
    end
    lookup = LittleGhost::Tool.define(name: "lookup", description: "Look up an order") { "found" }

    result = agent_class.new(model:, tools: [lookup]).call("Refund order 42 if it shipped late")

    assert_equal "done", result.text
    assert_equal ["Refund order 42 if it shipped late", "summary"], model.requests.last.messages.first(2).map(&:text)
  end

  private

  def response(text, usage: LittleGhost::Usage.new)
    LittleGhost::ModelResponse.new(
      message: LittleGhost::Message.new(role: :assistant, content: text),
      stop_reason: :end_turn,
      usage: usage
    )
  end

  def tool_use_response(id, usage: LittleGhost::Usage.new)
    LittleGhost::ModelResponse.new(
      message: LittleGhost::Message.new(
        role: :assistant,
        content: LittleGhost::Content::ToolUse.new(id:, name: "lookup", input: {})
      ),
      stop_reason: :tool_use,
      usage:
    )
  end
end
