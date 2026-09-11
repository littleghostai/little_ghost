# frozen_string_literal: true

require "json"
require_relative "assembly"

module LittleGhost
  # Coordinates Assembly participants with ordinary Ruby control flow.
  #
  # A workflow is an Assembly whose +perform+ method controls ordering,
  # branching, parallel work, and local variables. Each participant may be an
  # Agent or another coordinated Assembly. The workflow selects one participant
  # result or returns a value computed from intermediate answers.
  #
  # A support workflow can guarantee that research happens before the responder
  # writes the caller-visible answer:
  #
  #   class ResponseWorkflow < LittleGhost::Workflow
  #     private
  #
  #     def perform
  #       evidence = invoke(ResearchAgent).output
  #       invoke CustomerSupportAgent, input: <<~PROMPT
  #         #{input.text}
  #
  #         Research:
  #         #{evidence}
  #       PROMPT
  #     end
  #   end
  #
  #   run = ResponseWorkflow.ask("Why is transfer 481 pending?")
  #   run.response
  #   # One possible response: Transfer 481 is waiting for the receiving bank.
  #
  # Call a named Workflow with
  # ask[rdoc-ref:LittleGhost::Assembly.ask] for its final Run, or
  # the streaming entrypoint[rdoc-ref:LittleGhost::Assembly.stream_ask] for live
  # events.
  #
  # +invoke+ returns a lazy Workflow::Invocation. Reading +result+ runs the child
  # and returns its RunResult; +output+ returns RunResult#output. Repeated reads
  # reuse the completed result. Return an invocation to select its conversation,
  # state, and structured result as the workflow answer, or return a String or
  # JSON-compatible value computed in Ruby. Every step contributes usage.
  #
  # All participating Agents publish live +:agent_stream+ progress to the owning
  # Run, regardless of how results are accessed. Selecting a result does not
  # replay its progress. Applications choose which sources to show the caller;
  # see Run for how to identify participants and choose which data to share.
  #
  # A child receives the Workflow input unless +invoke+ supplies another one.
  # It also inherits history, settings, cancellation, deadline, template paths,
  # and the parent tracing relationship. JSON-like context is copied for each
  # child, preventing one intermediate Agent from mutating a sibling's state.
  # Non-JSON-like workflow context raises ArgumentError.
  #
  # A Workflow instance streams once. Returning +nil+, an unsupported value, an
  # invocation owned by another workflow, or a failed invocation raises ProtocolError.
  # A composition error fails the owning top-level Run. Each child Assembly
  # closes after its attempt, and a cleanup failure raises from that attempt.
  class Workflow < Assembly
    MAX_DIRECT_RESULT_BYTES = 1_000_000 # :nodoc:
    MAX_DIRECT_RESULT_DEPTH = 64 # :nodoc:
    MAX_DIRECT_RESULT_NODES = 100_000 # :nodoc:

    # Holds one lazy Assembly call inside a workflow composition.
    # Read #result for the child's RunResult or #output for its text or structured
    # value. Either accessor runs the child once and reuses the result on later
    # reads. Return this object from +perform+ to select its result as the answer.
    # Agent progress streams live independently of result access or selection.
    class Invocation
      def initialize(reference:, participant:, input:, history:, context:, policies:, owner:) # :nodoc:
        @reference = reference
        @participant = participant
        @input = input
        @history = history
        @context = context
        @policies = policies
        @owner = owner
        @mutex = Mutex.new
        @consumed = false
        @closed = false
      end

      def each(checkpoint: nil) # :nodoc:
        return enum_for(__method__, checkpoint:) unless block_given?

        @mutex.synchronize do
          raise Error, "workflow invocation is already closed" if @closed
          raise ProtocolError, "workflow invocation was already consumed" if @consumed

          @consumed = true
        end
        execution = @owner.send(
          :execute_workflow_invocation,
          reference: @reference,
          participant: @participant,
          input: @input,
          history: @history,
          context: @context,
          policies: @policies,
          checkpoint:
        ) { |event| yield event }
        @result = execution.result
        @step = execution.step
        @steps = execution.result.steps
        execution.events.each do |event|
          yield event
        end
        @result
      end

      # Runs this invocation when necessary and returns its completed RunResult.
      #
      # Repeated reads reuse the same result without repeating work. Agent
      # progress streams live regardless of how the result is accessed.
      def result
        unless consumed?
          each do |event|
            @owner.send(:emit_workflow_event, event) if event.type.to_s.start_with?("assembly_")
          end
        end
        raise ProtocolError, "workflow invocation has no completed result" unless @result

        @owner.send(:record_workflow_steps, @steps)
        @result
      end

      # Returns the completed child's text or structured value through RunResult#output.
      # Runs the child when necessary, with the same progress behavior as #result.
      def output = result.output

      def consumed? # :nodoc:
        @mutex.synchronize { @consumed }
      end

      def close # :nodoc:
        @mutex.synchronize do
          return if @closed

          @closed = true
        end
      end
    end

    # Run that owns this run-scoped Workflow.
    attr_reader :run
    # Runtime used to resolve child Assemblies.
    attr_reader :runtime

    def initialize(run: nil, runtime: nil) # :nodoc:
      super(run:, runtime:, standalone: run.nil?)
      @mutex = Mutex.new
      @closed = false
      @started = false
      @invocations = []
    end

    # Additional prompt locals shared by agents invoked from the workflow.
    # Subclasses may override this hook.
    def prompt_locals = {}

    # Streams the workflow once as StreamEvent objects.
    #
    # +perform+ may return an invocation owned by this workflow, a String, or a
    # JSON-compatible value. The final +:invocation_stop+ contains the selected
    # or computed result; it does not replay text events. A selected invocation
    # runs only if it has not started, and checkpoints its conversation and state.
    # Usage includes every workflow step. Cancellation and deadlines are checked before
    # child execution and final publication. The returned Enumerator is lazy, but
    # calling +stream+ reserves the single-use instance before enumeration starts.
    def stream(
      input = nil,
      history: nil,
      context: nil,
      cancellation_token: Support::CancellationToken.new,
      deadline: nil,
      settings: nil,
      template_locals: nil,
      template_paths: nil,
      parent_operation_id: nil,
      checkpoint: nil
    )
      raise ArgumentError, "input is required" if input.nil?

      if standalone?
        return build_run(entrypoint_payload(input, {
          history:,
          context:,
          settings:,
          template_paths:,
          deadline_at: deadline,
          cancellation_token:
        }.compact)).each
      end

      @mutex.synchronize do
        raise Error, "workflow is already closed" if @closed
        raise Error, "workflow instances can only be streamed once" if @started

        @started = true
        @input = input.is_a?(Message) ? input : Message.new(role: :user, content: input)
        @history = normalize_history(history)
        @context = context || {}
        @cancellation_token = cancellation_token
        @deadline = deadline
        @settings = settings || {}
        @template_locals = template_locals || {}
        @template_paths = template_paths || []
        @parent_operation_id = parent_operation_id
        @checkpoint = checkpoint
        @intermediate_usage = Usage.new
        @workflow_steps = []
        @workflow_events = nil
      end

      Enumerator.new do |events|
        @workflow_events = events
        ensure_open!
        check_execution!
        final_value = perform
        check_execution!
        if final_value.is_a?(Invocation)
          unless owned_invocation?(final_value)
            raise ProtocolError, "#{self.class} returned an invocation owned by another workflow"
          end
          result = final_value.result
          emit_completed_result(result.with(usage: workflow_usage, steps: workflow_steps), events)
        else
          emit_direct_result(final_value, events)
        end
      rescue => error
        events << StreamEvent.build(:invocation_error, error:, usage: workflow_usage, metadata: {})
        raise
      ensure
        @workflow_events = nil
      end
    end

    # Closes all declared invocations in reverse order.
    #
    # The operation is idempotent, attempts every close, and raises the first
    # cleanup failure.
    def close
      invocations = @mutex.synchronize do
        return if @closed

        @closed = true
        @invocations.reverse
      end
      errors = []
      invocations.each do |invocation|
        invocation.close
      rescue => error
        errors << error
      end
      raise errors.first if errors.any?
    end

    private

    # The current normalized input, frozen history, and JSON-like context exposed
    # to workflow implementations.
    # :doc:
    attr_reader :input, :history, :context

    # :doc:
    # Implements the composition and returns its final invocation or
    # a directly computed String or JSON-compatible value.
    # Subclasses must override this hook.
    def perform
      raise AbstractMethodError, "#{self.class} must implement #perform"
    end

    # :doc:
    # Creates a lazy invocation for +assembly+.
    #
    # Read +result+ or +output+ to execute the child and inspect its answer.
    # Return the invocation from +perform+ to select that result without repeating
    # work or replaying progress. +as+ names the participant in steps and
    # telemetry. Retries default to zero;
    # a positive +retries+ value requires explicit exception classes in +retry_on+.
    def invoke(
      assembly,
      as: nil,
      input: self.input,
      history: self.history,
      context: self.context,
      timeout: nil,
      retries: 0,
      retry_on: nil,
      retry_delay: 0
    )
      participant = as || assembly_identity(assembly)
      invocation = Invocation.new(
        reference: assembly,
        participant:,
        input:,
        history:,
        context: isolated_state(context),
        policies: {timeout:, retries:, retry_on:, retry_delay:},
        owner: self
      )
      @mutex.synchronize do
        raise Error, "workflow is already closed" if @closed

        @invocations << invocation
      end
      invocation
    end

    # :doc:
    # Consumes independent invocations concurrently and returns their outputs in
    # declaration order.
    #
    # +max_concurrency+ bounds active child executions. A child failure cancels
    # siblings cooperatively before the error is raised.
    def parallel(*invocations, max_concurrency: 8)
      raise ArgumentError, "parallel requires at least one invocation" if invocations.empty?
      unless invocations.all? { |invocation| owned_invocation?(invocation) && !invocation.consumed? }
        raise ArgumentError, "parallel accepts unconsumed invocations owned by this workflow"
      end

      token = @cancellation_token.child
      queue = SizedQueue.new(1_000)
      worker = task_runner.spawn do
        results = Support::Executor.new(max_concurrency:, runner: task_runner).map(
          invocations,
          cancellation_token: token,
          on_result: ->(_index, execution) { record_workflow_steps(execution.fetch(:steps)) }
        ) do |invocation|
          result = invocation.each do |event|
            if event.type.to_s.start_with?("assembly_")
              enqueue_assembly_event(queue, [:event, event], token)
            end
          end
          {output: result.output, steps: result.steps}
        end
        enqueue_assembly_event(queue, [:done, results], token)
      rescue => error
        token.cancel
        enqueue_assembly_terminal(queue, [:error, error])
      end
      executions = loop do
        type, value = queue.pop
        emit_workflow_event(value) if type == :event
        raise value if type == :error
        break value if type == :done
      end
      executions.map { |execution| execution.fetch(:output) }
    ensure
      token&.cancel
      worker&.wait
    end

    def execute_workflow_invocation(reference:, participant:, input:, history:, context:, policies:, checkpoint:)
      check_execution!
      step_id = SecureRandom.uuid
      predecessor_id = @mutex.synchronize do
        @workflow_steps.reverse.find { |step| step.parent_id.nil? }&.id
      end
      yield StreamEvent.build(
        :assembly_step_start,
        assembly_id: self.class.assembly_id,
        assembly_kind: :workflow,
        participant: participant.to_s,
        step_id:
      )
      execution = execute_assembly_step(
        reference:,
        participant:,
        input:,
        history:,
        context:,
        cancellation_token: @cancellation_token,
        deadline: @deadline,
        settings: @settings,
        template_locals: @template_locals,
        template_paths: @template_paths,
        parent_operation_id: @parent_operation_id,
        policies:,
        predecessor_ids: Array(predecessor_id),
        checkpoint:,
        step_id:
      ) { |event| yield event }
      yield StreamEvent.build(
        :assembly_step_stop,
        assembly_id: self.class.assembly_id,
        assembly_kind: :workflow,
        participant: participant.to_s,
        step_id: execution.step.id,
        usage: execution.step.usage
      )
      execution
    end

    def record_workflow_steps(steps)
      @mutex.synchronize do
        return if @workflow_steps.any? { |step| step.id == steps.first.id }

        @workflow_steps.concat(steps)
        @intermediate_usage += steps.first.usage
      end
    end

    def emit_workflow_event(event)
      sink = @mutex.synchronize do
        if event.type == :assembly_step_error && event.data[:terminal] && event.data[:usage]
          @intermediate_usage += event.data.fetch(:usage)
        end
        @workflow_events
      end
      sink << event if sink
    end

    def assembly_identity(reference)
      case reference
      when AssemblyBuilder, AssemblyDefinition
        reference.assembly_id
      when Class
        (reference <= Assembly) ? reference.assembly_id : reference.to_s
      else
        reference.to_s
      end
    end

    def emit_direct_result(value, events)
      raise ProtocolError, "#{self.class} returned nil from perform" if value.nil?

      usage = workflow_usage
      steps = workflow_steps
      state = DataMap.new(@context)
      if value.is_a?(String)
        if value.bytesize > MAX_DIRECT_RESULT_BYTES
          raise ProtocolError, "Workflow direct result exceeds the maximum serialized size"
        end

        message = Message.new(role: :assistant, content: value.dup)
        result = direct_run_result(message:, usage:, state:, steps:)
      else
        schema_name = "#{self.class.assembly_id}_result"
        structured_result = StructuredResult.new(
          schema_name:,
          value: normalize_direct_result(value)
        )
        message = Message.new(
          role: :assistant,
          content: FrameworkPrompts.for_runtime(runtime).render(
            "structured_output/persistence/format/redaction",
            locals: {schema_name:},
            invocation_paths: @template_paths
          )
        )
        result = direct_run_result(
          message:,
          usage:,
          state:,
          steps:,
          stop_reason: :structured_result,
          structured_result:
        )
      end
      emit_completed_result(result, events)
    end

    def emit_completed_result(result, events)
      check_execution!
      checkpoint_result(result)
      check_execution!
      events << StreamEvent.build(:invocation_stop, result:, metadata: {})
    end

    def direct_run_result(
      message:,
      usage:,
      state:,
      steps:,
      stop_reason: :end_turn,
      structured_result: nil
    )
      RunResult.new(
        message:,
        stop_reason:,
        usage:,
        messages: [*@history, @input, message].freeze,
        state:,
        structured_result:,
        steps:
      )
    end

    def checkpoint_result(result)
      return unless @checkpoint

      @checkpoint.call(
        messages: result.messages,
        state: result.state,
        parent_operation_id: @parent_operation_id
      )
    end

    def normalize_direct_result(value)
      counters = {nodes: 0}
      normalized = normalize_direct_value(value, depth: 1, ancestors: {}, counters:)
      if JSON.generate(normalized).bytesize > MAX_DIRECT_RESULT_BYTES
        raise ProtocolError, "Workflow direct result exceeds the maximum serialized size"
      end

      normalized
    rescue JSON::GeneratorError
      raise ProtocolError, "Workflow direct result cannot be serialized"
    end

    def normalize_direct_value(value, depth:, ancestors:, counters:)
      counters[:nodes] += 1
      if depth > MAX_DIRECT_RESULT_DEPTH
        raise ProtocolError, "Workflow direct result exceeds the maximum nesting depth"
      end
      if counters.fetch(:nodes) > MAX_DIRECT_RESULT_NODES
        raise ProtocolError, "Workflow direct result exceeds the maximum complexity"
      end

      case value
      when Hash
        normalize_direct_hash(value, depth:, ancestors:, counters:)
      when Array
        normalize_direct_array(value, depth:, ancestors:, counters:)
      when String
        value.dup
      when Integer, TrueClass, FalseClass, NilClass
        value
      when Float
        unless value.finite?
          raise ProtocolError, "Workflow direct result must contain only finite numbers"
        end

        value
      else
        raise ProtocolError, "Workflow direct result must be JSON-compatible"
      end
    end

    def normalize_direct_hash(value, depth:, ancestors:, counters:)
      with_direct_container(value, ancestors) do
        value.each_with_object({}) do |(key, child), normalized|
          unless key.is_a?(String) || key.is_a?(Symbol)
            raise ProtocolError, "Workflow direct result keys must be Strings or Symbols"
          end

          normalized_key = normalize_direct_value(
            key.to_s,
            depth: depth + 1,
            ancestors:,
            counters:
          )
          if normalized.key?(normalized_key)
            raise ProtocolError, "Workflow direct result keys must be unique after normalization"
          end

          normalized[normalized_key] = normalize_direct_value(
            child,
            depth: depth + 1,
            ancestors:,
            counters:
          )
        end
      end
    end

    def normalize_direct_array(value, depth:, ancestors:, counters:)
      with_direct_container(value, ancestors) do
        value.map do |child|
          normalize_direct_value(child, depth: depth + 1, ancestors:, counters:)
        end
      end
    end

    def with_direct_container(value, ancestors)
      if ancestors[value.object_id]
        raise ProtocolError, "Workflow direct result cannot contain cyclic values"
      end

      ancestors[value.object_id] = true
      yield
    ensure
      ancestors.delete(value.object_id)
    end

    def template_locals_for(agent)
      @template_locals.merge(runtime.template_locals(run:, agent:))
    end

    def isolated_state(value)
      case value
      when Hash
        value.to_h { |key, item| [isolated_state(key), isolated_state(item)] }
      when Array
        value.map { |item| isolated_state(item) }
      when String
        value.dup
      when NilClass, TrueClass, FalseClass, Numeric, Symbol
        value
      else
        raise ArgumentError, "workflow context must contain only JSON-like state"
      end
    end

    def workflow_usage
      @mutex.synchronize { @intermediate_usage }
    end

    def workflow_steps
      @mutex.synchronize { @workflow_steps.dup.freeze }
    end

    def ensure_open!
      @mutex.synchronize { raise Error, "workflow is already closed" if @closed }
    end

    def check_execution!
      @cancellation_token.raise_if_cancelled!
      raise DeadlineExceededError, "The run deadline was reached" if @deadline && Time.now >= @deadline
    end

    def owned_invocation?(value)
      @mutex.synchronize { @invocations.include?(value) }
    end

    def normalize_history(value)
      return [].freeze if value.nil?

      Array(value).map { |message| Message.coerce(message) }.freeze
    end
  end
end
