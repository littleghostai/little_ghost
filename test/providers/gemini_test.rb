# frozen_string_literal: true

require "test_helper"

class GeminiTest < Minitest::Test
  class Transport
    attr_reader :arguments

    def stream(**arguments)
      @arguments = arguments
      chunks = [
        {modelVersion: "gemini", candidates: [{content: {parts: [{text: "Hello"}]}}]},
        {candidates: [{content: {parts: [{functionCall: {id: "tool-1", name: "lookup", args: {id: 1}}}]}, finishReason: "STOP"}],
         usageMetadata: {promptTokenCount: 8, candidatesTokenCount: 5, cachedContentTokenCount: 2, thoughtsTokenCount: 1}}
      ]
      chunks.each { |chunk| yield "data: #{JSON.generate(chunk)}\n\n" }
    end
  end

  def test_streams_text_tools_and_normalized_usage
    transport = Transport.new
    provider = LittleGhost::Providers::Gemini.new(api_key: "secret", model: "gemini", transport:)
    request = LittleGhost::ModelRequest.new(messages: [LittleGhost::Message.new(role: :user, content: "Hi")],
      output_schema: {name: "answer", schema: {type: "object"}})

    events = provider.stream(request).to_a

    assert_equal %i[message_start text_delta tool_call_start tool_call_stop usage message_stop], events.map(&:type)
    response = events.last.data.fetch(:response)
    assert_equal :tool_use, response.stop_reason
    assert_equal 6, response.usage.input_tokens
    assert_equal 4, response.usage.output_tokens
    assert_includes transport.arguments.fetch(:path), "alt=sse&key=secret"
    assert_equal "application/json", JSON.parse(transport.arguments.fetch(:body)).dig("generationConfig", "responseMimeType")
  end

  class SequencedTransport
    attr_reader :requests

    def initialize(*responses)
      @responses = responses
      @requests = []
    end

    def stream(**arguments)
      @requests << arguments
      @responses.shift.each { |chunk| yield "data: #{JSON.generate(chunk)}\n\n" }
    end
  end

  def test_replays_a_thought_signature_on_the_next_request
    signed_call = {functionCall: {id: "tool-1", name: "lookup", args: {id: 1}}, thoughtSignature: "sig-abc"}
    transport = SequencedTransport.new(
      [{modelVersion: "gemini", candidates: [{content: {parts: [signed_call]}, finishReason: "STOP"}]}],
      [{candidates: [{content: {parts: [{text: "done"}]}, finishReason: "STOP"}]}]
    )
    provider = LittleGhost::Providers::Gemini.new(api_key: "secret", model: "gemini", transport:)

    message = call_tool(provider)
    follow_up_with(provider, message)

    assert_equal "sig-abc", function_call_part(transport, index: 1).fetch("thoughtSignature")
  end

  def test_omits_thought_signature_when_the_response_never_sent_one
    unsigned_call = {functionCall: {id: "tool-1", name: "lookup", args: {id: 1}}}
    transport = SequencedTransport.new(
      [{modelVersion: "gemini", candidates: [{content: {parts: [unsigned_call]}, finishReason: "STOP"}]}],
      [{candidates: [{content: {parts: [{text: "done"}]}, finishReason: "STOP"}]}]
    )
    provider = LittleGhost::Providers::Gemini.new(api_key: "secret", model: "gemini", transport:)

    message = call_tool(provider)
    follow_up_with(provider, message)

    refute function_call_part(transport, index: 1).key?("thoughtSignature")
  end

  def test_replays_a_thought_signature_for_a_function_call_missing_an_id
    signed_call = {functionCall: {name: "lookup", args: {id: 1}}, thoughtSignature: "sig-noid"}
    transport = SequencedTransport.new(
      [{modelVersion: "gemini", candidates: [{content: {parts: [signed_call]}, finishReason: "STOP"}]}],
      [{candidates: [{content: {parts: [{text: "done"}]}, finishReason: "STOP"}]}]
    )
    provider = LittleGhost::Providers::Gemini.new(api_key: "secret", model: "gemini", transport:)

    message = call_tool(provider)
    assert_match(/\A[0-9a-f-]{36}\z/, message.content.grep(LittleGhost::Content::ToolUse).first.id)
    follow_up_with(provider, message)

    assert_equal "sig-noid", function_call_part(transport, index: 1).fetch("thoughtSignature")
  end

  def test_only_replays_a_signature_for_the_call_that_had_one_in_a_parallel_batch
    parts = [
      {functionCall: {id: "tool-1", name: "lookup", args: {}}, thoughtSignature: "sig-1"},
      {functionCall: {id: "tool-2", name: "lookup", args: {}}}
    ]
    transport = SequencedTransport.new(
      [{modelVersion: "gemini", candidates: [{content: {parts:}, finishReason: "STOP"}]}],
      [{candidates: [{content: {parts: [{text: "done"}]}, finishReason: "STOP"}]}]
    )
    provider = LittleGhost::Providers::Gemini.new(api_key: "secret", model: "gemini", transport:)

    request = LittleGhost::ModelRequest.new(messages: [LittleGhost::Message.new(role: :user, content: "Hi")])
    response = provider.stream(request).to_a.last.data.fetch(:response)
    follow_up_with(provider, response.message)

    sent_parts = JSON.parse(transport.requests.last.fetch(:body)).fetch("contents")
      .flat_map { |message| message.fetch("parts") }.select { |part| part["functionCall"] }
    assert_equal "sig-1", sent_parts.find { |part| part.dig("functionCall", "id") == "tool-1" }.fetch("thoughtSignature")
    refute sent_parts.find { |part| part.dig("functionCall", "id") == "tool-2" }.key?("thoughtSignature")
  end

  def test_sequential_idless_calls_keep_their_original_signatures_in_full_history
    transport = SequencedTransport.new(
      [{candidates: [{content: {parts: [{functionCall: {name: "lookup", args: {}}, thoughtSignature: "sig-a"}]}, finishReason: "STOP"}]}],
      [{candidates: [{content: {parts: [{functionCall: {name: "lookup", args: {}}, thoughtSignature: "sig-b"}]}, finishReason: "STOP"}]}],
      [{candidates: [{content: {parts: [{text: "done"}]}, finishReason: "STOP"}]}]
    )
    provider = LittleGhost::Providers::Gemini.new(api_key: "secret", model: "gemini", transport:)
    first = call_tool(provider)
    first_result = LittleGhost::Message.new(role: :tool, content: [
      LittleGhost::Content::ToolResult.new(tool_use_id: first.content.first.id, content: "ok", status: :success)
    ])
    history = [LittleGhost::Message.new(role: :user, content: "Hi"), first, first_result]
    second = provider.stream(LittleGhost::ModelRequest.new(messages: history)).to_a.last.data.fetch(:response).message
    refute_equal first.content.first.id, second.content.first.id

    second_result = LittleGhost::Message.new(role: :tool, content: [
      LittleGhost::Content::ToolResult.new(tool_use_id: second.content.first.id, content: "ok", status: :success)
    ])
    provider.stream(LittleGhost::ModelRequest.new(messages: history + [second, second_result])).to_a

    assert_equal ["sig-a", "sig-b"], function_call_parts(transport, index: 2).map { |part| part.fetch("thoughtSignature") }
  end

  def test_reused_explicit_ids_are_scoped_to_each_message
    transport = SequencedTransport.new(
      [{candidates: [{content: {parts: [{functionCall: {id: "same", name: "lookup"}, thoughtSignature: "sig-a"}]}, finishReason: "STOP"}]}],
      [{candidates: [{content: {parts: [{functionCall: {id: "same", name: "lookup"}, thoughtSignature: "sig-b"}]}, finishReason: "STOP"}]}],
      [{candidates: [{content: {parts: [{functionCall: {id: "same", name: "lookup"}}]}, finishReason: "STOP"}]}],
      [{candidates: [{content: {parts: [{text: "done"}]}, finishReason: "STOP"}]}]
    )
    provider = LittleGhost::Providers::Gemini.new(api_key: "secret", model: "gemini", transport:)
    first = call_tool(provider)
    second = call_tool(provider)
    unsigned = call_tool(provider)

    provider.stream(LittleGhost::ModelRequest.new(messages: [first, second, unsigned])).to_a

    parts = function_call_parts(transport, index: 3)
    assert_equal ["same", "same", "same"], parts.map { |part| part.dig("functionCall", "id") }
    assert_equal ["sig-a", "sig-b", nil], parts.map { |part| part["thoughtSignature"] }
  end

  def test_persisted_signatures_survive_provider_recreation_and_reasoning_removal
    transport = SequencedTransport.new(
      [{candidates: [{content: {parts: [{text: "thinking", thought: true}, {functionCall: {id: "tool-1", name: "lookup"}, thoughtSignature: "sig-a"}]}, finishReason: "STOP"}]}]
    )
    provider = LittleGhost::Providers::Gemini.new(api_key: "secret", model: "gemini", transport:)
    original = call_tool(provider)
    restored = LittleGhost::Message.coerce(JSON.parse(JSON.generate(original.to_h))).without_reasoning
    assert_empty restored.content.grep(LittleGhost::Content::Reasoning)
    assert_equal original.metadata, restored.metadata
    resumed_transport = SequencedTransport.new([{candidates: [{content: {parts: [{text: "done"}]}, finishReason: "STOP"}]}])
    resumed = LittleGhost::Providers::Gemini.new(api_key: "secret", model: "gemini", transport: resumed_transport)

    follow_up_with(resumed, restored)

    assert_equal "sig-a", function_call_part(resumed_transport, index: 0).fetch("thoughtSignature")
    assert_equal "lookup", function_response_parts(resumed_transport, index: 0).first.dig("functionResponse", "name")
  end

  def test_shared_provider_keeps_independent_conversation_signatures
    transport = SequencedTransport.new(
      [{candidates: [{content: {parts: [{functionCall: {id: "tool-1", name: "lookup"}, thoughtSignature: "conversation-a"}]}, finishReason: "STOP"}]}],
      [{candidates: [{content: {parts: [{functionCall: {id: "tool-1", name: "lookup"}, thoughtSignature: "conversation-b"}]}, finishReason: "STOP"}]}],
      [{candidates: [{content: {parts: [{text: "done"}]}, finishReason: "STOP"}]}],
      [{candidates: [{content: {parts: [{text: "done"}]}, finishReason: "STOP"}]}]
    )
    provider = LittleGhost::Providers::Gemini.new(api_key: "secret", model: "gemini", transport:)
    conversation_a = call_tool(provider)
    conversation_b = call_tool(provider)

    follow_up_with(provider, conversation_a)
    follow_up_with(provider, conversation_b)

    assert_equal "conversation-a", function_call_part(transport, index: 2).fetch("thoughtSignature")
    assert_equal "conversation-b", function_call_part(transport, index: 3).fetch("thoughtSignature")
    assert_equal "lookup", function_response_parts(transport, index: 2).first.dig("functionResponse", "name")
    assert_equal "lookup", function_response_parts(transport, index: 3).first.dig("functionResponse", "name")
  end

  def test_tool_results_use_original_function_names_in_reverse_parallel_order
    transport = Transport.new
    provider = LittleGhost::Providers::Gemini.new(api_key: "secret", model: "gemini", transport:)
    call = LittleGhost::Message.new(role: :assistant, content: [
      LittleGhost::Content::ToolUse.new(id: "first-id", name: "lookup", input: {}),
      LittleGhost::Content::ToolUse.new(id: "second-id", name: "weather", input: {})
    ])
    results = LittleGhost::Message.new(role: :tool, content: [
      LittleGhost::Content::ToolResult.new(tool_use_id: "second-id", content: "sunny", status: :success),
      LittleGhost::Content::ToolResult.new(tool_use_id: "first-id", content: "found", status: :success)
    ])

    provider.stream(LittleGhost::ModelRequest.new(messages: [call, results])).to_a

    parts = JSON.parse(transport.arguments.fetch(:body)).fetch("contents").last.fetch("parts")
    assert_equal ["weather", "lookup"], parts.map { |part| part.dig("functionResponse", "name") }
    assert_equal ["second-id", "first-id"], parts.map { |part| part.dig("functionResponse", "id") }
  end

  def test_reused_tool_ids_keep_function_names_from_preceding_calls
    transport = Transport.new
    provider = LittleGhost::Providers::Gemini.new(api_key: "secret", model: "gemini", transport:)
    first = LittleGhost::Message.new(role: :assistant, content: [LittleGhost::Content::ToolUse.new(id: "same", name: "lookup", input: {})])
    first_result = LittleGhost::Message.new(role: :tool, content: [LittleGhost::Content::ToolResult.new(tool_use_id: "same", content: "found", status: :success)])
    second = LittleGhost::Message.new(role: :assistant, content: [LittleGhost::Content::ToolUse.new(id: "same", name: "weather", input: {})])
    second_result = LittleGhost::Message.new(role: :tool, content: [LittleGhost::Content::ToolResult.new(tool_use_id: "same", content: "sunny", status: :success)])

    provider.stream(LittleGhost::ModelRequest.new(messages: [first, first_result, second, second_result])).to_a

    parts = JSON.parse(transport.arguments.fetch(:body)).fetch("contents").flat_map { |message| message.fetch("parts") }
    assert_equal ["lookup", "weather"], parts.filter_map { |part| part.dig("functionResponse", "name") }
  end

  def test_orphaned_results_use_the_tool_id_without_inheriting_other_requests
    transport = SequencedTransport.new(
      [{candidates: [{content: {parts: [{functionCall: {id: "same", name: "lookup"}}]}, finishReason: "STOP"}]}],
      [{candidates: [{content: {parts: [{text: "done"}]}, finishReason: "STOP"}]}]
    )
    provider = LittleGhost::Providers::Gemini.new(api_key: "secret", model: "gemini", transport:)
    call_tool(provider)
    result = LittleGhost::Message.new(role: :tool, content: [LittleGhost::Content::ToolResult.new(tool_use_id: "same", content: "found", status: :success)])

    provider.stream(LittleGhost::ModelRequest.new(messages: [result])).to_a

    assert_equal "same", function_response_parts(transport, index: 1).first.dig("functionResponse", "name")
  end

  def test_vertex_uses_bearer_token_and_vertex_endpoint
    transport = Transport.new
    provider = LittleGhost::Providers::VertexAI.new(model: "gemini", project: "project", location: "us-central1",
      credential_resolver: ->(**) { "token" }, transport:)
    request = LittleGhost::ModelRequest.new(messages: [LittleGhost::Message.new(role: :user, content: "Hi")])

    provider.stream(request).to_a

    assert_equal "Bearer token", transport.arguments.dig(:headers, "authorization")
    assert_includes transport.arguments.fetch(:path), "projects/project/locations/us-central1"
    refute_includes transport.arguments.fetch(:path), "key="
  end

  private

  def call_tool(provider)
    request = LittleGhost::ModelRequest.new(messages: [LittleGhost::Message.new(role: :user, content: "Hi")])
    response = provider.stream(request).to_a.last.data.fetch(:response)
    response.message
  end

  def follow_up_with(provider, message)
    tool_uses = message.content.grep(LittleGhost::Content::ToolUse)
    results = tool_uses.map { |tool_use| LittleGhost::Content::ToolResult.new(tool_use_id: tool_use.id, content: "ok", status: :success) }
    request = LittleGhost::ModelRequest.new(messages: [
      LittleGhost::Message.new(role: :user, content: "Hi"),
      message,
      LittleGhost::Message.new(role: :tool, content: results)
    ])
    provider.stream(request).to_a
  end

  def function_response_parts(transport, index:)
    JSON.parse(transport.requests.fetch(index).fetch(:body)).fetch("contents")
      .flat_map { |message| message.fetch("parts") }.select { |part| part["functionResponse"] }
  end

  def function_call_part(transport, index:)
    function_call_parts(transport, index:).first
  end

  def function_call_parts(transport, index:)
    JSON.parse(transport.requests.fetch(index).fetch(:body)).fetch("contents")
      .flat_map { |message| message.fetch("parts") }.select { |part| part["functionCall"] }
  end
end
