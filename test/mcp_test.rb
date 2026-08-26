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
        tools = @tool_pages.fetch(page)
        value = {"tools" => tools}
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

  def test_toolset_uses_the_official_client_and_preserves_machine_values
    transport = Transport.new(results: {
      "content" => [{"type" => "text", "text" => "summary"}],
      "structuredContent" => {"items" => [1, 2]}
    })
    toolset = http_toolset

    with_http_transport(transport) do
      tool_class = toolset.tools(LittleGhost::Tool::Binding.new).first
      result = tool_class.new.execute({"query" => "ruby"})

      assert_operator tool_class, :<, LittleGhost::Tool
      assert_equal "search", tool_class.tool_name
      assert_equal({"items" => [1, 2]}, result.value)
      assert_equal "search", transport.requests.last.dig(:params, :name)
    end

    assert_equal :auto, transport.connects.fetch(0).fetch(:mode)
    assert_equal "little_ghost", transport.connects.fetch(0).dig(:client_info, :name)
    refute LittleGhost::MCP.const_defined?(:Client, false)
  end

  def test_toolset_preserves_raw_definition_metadata_omitted_by_sdk_tool_values
    tools = [[{
      "name" => "search",
      "title" => "Knowledge search",
      "description" => "Search",
      "inputSchema" => {"type" => "object"},
      "annotations" => {"readOnlyHint" => true},
      "_meta" => {"vendor.example/routing" => "public"},
      "vendorField" => {"enabled" => true}
    }]]

    with_http_transport(Transport.new(tool_pages: tools)) do
      definition = http_toolset.tools(LittleGhost::Tool::Binding.new).first.mcp_definition

      assert_equal "Knowledge search", definition.title
      assert_equal true, definition.annotations.fetch("readOnlyHint")
      assert_equal "public", definition.metadata.fetch("vendor.example/routing")
      assert_equal true, definition.dig("vendorField", "enabled")
      assert definition.raw.frozen?
    end
  end

  def test_toolset_resolves_http_options_for_the_current_binding
    binding = LittleGhost::Tool::Binding.new(workspace: Object.new)
    seen = nil
    received_options = nil
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      connection do |current|
        seen = current
        {
          url: "https://mcp.example/rpc",
          headers: {Authorization: "Bearer token"},
          timeout: 12,
          max_response_bytes: 4096,
          protocol_version: "2025-06-18",
          capabilities: {elicitation: {}}
        }
      end
    end

    with_http_transport(Transport.new, options: ->(values) { received_options = values }) do
      assert_equal ["search"], toolset.tools(binding).map(&:tool_name)
    end

    assert_same binding, seen
    assert_equal "https://mcp.example/rpc", received_options.fetch(:url)
    assert_equal({"Authorization" => "Bearer token"}, received_options.fetch(:headers))
    assert_equal 4096, received_options.fetch(:max_message_bytes)
  end

  def test_toolset_accepts_every_protocol_version_supported_by_the_sdk
    ::MCP::Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS.each do |version|
      transport = Transport.new
      toolset = Class.new(LittleGhost::MCP::Toolset) do
        connection url: "https://mcp.example/rpc", protocol_version: version
      end

      with_http_transport(transport) do
        assert_equal ["search"], toolset.tools(LittleGhost::Tool::Binding.new).map(&:tool_name)
      end

      assert_equal version, transport.connects.first.fetch(:protocol_version)
    end
  end

  def test_toolset_builds_stdio_without_loading_http_configuration
    transport = Transport.new
    received = nil
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      connection command: "bundle", args: ["exec", "mcp-server"], env: {"TENANT" => "public"},
        timeout: 15, max_response_bytes: 8192
    end

    constructor = lambda do |**values|
      received = values
      transport
    end
    ::MCP::Client::Stdio.stub(:new, constructor) do
      assert_equal ["search"], toolset.tools(LittleGhost::Tool::Binding.new).map(&:tool_name)
    end

    assert_equal "bundle", received.fetch(:command)
    assert_equal ["exec", "mcp-server"], received.fetch(:args)
    assert_equal({"TENANT" => "public"}, received.fetch(:env))
    assert_equal 15.0, received.fetch(:read_timeout)
    assert_equal 8192, received.fetch(:max_line_bytes)
  end

  def test_configure_client_runs_before_connect
    transport = Transport.new
    sequence = []
    transport.define_singleton_method(:connect) do |**values|
      sequence << :connect
      super(**values)
    end
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      connection url: "https://mcp.example/rpc", capabilities: {elicitation: {}}
      configure_client do |client, binding:|
        sequence << :configure
        raise "missing binding" unless binding.is_a?(LittleGhost::Tool::Binding)
        raise "wrong client" unless client.is_a?(::MCP::Client)
      end
    end

    with_http_transport(transport) do
      toolset.tools(LittleGhost::Tool::Binding.new)
    end

    assert_equal %i[configure connect], sequence
    assert_equal({elicitation: {}}, transport.connects.first.fetch(:capabilities))
  end

  def test_connection_block_can_return_a_run_scoped_official_transport
    transport = Transport.new(tool_pages: [[{
      "name" => "search",
      "title" => "Search title",
      "inputSchema" => {"type" => "object"},
      "_meta" => {"vendor.example/value" => true}
    }]])
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      connection { |_binding| transport }
    end

    tool = toolset.tools(LittleGhost::Tool::Binding.new).first

    assert_equal "search", tool.tool_name
    assert_equal "Search title", tool.mcp_definition.title
    assert_equal true, tool.mcp_definition.metadata.fetch("vendor.example/value")
    tool.new.close
    assert transport.closed?
  end

  def test_static_transport_and_connection_block_client_are_rejected
    transport = Transport.new

    error = assert_raises(ArgumentError) do
      Class.new(LittleGhost::MCP::Toolset) { connection transport }
    end
    assert_match(/connection block/, error.message)

    client = ::MCP::Client.new(transport:)
    toolset = Class.new(LittleGhost::MCP::Toolset) { connection { |_binding| client } }
    assert_raises(LittleGhost::ConfigurationError) do
      toolset.tools(LittleGhost::Tool::Binding.new)
    end
  end

  def test_map_tool_can_omit_and_rename_without_changing_dispatch
    transport = Transport.new(tool_pages: [[
      {"name" => "search", "description" => "Search", "inputSchema" => {"type" => "object"}},
      {"name" => "delete", "description" => "Delete", "inputSchema" => {"type" => "object"}}
    ]])
    definitions = []
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      connection url: "https://mcp.example/rpc"
      map_tool do |tool_class, definition:, binding:|
        definitions << [definition, binding]
        next if definition.source_name == "delete"

        tool_class.tool_name "knowledge_search"
        tool_class
      end
    end
    binding = LittleGhost::Tool::Binding.new

    with_http_transport(transport) do
      tool_class = toolset.tools(binding).fetch(0)
      assert_equal "found", tool_class.new.execute({}).value
      assert_equal "knowledge_search", tool_class.tool_name
    end

    assert_equal %w[search delete], definitions.map { |definition, _| definition.source_name }
    assert_equal "search", transport.requests.last.dig(:params, :name)
  end

  def test_map_result_receives_immutable_values_and_can_return_artifacts
    seen = nil
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      connection url: "https://mcp.example/rpc"
      map_result do |result, call:, binding:|
        seen = [result, call, binding]
        LittleGhost::Tool::Result.new(
          value: {"mapped" => result.content.first.fetch("text")},
          artifacts: [LittleGhost::Artifact.deferred(
            reference: "record:1",
            media_type: "application/octet-stream"
          )]
        )
      end
    end
    binding = LittleGhost::Tool::Binding.new

    with_http_transport(Transport.new) do
      result = toolset.tools(binding).first.new(binding:).execute({})
      assert_equal({"mapped" => "found"}, result.value)
      assert_equal "record:1", result.artifacts.first.reference
    end

    protocol_result, call, current_binding = seen
    assert_instance_of LittleGhost::MCP::Result, protocol_result
    assert protocol_result.content.frozen?
    assert_instance_of LittleGhost::MCP::Call, call
    assert_same binding, current_binding
  end

  def test_optional_toolset_reports_expected_discovery_failures_and_closes
    error = ::MCP::Client::RequestHandlerError.new("offline", {}, error_type: :network_error)
    transport = Transport.new(request_error: error)
    observed = []
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      connection url: "https://mcp.example/rpc"
      optional true
      on_error { |failure, binding:| observed << [failure, binding] }
    end
    binding = LittleGhost::Tool::Binding.new

    with_http_transport(transport) do
      assert_empty toolset.tools(binding)
    end

    assert_instance_of LittleGhost::ProviderError, observed.first.first
    assert_same binding, observed.first.last
    assert transport.closed?
  end

  def test_optional_toolset_does_not_consume_application_callback_failures
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      connection { |_binding| raise LittleGhost::ToolError, "caller policy failed" }
      optional true
    end

    error = assert_raises(LittleGhost::ToolError) do
      toolset.tools(LittleGhost::Tool::Binding.new)
    end
    assert_equal "caller policy failed", error.message
  end

  def test_run_owns_and_closes_the_official_transport
    transport = Transport.new
    run = FakeRun.new
    binding = LittleGhost::Tool::Binding.new(run:)

    with_http_transport(transport) do
      http_toolset.tools(binding)
    end

    assert_equal 1, run.resources.length
    run.resources.first.close
    run.resources.first.close
    assert transport.closed?
  end

  def test_cancellation_stops_discovery_before_transport_work
    token = LittleGhost::Support::CancellationToken.new.cancel
    run = FakeRun.new(LittleGhost::RunContext.new(cancellation_token: token))
    transport = Transport.new

    with_http_transport(transport) do
      assert_raises(LittleGhost::CancelledError) do
        http_toolset.tools(LittleGhost::Tool::Binding.new(run:))
      end
    end

    assert_empty transport.requests
    refute transport.closed?
  end

  def test_deadline_bounds_protocol_initialization_timeout
    transport = Transport.new
    context = LittleGhost::RunContext.new(deadline: Time.now + 0.25)
    run = FakeRun.new(context)
    configured_timeout = nil

    with_http_transport(transport, faraday: ->(value) { configured_timeout = value.options.timeout }) do
      http_toolset.tools(LittleGhost::Tool::Binding.new(run:))
    end

    assert_operator configured_timeout, :>, 0
    assert_operator configured_timeout, :<=, 0.25
  end

  def test_input_schema_uses_full_draft_validation
    tools = [[{
      "name" => "count",
      "inputSchema" => {
        "type" => "object",
        "properties" => {"count" => {"const" => 1}},
        "required" => ["count"]
      }
    }]]

    with_http_transport(Transport.new(tool_pages: tools)) do
      result = http_toolset.tools(LittleGhost::Tool::Binding.new).first.new.execute({"count" => 2})

      assert result.error?
      assert_match(/did not match inputSchema/, result.content)
    end
  end

  def test_full_draft_validation_is_not_preempted_by_the_local_tool_subset
    tools = [[{
      "name" => "integer",
      "inputSchema" => {
        "type" => "object",
        "properties" => {"count" => {"type" => "integer"}},
        "required" => ["count"]
      }
    }]]
    transport = Transport.new(tool_pages: tools)

    with_http_transport(transport) do
      result = http_toolset.tools(LittleGhost::Tool::Binding.new).first.new.execute({"count" => 1.0})

      assert result.success?
      assert_equal 1.0, transport.requests.last.dig(:params, :arguments, "count")
    end
  end

  def test_recursive_schema_failure_stays_inside_the_tool_boundary
    tools = [[{
      "name" => "recursive",
      "inputSchema" => {"$ref" => "#"}
    }]]

    with_http_transport(Transport.new(tool_pages: tools)) do
      result = http_toolset.tools(LittleGhost::Tool::Binding.new).first.new.execute({})
      assert result.error?
      assert_match(/recursion limit/, result.content)
    end

    output_tools = [[{
      "name" => "recursive_output",
      "inputSchema" => {"type" => "object"},
      "outputSchema" => {"$ref" => "#"}
    }]]
    transport = Transport.new(tool_pages: output_tools, results: {"structuredContent" => {}})
    with_http_transport(transport) do
      result = http_toolset.tools(LittleGhost::Tool::Binding.new).first.new.execute({})
      assert result.error?
      assert_equal "Tool failed (LittleGhost::ProtocolError)", result.content
    end
  end

  def test_output_schema_accepts_false_and_explicit_null_roots
    false_tool = [[{
      "name" => "flag",
      "inputSchema" => {"type" => "object"},
      "outputSchema" => {"type" => "boolean"}
    }]]
    with_http_transport(Transport.new(tool_pages: false_tool, results: {"structuredContent" => false})) do
      assert_equal false, http_toolset.tools(LittleGhost::Tool::Binding.new).first.new.execute({}).value
    end

    null_tool = [[{
      "name" => "nothing",
      "inputSchema" => {"type" => "object"},
      "outputSchema" => {"type" => "null"}
    }]]
    with_http_transport(Transport.new(tool_pages: null_tool, results: {"structuredContent" => nil})) do
      result = http_toolset.tools(LittleGhost::Tool::Binding.new).first.new.execute({})
      assert result.success?
      assert_nil result.value
    end
  end

  def test_output_schema_rejects_absent_or_invalid_structured_content
    tools = [[{
      "name" => "count",
      "inputSchema" => {"type" => "object"},
      "outputSchema" => {"type" => "integer", "const" => 1}
    }]]

    with_http_transport(Transport.new(tool_pages: tools, results: {})) do
      result = http_toolset.tools(LittleGhost::Tool::Binding.new).first.new.execute({})
      assert result.error?
      assert_equal "Tool failed (LittleGhost::ProtocolError)", result.content
    end
    with_http_transport(Transport.new(tool_pages: tools, results: {"structuredContent" => 2})) do
      result = http_toolset.tools(LittleGhost::Tool::Binding.new).first.new.execute({})
      assert result.error?
      assert_equal "Tool failed (LittleGhost::ProtocolError)", result.content
    end
  end

  def test_external_schema_references_are_rejected
    tools = [[{
      "name" => "unsafe",
      "inputSchema" => {"$ref" => "https://example.com/schema.json"}
    }]]

    with_http_transport(Transport.new(tool_pages: tools)) do
      error = assert_raises(LittleGhost::ProtocolError) do
        http_toolset.tools(LittleGhost::Tool::Binding.new)
      end
      assert_match(/same-document/, error.message)
    end
  end

  def test_schema_patterns_keep_ecmascript_semantics_and_size_limits
    tools = [[{
      "name" => "match",
      "inputSchema" => {
        "type" => "object",
        "properties" => {"value" => {"type" => "string", "pattern" => "^foo$"}}
      }
    }]]
    with_http_transport(Transport.new(tool_pages: tools)) do
      result = http_toolset.tools(LittleGhost::Tool::Binding.new).first.new.execute({"value" => "x\nfoo\ny"})
      assert result.error?
    end

    oversized = [[{
      "name" => "oversized",
      "inputSchema" => {"type" => "string", "pattern" => "x" * 65_537}
    }]]
    with_http_transport(Transport.new(tool_pages: oversized)) do
      assert_raises(LittleGhost::ProtocolError) do
        http_toolset.tools(LittleGhost::Tool::Binding.new)
      end
    end
  end

  def test_mcp_images_become_artifacts_without_retaining_base64_in_the_value
    encoded = Base64.strict_encode64("image-bytes")
    transport = Transport.new(results: {
      "content" => [{"type" => "image", "data" => encoded, "mimeType" => "image/png", "name" => "chart.png"}]
    })

    with_http_transport(transport) do
      result = http_toolset.tools(LittleGhost::Tool::Binding.new).first.new.execute({})
      assert_equal({"images" => [{"mediaType" => "image/png", "name" => "chart.png", "bytes" => 11}]}, result.value)
      refute_includes result.value.inspect, encoded
      assert_equal "image-bytes", result.artifacts.fetch(0).data
    end
  end

  def test_mcp_image_count_limit_is_applied_before_decode
    images = Array.new(21) do
      {"type" => "image", "data" => Base64.strict_encode64("x"), "mimeType" => "image/png"}
    end

    with_http_transport(Transport.new(results: {"content" => images})) do
      result = http_toolset.tools(LittleGhost::Tool::Binding.new).first.new.execute({})
      assert result.error?
      assert_equal "Tool failed (LittleGhost::ProtocolError)", result.content
    end
  end

  def test_server_tool_errors_remain_tool_errors
    transport = Transport.new(results: {
      "content" => [{"type" => "text", "text" => "safe failure"}],
      "isError" => true
    })

    with_http_transport(transport) do
      result = http_toolset.tools(LittleGhost::Tool::Binding.new).first.new.execute({})
      assert result.error?
      assert_equal "safe failure", result.content
    end
  end

  def test_loads_all_pages_and_normalizes_long_names
    long_name = "search." + ("a" * 100)
    pages = [
      [{"name" => "first", "inputSchema" => {"type" => "object"}}],
      [{"name" => long_name, "inputSchema" => {"type" => "object"}}]
    ]

    with_http_transport(Transport.new(tool_pages: pages)) do
      names = http_toolset.tools(LittleGhost::Tool::Binding.new).map(&:tool_name)
      assert_equal "first", names.first
      assert_equal 64, names.last.length
      assert_match(/_[a-f0-9]{12}\z/, names.last)
    end
  end

  def test_malformed_tool_catalog_is_a_protocol_error_and_optional_failure
    transport = Transport.new(tool_pages: ["invalid"])
    with_http_transport(transport) do
      assert_raises(LittleGhost::ProtocolError) do
        http_toolset.tools(LittleGhost::Tool::Binding.new)
      end
    end

    optional = Class.new(LittleGhost::MCP::Toolset) do
      connection url: "https://mcp.example/rpc"
      optional true
    end
    with_http_transport(Transport.new(tool_pages: ["invalid"])) do
      assert_empty optional.tools(LittleGhost::Tool::Binding.new)
    end

    [{"jsonrpc" => "2.0", "id" => 1}, "invalid"].each do |response|
      malformed = Transport.new
      malformed.define_singleton_method(:send_request) do |request:|
        (request[:method] == "tools/list") ? response : super(request:)
      end
      with_http_transport(malformed) do
        assert_raises(LittleGhost::ProtocolError) do
          http_toolset.tools(LittleGhost::Tool::Binding.new)
        end
      end
    end
  end

  def test_stdio_calls_are_serialized
    transport = Transport.new(tool_pages: [[
      {"name" => "first", "inputSchema" => {"type" => "object"}},
      {"name" => "second", "inputSchema" => {"type" => "object"}}
    ]])
    active = 0
    maximum = 0
    mutex = Mutex.new
    original = transport.method(:send_request)
    transport.define_singleton_method(:send_request) do |request:, &sent|
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
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      connection command: "server"
    end

    ::MCP::Client::Stdio.stub(:new, transport) do
      tools = toolset.tools(LittleGhost::Tool::Binding.new).map(&:new)
      tools.map { |tool| Thread.new { tool.execute({}) } }.each(&:value)
    end

    assert_equal 1, maximum
  end

  def test_rejects_transport_specific_options_on_the_wrong_transport
    assert_raises(LittleGhost::ConfigurationError) do
      Class.new(LittleGhost::MCP::Toolset) do
        connection command: "server", headers: {"Authorization" => "secret"}
      end
    end
    assert_raises(LittleGhost::ConfigurationError) do
      Class.new(LittleGhost::MCP::Toolset) do
        connection url: "https://mcp.example/rpc", args: ["server"]
      end
    end
  end

  def test_custom_transport_requires_cancellation_and_cleanup_methods
    transport = Object.new
    closed = false
    transport.define_singleton_method(:send_request) { |request:| {"result" => {"tools" => []}} }
    transport.define_singleton_method(:close) { closed = true }
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      connection { |_binding| transport }
    end

    error = assert_raises(LittleGhost::ConfigurationError) do
      toolset.tools(LittleGhost::Tool::Binding.new)
    end
    assert_match(/send_notification/, error.message)
    assert closed
  end

  def test_stdio_can_start_with_a_clean_environment_and_unset_entries
    received = nil
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      connection command: "server", inherit_env: false,
        env: {"ONLY_THIS" => "value", "REMOVE_THIS" => nil}
    end
    constructor = lambda do |**values|
      received = values
      Transport.new
    end

    ::MCP::Client::Stdio.stub(:new, constructor) do
      toolset.tools(LittleGhost::Tool::Binding.new)
    end

    environment = received.fetch(:env)
    assert_equal "value", environment.fetch("ONLY_THIS")
    assert_nil environment.fetch("REMOVE_THIS")
    inherited_name = (ENV.keys - %w[ONLY_THIS REMOVE_THIS]).first
    assert_nil environment.fetch(inherited_name) if inherited_name
  end

  def test_oauth_accepts_an_official_provider_escape_hatch
    provider = Object.new
    provider.define_singleton_method(:authorization_flow) { :custom }
    received = nil
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      connection url: "https://mcp.example/rpc", oauth: provider
    end

    with_http_transport(Transport.new, options: ->(values) { received = values }) do
      toolset.tools(LittleGhost::Tool::Binding.new)
    end

    assert_same provider, received.fetch(:oauth)
  end

  def test_oauth_hash_selects_the_official_provider
    provider = Object.new
    received = nil
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      connection url: "https://mcp.example/rpc", oauth: {
        grant: :client_credentials,
        client_id: "client",
        client_secret: "secret"
      }
    end

    constructor = lambda do |**values|
      received = values
      provider
    end
    ::MCP::Client::OAuth::ClientCredentialsProvider.stub(:new, constructor) do
      with_http_transport(Transport.new) do
        toolset.tools(LittleGhost::Tool::Binding.new)
      end
    end

    assert_equal "client", received.fetch(:client_id)
    assert_equal "secret", received.fetch(:client_secret)
  end

  def test_signer_middleware_preserves_the_net_http_request_contract
    seen = nil
    signer = lambda do |request|
      seen = request
      request["Authorization"] = "signed"
    end
    response = Object.new
    app = ->(environment) { response }
    environment = Struct.new(:url, :request_headers, :body).new(
      URI("https://mcp.example/rpc"),
      {"Content-Type" => "application/json"},
      "{}"
    )

    result = LittleGhost::MCP::SignerMiddleware.new(app, signer).call(environment)

    assert_instance_of Net::HTTP::Post, seen
    assert_equal "{}", seen.body
    assert_equal "signed", environment.request_headers.fetch("authorization")
    assert_same response, result
  end

  private

  def http_toolset
    Class.new(LittleGhost::MCP::Toolset) do
      connection url: "https://mcp.example/rpc"
    end
  end

  def with_http_transport(transport, options: nil, faraday: nil)
    constructor = lambda do |**values, &customizer|
      options&.call(values)
      connection = FakeFaraday.new
      customizer&.call(connection)
      faraday&.call(connection)
      transport
    end
    ::MCP::Client::HTTP.stub(:new, constructor) { yield }
  end

  class FakeFaraday
    Options = Struct.new(:timeout, :open_timeout)

    attr_reader :options, :middleware

    def initialize
      @options = Options.new
      @middleware = []
    end

    def use(*values)
      middleware << values
    end
  end
end
