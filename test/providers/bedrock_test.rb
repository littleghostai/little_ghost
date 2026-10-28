# frozen_string_literal: true

require "test_helper"
require "little_ghost/providers/bedrock"

class BedrockTest < Minitest::Test
  FakeResponse = Data.define(:stream)
  NetworkingError = Class.new(StandardError)
  ServiceUnavailableException = Class.new(StandardError)
  ThrottlingException = Class.new(StandardError)

  class FakeClient
    attr_reader :parameters

    def initialize(events)
      @events = events
    end

    def converse_stream(**parameters)
      @parameters = parameters
      FakeResponse.new(stream: @events)
    end
  end

  class ConverseValidatingClient
    attr_reader :requests

    def initialize
      @requests = []
    end

    def converse_stream(**parameters)
      @requests << parameters
      declared = Array(parameters.dig(:tool_config, :tools)).map { |tool| tool.dig(:tool_spec, :name) }
      parameters.fetch(:messages).flat_map { |message| message.fetch(:content) }.each do |block|
        if block[:tool_use] && !declared.include?(block.dig(:tool_use, :name))
          raise LittleGhost::ProviderError, "ValidationException: toolConfig must declare #{block.dig(:tool_use, :name)}"
        end
        if block[:tool_result] && declared.empty?
          raise LittleGhost::ProviderError, "ValidationException: toolConfig is required with toolResult blocks"
        end
      end
      text = (@requests.length == 1) ? "Summary" : "Done"
      FakeResponse.new(stream: [
        {message_start: {role: "assistant"}},
        {content_block_delta: {content_block_index: 0, delta: {text:}}},
        {message_stop: {stop_reason: "end_turn"}}
      ])
    end
  end

  class FakeEmbeddingClient
    attr_reader :parameters

    def initialize(responses)
      @responses = responses
      @parameters = []
    end

    def invoke_model(**parameters)
      @parameters << parameters
      LittleGhost::Providers::Bedrock::HTTPClient::InvokeResponse.new(body: JSON.generate(@responses.shift))
    end
  end

  class RawEmbeddingClient
    def initialize(body) = @body = body

    def invoke_model(**)
      LittleGhost::Providers::Bedrock::HTTPClient::InvokeResponse.new(body: @body)
    end
  end

  def test_embeds_titan_inputs_sequentially
    client = FakeEmbeddingClient.new([
      {embedding: [1] + ([0] * 255), inputTextTokenCount: 2},
      {embedding: [0, 1] + ([0] * 254), inputTextTokenCount: 3}
    ])
    provider = LittleGhost::Providers::Bedrock.new(model: "amazon.titan-embed-text-v2:0", client:)

    result = provider.embed(LittleGhost::Embeddings::Request.new(
      inputs: ["one", "two"], settings: {dimensions: 256, normalize: false}
    ))

    assert_equal [1.0, 0.0], result.vectors.first.first(2)
    assert_equal [0.0, 1.0], result.vectors.last.first(2)
    assert_equal 5, result.usage.input_tokens
    assert_equal 2, client.parameters.length
    assert_equal({input_text: "one", dimensions: 256, normalize: false}, client.parameters.first[:body])
    assert_equal LittleGhost::Providers::Bedrock::DEFAULT_MAX_EMBEDDING_RESPONSE_BYTES,
      client.parameters.first[:max_response_bytes]
  end

  def test_rejects_titan_vectors_with_unexpected_dimensions
    client = FakeEmbeddingClient.new([{embedding: [1, 0], inputTextTokenCount: 2}])
    provider = LittleGhost::Providers::Bedrock.new(model: "amazon.titan-embed-text-v2:0", client:)

    assert_raises(LittleGhost::ProtocolError) do
      provider.embed(LittleGhost::Embeddings::Request.new(inputs: "one", settings: {dimensions: 256}))
    end
  end

  def test_rejects_embedding_for_another_bedrock_model
    provider = LittleGhost::Providers::Bedrock.new(model: "other", client: FakeClient.new([]))

    assert_raises(LittleGhost::UnsupportedModelOperationError) do
      provider.embed(LittleGhost::Embeddings::Request.new(inputs: "text"))
    end
  end

  def test_invalid_embedding_json_does_not_leak_provider_content
    sentinel = "SENSITIVE_PROVIDER_FRAGMENT"
    provider = LittleGhost::Providers::Bedrock.new(
      model: "amazon.titan-embed-text-v2:0",
      client: RawEmbeddingClient.new("{#{sentinel}")
    )

    error = assert_raises(LittleGhost::ProtocolError) do
      provider.embed(LittleGhost::Embeddings::Request.new(inputs: "text"))
    end

    assert_equal "Bedrock returned an invalid embedding response", error.message
    refute_includes error.message, sentinel
  end

  class StalledEvents
    attr_reader :started

    def initialize
      @started = Queue.new
      @release = Queue.new
    end

    def each
      started << true
      @release.pop
    end
  end

  def test_normalizes_converse_stream_and_request
    events = [
      {message_start: {role: "assistant"}},
      {content_block_delta: {content_block_index: 0, delta: {text: "Hello"}}},
      {content_block_start: {content_block_index: 1, start: {tool_use: {tool_use_id: "tool-1", name: "lookup"}}}},
      {content_block_delta: {content_block_index: 1, delta: {tool_use: {input: "{\"id\":1}"}}}},
      {content_block_stop: {content_block_index: 1}},
      {message_stop: {stop_reason: "tool_use"}},
      {metadata: {usage: {input_tokens: 10, output_tokens: 4, cache_read_input_tokens: 3}}}
    ]
    client = FakeClient.new(events)
    provider = LittleGhost::Providers::Bedrock.new(model: "anthropic.test", client:)
    tool = {name: "lookup", description: "Lookup", input_schema: {type: "object"}}
    request = LittleGhost::ModelRequest.new(
      messages: [{role: :system, content: "System"}, {role: :user, content: "Hi"}],
      tools: [tool],
      settings: {max_tokens: 100}
    )

    result = provider.stream(request).to_a

    assert_equal %i[message_start text_delta tool_call_start tool_call_delta tool_call_stop usage message_stop], result.map(&:type)
    response = result.last.data[:response]
    assert_equal :tool_use, response.stop_reason
    assert_equal({"id" => 1}, response.message.content.grep(LittleGhost::Content::ToolUse).fetch(0).input)
    assert_equal 3, response.usage.cache_read_tokens
    assert_equal [{text: "System"}], client.parameters[:system]
    assert_equal 100, client.parameters.dig(:inference_config, :max_tokens)
    assert_equal "lookup", client.parameters.dig(:tool_config, :tools, 0, :tool_spec, :name)
  end

  def test_normalizes_camel_case_http_events_for_tool_backed_structured_output
    events = [
      http_event("messageStart", {"role" => "assistant"}),
      http_event("contentBlockStart", {"contentBlockIndex" => 0, "start" => {"toolUse" => {"toolUseId" => "tool-1", "name" => "submit_result"}}}),
      http_event("contentBlockDelta", {"contentBlockIndex" => 0, "delta" => {"toolUse" => {"input" => "{\"english_text\":\"yes\"}"}}}),
      http_event("contentBlockStop", {"contentBlockIndex" => 0}),
      http_event("messageStop", {"stopReason" => "tool_use"}),
      http_event("metadata", {"usage" => {"inputTokens" => 10, "outputTokens" => 4}})
    ]
    provider = LittleGhost::Providers::Bedrock.new(model: "amazon.nova-test", client: FakeClient.new(events))

    result = provider.stream(request).to_a

    assert_equal %i[message_start tool_call_start tool_call_delta tool_call_stop usage message_stop], result.map(&:type)
    response = result.last.data.fetch(:response)
    assert_equal :tool_use, response.stop_reason
    assert_equal({"english_text" => "yes"}, response.message.content.grep(LittleGhost::Content::ToolUse).fetch(0).input)
    assert_equal 10, response.usage.input_tokens
    assert_equal 4, response.usage.output_tokens
  end

  def test_preserves_tool_schema_and_arguments_field_names_on_the_wire
    credentials = LittleGhost::Providers::Bedrock::Credentials.new(access_key_id: "key", secret_access_key: "secret")
    client = LittleGhost::Providers::Bedrock::HTTPClient.new(region: "us-east-1", credentials:)
    payload = client.send(:camelize, {
      tool_config: {
        tools: [{
          tool_spec: {
            input_schema: {
              json: {
                type: "object",
                properties: {
                  english_text: {type: "string"},
                  accountID: {type: "string"}
                },
                required: ["english_text", "accountID"],
                additionalProperties: false
              }
            }
          }
        }]
      }
    })

    schema = payload.dig("toolConfig", "tools", 0, "toolSpec", "inputSchema", "json")
    assert_equal %w[accountID english_text], schema.fetch("properties").keys.sort
    assert_equal ["english_text", "accountID"], schema.fetch("required")
    assert_equal false, schema.fetch("additionalProperties")
  end

  def test_default_client_is_zero_dependency_and_requires_a_region
    error = assert_raises(LittleGhost::ConfigurationError) do
      LittleGhost::Providers::Bedrock.new(model: "test", credential_resolver: -> { flunk })
    end

    assert_includes error.message, "region"
  end

  def test_capabilities_are_derived_from_model_metadata
    provider = LittleGhost::Providers::Bedrock.new(model: "anthropic.test", client: FakeClient.new([]))

    unknown = provider.capabilities
    known = provider.capabilities(
      metadata: {supported_parameters: %w[structured_outputs tools tool_choice]}
    )

    refute unknown.known?
    assert known.native_structured_output?
    assert known.tools?
    assert known.tool_choice?
  end

  def test_serializes_native_json_schema_output_configuration
    client = FakeClient.new([
      {message_start: {role: "assistant"}},
      {message_stop: {stop_reason: "end_turn"}}
    ])
    provider = LittleGhost::Providers::Bedrock.new(model: "anthropic.test", client:)
    output_schema = {
      name: "answer",
      description: "Return an answer",
      schema: {
        "type" => "object",
        "properties" => {"answer" => {"type" => "string"}},
        "required" => ["answer"],
        "additionalProperties" => false
      }
    }

    provider.stream(LittleGhost::ModelRequest.new(messages: [], output_schema:)).to_a

    json_schema = client.parameters.dig(
      :output_config, :text_format, :structure, :json_schema
    )
    assert_equal "json_schema", client.parameters.dig(:output_config, :text_format, :type)
    assert_equal "answer", json_schema.fetch(:name)
    assert_equal output_schema.fetch(:schema), JSON.parse(json_schema.fetch(:schema))
  end

  def test_omits_unsupported_strict_result_tool_flag_and_serializes_tool_choice
    client = FakeClient.new([
      {message_start: {role: "assistant"}},
      {message_stop: {stop_reason: "end_turn"}}
    ])
    provider = LittleGhost::Providers::Bedrock.new(model: "anthropic.test", client:)
    tool = {
      name: "submit_result",
      description: "Submit",
      input_schema: {type: "object"},
      strict: true
    }

    provider.stream(
      LittleGhost::ModelRequest.new(
        messages: [],
        tools: [tool],
        tool_choice: {name: "submit_result"}
      )
    ).to_a

    tool_spec = client.parameters.dig(:tool_config, :tools, 0, :tool_spec)

    assert_equal "submit_result", tool_spec.fetch(:name)
    assert_equal({json: {type: "object"}}, tool_spec.fetch(:input_schema))
    assert_nil tool_spec[:strict]
    assert_equal(
      {tool: {name: "submit_result"}},
      client.parameters.dig(:tool_config, :tool_choice)
    )
  end

  def test_strips_unsupported_top_level_tool_schema_keywords_for_nova
    client = FakeClient.new([
      {message_start: {role: "assistant"}},
      {message_stop: {stop_reason: "end_turn"}}
    ])
    provider = LittleGhost::Providers::Bedrock.new(model: "us.amazon.nova-2-lite-v1:0", client:)

    provider.stream(
      LittleGhost::ModelRequest.new(
        messages: [],
        tools: [{
          name: "submit_result",
          input_schema: {
            type: "object",
            properties: {answer: {type: "string"}},
            required: ["answer"],
            additionalProperties: false
          }
        }]
      )
    ).to_a

    schema = client.parameters.dig(:tool_config, :tools, 0, :tool_spec, :input_schema, :json)

    assert_equal({
      type: "object",
      properties: {answer: {type: "string"}},
      required: ["answer"]
    }, schema)
  end

  def test_serializes_required_tool_choice_as_any
    client = FakeClient.new([
      {message_start: {role: "assistant"}},
      {message_stop: {stop_reason: "end_turn"}}
    ])
    provider = LittleGhost::Providers::Bedrock.new(model: "anthropic.test", client:)

    provider.stream(
      LittleGhost::ModelRequest.new(
        messages: [],
        tools: [{name: "lookup", description: "Lookup", input_schema: {type: "object"}}],
        tool_choice: :required
      )
    ).to_a

    assert_equal({any: {}}, client.parameters.dig(:tool_config, :tool_choice))
  end

  def test_accepts_the_event_type_shape_used_by_the_aws_sdk
    events = [
      {role: "assistant", event_type: :message_start},
      {content_block_index: 0, delta: {text: "Hello"}, event_type: :content_block_delta},
      {stop_reason: "end_turn", event_type: :message_stop}
    ]
    provider = LittleGhost::Providers::Bedrock.new(model: "test", client: FakeClient.new(events))

    result = provider.stream(request).to_a

    assert_equal %i[message_start text_delta message_stop], result.map(&:type)
    assert_equal "Hello", result.last.data[:response].message.text
  end

  def test_preserves_native_signed_reasoning_for_the_next_tool_turn
    events = [
      {message_start: {role: "assistant"}},
      {content_block_delta: {content_block_index: 0, delta: {reasoning_content: {text: "private reasoning"}}}},
      {content_block_delta: {content_block_index: 0, delta: {reasoning_content: {signature: "signed-reasoning"}}}},
      {content_block_start: {content_block_index: 1, start: {tool_use: {tool_use_id: "tool-1", name: "lookup"}}}},
      {content_block_delta: {content_block_index: 1, delta: {tool_use: {input: "{}"}}}},
      {content_block_stop: {content_block_index: 1}},
      {message_stop: {stop_reason: "tool_use"}}
    ]
    first_provider = LittleGhost::Providers::Bedrock.new(model: "anthropic.test", client: FakeClient.new(events))
    response = first_provider.stream(request).to_a.last.data.fetch(:response)
    reasoning = response.message.content.grep(LittleGhost::Content::Reasoning).fetch(0)
    tool_use = response.message.content.grep(LittleGhost::Content::ToolUse).fetch(0)

    client = FakeClient.new([{message_stop: {stop_reason: "end_turn"}}])
    second_provider = LittleGhost::Providers::Bedrock.new(model: "anthropic.test", client:)
    second_provider.stream(request(messages: [
      response.message,
      {role: :tool, content: [LittleGhost::Content::ToolResult.new(tool_use_id: tool_use.id, content: "found", status: :success)]}
    ])).to_a

    assert_equal "private reasoning", reasoning.text
    assert_equal "signed-reasoning", reasoning.signature
    assert_equal({
      reasoning_content: {
        reasoning_text: {text: "private reasoning", signature: "signed-reasoning"}
      }
    }, client.parameters.dig(:messages, 0, :content, 0))
  end

  def test_serializes_redacted_bedrock_reasoning_natively
    client = FakeClient.new([{message_stop: {stop_reason: "end_turn"}}])
    provider = LittleGhost::Providers::Bedrock.new(model: "anthropic.test", client:)
    reasoning = LittleGhost::Content::Reasoning.new(redacted_content: "\x00encrypted".b)

    provider.stream(request(messages: [{role: :assistant, content: [reasoning]}])).to_a

    assert_equal({reasoning_content: {redacted_content: "\x00encrypted".b}}, client.parameters.dig(:messages, 0, :content, 0))
    assert_equal reasoning, LittleGhost::Content.normalize(reasoning.to_h)
  end

  def test_rejects_a_truncated_stream
    events = [{message_start: {role: "assistant"}}, {content_block_delta: {content_block_index: 0, delta: {text: "partial"}}}]
    provider = LittleGhost::Providers::Bedrock.new(model: "test", client: FakeClient.new(events))

    error = assert_raises(LittleGhost::ProtocolError) { provider.stream(request).to_a }
    assert_includes error.message, "message_stop"
  end

  def test_rejects_malformed_tool_calls_with_a_specific_error
    events = [
      {content_block_start: {content_block_index: 0, start: {tool_use: {tool_use_id: "tool-1", name: "lookup"}}}},
      {content_block_delta: {content_block_index: 0, delta: {tool_use: {input: "{"}}}},
      {content_block_stop: {content_block_index: 0}}
    ]
    provider = LittleGhost::Providers::Bedrock.new(model: "test", client: FakeClient.new(events))

    error = assert_raises(LittleGhost::MalformedToolCallError) { provider.stream(request).to_a }

    assert_includes error.message, "invalid tool call"
  end

  def test_rejects_bedrock_malformed_tool_use_stop_with_a_specific_error
    events = [{message_stop: {stop_reason: "malformed_tool_use"}}]
    provider = LittleGhost::Providers::Bedrock.new(model: "test", client: FakeClient.new(events))

    error = assert_raises(LittleGhost::MalformedToolCallError) { provider.stream(request).to_a }

    assert_includes error.message, "malformed_tool_use"
  end

  def test_cancellation_interrupts_a_stalled_stream
    stalled = StalledEvents.new
    token = LittleGhost::Support::CancellationToken.new
    provider = LittleGhost::Providers::Bedrock.new(model: "test", client: FakeClient.new(stalled))
    runner = provider_thread(provider, request(cancellation_token: token))
    stalled.started.pop

    token.cancel

    assert runner.join(1), "stalled Bedrock stream did not stop after cancellation"
    assert_instance_of LittleGhost::CancelledError, runner.value
  ensure
    token&.cancel
    runner&.kill
    runner&.join
  end

  def test_deadline_interrupts_a_stalled_stream
    stalled = StalledEvents.new
    token = LittleGhost::Support::CancellationToken.new
    provider = LittleGhost::Providers::Bedrock.new(model: "test", client: FakeClient.new(stalled))
    runner = provider_thread(provider, request(cancellation_token: token, deadline: Time.now + 0.05))
    stalled.started.pop

    assert runner.join(1), "stalled Bedrock stream did not stop at its deadline"
    assert_instance_of LittleGhost::DeadlineExceededError, runner.value
  ensure
    token&.cancel
    runner&.kill
    runner&.join
  end

  def test_retries_transient_failures_and_reports_them
    client = Class.new do
      attr_reader :attempts

      def initialize
        @attempts = 0
      end

      def converse_stream(**)
        @attempts += 1
        raise BedrockTest::NetworkingError, "busy" if attempts == 1

        BedrockTest::FakeResponse.new(stream: [{message_stop: {stop_reason: "end_turn"}}])
      end
    end.new
    delays = []
    retries = []
    provider = LittleGhost::Providers::Bedrock.new(
      model: "test",
      client:,
      max_retries: 1,
      sleeper: ->(delay) { delays << delay },
      on_retry: ->(*arguments) { retries << arguments }
    )

    provider.stream(request).to_a

    assert_equal 2, client.attempts
    assert_equal [1], delays
    assert_equal 1, retries.first.fetch(0)
    assert_instance_of NetworkingError, retries.first.fetch(1)
    assert_equal 1, retries.first.fetch(2)
  end

  def test_does_not_outer_retry_sdk_throttling_failures
    client = Class.new do
      attr_reader :attempts

      def initialize
        @attempts = 0
      end

      def converse_stream(**)
        @attempts += 1
        raise BedrockTest::ThrottlingException, "throttled"
      end
    end.new
    provider = LittleGhost::Providers::Bedrock.new(
      model: "test",
      client:,
      max_retries: 2,
      sleeper: ->(*) { flunk("outer retry should not sleep for SDK throttling") }
    )

    assert_raises(LittleGhost::ProviderError) { provider.stream(request).to_a }
    assert_equal 1, client.attempts
  end

  def test_retries_terminal_service_failures
    client = Class.new do
      attr_reader :attempts

      def initialize
        @attempts = 0
      end

      def converse_stream(**)
        @attempts += 1
        raise BedrockTest::ServiceUnavailableException, "unavailable" if attempts == 1

        BedrockTest::FakeResponse.new(stream: [{message_stop: {stop_reason: "end_turn"}}])
      end
    end.new
    provider = LittleGhost::Providers::Bedrock.new(
      model: "test",
      client:,
      max_retries: 1,
      sleeper: ->(*) {}
    )

    provider.stream(request).to_a

    assert_equal 2, client.attempts
  end

  def test_retries_a_transient_stream_failure_after_partial_output
    client = Class.new do
      attr_reader :attempts

      def initialize
        @attempts = 0
      end

      def converse_stream(**)
        @attempts += 1
        if attempts > 1
          return BedrockTest::FakeResponse.new(stream: [
            {message_start: {role: "assistant"}},
            {content_block_delta: {content_block_index: 0, delta: {text: "complete"}}},
            {message_stop: {stop_reason: "end_turn"}}
          ])
        end

        stream = Enumerator.new do |output|
          output << {message_start: {role: "assistant"}}
          output << {content_block_delta: {content_block_index: 0, delta: {text: "partial"}}}
          raise BedrockTest::NetworkingError, "lost"
        end
        BedrockTest::FakeResponse.new(stream:)
      end
    end.new
    delivered = []
    retries = []
    provider = LittleGhost::Providers::Bedrock.new(
      model: "test",
      client:,
      max_retries: 1,
      sleeper: ->(*) {},
      on_retry: ->(*arguments) { retries << arguments }
    )

    provider.stream(request) { |event| delivered << event }

    assert_equal 2, client.attempts
    assert_equal 1, retries.length
    assert_equal %i[message_start text_delta model_retry message_start text_delta message_stop], delivered.map(&:type)
    assert_equal true, delivered.find { |event| event.type == :model_retry }.data.fetch(:partial_text)
    assert_equal "complete", delivered.last.data.fetch(:response).message.text
  end

  def test_retries_after_a_partial_tool_call_and_returns_only_the_successful_attempt
    client = Class.new do
      attr_reader :attempts

      def initialize = @attempts = 0

      def converse_stream(**)
        @attempts += 1
        events = if attempts == 1
          [
            {message_start: {role: "assistant"}},
            {content_block_start: {content_block_index: 0, start: {tool_use: {tool_use_id: "stale", name: "stale"}}}},
            {content_block_delta: {content_block_index: 0, delta: {tool_use: {input: "{}"}}}},
            {content_block_stop: {content_block_index: 0}},
            {service_unavailable_exception: {message: "retry"}}
          ]
        else
          [
            {message_start: {role: "assistant"}},
            {content_block_start: {content_block_index: 0, start: {tool_use: {tool_use_id: "current", name: "current"}}}},
            {content_block_delta: {content_block_index: 0, delta: {tool_use: {input: "{\"id\":1}"}}}},
            {content_block_stop: {content_block_index: 0}},
            {message_stop: {stop_reason: "tool_use"}}
          ]
        end
        BedrockTest::FakeResponse.new(stream: events)
      end
    end.new

    events = LittleGhost::Providers::Bedrock.new(
      model: "test", client:, max_retries: 1, sleeper: ->(*) {}
    ).stream(request).to_a
    retry_index = events.index { |event| event.type == :model_retry }
    response = events.last.data.fetch(:response)

    assert_equal 2, client.attempts
    assert events[0...retry_index].any? { |event| event.type == :tool_call_stop }
    assert_equal false, events.fetch(retry_index).data.fetch(:partial_text)
    assert_equal "service_unavailable_exception", events.fetch(retry_index).data.fetch(:error_code)
    assert_equal ["current"], response.message.content.grep(LittleGhost::Content::ToolUse).map(&:name)
    assert_equal({"id" => 1}, response.message.content.grep(LittleGhost::Content::ToolUse).fetch(0).input)
  end

  def test_retries_modeled_transient_stream_errors_after_partial_output
    transient_types = %i[
      internal_server_exception model_stream_error_exception service_unavailable_exception throttling_exception
    ]

    transient_types.each do |type|
      client = Class.new do
        attr_reader :attempts

        define_method(:initialize) do |event_type|
          @event_type = event_type
          @attempts = 0
        end

        define_method(:converse_stream) do |**|
          @attempts += 1
          events = if attempts == 1
            [
              {message_start: {role: "assistant"}},
              {content_block_delta: {content_block_index: 0, delta: {text: "partial"}}},
              {@event_type => {message: "retryable stream failure"}}
            ]
          else
            [{message_start: {role: "assistant"}}, {message_stop: {stop_reason: "end_turn"}}]
          end
          BedrockTest::FakeResponse.new(stream: events)
        end
      end.new(type)
      events = LittleGhost::Providers::Bedrock.new(
        model: "test", client:, max_retries: 1, sleeper: ->(*) {}
      ).stream(request).to_a

      assert_equal 2, client.attempts, type
      retry_events = events.select { |event| event.type == :model_retry }
      assert_equal 1, retry_events.length, type
      retry_event = retry_events.first
      assert_equal type.to_s, retry_event.data.fetch(:error_code), type
      assert_equal true, retry_event.data.fetch(:partial_text), type
    end
  end

  def test_does_not_retry_modeled_validation_stream_errors
    client = FakeClient.new([{validation_exception: {message: "invalid request"}}])
    provider = LittleGhost::Providers::Bedrock.new(
      model: "test", client:, max_retries: 2,
      sleeper: ->(*) { flunk("validation failures must not be retried") }
    )

    error = assert_raises(LittleGhost::Providers::Bedrock::StreamError) { provider.stream(request).to_a }

    assert_equal "validation_exception", error.event_type
  end

  def test_cancellation_interrupts_retry_backoff
    client = Class.new do
      attr_reader :attempts

      def initialize
        @attempts = 0
      end

      def converse_stream(**)
        @attempts += 1
        raise BedrockTest::NetworkingError, "busy"
      end
    end.new
    token = LittleGhost::Support::CancellationToken.new
    backoff_started = Queue.new
    retry_callback = ->(*) { backoff_started << true }
    provider = LittleGhost::Providers::Bedrock.new(model: "test", client:, max_retries: 1, on_retry: retry_callback)
    runner = provider_thread(provider, request(cancellation_token: token))
    backoff_started.pop

    token.cancel

    assert runner.join(0.5), "Bedrock retry backoff did not stop after cancellation"
    assert_instance_of LittleGhost::CancelledError, runner.value
    assert_equal 1, client.attempts
  ensure
    token&.cancel
    runner&.kill
    runner&.join
  end

  def test_retry_backoff_is_capped_by_the_deadline
    client = Class.new do
      attr_reader :attempts

      def initialize
        @attempts = 0
      end

      def converse_stream(**)
        @attempts += 1
        raise BedrockTest::NetworkingError, "busy"
      end
    end.new
    delays = []
    retry_callback = ->(_attempt, _error, delay) { delays << delay }
    provider = LittleGhost::Providers::Bedrock.new(model: "test", client:, max_retries: 1, on_retry: retry_callback)

    assert_raises(LittleGhost::DeadlineExceededError) do
      provider.stream(request(deadline: Time.now + 0.2)).to_a
    end

    assert_equal 1, client.attempts
    assert_equal 1, delays.length
    assert_operator delays.first, :>, 0
    assert_operator delays.first, :<=, 0.2
  end

  def test_rejects_unsupported_reasoning_effort
    provider = LittleGhost::Providers::Bedrock.new(model: "test", client: FakeClient.new([]))
    configured = LittleGhost::ModelRequest.new(
      messages: [{role: :user, content: "Hello"}],
      settings: {reasoning_effort: "high"}
    )

    error = assert_raises(LittleGhost::ConfigurationError) { provider.stream(configured).to_a }

    assert_equal "Bedrock does not support reasoning_effort", error.message
  end

  def test_normalizes_context_window_errors_for_agent_recovery
    client = Class.new do
      def converse_stream(**)
        raise BedrockTest::NetworkingError, "Input is too long for requested model"
      end
    end.new
    provider = LittleGhost::Providers::Bedrock.new(model: "test", client:)

    error = assert_raises(LittleGhost::ContextWindowOverflowError) do
      provider.stream(request).to_a
    end

    assert_equal "The model context window was exceeded", error.message
  end

  def test_maps_bedrock_media_formats
    client = FakeClient.new([{message_stop: {stop_reason: "end_turn"}}])
    provider = LittleGhost::Providers::Bedrock.new(model: "test", client:)
    messages = [{
      role: :user,
      content: [
        LittleGhost::Content::Image.new(data: "image", media_type: "image/jpeg"),
        LittleGhost::Content::Document.new(data: "document", media_type: "text/markdown", name: "notes.md")
      ]
    }]

    provider.stream(request(messages:)).to_a

    content = client.parameters.dig(:messages, 0, :content)
    assert_equal "jpeg", content[0].dig(:image, :format)
    assert_equal "md", content[1].dig(:document, :format)
  end

  def test_sends_tool_history_as_text_when_the_request_declares_no_tools
    client = ConverseValidatingClient.new
    provider = LittleGhost::Providers::Bedrock.new(model: "anthropic.test", client:)

    provider.stream(request(messages: [
      {role: :user, content: "Where is order A1?"},
      {role: :assistant, content: [
        LittleGhost::Content::Text.new(text: "Checking."),
        LittleGhost::Content::ToolUse.new(id: "call-1", name: "lookup_order", input: {order_id: "A1"})
      ]},
      {role: :tool, content: [LittleGhost::Content::ToolResult.new(tool_use_id: "call-1", content: "Order A1 shipped", status: :success)]},
      {role: :assistant, content: "It shipped."}
    ])).to_a

    parameters = client.requests.fetch(0)
    refute parameters.key?(:tool_config)
    assert_equal 4, parameters[:messages].length
    assert_equal({text: "Checking."}, parameters.dig(:messages, 1, :content, 0))
    call = parameters.dig(:messages, 1, :content, 1, :text)
    result = parameters.dig(:messages, 2, :content, 0, :text)
    assert_includes call, "lookup_order"
    assert_includes call, "call-1"
    assert_includes call, JSON.generate({"order_id" => "A1"})
    assert_includes result, "lookup_order"
    assert_includes result, "call-1"
    assert_includes result, "Order A1 shipped"
  end

  def test_sends_calls_to_undeclared_tools_as_text_and_keeps_declared_calls_native
    client = ConverseValidatingClient.new
    provider = LittleGhost::Providers::Bedrock.new(model: "anthropic.test", client:)
    lookup = {name: "lookup_order", description: "Look up an order", input_schema: {type: "object"}}

    provider.stream(LittleGhost::ModelRequest.new(
      messages: [
        {role: :user, content: "Check order A1 and the shipping log."},
        {role: :assistant, content: [
          LittleGhost::Content::ToolUse.new(id: "call-1", name: "lookup_order", input: {order_id: "A1"}),
          LittleGhost::Content::ToolUse.new(id: "call-2", name: "tools.bash", input: {command: "tail shipping.log"})
        ]},
        {role: :tool, content: [
          LittleGhost::Content::ToolResult.new(tool_use_id: "call-1", content: "Order A1 shipped", status: :success),
          LittleGhost::Content::ToolResult.new(tool_use_id: "call-2", content: "Unknown Tool: tools.bash", status: :error)
        ]}
      ],
      tools: [lookup]
    )).to_a

    parameters = client.requests.fetch(0)
    assert_equal ["lookup_order"], parameters.dig(:tool_config, :tools).map { |tool| tool.dig(:tool_spec, :name) }
    assert_equal({tool_use_id: "call-1", name: "lookup_order", input: {"order_id" => "A1"}}, parameters.dig(:messages, 1, :content, 0, :tool_use))
    assert_equal "call-1", parameters.dig(:messages, 2, :content, 0, :tool_result, :tool_use_id)
    call = parameters.dig(:messages, 1, :content, 1, :text)
    result = parameters.dig(:messages, 2, :content, 1, :text)
    assert_includes call, "tools.bash"
    assert_includes call, JSON.generate({"command" => "tail shipping.log"})
    assert_includes result, "tools.bash"
    assert_includes result, "Unknown Tool: tools.bash"
  end

  def test_sends_an_object_schema_for_tools_without_inputs
    client = FakeClient.new([{message_stop: {stop_reason: "end_turn"}}])
    provider = LittleGhost::Providers::Bedrock.new(model: "anthropic.test", client:)
    ping = LittleGhost::Tool.define(name: "ping", description: "Ping") { "pong" }.new.specification

    provider.stream(LittleGhost::ModelRequest.new(
      messages: [{role: :user, content: "Ping"}],
      tools: [ping, {name: "status", description: "Status"}]
    )).to_a

    schemas = client.parameters.dig(:tool_config, :tools).map { |tool| tool.dig(:tool_spec, :input_schema, :json) }
    assert_equal [{"type" => "object", "properties" => {}}] * 2, schemas
  end

  def test_tool_result_transcripts_distinguish_errors_from_successes
    transcripts = %i[success error].map do |status|
      client = ConverseValidatingClient.new
      LittleGhost::Providers::Bedrock.new(model: "anthropic.test", client:).stream(request(messages: [
        {role: :assistant, content: LittleGhost::Content::ToolUse.new(id: "call-1", name: "lookup_order", input: {})},
        {role: :tool, content: LittleGhost::Content::ToolResult.new(tool_use_id: "call-1", content: "Lookup finished", status:)}
      ])).to_a
      client.requests.fetch(0).dig(:messages, 1, :content, 0, :text)
    end

    refute_equal(*transcripts)
  end

  def test_decides_each_occurrence_of_a_repeated_call_id_separately
    client = ConverseValidatingClient.new
    provider = LittleGhost::Providers::Bedrock.new(model: "anthropic.test", client:)
    lookup = {name: "lookup_order", description: "Look up an order", input_schema: {type: "object"}}

    provider.stream(LittleGhost::ModelRequest.new(
      messages: [
        {role: :assistant, content: LittleGhost::Content::ToolUse.new(id: "call_0", name: "lookup_order", input: {order_id: "A1"})},
        {role: :tool, content: LittleGhost::Content::ToolResult.new(tool_use_id: "call_0", content: "Order A1 shipped", status: :success)},
        {role: :assistant, content: LittleGhost::Content::ToolUse.new(id: "call_0", name: "tools.bash", input: {command: "tail shipping.log"})},
        {role: :tool, content: LittleGhost::Content::ToolResult.new(tool_use_id: "call_0", content: "Unknown Tool: tools.bash", status: :error)}
      ],
      tools: [lookup]
    )).to_a

    messages = client.requests.fetch(0).fetch(:messages)
    assert_equal "lookup_order", messages.dig(0, :content, 0, :tool_use, :name)
    assert_equal "call_0", messages.dig(1, :content, 0, :tool_result, :tool_use_id)
    assert_includes messages.dig(2, :content, 0, :text), "tools.bash"
    assert_includes messages.dig(3, :content, 0, :text), "tools.bash"
    assert_includes messages.dig(3, :content, 0, :text), "Unknown Tool: tools.bash"
  end

  def test_context_compaction_summarizes_a_tool_using_history
    client = ConverseValidatingClient.new
    provider = LittleGhost::Providers::Bedrock.new(model: "anthropic.test", client:)
    model = LittleGhost::Model.new(provider:, target: "bedrock:anthropic.test")
    lookup_order = LittleGhost::Tool.define(name: "lookup_order", description: "Look up an order") { "unused" }.new
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 80, compression_threshold: 0.1,
        summary_ratio: 0.5, preserve_recent_messages: 2
    end
    history = [
      LittleGhost::Message.new(role: :user, content: "Where is order A1?"),
      LittleGhost::Message.new(role: :assistant, content: LittleGhost::Content::ToolUse.new(id: "call-1", name: "lookup_order", input: {order_id: "A1"})),
      LittleGhost::Message.new(role: :tool, content: LittleGhost::Content::ToolResult.new(tool_use_id: "call-1", content: "Order A1 shipped", status: :success)),
      LittleGhost::Message.new(role: :assistant, content: "Order A1 shipped."),
      LittleGhost::Message.new(role: :user, content: "Thanks")
    ]
    outcomes = []
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new
    instrumentation.subscribe(TestTelemetryRecorder.new(outcomes))

    agent_class.new(model:, tools: [lookup_order]).call("Anything else?", history:)

    summary, final = client.requests
    refute summary.key?(:tool_config)
    assert_includes summary[:messages].map { |message| message[:content].map { |block| block[:text] }.join }.join, "Order A1 shipped"
    assert_equal 2, client.requests.length
    assert_equal "Summary", final.dig(:messages, 0, :content, 0, :text)
    refute outcomes.any? { |name, attributes| name == :context_compaction && attributes[:outcome] == :error }
    assert outcomes.any? { |name, attributes| name == :context_compaction && attributes[:removed_messages].to_i.positive? }
  end

  private

  def http_event(type, payload)
    credentials = LittleGhost::Providers::Bedrock::Credentials.new(access_key_id: "key", secret_access_key: "secret")
    client = LittleGhost::Providers::Bedrock::HTTPClient.new(region: "us-east-1", credentials:)
    client.send(:event, {":event-type" => type}, JSON.generate(payload))
  end

  def request(messages: [{role: :user, content: "Hello"}],
    cancellation_token: LittleGhost::Support::CancellationToken.new, deadline: nil)
    LittleGhost::ModelRequest.new(messages:, cancellation_token:, deadline:)
  end

  def provider_thread(provider, model_request)
    Thread.new do
      provider.stream(model_request).to_a
    rescue => error
      error
    end.tap { |thread| thread.report_on_exception = false }
  end
end
