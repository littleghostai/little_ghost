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

    tool_use = call_tool(provider)
    follow_up_with(provider, tool_use)

    assert_equal "sig-abc", function_call_part(transport, index: 1).fetch("thoughtSignature")
  end

  def test_omits_thought_signature_when_the_response_never_sent_one
    unsigned_call = {functionCall: {id: "tool-1", name: "lookup", args: {id: 1}}}
    transport = SequencedTransport.new(
      [{modelVersion: "gemini", candidates: [{content: {parts: [unsigned_call]}, finishReason: "STOP"}]}],
      [{candidates: [{content: {parts: [{text: "done"}]}, finishReason: "STOP"}]}]
    )
    provider = LittleGhost::Providers::Gemini.new(api_key: "secret", model: "gemini", transport:)

    tool_use = call_tool(provider)
    follow_up_with(provider, tool_use)

    refute function_call_part(transport, index: 1).key?("thoughtSignature")
  end

  def test_replays_a_thought_signature_for_a_function_call_missing_an_id
    signed_call = {functionCall: {name: "lookup", args: {id: 1}}, thoughtSignature: "sig-noid"}
    transport = SequencedTransport.new(
      [{modelVersion: "gemini", candidates: [{content: {parts: [signed_call]}, finishReason: "STOP"}]}],
      [{candidates: [{content: {parts: [{text: "done"}]}, finishReason: "STOP"}]}]
    )
    provider = LittleGhost::Providers::Gemini.new(api_key: "secret", model: "gemini", transport:)

    tool_use = call_tool(provider)
    assert_equal "call-0", tool_use.id
    follow_up_with(provider, tool_use)

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
    tool_uses = response.message.content.grep(LittleGhost::Content::ToolUse)
    follow_up_with(provider, *tool_uses)

    sent_parts = JSON.parse(transport.requests.last.fetch(:body)).fetch("contents")
      .flat_map { |message| message.fetch("parts") }.select { |part| part["functionCall"] }
    assert_equal "sig-1", sent_parts.find { |part| part.dig("functionCall", "id") == "tool-1" }.fetch("thoughtSignature")
    refute sent_parts.find { |part| part.dig("functionCall", "id") == "tool-2" }.key?("thoughtSignature")
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
    response.message.content.grep(LittleGhost::Content::ToolUse).first
  end

  def follow_up_with(provider, *tool_uses)
    results = tool_uses.map { |tool_use| LittleGhost::Content::ToolResult.new(tool_use_id: tool_use.id, content: "ok", status: :success) }
    request = LittleGhost::ModelRequest.new(messages: [
      LittleGhost::Message.new(role: :user, content: "Hi"),
      LittleGhost::Message.new(role: :assistant, content: tool_uses),
      LittleGhost::Message.new(role: :tool, content: results)
    ])
    provider.stream(request).to_a
  end

  def function_call_part(transport, index:)
    JSON.parse(transport.requests.fetch(index).fetch(:body)).fetch("contents")
      .flat_map { |message| message.fetch("parts") }.find { |part| part["functionCall"] }
  end
end
