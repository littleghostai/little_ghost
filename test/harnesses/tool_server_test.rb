# frozen_string_literal: true

require "test_helper"
require "socket"
require "tmpdir"

class HarnessToolServerTest < Minitest::Test
  class PolicyLookupTool < LittleGhost::Tool
    tool_name "policy_lookup"
    description "Looks up a policy."
    input_schema type: "object", properties: {topic: {type: "string"}}, required: ["topic"]

    def call(input)
      raise LittleGhost::ToolError, "No policy for #{input.fetch("topic")}" if input.fetch("topic") == "unknown"

      {topic: input.fetch("topic"), answer: "Refunds take five days."}
    end
  end

  class WaitingTool < LittleGhost::Tool
    tool_name "wait_for_cancellation"
    description "Waits until the run is cancelled."

    def call(_input)
      loop do
        context.check!
        sleep 0.01
      end
    end
  end

  def setup
    @directory = Dir.mktmpdir("lg", "/tmp")
    @socket_path = File.join(@directory, "tools.sock")
    @context = LittleGhost::RunContext.new
    @server = LittleGhost::Harnesses::ToolServer.new(
      tools: [PolicyLookupTool.new, WaitingTool.new],
      socket_path: @socket_path,
      context: @context,
      name: "support"
    ).start
  end

  def teardown
    @server.close
    FileUtils.remove_entry(@directory)
  end

  def test_initializes_lists_and_calls_tools
    initialized = rpc("initialize", protocolVersion: "2025-03-26", capabilities: {}, clientInfo: {name: "client", version: "1"})
    acknowledged = post({jsonrpc: "2.0", method: "notifications/initialized"})
    tools = rpc("tools/list").fetch("tools")
    called = rpc("tools/call", name: "policy_lookup", arguments: {topic: "refunds"})

    assert_equal "2025-03-26", initialized.fetch("protocolVersion")
    assert_equal "support", initialized.dig("serverInfo", "name")
    assert_equal 202, acknowledged.first
    assert_equal %w[policy_lookup wait_for_cancellation], tools.map { |tool| tool.fetch("name") }
    assert_equal ["topic"], tools.first.dig("inputSchema", "required")
    assert_equal false, called.fetch("isError")
    assert_equal({"topic" => "refunds", "answer" => "Refunds take five days."}, JSON.parse(called.dig("content", 0, "text")))
  end

  def test_tool_failures_and_invalid_input_are_tool_errors
    failed = rpc("tools/call", name: "policy_lookup", arguments: {topic: "unknown"})
    invalid = rpc("tools/call", name: "policy_lookup", arguments: {})

    assert failed.fetch("isError")
    assert_equal "No policy for unknown", failed.dig("content", 0, "text")
    assert invalid.fetch("isError")
  end

  def test_unknown_tools_methods_and_requests_are_protocol_errors
    unknown_tool = post({jsonrpc: "2.0", id: 1, method: "tools/call", params: {name: "missing"}})
    unknown_method = post({jsonrpc: "2.0", id: 2, method: "resources/list"})

    assert_equal(-32_602, JSON.parse(unknown_tool.last).dig("error", "code"))
    assert_equal(-32_601, JSON.parse(unknown_method.last).dig("error", "code"))
    assert_equal 400, post("not json").first
    assert_equal 405, request("GET /mcp HTTP/1.1\r\n\r\n").first
    assert_equal 404, request("POST /other HTTP/1.1\r\ncontent-length: 2\r\n\r\n{}").first
  end

  def test_cancelling_the_run_stops_a_call_in_progress
    response = Thread.new { post({jsonrpc: "2.0", id: 1, method: "tools/call", params: {name: "wait_for_cancellation"}}) }
    sleep 0.1
    @context.cancellation_token.cancel

    assert_equal(-32_000, JSON.parse(response.value.last).dig("error", "code"))
  end

  def test_close_removes_the_socket
    assert File.socket?(@socket_path)
    assert_equal 0o600, File.stat(@socket_path).mode & 0o777

    @server.close

    refute File.exist?(@socket_path)
  end

  private

  def rpc(method, **params)
    status, body = post({jsonrpc: "2.0", id: 1, method:, params:})
    assert_equal 200, status
    JSON.parse(body).fetch("result")
  end

  def post(message)
    body = message.is_a?(String) ? message : JSON.generate(message)
    request("POST /mcp HTTP/1.1\r\ncontent-type: application/json\r\ncontent-length: #{body.bytesize}\r\n\r\n#{body}")
  end

  def request(raw)
    UNIXSocket.open(@socket_path) do |socket|
      socket.write(raw)
      response = socket.read
      head, body = response.split("\r\n\r\n", 2)
      [Integer(head[/\AHTTP\/1\.1 (\d+)/, 1]), body]
    end
  end
end
