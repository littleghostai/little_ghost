# frozen_string_literal: true

require "test_helper"
require "little_ghost/mcp"
require "base64"

class MCPTest < Minitest::Test
  class Transport
    attr_reader :connects, :notifications, :requests

    def initialize(tool_pages: nil, results: nil, request_error: nil)
      @tool_pages = tool_pages || [[{
        "name" => "search",
        "description" => "Search",
        "inputSchema" => {"type" => "object"}
      }]]
      configured_results = results || {"content" => [{"type" => "text", "text" => "found"}]}
      @results = configured_results.is_a?(Array) ? configured_results : [configured_results]
      @request_error = request_error
      @connects = []
      @notifications = []
      @requests = []
      @connected = false
      @closed = false
    end

    def connect(client_info: nil, protocol_version: nil, capabilities: {}, mode: :legacy)
      connects << {client_info:, protocol_version:, capabilities:, mode:}
      @connected = true
      {
        "protocolVersion" => protocol_version || "2025-11-25",
        "capabilities" => {},
        "serverInfo" => {"name" => "test", "version" => "1.0"}
      }
    end

    def connected? = @connected
    def closed? = @closed

    def send_request(request:)
      yield if block_given?
      requests << request
      raise @request_error if @request_error

      result = case request[:method]
      when "tools/list"
        page = request.dig(:params, :cursor).to_i
        value = {"tools" => @tool_pages.fetch(page)}
        value["nextCursor"] = (page + 1).to_s if page + 1 < @tool_pages.length
        value
      when "tools/call"
        (@results.length > 1) ? @results.shift : @results.first
      else
        {}
      end
      {"jsonrpc" => "2.0", "id" => request.fetch(:id), "result" => result}
    end

    def send_notification(notification:)
      notifications << notification
    end

    def close
      @closed = true
      @connected = false
    end
  end

  class FakeRun
    attr_reader :context, :resources

    def initialize(context = LittleGhost::RunContext.new)
      @context = context
      @resources = []
    end

    def register(resource)
      resources << resource
      resource
    end
  end

  def test_factory_returns_the_official_client_and_connect_options_are_forwarded
    transport = Transport.new
    binding = LittleGhost::Tool::Binding.new(workspace: Object.new)
    seen = nil
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      client(protocol_version: "2025-06-18", capabilities: {elicitation: {}}) do |current|
        seen = current
        ::MCP::Client.new(transport:)
      end
    end

    tool = toolset.tools(binding).fetch(0)

    assert_same binding, seen
    assert_instance_of ::MCP::Client::Tool, tool.mcp_tool
    assert_equal "search", tool.tool_name
    assert_equal "2025-06-18", transport.connects.first.fetch(:protocol_version)
    assert_equal({elicitation: {}}, transport.connects.first.fetch(:capabilities))
  end

  def test_sdk_defaults_negotiate_every_supported_protocol_version
    ::MCP::Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS.each do |version|
      transport = Transport.new
      tools = client_toolset(transport, protocol_version: version).tools(LittleGhost::Tool::Binding.new)

      assert_equal ["search"], tools.map(&:tool_name)
      assert_equal version, transport.connects.first.fetch(:protocol_version)
    end

    transport = Transport.new
    client_toolset(transport).tools(LittleGhost::Tool::Binding.new)
    assert_equal :auto, transport.connects.first.fetch(:mode)
  end

  def test_wrapper_preserves_legacy_connect_for_keyrest_only_transports
    transport = Transport.new
    received = []
    transport.define_singleton_method(:connect) do |**values|
      received << values
      @connected = true
    end

    client_toolset(transport).tools(LittleGhost::Tool::Binding.new)

    refute received.first.key?(:mode)

    legacy = Transport.new
    legacy.define_singleton_method(:connect) { |**_values| @connected = true }
    pinned = client_toolset(legacy, mode: :auto)
    assert_raises(LittleGhost::ConfigurationError) do
      pinned.tools(LittleGhost::Tool::Binding.new)
    end
  end

  def test_factory_can_configure_sdk_handlers_before_little_ghost_connects
    transport = Transport.new
    sequence = []
    transport.define_singleton_method(:connect) do |**values|
      sequence << :connect
      super(**values)
    end
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      client(capabilities: {elicitation: {}}) do |_binding|
        ::MCP::Client.new(transport:).tap do |official_client|
          official_client.on_elicitation { |_request| nil }
          sequence << :configure
        end
      end
    end

    toolset.tools(LittleGhost::Tool::Binding.new)

    assert_equal %i[configure connect], sequence
  end

  def test_factory_requires_a_fresh_unconnected_official_client
    missing = Class.new(LittleGhost::MCP::Toolset)
    assert_raises(LittleGhost::ConfigurationError) do
      missing.tools(LittleGhost::Tool::Binding.new)
    end

    wrong = Class.new(LittleGhost::MCP::Toolset) { client { |_binding| Object.new } }
    assert_raises(LittleGhost::ConfigurationError) do
      wrong.tools(LittleGhost::Tool::Binding.new)
    end

    transport = Transport.new
    official_client = ::MCP::Client.new(transport:)
    official_client.connect
    connected = Class.new(LittleGhost::MCP::Toolset) { client { |_binding| official_client } }
    error = assert_raises(LittleGhost::ConfigurationError) do
      connected.tools(LittleGhost::Tool::Binding.new)
    end
    assert_match(/unconnected/, error.message)
    assert transport.closed?
  end

  def test_client_options_require_a_factory_block
    error = assert_raises(ArgumentError) do
      Class.new(LittleGhost::MCP::Toolset) { client(capabilities: {}) }
    end

    assert_match(/factory block/, error.message)
  end

  def test_tool_generation_uses_sdk_values_and_skips_little_ghost_subset_validation
    tools = [[{
      "name" => "count.items",
      "description" => "Count items",
      "inputSchema" => {
        "type" => "object",
        "properties" => {"count" => {"const" => 1}},
        "required" => ["count"]
      },
      "outputSchema" => {"type" => "integer"},
      "annotations" => {"readOnlyHint" => true}
    }]]
    transport = Transport.new(tool_pages: tools)
    tool = client_toolset(transport).tools(LittleGhost::Tool::Binding.new).fetch(0)
    result = tool.new.execute({"count" => 2})

    assert_equal "count_items", tool.tool_name
    assert_equal({"const" => 1}, tool.input_schema.dig("properties", "count"))
    assert_equal true, tool.mcp_tool.annotations.fetch("readOnlyHint")
    assert result.success?
    assert_equal 2, transport.requests.last.dig(:params, :arguments, "count")
  end

  def test_blank_description_uses_bundled_fallback_with_a_non_agent_binding
    transport = Transport.new(tool_pages: [[{
      "name" => "search",
      "inputSchema" => {"type" => "object"}
    }]])
    application_agent = Class.new.new
    binding = LittleGhost::Tool::Binding.new(agent: application_agent)

    tool = client_toolset(transport).tools(binding).fetch(0)

    assert_equal "MCP Tool from MCP Toolset", tool.description
  end

  def test_blank_server_error_uses_bundled_fallback_with_a_non_agent_binding
    failure = ::MCP::Client::ServerError.new("", code: -32_000)
    transport = Transport.new(request_error: failure)
    application_agent = Class.new.new
    binding = LittleGhost::Tool::Binding.new(agent: application_agent)

    error = assert_raises(LittleGhost::ToolError) do
      client_toolset(transport).tools(binding)
    end

    assert_equal "MCP request failed", error.message
  end

  def test_map_tool_can_omit_and_rename_without_changing_dispatch
    transport = Transport.new(tool_pages: [[
      {"name" => "search", "description" => "Search", "inputSchema" => {"type" => "object"}},
      {"name" => "delete", "description" => "Delete", "inputSchema" => {"type" => "object"}}
    ]])
    observed = []
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      client { |_binding| ::MCP::Client.new(transport:) }
      map_tool do |tool_class, mcp_tool:, binding:|
        observed << [mcp_tool, binding]
        next if mcp_tool.name == "delete"

        tool_class.tool_name "knowledge_search"
        tool_class
      end
    end
    binding = LittleGhost::Tool::Binding.new

    tool = toolset.tools(binding).fetch(0)
    result = tool.new.execute({})

    assert_equal "found", result.value
    assert_equal "knowledge_search", tool.tool_name
    assert_equal %w[search delete], observed.map { |mcp_tool, _| mcp_tool.name }
    assert observed.all? { |_, current| current.equal?(binding) }
    assert_equal "search", transport.requests.last.dig(:params, :name)
  end

  def test_map_tool_rejects_collisions_after_customization
    transport = Transport.new(tool_pages: [[
      {"name" => "first", "inputSchema" => {"type" => "object"}},
      {"name" => "second", "inputSchema" => {"type" => "object"}}
    ]])
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      client { |_binding| ::MCP::Client.new(transport:) }
      map_tool do |tool_class, **|
        tool_class.tool_name "duplicate"
        tool_class
      end
    end

    assert_raises(LittleGhost::ConfigurationError) do
      toolset.tools(LittleGhost::Tool::Binding.new)
    end
    assert transport.closed?
  end

  def test_map_result_receives_the_default_value_and_sdk_native_values
    transport = Transport.new(results: {
      "content" => [{"type" => "text", "text" => "summary"}],
      "structuredContent" => {"items" => [1, 2]},
      "_meta" => {"download_id" => "record:1"}
    })
    observed = nil
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      client { |_binding| ::MCP::Client.new(transport:) }
      map_result do |value, result:, mcp_tool:, arguments:, binding:|
        observed = [value, result, mcp_tool, arguments, binding]
        LittleGhost::Tool::Result.new(
          value: {"mapped" => value.fetch("items")},
          artifacts: [LittleGhost::Artifact.deferred(
            reference: result.fetch("_meta").fetch("download_id"),
            media_type: "application/octet-stream"
          )]
        )
      end
    end
    binding = LittleGhost::Tool::Binding.new

    execution = toolset.tools(binding).first.new(binding:).execute({"query" => "ruby"})

    assert_equal({"mapped" => [1, 2]}, execution.value)
    assert_equal "record:1", execution.artifacts.first.reference
    value, result, mcp_tool, arguments, current_binding = observed
    assert_equal({"items" => [1, 2]}, value)
    assert_equal "record:1", result.dig("_meta", "download_id")
    assert_instance_of ::MCP::Client::Tool, mcp_tool
    assert_equal({"query" => "ruby"}, arguments)
    assert_same binding, current_binding
  end

  def test_map_result_tool_errors_keep_their_model_safe_message
    transport = Transport.new
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      client { |_binding| ::MCP::Client.new(transport:) }
      map_result { |_value, **| raise LittleGhost::ToolError, "safe mapping failure" }
    end

    execution = toolset.tools(LittleGhost::Tool::Binding.new).first.new.execute({})

    assert execution.error?
    assert_equal "safe mapping failure", execution.content
  end

  def test_structured_content_preserves_false_and_explicit_null
    false_result = Transport.new(results: {"structuredContent" => false})
    execution = client_toolset(false_result).tools(LittleGhost::Tool::Binding.new).first.new.execute({})
    assert_equal false, execution.value

    null_result = Transport.new(results: {"structuredContent" => nil})
    execution = client_toolset(null_result).tools(LittleGhost::Tool::Binding.new).first.new.execute({})
    assert execution.success?
    assert_nil execution.value
  end

  def test_images_become_artifacts_without_retaining_base64_in_the_value
    encoded = Base64.strict_encode64("image-bytes")
    transport = Transport.new(results: {
      "content" => [{"type" => "image", "data" => encoded, "mimeType" => "image/png", "name" => "chart.png"}]
    })

    result = client_toolset(transport).tools(LittleGhost::Tool::Binding.new).first.new.execute({})

    assert_equal({"images" => [{"mediaType" => "image/png", "name" => "chart.png", "bytes" => 11}]}, result.value)
    refute_includes result.value.inspect, encoded
    assert_equal "image-bytes", result.artifacts.fetch(0).data
  end

  def test_invalid_image_data_and_result_shapes_fail_inside_the_tool_boundary
    invalid_image = Transport.new(results: {
      "content" => [{"type" => "image", "data" => "not base64", "mimeType" => "image/png"}]
    })
    result = client_toolset(invalid_image).tools(LittleGhost::Tool::Binding.new).first.new.execute({})
    assert result.error?
    assert_equal "Tool failed (LittleGhost::ProtocolError)", result.content

    invalid_content = Transport.new(results: {"content" => {}})
    result = client_toolset(invalid_content).tools(LittleGhost::Tool::Binding.new).first.new.execute({})
    assert result.error?
    assert_equal "Tool failed (LittleGhost::ProtocolError)", result.content
  end

  def test_server_tool_errors_remain_safe_tool_errors
    transport = Transport.new(results: {
      "content" => [{"type" => "text", "text" => "safe failure"}],
      "isError" => true
    })

    result = client_toolset(transport).tools(LittleGhost::Tool::Binding.new).first.new.execute({})

    assert result.error?
    assert_equal "safe failure", result.content
  end

  def test_loads_all_pages_and_normalizes_long_names
    long_name = "search." + ("a" * 100)
    transport = Transport.new(tool_pages: [
      [{"name" => "first", "inputSchema" => {"type" => "object"}}],
      [{"name" => long_name, "inputSchema" => {"type" => "object"}}]
    ])

    names = client_toolset(transport).tools(LittleGhost::Tool::Binding.new).map(&:tool_name)

    assert_equal "first", names.first
    assert_equal 64, names.last.length
    assert_match(/_[a-f0-9]{12}\z/, names.last)
  end

  def test_discovery_bounds_tools_before_generating_classes
    tools = Array.new(1_001) do |index|
      {"name" => "tool_#{index}", "inputSchema" => {"type" => "object"}}
    end
    transport = Transport.new(tool_pages: [tools])

    error = assert_raises(LittleGhost::ProtocolError) do
      client_toolset(transport).tools(LittleGhost::Tool::Binding.new)
    end

    assert_match(/1000-tool limit/, error.message)
    assert transport.closed?
  end

  def test_discovery_bounds_empty_pagination
    transport = Transport.new(tool_pages: Array.new(101) { [] })

    error = assert_raises(LittleGhost::ProtocolError) do
      client_toolset(transport).tools(LittleGhost::Tool::Binding.new)
    end

    assert_match(/100-page limit/, error.message)
    assert_equal 100, transport.requests.length
  end

  def test_malformed_catalog_responses_are_protocol_errors
    responses = [
      "invalid",
      {"jsonrpc" => "2.0", "id" => "1"},
      {"jsonrpc" => "2.0", "id" => "1", "result" => {"tools" => ["invalid"]}},
      {"jsonrpc" => "2.0", "id" => "1", "error" => nil},
      {"jsonrpc" => "2.0", "id" => "1", "error" => {"code" => "bad", "message" => nil}}
    ]

    responses.each do |response|
      transport = transport_with_catalog_response(response)
      assert_raises(LittleGhost::ProtocolError) do
        client_toolset(transport).tools(LittleGhost::Tool::Binding.new)
      end
      assert transport.closed?
    end

    transport = transport_with_catalog_response(responses.first)
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      client { |_binding| ::MCP::Client.new(transport:) }
      optional true
    end
    assert_empty toolset.tools(LittleGhost::Tool::Binding.new)
  end

  def test_deep_input_schema_is_rejected_before_sdk_scanning
    schema = {"type" => "object"}
    129.times { schema = {"properties" => {"child" => schema}} }
    transport = Transport.new(tool_pages: [[{
      "name" => "deep",
      "inputSchema" => schema
    }]])
    run = FakeRun.new

    error = assert_raises(LittleGhost::ProtocolError) do
      client_toolset(transport).tools(LittleGhost::Tool::Binding.new(run:))
    end

    assert_match(/depth limit/, error.message)
    assert transport.closed?
  end

  def test_schema_node_budget_is_cumulative_across_pages
    maximum = LittleGhost::MCP::CatalogValidatingTransport::MAX_SCHEMA_NODES
    LittleGhost::MCP::CatalogValidatingTransport.send(:remove_const, :MAX_SCHEMA_NODES)
    LittleGhost::MCP::CatalogValidatingTransport.const_set(:MAX_SCHEMA_NODES, 5)
    schema = {"properties" => {"child" => {}}}
    transport = Transport.new(tool_pages: [
      [{"name" => "first", "inputSchema" => schema}],
      [{"name" => "second", "inputSchema" => schema}]
    ])

    error = assert_raises(LittleGhost::ProtocolError) do
      client_toolset(transport).tools(LittleGhost::Tool::Binding.new)
    end

    assert_match(/node limit/, error.message)
  ensure
    LittleGhost::MCP::CatalogValidatingTransport.send(:remove_const, :MAX_SCHEMA_NODES)
    LittleGhost::MCP::CatalogValidatingTransport.const_set(:MAX_SCHEMA_NODES, maximum)
  end

  def test_transport_schema_stack_errors_wake_discovery_and_close
    transport = Transport.new
    original = transport.method(:send_request)
    transport.define_singleton_method(:send_request) do |request:, &sent|
      raise SystemStackError if request[:method] == "tools/list"

      original.call(request:, &sent)
    end
    run = FakeRun.new

    error = assert_raises(LittleGhost::ProtocolError) do
      client_toolset(transport).tools(LittleGhost::Tool::Binding.new(run:))
    end

    assert_match(/SDK nesting limit/, error.message)
    assert transport.closed?
  end

  def test_optional_toolset_reports_expected_discovery_failures_and_closes
    error = ::MCP::Client::RequestHandlerError.new("offline", {}, error_type: :network_error)
    transport = Transport.new(request_error: error)
    observed = []
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      client { |_binding| ::MCP::Client.new(transport:) }
      optional true
      on_error { |failure, binding:| observed << [failure, binding] }
    end
    binding = LittleGhost::Tool::Binding.new

    assert_empty toolset.tools(binding)

    assert_instance_of LittleGhost::ProviderError, observed.first.first
    assert_same binding, observed.first.last
    assert transport.closed?
  end

  def test_optional_toolset_does_not_consume_application_callback_failures
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      client { |_binding| raise LittleGhost::ToolError, "caller policy failed" }
      optional true
    end

    error = assert_raises(LittleGhost::ToolError) do
      toolset.tools(LittleGhost::Tool::Binding.new)
    end
    assert_equal "caller policy failed", error.message
  end

  def test_run_owns_and_idempotently_closes_the_official_transport
    transport = Transport.new
    run = FakeRun.new
    binding = LittleGhost::Tool::Binding.new(run:)

    client_toolset(transport).tools(binding)

    assert_equal 1, run.resources.length
    run.resources.first.close
    run.resources.first.close
    assert transport.closed?
  end

  def test_discovery_failure_closes_the_transport
    transport = Transport.new(tool_pages: [[{"name" => nil, "inputSchema" => {"type" => "object"}}]])

    assert_raises(LittleGhost::ProtocolError) do
      client_toolset(transport).tools(LittleGhost::Tool::Binding.new)
    end
    assert transport.closed?
  end

  def test_cancellation_stops_before_client_construction
    token = LittleGhost::Support::CancellationToken.new.cancel
    run = FakeRun.new(LittleGhost::RunContext.new(cancellation_token: token))
    constructed = false
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      client do |_binding|
        constructed = true
        ::MCP::Client.new(transport: Transport.new)
      end
    end

    assert_raises(LittleGhost::CancelledError) do
      toolset.tools(LittleGhost::Tool::Binding.new(run:))
    end
    refute constructed
  end

  def test_successful_requests_wake_the_cancellation_watcher_immediately
    interval = LittleGhost::MCP::Adapter::CONTEXT_POLL_INTERVAL
    LittleGhost::MCP::Adapter.send(:remove_const, :CONTEXT_POLL_INTERVAL)
    LittleGhost::MCP::Adapter.const_set(:CONTEXT_POLL_INTERVAL, 1)
    run = FakeRun.new

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    client_toolset(Transport.new).tools(LittleGhost::Tool::Binding.new(run:))
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 0.2
  ensure
    LittleGhost::MCP::Adapter.send(:remove_const, :CONTEXT_POLL_INTERVAL)
    LittleGhost::MCP::Adapter.const_set(:CONTEXT_POLL_INTERVAL, interval)
  end

  def test_stdio_session_is_poisoned_after_sdk_cancellation
    delegate = Transport.new
    transport = stdio_transport(delegate)
    session = LittleGhost::MCP::Session.new(::MCP::Client.new(transport:))
    cancellation = ::MCP::CancelledError.new(request_id: "request-1", reason: "cancelled")

    assert_raises(::MCP::CancelledError) do
      session.request { raise cancellation }
    end
    assert transport.closed?
    error = assert_raises(LittleGhost::ProviderError) do
      session.request { flunk "poisoned session should not dispatch" }
    end
    assert_match(/unavailable after cancellation/, error.message)
  end

  def test_stdio_calls_are_serialized
    delegate = Transport.new(tool_pages: [[
      {"name" => "first", "inputSchema" => {"type" => "object"}},
      {"name" => "second", "inputSchema" => {"type" => "object"}}
    ]])
    active = 0
    maximum = 0
    mutex = Mutex.new
    original = delegate.method(:send_request)
    delegate.define_singleton_method(:send_request) do |request:, &sent|
      if request[:method] == "tools/call"
        mutex.synchronize do
          active += 1
          maximum = [maximum, active].max
        end
        sleep 0.03
      end
      original.call(request:, &sent)
    ensure
      mutex.synchronize { active -= 1 } if request[:method] == "tools/call"
    end
    transport = stdio_transport(delegate)

    tools = client_toolset(transport).tools(LittleGhost::Tool::Binding.new).map(&:new)
    tools.map { |tool| Thread.new { tool.execute({}) } }.each(&:value)

    assert_equal 1, maximum
  end

  private

  def client_toolset(transport, **connect_options)
    Class.new(LittleGhost::MCP::Toolset) do
      client(**connect_options) { |_binding| ::MCP::Client.new(transport:) }
    end
  end

  def stdio_transport(delegate)
    ::MCP::Client::Stdio.allocate.tap do |transport|
      %i[connect connected? closed? send_request send_notification close].each do |name|
        transport.define_singleton_method(name) { |**values, &block| delegate.public_send(name, **values, &block) }
      end
    end
  end

  def transport_with_catalog_response(response)
    Transport.new.tap do |transport|
      original = transport.method(:send_request)
      transport.define_singleton_method(:send_request) do |request:, &sent|
        if request[:method] == "tools/list"
          sent&.call
          requests << request
          response
        else
          original.call(request:, &sent)
        end
      end
    end
  end
end
