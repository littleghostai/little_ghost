# frozen_string_literal: true

require "test_helper"

class AnthropicTest < Minitest::Test
  class Transport
    attr_reader :arguments

    def initialize(frames)
      @frames = frames
    end

    def stream(**arguments)
      @arguments = arguments
      @frames.each { |frame| yield "data: #{JSON.generate(frame)}\n\n" }
    end
  end

  def test_streams_text_tools_usage_and_builds_messages_request
    frames = [
      {type: "message_start", message: {id: "message-1", model: "claude", usage: {input_tokens: 5}}},
      {type: "content_block_start", index: 0, content_block: {type: "text"}},
      {type: "content_block_delta", index: 0, delta: {type: "text_delta", text: "Hello"}},
      {type: "content_block_start", index: 1, content_block: {type: "tool_use", id: "tool-1", name: "lookup"}},
      {type: "content_block_delta", index: 1, delta: {type: "input_json_delta", partial_json: "{\"id\":1}"}},
      {type: "content_block_stop", index: 1},
      {type: "message_delta", delta: {stop_reason: "tool_use"}, usage: {output_tokens: 3}},
      {type: "message_stop"}
    ]
    transport = Transport.new(frames)
    provider = LittleGhost::Providers::Anthropic.new(api_key: "secret", model: "claude", transport:)
    request = LittleGhost::ModelRequest.new(messages: [LittleGhost::Message.new(role: :user, content: "Hi")])

    events = provider.stream(request).to_a

    assert_equal %i[message_start text_delta tool_call_start tool_call_delta tool_call_stop usage message_stop], events.map(&:type)
    assert_equal({"id" => 1}, events.last.data[:response].message.content.last.input)
    body = JSON.parse(transport.arguments.fetch(:body))
    assert_equal "claude", body.fetch("model")
    assert_equal "secret", transport.arguments.dig(:headers, "x-api-key")
  end

  def test_sends_tool_history_as_text_only_when_the_request_declares_no_tools
    history = [
      LittleGhost::Message.new(role: :user, content: "Where is order A1?"),
      LittleGhost::Message.new(role: :assistant, content: LittleGhost::Content::ToolUse.new(id: "call-1", name: "lookup_order", input: {order_id: "A1"})),
      LittleGhost::Message.new(role: :tool, content: LittleGhost::Content::ToolResult.new(tool_use_id: "call-1", content: "Lookup timed out", status: :error))
    ]
    lookup = {name: "lookup_order", description: "Look up an order", input_schema: {type: "object"}}
    without_tools = Transport.new(completed_frames)
    with_tools = Transport.new(completed_frames)

    LittleGhost::Providers::Anthropic.new(api_key: "secret", model: "claude", transport: without_tools)
      .stream(LittleGhost::ModelRequest.new(messages: history)).to_a
    LittleGhost::Providers::Anthropic.new(api_key: "secret", model: "claude", transport: with_tools)
      .stream(LittleGhost::ModelRequest.new(messages: history, tools: [lookup])).to_a

    text_body = JSON.parse(without_tools.arguments.fetch(:body))
    refute text_body.key?("tools")
    assert_equal [%w[text], %w[text], %w[text]], text_body.fetch("messages").map { |message| message.fetch("content").map { |block| block.fetch("type") } }
    call = text_body.dig("messages", 1, "content", 0, "text")
    result = text_body.dig("messages", 2, "content", 0, "text")
    assert_includes call, "lookup_order"
    assert_includes call, JSON.generate({"order_id" => "A1"})
    assert_includes result, "Lookup timed out"
    native_body = JSON.parse(with_tools.arguments.fetch(:body))
    assert_equal "tool_use", native_body.dig("messages", 1, "content", 0, "type")
    assert_equal "tool_result", native_body.dig("messages", 2, "content", 0, "type")
  end

  private

  def completed_frames
    [
      {type: "message_start", message: {id: "message-1", model: "claude", usage: {input_tokens: 5}}},
      {type: "message_delta", delta: {stop_reason: "end_turn"}, usage: {output_tokens: 1}},
      {type: "message_stop"}
    ]
  end
end
