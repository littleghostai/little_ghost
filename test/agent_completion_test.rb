# frozen_string_literal: true

require "test_helper"

class AgentCompletionTest < Minitest::Test
  class ScriptedModel
    include LittleGhost::ModelInterface

    attr_reader :requests

    def initialize(*responses)
      @responses = responses
      @requests = []
    end

    def stream(request)
      requests << request
      response = @responses.shift
      raise "unexpected model request" unless response

      [
        LittleGhost::StreamEvent.build(:message_start),
        LittleGhost::StreamEvent.build(:text_delta, text: response.message.text),
        LittleGhost::StreamEvent.build(:message_stop, response:)
      ].each
    end
  end

  def test_continues_unfinished_work_in_the_same_invocation_and_accepts_once
    contexts = []
    accepted = []
    checked = false
    lookup = LittleGhost::Tool.define(name: "lookup", description: "Look up the missing fact") do
      checked = true
      "The order was delivered"
    end
    agent_class = Class.new(LittleGhost::Agent) do
      before_completion do |payload, context:|
        contexts << context
        raise "missing pending work" unless context.state["pending"] == "delivery lookup"
        raise "mutable conversation" unless payload.fetch(:messages).frozen?

        checked ? LittleGhost::CompletionDecision.accept :
          LittleGhost::CompletionDecision.continue(feedback: "Look up delivery before answering.")
      end
      after_invocation { |payload| accepted << payload.fetch(:result).text }
    end
    use = LittleGhost::Content::ToolUse.new(id: "lookup-1", name: "lookup", input: {})
    model = ScriptedModel.new(response("I have not checked."), response([use], stop_reason: :tool_use), response("Delivered."))
    agent = agent_class.new(model:, tools: [lookup])

    events = agent.stream("Find the delivery status.", context: {"pending" => "delivery lookup"}).to_a

    assert_equal 3, model.requests.length
    assert_same contexts.first, contexts.last
    assert_equal ["Delivered."], accepted
    assert_equal 1, events.count { |event| event.type == :invocation_start }
    assert_equal 1, events.count { |event| event.type == :completion_continued }
    assert_equal 1, events.count { |event| event.type == :invocation_stop }
    assert_equal "Delivered.", events.last.data.fetch(:result).text
    assert_equal "Look up delivery before answering.", model.requests.fetch(1).messages.last.text
  ensure
    agent&.close
  end

  def test_first_continuation_wins_and_later_callbacks_run_after_acceptance
    calls = []
    agent_class = Class.new(LittleGhost::Agent) do
      before_completion do |payload|
        calls << [:first, payload.fetch(:turn)]
        payload.fetch(:turn).zero? ? LittleGhost::CompletionDecision.continue(feedback: "Check again.") :
          LittleGhost::CompletionDecision.accept
      end
      before_completion { |payload| calls << [:second, payload.fetch(:turn)] }
    end
    agent = agent_class.new(model: ScriptedModel.new(response("candidate"), response("confirmed")))

    assert_equal "confirmed", agent.call("check").text
    assert_equal [[:first, 0], [:first, 1], [:second, 1]], calls
  ensure
    agent&.close
  end

  def test_deadline_reached_during_completion_check_prevents_another_model_call
    now = Time.now
    deadline = now + 60
    agent_class = Class.new(LittleGhost::Agent) do
      before_completion do
        now = deadline
        LittleGhost::CompletionDecision.accept
      end
    end
    model = ScriptedModel.new(response("candidate"))
    agent = agent_class.new(model:)

    Time.stub(:now, -> { now }) do
      assert_raises(LittleGhost::DeadlineExceededError) { agent.call("check", deadline:) }
    end
    assert_equal 1, model.requests.length
  ensure
    agent&.close
  end

  def test_completion_callback_can_cancel
    agent_class = Class.new(LittleGhost::Agent) do
      before_completion { LittleGhost::Support::Callbacks.cancel("The request was withdrawn") }
    end
    agent = agent_class.new(model: ScriptedModel.new(response("candidate")))

    assert_raises(LittleGhost::CancelledError) { agent.call("check") }
  ensure
    agent&.close
  end

  def test_cancellation_during_completion_check_prevents_acceptance
    token = LittleGhost::Support::CancellationToken.new
    agent_class = Class.new(LittleGhost::Agent) do
      before_completion do
        token.cancel
        LittleGhost::CompletionDecision.accept
      end
    end
    agent = agent_class.new(model: ScriptedModel.new(response("candidate")))

    assert_raises(LittleGhost::CancelledError) { agent.call("check", cancellation_token: token) }
  ensure
    agent&.close
  end

  def test_provider_output_exhaustion_does_not_pass_through_completion_check
    calls = []
    agent_class = Class.new(LittleGhost::Agent) { before_completion { calls << true } }
    agent = agent_class.new(model: ScriptedModel.new(response("unfinished", stop_reason: :max_tokens)))

    assert_raises(LittleGhost::OutputLimitError) { agent.call("check") }
    assert_empty calls
  ensure
    agent&.close
  end

  def test_continuations_respect_a_configured_model_turn_limit
    agent_class = Class.new(LittleGhost::Agent) do
      before_completion { LittleGhost::CompletionDecision.continue(feedback: "Still incomplete.") }
    end
    model = ScriptedModel.new(response("candidate"))
    agent = agent_class.new(model:, max_turns: 1)

    error = assert_raises(LittleGhost::ProtocolError) { agent.call("check") }
    assert_match(/maximum model turns/, error.message)
    assert_equal 1, model.requests.length
  ensure
    agent&.close
  end

  def test_nil_model_turn_limit_allows_more_than_the_default_number_of_turns
    agent_class = Class.new(LittleGhost::Agent) do
      before_completion do |payload|
        (payload.fetch(:turn) < 101) ? LittleGhost::CompletionDecision.continue(feedback: "Continue checking.") :
          LittleGhost::CompletionDecision.accept
      end
    end
    responses = Array.new(102) { response("candidate") }
    model = ScriptedModel.new(*responses)
    agent = agent_class.new(model:, max_turns: nil, max_tool_calls: nil)

    assert_equal "candidate", agent.call("check").text
    assert_equal 102, model.requests.length
  ensure
    agent&.close
  end

  def test_nil_tool_call_limit_allows_more_than_the_default_number_of_calls
    calls = 0
    lookup = LittleGhost::Tool.define(name: "lookup", description: "Look up a fact") { calls += 1 }
    uses = Array.new(1_001) { |index| LittleGhost::Content::ToolUse.new(id: index.to_s, name: "lookup", input: {}) }
    model = ScriptedModel.new(response(uses, stop_reason: :tool_use), response("done"))
    agent = LittleGhost::Agent.new(model:, tools: [lookup], max_tool_calls: nil)

    assert_equal "done", agent.call("check").text
    assert_equal 1_001, calls
  ensure
    agent&.close
  end

  def test_completion_decisions_validate_and_freeze_feedback
    assert_predicate LittleGhost::CompletionDecision.accept, :accept?
    [nil, "", "  ", 1].each do |feedback|
      assert_raises(ArgumentError) { LittleGhost::CompletionDecision.continue(feedback:) }
    end
    feedback = +"Continue checking."
    decision = LittleGhost::CompletionDecision.continue(feedback:)
    feedback.replace("Changed")

    assert_predicate decision, :continue?
    assert_predicate decision, :frozen?
    assert_predicate decision.feedback, :frozen?
    assert_equal "Continue checking.", decision.feedback
  end

  private

  def response(content, stop_reason: :end_turn)
    LittleGhost::ModelResponse.new(
      message: LittleGhost::Message.new(role: :assistant, content:),
      stop_reason:,
      usage: LittleGhost::Usage.new
    )
  end
end
