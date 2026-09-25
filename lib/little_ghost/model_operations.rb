# frozen_string_literal: true

require "json"

module LittleGhost
  # Executes bounded model operations without creating an Agent or Run.
  class ModelOperations # :nodoc:
    MAX_STRUCTURED_RESULT_BYTES = 1_000_000
    MAX_STRUCTURED_RESULT_DEPTH = 64
    MAX_STRUCTURED_RESULT_NODES = 100_000
    MAX_STRUCTURED_RESULT_REPAIR_ATTEMPTS = 3

    def initialize(model_resolver:, framework_prompts: FrameworkPrompts.new)
      @model_resolver = model_resolver
      @framework_prompts = framework_prompts
    end

    def generate(model:, messages:, result_schema: nil, settings: {}, structured_result_repair_attempts: 1,
      template_paths: [], cancellation_token: Support::CancellationToken.new, deadline: nil)
      invocation_paths = normalize_template_paths(template_paths)
      resolved = @model_resolver.resolve(model)
      schema = normalize_schema(result_schema)
      repair_attempts = normalize_repair_attempts(structured_result_repair_attempts) if schema
      strategy = StructuredOutput.resolve(schema, model: resolved, ordinary_tools: []) if schema
      handle = Instrumentation.start(:generation, model_provider: resolved.target.provider, model_id: resolved.model_id, model_role: resolved.role, structured: !schema.nil?)
      usage = Usage.new
      conversation = messages.map { |message| Message.coerce(message) }
      response = complete(resolved, messages: conversation, settings:, schema:, strategy:, repair: false,
        invocation_paths:, cancellation_token:, deadline:)
      usage += response.usage
      output, errors = schema ? parse_structured_response(
        response.message,
        schema,
        strategy,
        invocation_paths:
      ) : [response.message.text, []]
      conversation << (schema ? redact_structured_response(
        response.message,
        schema,
        strategy,
        invocation_paths:
      ) : response.message)
      repairs_remaining = repair_attempts
      while schema && !errors.empty? && repairs_remaining.positive?
        conversation << structured_repair_message(
          response.message, strategy, errors:, repairs_remaining:, invocation_paths:
        )
        response = complete(resolved, messages: conversation, settings:, schema:, strategy:, repair: true,
          invocation_paths:, cancellation_token:, deadline:)
        usage += response.usage
        output, errors = parse_structured_response(response.message, schema, strategy, invocation_paths:)
        conversation << redact_structured_response(response.message, schema, strategy, invocation_paths:)
        repairs_remaining -= 1
      end
      unless errors.empty?
        raise StructuredResultError.new(
          "The model did not return a valid structured result after its repair attempts",
          schema_name: schema.fetch(:name), validation_errors: errors
        )
      end
      handle.finish(outcome: :success, **usage_attributes(usage))
      structured_result = StructuredResult.new(schema_name: schema.fetch(:name), value: output) if schema
      final_message = schema ? conversation.last : response.message
      RunResult.new(
        message: final_message,
        stop_reason: schema ? :structured_result : response.stop_reason,
        usage:,
        messages: conversation.freeze,
        state: DataMap.new,
        structured_result:,
        steps: []
      )
    rescue => error
      handle&.finish(outcome: :error, error_type: error.class.name) if handle&.active?
      raise
    end

    def embed(model:, inputs:, settings: {}, limits: {}, cancellation_token: Support::CancellationToken.new, deadline: nil)
      request = Embeddings::Request.new(inputs:, settings:, limits:, cancellation_token:, deadline:)
      resolved = @model_resolver.resolve(model)
      handle = Instrumentation.start(:embedding, model_provider: resolved.target.provider, model_id: resolved.model_id, model_role: resolved.role, input_count: request.inputs.length)
      response = resolved.embed(request)
      metadata = response.metadata.merge(provider: resolved.target.provider, model: resolved.model_id, model_role: resolved.role, input_count: request.inputs.length).compact
      result = Embeddings::Response.new(vectors: response.vectors, usage: response.usage, metadata:)
      handle.finish(outcome: :success, dimensions: result.dimensions, **usage_attributes(result.usage))
      result
    rescue => error
      handle&.finish(outcome: :error, error_type: error.class.name) if handle&.active?
      raise
    end

    def decide(model:, state:, questions:, cancellation_token: Support::CancellationToken.new, deadline: nil)
      request = DecisionRequest.new(state:, questions:, cancellation_token:, deadline:)
      resolved = @model_resolver.resolve(model)
      handle = Instrumentation.start(:decision, model_provider: resolved.target.provider, model_id: resolved.model_id, question_count: request.questions.length)
      result = resolved.decide(request)
      raise ProtocolError, "Decision provider returned an unexpected result" unless result.is_a?(DecisionResult)

      handle.finish(outcome: :success, **usage_attributes(result.usage))
      result
    rescue => error
      handle&.finish(outcome: :error, error_type: error.class.name) if handle&.active?
      raise
    end

    private

    def complete(model, messages:, settings:, schema:, strategy:, repair:, invocation_paths:, cancellation_token:, deadline:)
      request = ModelRequest.new(
        messages:, settings:,
        tools: strategy ? strategy.tools(
          [],
          description: framework_prompt("structured_output/tools/result/description", {}, invocation_paths:)
        ) : [],
        output_schema: strategy&.output_schema,
        tool_choice: direct_generation_tool_choice(strategy, repair:),
        required_capabilities: strategy ? strategy.required_capabilities : [],
        cancellation_token:, deadline:
      )
      response = nil
      model.stream(request) do |event|
        response = event.data[:response] if event.type == :message_stop
      end
      response || raise(ProtocolError, "Provider stream ended without a response")
    end

    def normalize_schema(value)
      return unless value
      raise ArgumentError, "result_schema must be a mapping" unless value.respond_to?(:to_h)

      schema = value.to_h.transform_keys(&:to_sym)
      name = schema.fetch(:name).to_s
      json_schema = schema.fetch(:schema)
      Class.new(Agent).result_schema(
        json_schema,
        name:,
        description: schema[:description],
        strategy: :auto
      ).except(:strategy).freeze
    end

    def parse_structured_response(message, schema, strategy, invocation_paths:)
      return parse_structured(message.text, schema, invocation_paths:) if strategy.provider?

      tool_uses = message.content.grep(Content::ToolUse)
      result_tool_uses = tool_uses.select { |tool_use| tool_use.name == strategy.schema_name }
      if result_tool_uses.empty?
        return [nil, [framework_prompt("structured_output/validation/feedback/missing_tool", {}, invocation_paths:)]]
      end
      if result_tool_uses.length > 1
        return [nil, [framework_prompt("structured_output/validation/feedback/multiple_tools", {}, invocation_paths:)]]
      end
      if tool_uses.length > 1
        return [nil, [framework_prompt("structured_output/validation/feedback/tool_not_exclusive", {}, invocation_paths:)]]
      end

      validate_structured_value(result_tool_uses.first.input, schema, invocation_paths:)
    end

    def parse_structured(text, schema, invocation_paths:)
      if text.bytesize > MAX_STRUCTURED_RESULT_BYTES
        raise StructuredResultError.new(
          framework_prompt("structured_output/validation/feedback/too_large", {}, invocation_paths:),
          schema_name: schema.fetch(:name)
        )
      end
      value = JSON.parse(text)
      validate_structured_value(value, schema, invocation_paths:)
    rescue JSON::ParserError
      [nil, [framework_prompt("structured_output/validation/feedback/invalid_json", {}, invocation_paths:)]]
    rescue StructuredResultError => error
      [nil, [error.message]]
    end

    def validate_structured_value(value, schema, invocation_paths:)
      validate_complexity!(value, schema.fetch(:name), invocation_paths:)
      errors = Tool::SchemaValidator.new(
        schema.fetch(:schema),
        prompt_renderer: ->(key, **locals) { framework_prompt(key, locals, invocation_paths:) }
      ).validate(value)
      [value, errors]
    rescue StructuredResultError => error
      [nil, [error.message]]
    end

    def structured_repair_message(message, strategy, errors:, repairs_remaining:, invocation_paths:)
      tool_uses = message.content.grep(Content::ToolUse)
      feedback = framework_prompt("structured_output/repair/feedback/schema_errors", {errors:}, invocation_paths:)
      if strategy.tool? && !tool_uses.empty?
        return Message.new(
          role: :tool,
          content: tool_uses.map do |tool_use|
            Content::ToolResult.new(
              tool_use_id: tool_use.id,
              content: feedback,
              status: :error
            )
          end
        )
      end

      Message.new(
        role: :user,
        content: framework_prompt(
          "structured_output/repair/request",
          {tool: strategy.tool?, schema_name: strategy.schema_name, repairs_remaining:, feedback:},
          invocation_paths:
        )
      )
    end

    def direct_generation_tool_choice(strategy, repair:)
      return unless strategy
      return {name: strategy.schema_name}.freeze if strategy.tool?

      strategy.tool_choice(repair:)
    end

    def normalize_repair_attempts(value)
      return value if value.is_a?(Integer) && value.between?(0, MAX_STRUCTURED_RESULT_REPAIR_ATTEMPTS)

      raise ArgumentError, "structured_result_repair_attempts must be an integer from zero through #{MAX_STRUCTURED_RESULT_REPAIR_ATTEMPTS}"
    end

    def validate_complexity!(value, schema_name, invocation_paths:)
      nodes = 0
      stack = [[value, 1]]
      until stack.empty?
        child, depth = stack.pop
        nodes += 1
        if depth > MAX_STRUCTURED_RESULT_DEPTH
          raise StructuredResultError.new(
            framework_prompt("structured_output/validation/feedback/too_deep", {}, invocation_paths:),
            schema_name:
          )
        end
        if nodes > MAX_STRUCTURED_RESULT_NODES
          raise StructuredResultError.new(
            framework_prompt("structured_output/validation/feedback/too_complex", {}, invocation_paths:),
            schema_name:
          )
        end
        child.each { |key, nested| stack << [key, depth + 1] << [nested, depth + 1] } if child.is_a?(Hash)
        child.each { |nested| stack << [nested, depth + 1] } if child.is_a?(Array)
      end
    end

    def redact_structured_message(message, schema, invocation_paths:)
      Message.new(
        role: message.role,
        content: framework_prompt(
          "structured_output/persistence/format/redaction",
          {schema_name: schema.fetch(:name)},
          invocation_paths:
        ),
        metadata: message.metadata
      )
    end

    def redact_structured_response(message, schema, strategy, invocation_paths:)
      tool_uses = message.content.grep(Content::ToolUse)
      return redact_structured_message(message, schema, invocation_paths:) unless strategy.tool? && !tool_uses.empty?

      Message.new(
        role: message.role,
        content: tool_uses.map do |tool_use|
          Content::ToolUse.new(id: tool_use.id, name: tool_use.name, input: {})
        end,
        metadata: message.metadata
      )
    end

    def usage_attributes(usage)
      usage.to_h.except(:total_tokens)
    end

    def framework_prompt(key, locals = {}, invocation_paths: [])
      @framework_prompts.render(key, locals:, invocation_paths:)
    end

    def normalize_template_paths(paths)
      Array(paths).map do |path|
        unless path.is_a?(TrustedPath)
          raise ArgumentError, "template_paths must contain only LittleGhost::TrustedPath values"
        end

        path
      end.freeze
    end
  end
end
