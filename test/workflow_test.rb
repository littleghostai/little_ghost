# frozen_string_literal: true

require "test_helper"
require "async"

class WorkflowTest < Minitest::Test
  class FakeAgent
    attr_reader :calls

    def self.assembly_id = "fake_agent"
    def self.assembly_kind = :agent

    def initialize(result, mutation: nil, failure_usage: LittleGhost::Usage.new, close_error: nil, delta_count: 0)
      @result = result
      @mutation = mutation
      @failure_usage = failure_usage
      @close_error = close_error
      @delta_count = delta_count
      @calls = []
    end

    def prompt_locals = {}
    def bind_agent_stream_path(_path) = self

    def call(input, **options)
      calls << [:call, input, options]
      @mutation&.call(options.fetch(:context))
      raise @result if @result.is_a?(Exception)

      @result
    end

    def stream(input, **options)
      calls << [:stream, input, options]
      @mutation&.call(options.fetch(:context))

      Enumerator.new do |events|
        @delta_count.times { events << LittleGhost::StreamEvent.build(:text_delta, text: "x" * 2_048) }
        if @result.is_a?(Exception)
          events << LittleGhost::StreamEvent.build(
            :invocation_error,
            error: @result,
            usage: @failure_usage,
            metadata: {}
          )
          raise @result
        end
        events << LittleGhost::StreamEvent.build(:invocation_stop, result: @result)
      end
    end

    def close
      @closed = true
      raise @close_error if @close_error
    end

    def closed? = @closed == true
  end

  class Application
    attr_reader :built

    attr_reader :task_runner

    def initialize(agents = nil, task_runner: LittleGhost::Support::TaskRunner.new, **agent_keywords)
      agents ||= agent_keywords
      @agents = agents.transform_values(&:dup)
      @built = []
      @task_runner = task_runner
    end

    def build_assembly(agent_class_or_name, run:, agent_stream_path:)
      built << [agent_class_or_name, run]
      (@agents.fetch(agent_class_or_name).shift ||
        raise("No fake #{agent_class_or_name} configured")
      ).bind_agent_stream_path(agent_stream_path)
    end

    def template_locals(run:, agent:)
      {run:, agent:}.merge(agent.prompt_locals)
    end
  end

  Run = Struct.new(:runtime, :workspace, :sandbox)

  class ExampleWorkflow < LittleGhost::Workflow
    attr_reader :route, :note

    private

    def perform
      @route = invoke(:router).output
      @note = invoke(:note).output
      invoke :main, input: "#{input.text}\n\nResearch:\n#{note}"
    end
  end

  class SharedLocalsWorkflow < ExampleWorkflow
    def prompt_locals = {workflow_policy: "shared"}
  end

  class ParallelWorkflow < LittleGhost::Workflow
    attr_reader :parallel_outputs

    private

    def perform
      @parallel_outputs = parallel(
        invoke(:first, as: :first),
        invoke(:second, as: :second),
        max_concurrency: 2
      )
      invoke :main, input: parallel_outputs.join(" + ")
    end
  end

  class RetryingWorkflow < LittleGhost::Workflow
    private

    def perform
      evidence = invoke(:research, retries: 1, retry_on: [RuntimeError]).output
      invoke :main, input: evidence
    end
  end

  class TimedWorkflow < LittleGhost::Workflow
    private

    def perform = invoke(:main, timeout: 0.01)
  end

  def test_composes_structured_and_text_agents_then_streams_the_responder
    router = FakeAgent.new(
      result(structured: {"path" => "investigate"}, usage: LittleGhost::Usage.new(input_tokens: 2)),
      mutation: ->(state) { state["poisoned"] = true }
    )
    note = FakeAgent.new(result(text: "evidence", usage: LittleGhost::Usage.new(input_tokens: 3)))
    main_result = result(text: "final", usage: LittleGhost::Usage.new(input_tokens: 5))
    main = FakeAgent.new(main_result)
    application = Application.new(router: [router], note: [note], main: [main])
    run = Run.new(application)
    workflow = ExampleWorkflow.new(run:)
    cancellation = LittleGhost::Support::CancellationToken.new
    deadline = Time.now + 60
    checkpoint = ->(**) {}
    history = [LittleGhost::Message.new(role: :assistant, content: "prior")]
    context = {"request_id" => "request-1"}

    events = workflow.stream(
      "question",
      history:,
      context:,
      settings: {temperature: 0.1},
      template_locals: {shared: "value", agent: "wrong"},
      template_paths: [],
      cancellation_token: cancellation,
      deadline:,
      parent_operation_id: "run-1",
      checkpoint:
    ).to_a

    assert_equal({"path" => "investigate"}, workflow.route)
    assert_equal "evidence", workflow.note
    assert_equal main_result.text, events.last.data.fetch(:result).text
    assert_equal 10, events.last.data.fetch(:result).usage.input_tokens
    refute context.key?("poisoned")
    assert router.closed?
    assert note.closed?
    assert main.closed?

    router_options = router.calls.first.fetch(2)
    refute_same context, router_options.fetch(:context)
    assert router_options.fetch(:context).fetch("poisoned")
    assert_same cancellation, router_options.fetch(:cancellation_token)
    assert_equal deadline, router_options.fetch(:deadline)
    assert_equal "run-1", router_options.fetch(:parent_operation_id)
    assert_same router, router_options.dig(:template_locals, :agent)
    assert_equal "value", router_options.dig(:template_locals, :shared)

    operation, final_input, final_options = main.calls.first
    assert_equal :stream, operation
    assert_equal "question\n\nResearch:\nevidence", final_input
    assert_equal %w[prior], final_options.fetch(:history).map(&:text)
    refute final_options.fetch(:context).key?("poisoned")
    assert_equal({temperature: 0.1}, final_options.fetch(:settings))
    assert_same checkpoint, final_options.fetch(:checkpoint)
    assert_same main, final_options.dig(:template_locals, :agent)
    assert_equal "value", final_options.dig(:template_locals, :shared)

    assert_raises(LittleGhost::Error) { workflow.stream("again") }
    workflow.close
    workflow.close
  end

  def test_workflow_prompt_locals_flow_to_child_templates
    router = FakeAgent.new(result(structured: {"path" => "answer"}))
    note = FakeAgent.new(result(text: "evidence"))
    main = FakeAgent.new(result(text: "final"))
    application = Application.new(router: [router], note: [note], main: [main])
    run = Run.new(application)
    workflow = SharedLocalsWorkflow.new(run:)

    workflow.stream(
      "question",
      template_locals: application.template_locals(run:, agent: workflow)
    ).to_a

    assert_equal "shared", router.calls.first.fetch(2).dig(:template_locals, :workflow_policy)
    assert_equal "shared", main.calls.first.fetch(2).dig(:template_locals, :workflow_policy)
  ensure
    workflow&.close
  end

  def test_closes_an_intermediate_agent_when_it_fails
    error = RuntimeError.new("failed")
    router = FakeAgent.new(error, failure_usage: LittleGhost::Usage.new(input_tokens: 7))
    application = Application.new(router: [router])
    workflow = ExampleWorkflow.new(run: Run.new(application))
    events = []

    caught = assert_raises(RuntimeError) do
      workflow.stream("question").each { |event| events << event }
    end

    assert_same error, caught
    assert_equal :invocation_error, events.last.type
    assert_equal 7, events.last.data.fetch(:usage).input_tokens
    assert router.closed?
  end

  def test_returns_a_direct_string_as_the_terminal_text_result
    workflow_class = Class.new(LittleGhost::Workflow) do
      assembly_id "computed_response"

      private

      def perform = "computed response"
    end
    workflow = workflow_class.new(run: Run.new(Application.new({})))
    checkpoints = []
    history = [LittleGhost::Message.new(role: :assistant, content: "prior")]

    events = workflow.stream(
      "question",
      history:,
      context: {request_id: "request-1"},
      parent_operation_id: "run-1",
      checkpoint: ->(**values) { checkpoints << values }
    ).to_a
    result = events.last.data.fetch(:result)

    assert_equal %i[message_start text_delta message_stop invocation_stop], events.map(&:type)
    assert_equal "computed response", result.text
    assert_equal :end_turn, result.stop_reason
    assert_equal %w[prior question computed\ response], result.messages.map(&:text)
    assert_equal "request-1", result.state.fetch("request_id")
    assert_equal "computed response", events.fetch(1).data.fetch(:text)
    assert_equal 1, checkpoints.length
    assert_equal "run-1", checkpoints.first.fetch(:parent_operation_id)
    assert_equal result.messages, checkpoints.first.fetch(:messages)
    assert_equal result.state, checkpoints.first.fetch(:state)
  end

  def test_returns_a_direct_json_value_as_a_structured_result
    source = {answer: ["yes"], count: 2}
    workflow_class = Class.new(LittleGhost::Workflow) do
      assembly_id "computed_response"

      define_method(:perform) { source }
      private :perform
    end
    workflow = workflow_class.new(run: Run.new(Application.new({})))

    events = workflow.stream("question").to_a
    result = events.last.data.fetch(:result)
    source[:answer] << "later"

    assert_equal [:invocation_stop], events.map(&:type)
    assert result.structured?
    assert_equal :structured_result, result.stop_reason
    assert_equal "computed_response_result", result.structured_result.schema_name
    assert_equal({"answer" => ["yes"], "count" => 2}, result.output)
    assert_equal "[Structured result computed_response_result redacted]", result.message.text
  end

  def test_accepts_direct_array_numeric_and_boolean_results
    [[1, nil], 42, 1.5, true, false].each do |value|
      workflow_class = Class.new(LittleGhost::Workflow) do
        define_method(:perform) { value }
        private :perform
      end

      result = workflow_class.new(
        run: Run.new(Application.new({}))
      ).stream("question").to_a.last.data.fetch(:result)

      assert_equal value, result.output
    end
  end

  def test_rejects_invalid_direct_results
    cycle = []
    cycle << cycle
    invalid = [nil, Object.new, Float::NAN, cycle, {1 => "invalid"}, {:key => 1, "key" => 2}]

    invalid.each do |value|
      workflow_class = Class.new(LittleGhost::Workflow) do
        define_method(:perform) { value }
        private :perform
      end
      workflow = workflow_class.new(run: Run.new(Application.new({})))

      assert_raises(LittleGhost::ProtocolError) { workflow.stream("question").to_a }
    end
  end

  def test_rejects_direct_results_over_structured_limits
    oversized = {value: "x" * LittleGhost::Workflow::MAX_DIRECT_RESULT_BYTES}
    deep = []
    cursor = deep
    LittleGhost::Workflow::MAX_DIRECT_RESULT_DEPTH.times do
      child = []
      cursor << child
      cursor = child
    end
    complex = Array.new(LittleGhost::Workflow::MAX_DIRECT_RESULT_NODES, nil)

    [oversized, deep, complex].each do |value|
      workflow_class = Class.new(LittleGhost::Workflow) do
        define_method(:perform) { value }
        private :perform
      end
      workflow = workflow_class.new(run: Run.new(Application.new({})))

      assert_raises(LittleGhost::ProtocolError) { workflow.stream("question").to_a }
    end
  end

  def test_rejects_direct_text_over_the_size_limit
    value = "x" * (LittleGhost::Workflow::MAX_DIRECT_RESULT_BYTES + 1)
    workflow_class = Class.new(LittleGhost::Workflow) do
      define_method(:perform) { value }
      private :perform
    end
    workflow = workflow_class.new(run: Run.new(Application.new({})))

    error = assert_raises(LittleGhost::ProtocolError) do
      workflow.stream("start").to_a
    end

    assert_match(/maximum serialized size/, error.message)
  end

  def test_returns_a_reviewed_consumed_invocation_without_repeating_its_work
    history = [LittleGhost::Message.new(role: :user, content: "question"), LittleGhost::Message.new(role: :assistant, content: "final")]
    main_result = result(text: "final", messages: history, state: {"checked" => true}, usage: LittleGhost::Usage.new(input_tokens: 5))
    main = FakeAgent.new(main_result)
    reviewer = FakeAgent.new(result(text: "approved", usage: LittleGhost::Usage.new(input_tokens: 3)))
    workflow_class = Class.new(LittleGhost::Workflow) do
      private

      def perform
        final = invoke(:main)
        final.output
        final.output
        invoke(:reviewer).output
        final
      end
    end
    workflow = workflow_class.new(run: Run.new(Application.new(main: [main], reviewer: [reviewer])))
    checkpoints = []

    events = workflow.stream("question", checkpoint: ->(**values) { checkpoints << values }, parent_operation_id: "run-1").to_a
    final = events.last.data.fetch(:result)

    assert_equal "final", final.text
    assert_equal main_result.messages, final.messages
    assert_equal main_result.state, final.state
    assert_equal main_result.stop_reason, final.stop_reason
    assert_equal 8, final.usage.input_tokens
    assert_equal %w[main reviewer], final.steps.map(&:participant)
    assert_equal ["final"], events.select { |event| event.type == :text_delta }.map { |event| event.data.fetch(:text) }
    assert_equal 1, events.count { |event| event.type == :invocation_stop }
    assert_equal 1, main.calls.length
    assert main.closed?
    assert reviewer.closed?
    assert_equal 1, checkpoints.length
    assert_equal final.messages, checkpoints.first.fetch(:messages)
    assert_equal final.state, checkpoints.first.fetch(:state)
    assert_equal "run-1", checkpoints.first.fetch(:parent_operation_id)
  end

  def test_returns_a_consumed_structured_result_with_its_original_schema
    candidate = result(structured: {"answer" => "verified"}, state: {"verified" => true}, usage: LittleGhost::Usage.new(input_tokens: 2))
    workflow_class = Class.new(LittleGhost::Workflow) do
      private

      def perform
        final = invoke(:main)
        final.output
        final
      end
    end
    workflow = workflow_class.new(run: Run.new(Application.new(main: [FakeAgent.new(candidate)])))

    events = workflow.stream("question").to_a
    final = events.last.data.fetch(:result)

    assert_same candidate.structured_result, final.structured_result
    assert_equal :structured_result, final.stop_reason
    assert_equal candidate.state, final.state
    assert_equal 2, final.usage.input_tokens
    refute events.any? { |event| %i[text_delta message_start message_stop].include?(event.type) }
  end

  def test_result_only_invocations_do_not_buffer_raw_child_deltas
    main = FakeAgent.new(result(text: "final"), delta_count: 10_001)
    workflow_class = Class.new(LittleGhost::Workflow) do
      private

      def perform
        candidate = invoke(:main)
        candidate.output
        candidate
      end
    end
    workflow = workflow_class.new(run: Run.new(Application.new(main: [main])))

    events = workflow.stream("question").to_a

    assert_equal "final", events.last.data.fetch(:result).text
    assert_equal ["final"], events.select { |event| event.type == :text_delta }.map { |event| event.data.fetch(:text) }
    assert main.closed?
  end

  def test_parallel_result_only_invocations_can_select_a_completed_child
    first = FakeAgent.new(result(text: "one", usage: LittleGhost::Usage.new(input_tokens: 2)), delta_count: 10_001)
    second = FakeAgent.new(result(text: "two", usage: LittleGhost::Usage.new(input_tokens: 3)), delta_count: 10_001)
    workflow_class = Class.new(LittleGhost::Workflow) do
      private

      def perform
        first = invoke(:first)
        second = invoke(:second)
        parallel(first, second)
        first
      end
    end
    workflow = workflow_class.new(run: Run.new(Application.new(first: [first], second: [second])))

    final = workflow.stream("question").to_a.last.data.fetch(:result)

    assert_equal "one", final.text
    assert_equal 5, final.usage.input_tokens
    assert_equal %w[first second], final.steps.map(&:participant)
    assert_equal 1, first.calls.length
    assert_equal 1, second.calls.length
  end

  def test_result_only_invocations_still_reject_oversized_terminal_state
    candidate = result(text: "final", state: {"large" => "x" * LittleGhost::Assembly::MAX_STEP_EVENT_BYTES})
    workflow_class = Class.new(LittleGhost::Workflow) do
      private

      def perform = invoke(:main).output
    end
    main = FakeAgent.new(candidate)
    workflow = workflow_class.new(run: Run.new(Application.new(main: [main])))

    assert_raises(LittleGhost::AssemblyLimitError) { workflow.stream("question").to_a }
    assert main.closed?
  end

  def test_rejects_an_invocation_owned_by_another_workflow
    [false, true].each do |consumed|
      foreign = nil
      owner_class = Class.new(LittleGhost::Workflow) do
        define_method(:perform) do
          foreign = invoke(:main)
          foreign.output if consumed
          "owner answer"
        end
        private :perform
      end
      main = FakeAgent.new(result(text: "foreign answer"))
      owner = owner_class.new(run: Run.new(Application.new(main: [main])))
      owner.stream("foreign question").to_a
      workflow_class = Class.new(LittleGhost::Workflow) do
        define_method(:perform) { foreign }
        private :perform
      end
      workflow = workflow_class.new(run: Run.new(Application.new({})))

      error = assert_raises(LittleGhost::ProtocolError) { workflow.stream("question").to_a }

      assert_includes error.message, "owned by another workflow"
      assert_equal consumed ? 1 : 0, main.calls.length
    end
  end

  def test_cannot_return_an_invocation_that_failed_without_a_result
    main = FakeAgent.new(RuntimeError.new("failed"), failure_usage: LittleGhost::Usage.new(input_tokens: 4))
    workflow_class = Class.new(LittleGhost::Workflow) do
      private

      def perform
        candidate = invoke(:main)
        begin
          candidate.output
        rescue RuntimeError
          candidate
        end
      end
    end
    workflow = workflow_class.new(run: Run.new(Application.new(main: [main])))
    events = []

    error = assert_raises(LittleGhost::ProtocolError) { workflow.stream("question").each { |event| events << event } }

    assert_includes error.message, "without a completed result"
    refute events.any? { |event| event.type == :invocation_stop }
    assert_equal 4, events.last.data.fetch(:usage).input_tokens
    assert_equal 1, main.calls.length
  end

  def test_result_only_failure_and_cleanup_preserve_usage_after_many_deltas
    [RuntimeError.new("provider failed"), :cleanup].each do |failure|
      main = if failure == :cleanup
        FakeAgent.new(result(text: "candidate", usage: LittleGhost::Usage.new(input_tokens: 6)), close_error: RuntimeError.new("cleanup failed"), delta_count: 10_001)
      else
        FakeAgent.new(failure, failure_usage: LittleGhost::Usage.new(input_tokens: 6), delta_count: 10_001)
      end
      workflow_class = Class.new(LittleGhost::Workflow) do
        private

        def perform = invoke(:main).output
      end
      workflow = workflow_class.new(run: Run.new(Application.new(main: [main])))
      events = []

      assert_raises(RuntimeError) { workflow.stream("question").each { |event| events << event } }

      assert_equal 6, events.last.data.fetch(:usage).input_tokens
      assert main.closed?
      refute events.any? { |event| event.type == :invocation_stop }
    end
  end

  def test_cancelled_and_expired_workflows_do_not_start_application_work
    workflow_class = Class.new(LittleGhost::Workflow) do
      private

      def perform = raise("must not run")
    end
    cancellation = LittleGhost::Support::CancellationToken.new
    cancellation.cancel
    [{cancellation_token: cancellation}, {deadline: Time.now - 1}].each do |options|
      workflow = workflow_class.new(run: Run.new(Application.new({})))

      assert_raises(LittleGhost::CancelledError, LittleGhost::DeadlineExceededError) { workflow.stream("question", **options).to_a }
    end
  end

  def test_cancellation_after_review_prevents_publication_and_next_child_execution
    [:publish, :invoke].each do |action|
      cancellation = LittleGhost::Support::CancellationToken.new
      main = FakeAgent.new(result(text: "candidate", usage: LittleGhost::Usage.new(input_tokens: 5)))
      workflow_class = Class.new(LittleGhost::Workflow) do
        define_method(:perform) do
          candidate = invoke(:main)
          candidate.output
          cancellation.cancel
          invoke(:unexpected).output if action == :invoke
          candidate
        end
        private :perform
      end
      application = Application.new(main: [main])
      workflow = workflow_class.new(run: Run.new(application))
      checkpoints = []
      events = []

      assert_raises(LittleGhost::CancelledError) do
        workflow.stream("question", cancellation_token: cancellation, checkpoint: ->(**values) { checkpoints << values }).each { |event| events << event }
      end

      assert_equal 5, events.last.data.fetch(:usage).input_tokens
      refute events.any? { |event| event.type == :invocation_stop }
      assert_empty checkpoints
      assert_equal 1, application.built.length
    end
  end

  def test_deadline_after_review_prevents_publication
    deadline = Time.now + 60
    main = FakeAgent.new(result(text: "candidate", usage: LittleGhost::Usage.new(input_tokens: 5)))
    workflow_class = Class.new(LittleGhost::Workflow) do
      private

      def perform
        candidate = invoke(:main)
        candidate.output
        candidate
      end
    end
    workflow = workflow_class.new(run: Run.new(Application.new(main: [main])))
    events = []

    Time.stub(:now, -> { main.closed? ? deadline + 1 : deadline - 1 }) do
      assert_raises(LittleGhost::DeadlineExceededError) do
        workflow.stream("question", deadline:).each { |event| events << event }
      end
    end

    refute events.any? { |event| event.type == :invocation_stop }
    assert_equal 5, events.last.data.fetch(:usage).input_tokens
  end

  def test_checkpoint_cancellation_or_failure_prevents_terminal_publication
    [:cancel, :failure].each do |action|
      cancellation = LittleGhost::Support::CancellationToken.new
      main = FakeAgent.new(result(text: "candidate", usage: LittleGhost::Usage.new(input_tokens: 5)))
      workflow_class = Class.new(LittleGhost::Workflow) do
        private

        def perform
          candidate = invoke(:main)
          candidate.output
          candidate
        end
      end
      workflow = workflow_class.new(run: Run.new(Application.new(main: [main])))
      checkpoint = lambda do |**|
        raise "store failed" if action == :failure

        cancellation.cancel
      end
      events = []

      assert_raises(LittleGhost::CancelledError, RuntimeError) do
        workflow.stream("question", cancellation_token: cancellation, checkpoint:).each { |event| events << event }
      end

      refute events.any? { |event| event.type == :invocation_stop }
      assert_equal 5, events.last.data.fetch(:usage).input_tokens
    end
  end

  def test_preserves_final_usage_when_final_agent_cleanup_fails
    cleanup_error = RuntimeError.new("cleanup failed")
    router = FakeAgent.new(result(structured: {"path" => "investigate"}, usage: LittleGhost::Usage.new(input_tokens: 2)))
    note = FakeAgent.new(result(text: "evidence", usage: LittleGhost::Usage.new(input_tokens: 3)))
    main = FakeAgent.new(
      result(text: "final", usage: LittleGhost::Usage.new(input_tokens: 5)),
      close_error: cleanup_error
    )
    workflow = ExampleWorkflow.new(
      run: Run.new(Application.new(router: [router], note: [note], main: [main]))
    )
    events = []

    caught = assert_raises(RuntimeError) do
      workflow.stream("question").each { |event| events << event }
    end

    assert_same cleanup_error, caught
    assert_equal %i[
      assembly_step_start assembly_step_stop
      assembly_step_start assembly_step_stop
      assembly_step_start assembly_step_error invocation_error
    ], events.map(&:type)
    assert_equal 10, events.last.data.fetch(:usage).input_tokens
  end

  def test_tool_stop_result_is_not_treated_as_usage_observation
    final_result = result(text: "final", usage: LittleGhost::Usage.new(input_tokens: 5))
    tool_use = LittleGhost::Content::ToolUse.new(id: "tool-1", name: "inspect", input: {})
    tool_result = LittleGhost::Content::ToolResult.new(
      tool_use_id: tool_use.id,
      content: "found",
      status: :success
    )
    agent = FakeAgent.new(final_result)
    agent.define_singleton_method(:stream) do |input, **options|
      calls << [:stream, input, options]
      [
        LittleGhost::StreamEvent.build(:tool_stop, tool_use:, result: tool_result),
        LittleGhost::StreamEvent.build(:invocation_stop, result: final_result)
      ].each
    end
    workflow_class = Class.new(LittleGhost::Workflow) do
      private

      def perform = invoke(:main)
    end
    workflow = workflow_class.new(run: Run.new(Application.new(main: [agent])))

    events = workflow.stream("question").to_a

    assert_equal %i[assembly_step_start assembly_step_stop tool_stop invocation_stop], events.map(&:type)
    assert_same tool_result, events.find { |event| event.type == :tool_stop }.data.fetch(:result)
    assert_equal 5, events.last.data.fetch(:result).usage.input_tokens
  end

  def test_runs_parallel_invocations_and_records_their_steps_in_order
    started = Queue.new
    release = Queue.new
    parallel_agent = lambda do |text|
      agent = FakeAgent.new(result(text:, usage: LittleGhost::Usage.new(input_tokens: 2)))
      agent.define_singleton_method(:stream) do |input, **options|
        calls << [:stream, input, options]
        started << true
        release.pop
        [LittleGhost::StreamEvent.build(:invocation_stop, result: @result)].each
      end
      agent
    end
    first = parallel_agent.call("one")
    second = parallel_agent.call("two")
    main = FakeAgent.new(result(text: "done", usage: LittleGhost::Usage.new(input_tokens: 1)))
    workflow = ParallelWorkflow.new(
      run: Run.new(Application.new(first: [first], second: [second], main: [main]))
    )

    live_events = Queue.new
    worker = Thread.new do
      workflow.stream("request").each_with_object([]) do |event, collected|
        live_events << event
        collected << event
      end
    end
    2.times { started.pop }
    live_types = 2.times.map { live_events.pop.type }
    assert_equal [:assembly_step_start, :assembly_step_start], live_types
    2.times { release << true }
    events = worker.value
    result = events.find { |event| event.type == :invocation_stop }.data.fetch(:result)

    assert_equal %w[one two], workflow.parallel_outputs
    assert_equal "one + two", main.calls.first.fetch(1)
    assert_equal %w[first second main], result.steps.map(&:participant)
    assert result.trajectory.concurrent?(result.steps[0].id, result.steps[1].id)
    assert_equal 5, result.usage.input_tokens
  end

  def test_returns_parallel_outputs_directly_with_usage_and_steps
    workflow_class = Class.new(LittleGhost::Workflow) do
      private

      def perform
        parallel(
          invoke(:first, as: :first),
          invoke(:second, as: :second),
          max_concurrency: 2
        )
      end
    end
    first = FakeAgent.new(result(text: "one", usage: LittleGhost::Usage.new(input_tokens: 2)))
    second = FakeAgent.new(result(structured: {"value" => "two"}, usage: LittleGhost::Usage.new(input_tokens: 3)))
    workflow = workflow_class.new(
      run: Run.new(Application.new(first: [first], second: [second]))
    )

    result = workflow.stream("request").to_a.last.data.fetch(:result)

    assert_equal ["one", {"value" => "two"}], result.output
    assert_equal 5, result.usage.input_tokens
    assert_equal %w[first second], result.steps.map(&:participant)
    assert_empty result.trajectory.transitions
  end

  def test_parallel_invocations_use_scheduler_fibers
    workers = Queue.new
    parallel_agent = lambda do |text|
      FakeAgent.new(
        result(text:),
        mutation: lambda do |_context|
          workers << [Thread.current.object_id, Fiber.current.object_id, Fiber.blocking?]
          Async::Task.current.yield
        end
      )
    end
    runtime = Application.new(
      {
        first: [parallel_agent.call("one")],
        second: [parallel_agent.call("two")],
        main: [FakeAgent.new(result(text: "done"))]
      },
      task_runner: LittleGhost::Support::TaskRunner.new(backend: :auto)
    )

    Async do
      workflow = ParallelWorkflow.new(run: Run.new(runtime))
      workflow.stream("request").to_a
    end.wait

    contexts = 2.times.map { workers.pop }
    assert_equal 1, contexts.map(&:first).uniq.length
    assert_equal 2, contexts.map { |context| context.fetch(1) }.uniq.length
    assert contexts.none?(&:last)
  end

  def test_retries_only_explicit_errors_and_records_each_attempt
    failed = FakeAgent.new(
      RuntimeError.new("temporary"),
      failure_usage: LittleGhost::Usage.new(input_tokens: 3)
    )
    recovered = FakeAgent.new(result(text: "evidence", usage: LittleGhost::Usage.new(input_tokens: 2)))
    main = FakeAgent.new(result(text: "done", usage: LittleGhost::Usage.new(input_tokens: 1)))
    workflow = RetryingWorkflow.new(
      run: Run.new(Application.new(research: [failed, recovered], main: [main]))
    )

    events = workflow.stream("request").to_a
    final = events.find { |event| event.type == :invocation_stop }.data.fetch(:result)

    assert_includes events.map(&:type), :assembly_step_retry
    assert_equal %i[failed completed], final.steps.first.attempts.map(&:status)
    assert_equal "RuntimeError", final.steps.first.attempts.first.error
    refute_includes final.steps.first.attempts.first.error, "temporary"
    assert_equal 5, final.steps.first.usage.input_tokens
    assert_equal 6, final.usage.input_tokens
    assert failed.closed?
    assert recovered.closed?
  end

  def test_requires_explicit_retry_error_classes
    workflow_class = Class.new(LittleGhost::Workflow) do
      private

      def perform = invoke(:main, retries: 1)
    end
    workflow = workflow_class.new(run: Run.new(Application.new(main: [FakeAgent.new(result(text: "done"))])))

    error = assert_raises(ArgumentError) { workflow.stream("request").to_a }

    assert_includes error.message, "retry_on"
  end

  def test_translates_a_child_deadline_into_a_step_timeout
    child = FakeAgent.new(LittleGhost::DeadlineExceededError.new("deadline"))
    workflow = TimedWorkflow.new(run: Run.new(Application.new(main: [child])))
    events = []

    error = assert_raises(LittleGhost::AssemblyStepTimeoutError) do
      workflow.stream("request").each { |event| events << event }
    end

    assert_includes error.message, "main"
    step_error = events.find { |event| event.type == :assembly_step_error }
    assert_equal "LittleGhost::AssemblyStepTimeoutError", step_error.data.fetch(:error_type)
    assert child.closed?
  end

  def test_preserves_nested_assembly_steps_and_their_parent_relationship
    nested = LittleGhost::Assembly::Step.new(
      id: "nested",
      participant: "child",
      assembly_id: "child",
      assembly_kind: :agent,
      status: :completed,
      attempts: [],
      usage: LittleGhost::Usage.new(input_tokens: 1),
      output: "evidence"
    )
    composite = FakeAgent.new(result(text: "evidence", usage: LittleGhost::Usage.new(input_tokens: 2), steps: [nested]))
    main = FakeAgent.new(result(text: "done", usage: LittleGhost::Usage.new(input_tokens: 1)))
    workflow_class = Class.new(LittleGhost::Workflow) do
      private

      def perform
        invoke(:composite).output
        invoke(:main)
      end
    end
    workflow = workflow_class.new(run: Run.new(Application.new(composite: [composite], main: [main])))

    final = workflow.stream("request").to_a.last.data.fetch(:result)
    outer, child, terminal = final.steps

    assert_equal %w[composite child main], final.steps.map(&:participant)
    assert_equal outer.id, child.parent_id
    assert_equal [outer.id], terminal.predecessor_ids
    assert_equal [[outer.id, terminal.id]], final.trajectory.transitions
  end

  private

  def result(text: nil, structured: nil, usage: LittleGhost::Usage.new, steps: [], messages: [], state: {})
    LittleGhost::RunResult.new(
      message: LittleGhost::Message.new(role: :assistant, content: text || "structured"),
      stop_reason: structured ? :structured_result : :end_turn,
      usage:,
      messages:,
      state:,
      structured_result: structured && LittleGhost::StructuredResult.new(
        schema_name: "test",
        value: structured
      ),
      steps:
    )
  end
end
