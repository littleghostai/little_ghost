# frozen_string_literal: true

require "json"
require "openssl"
require "socket"
require "timeout"
require "tmpdir"
require "async"
require "test_helper"
require "little_ghost/network"
require "little_ghost/network/authorizer_server"
require "little_ghost/network/certificate_authority"
require "little_ghost/network/envoy_config"
require "little_ghost/network/envoy_gateway"

class NetworkTest < Minitest::Test
  def test_envoy_connect_config_allows_only_exact_authorities
    policy = LittleGhost::Sandbox::NetworkPolicy.new(
      mode: :allowlist,
      allow: ["rubygems.org:443", "registry.npmjs.org:443"]
    )

    config = LittleGhost::Network::EnvoyConfig.build(
      policy:,
      listener: LittleGhost::Network::EnvoyConfig.pipe_address("/tmp/proxy.sock")
    )
    serialized = JSON.generate(config)

    assert_includes serialized, '"exact":"rubygems.org:443"'
    assert_includes serialized, '"exact":"registry.npmjs.org:443"'
    assert_includes serialized, '"status":403'
    assert_includes serialized, '"resolved_address_filter"'
    refute_includes serialized, "ext_authz"
  end

  def test_envoy_config_rejects_ambiguous_or_unsafe_destinations
    ["*.example.com:443", "127.0.0.1:443", "example.com", "example.com:0"].each do |destination|
      policy = LittleGhost::Sandbox::NetworkPolicy.new(mode: :allowlist, allow: [destination])

      assert_raises(LittleGhost::PolicyError) do
        LittleGhost::Network::EnvoyConfig.build(
          policy:,
          listener: LittleGhost::Network::EnvoyConfig.pipe_address("/tmp/proxy.sock")
        )
      end
    end
  end

  def test_http_inspection_adds_tls_and_external_authorization
    Dir.mktmpdir do |root|
      policy = LittleGhost::Sandbox::NetworkPolicy.new(
        mode: :allowlist,
        allow: ["example.com:443"],
        inspection: :http,
        authorizer: ->(request:) { LittleGhost::Network::Decision.allow },
        forward_headers: ["git-protocol"],
        mutation_headers: ["authorization", "user-agent"]
      )
      paths = {
        interceptor_socket: File.join(root, "interceptor.sock"),
        authorizer_socket: File.join(root, "authorizer.sock"),
        certificate_chain: File.join(root, "leaf.crt"),
        private_key: File.join(root, "leaf.key"),
        trusted_ca: "/etc/ssl/certs/ca-certificates.crt",
        access_log: File.join(root, "access.log")
      }

      serialized = JSON.generate(LittleGhost::Network::EnvoyConfig.build(
        policy:,
        listener: LittleGhost::Network::EnvoyConfig.pipe_address(File.join(root, "proxy.sock")),
        paths:
      ))

      assert_includes serialized, "envoy.filters.http.ext_authz"
      assert_includes serialized, "git-protocol"
      assert_includes serialized, '"exact":"authorization"'
      refute_includes serialized, '"safe_regex":{"regex":"^[a-z0-9-]+$"}'
      assert_includes serialized, '"disallowed_headers"'
      assert_includes serialized, '"exact":"authorization"'
      assert_includes serialized, paths.fetch(:certificate_chain)
      refute_includes serialized, "%REQ(:PATH)%"
    end
  end

  def test_certificate_authority_creates_a_verifiable_leaf_for_each_host
    Dir.mktmpdir do |root|
      paths = LittleGhost::Network::CertificateAuthority.create(
        root:,
        hosts: %w[example.com api.example.com]
      )
      ca = OpenSSL::X509::Certificate.new(File.binread(paths.fetch(:ca_certificate)))
      leaf = OpenSSL::X509::Certificate.new(File.binread(paths.fetch(:certificate_chain)))
      store = OpenSSL::X509::Store.new
      store.add_cert(ca)

      assert store.verify(leaf)
      san = leaf.extensions.find { |extension| extension.oid == "subjectAltName" }.value
      assert_includes san, "DNS:example.com"
      assert_includes san, "DNS:api.example.com"
      assert_equal 0o600, File.stat(paths.fetch(:ca_key)).mode & 0o777
      assert_equal 0o600, File.stat(paths.fetch(:private_key)).mode & 0o777
      refute_equal File.dirname(paths.fetch(:private_key)), paths.fetch(:trust_root)
      assert_empty Dir.glob(File.join(paths.fetch(:trust_root), "*.key"))
    end
  end

  def test_certificate_authority_does_not_block_the_scheduler_thread
    started = Queue.new
    release = Queue.new
    operation_thread = nil
    scheduler_thread = nil
    result = nil

    Async do |task|
      scheduler_thread = Thread.current
      generation = task.async do
        LittleGhost::Network::CertificateAuthority.stub(:create_material, lambda { |**|
          operation_thread = Thread.current
          started << true
          release.pop
          {ca_certificate: "ca.pem"}
        }) do
          result = LittleGhost::Network::CertificateAuthority.create(root: "/tmp", hosts: ["example.test"])
        end
      end
      started.pop
      release << true
      generation.wait
    end.wait

    assert_equal({ca_certificate: "ca.pem"}, result)
    refute_same scheduler_thread, operation_thread
  ensure
    release&.push(true)
  end

  def test_docker_envoy_rejects_http_inspection_instead_of_weakening_it
    policy = LittleGhost::Sandbox::NetworkPolicy.new(
      mode: :allowlist,
      allow: ["example.com:443"],
      inspection: :http,
      authorizer: ->(request:) { LittleGhost::Network::Decision.allow }
    )
    gateway = LittleGhost::Network::EnvoyGateway.new(policy:, runtime: :docker, transport: :docker)
    gateway.instance_variable_set(:@resolved_runtime, :docker)

    error = assert_raises(LittleGhost::CapabilityError) { gateway.send(:validate_runtime!) }

    assert_match(/supports CONNECT allowlisting/, error.message)
  end

  def test_envoy_gateway_rejects_unsafe_runtime_options
    policy = LittleGhost::Sandbox::NetworkPolicy.new(
      mode: :allowlist,
      allow: ["example.com:443"]
    )

    assert_raises(LittleGhost::PolicyError) do
      LittleGhost::Network::EnvoyGateway.new(policy:, image: "--privileged")
    end
    assert_raises(LittleGhost::PolicyError) do
      LittleGhost::Network::EnvoyGateway.new(policy:, dns: ["resolver.example.com"])
    end
  end

  def test_external_gateway_exposes_only_declared_resources_and_validates_readiness
    Dir.mktmpdir do |root|
      ready = false
      policy = LittleGhost::Sandbox::NetworkPolicy.new(
        mode: :allowlist,
        allow: ["example.com:443"]
      )
      workspace = LittleGhost::Workspace.new(root:, paths: {egress: "egress"}).open
      gateway = LittleGhost::Network::ExternalGateway.new(
        policy:,
        workspace:,
        runtime_paths: [:egress],
        proxy_mount_path: File.join(workspace.path(:egress), "proxy.sock"),
        environment: {HTTPS_PROXY: "http://127.0.0.1:3128"},
        validate: -> { raise LittleGhost::DependencyError, "not ready" unless ready }
      )

      assert_raises(LittleGhost::DependencyError) { gateway.validate! }
      ready = true
      assert_same gateway, gateway.validate!
      assert_equal({"HTTPS_PROXY" => "http://127.0.0.1:3128"}, gateway.environment)
      assert_equal [:egress], gateway.runtime_paths
      assert_equal File.join(workspace.path(:egress), "proxy.sock"), gateway.proxy_mount_path

      assert_raises(LittleGhost::PolicyError) do
        LittleGhost::Network::ExternalGateway.new(
          policy:,
          workspace:,
          runtime_paths: [:egress],
          proxy_mount_path: "/outside/proxy.sock"
        )
      end
    ensure
      workspace&.close
    end
  end

  def test_authorizer_server_passes_normalized_metadata_and_mutates_headers
    Dir.mktmpdir do |root|
      received = Queue.new
      authorizer = lambda do |request:|
        received << request
        LittleGhost::Network::Decision.allow(
          set_headers: {"authorization" => "Bearer trusted"},
          remove_headers: ["x-untrusted"]
        )
      end
      socket_path = File.join(root, "authorizer.sock")
      server = LittleGhost::Network::AuthorizerServer.new(socket_path:, authorizer:).start

      client = UNIXSocket.new(socket_path)
      client.write("POST /v1/items?secret=no HTTP/1.1\r\nHost: API.EXAMPLE.COM:443\r\nX-Untrusted: value\r\n\r\n")
      response = client.read
      request = received.pop

      assert_equal "POST", request.method
      assert_equal "api.example.com", request.host
      assert_equal 443, request.port
      assert_includes response, "HTTP/1.0 200 OK"
      assert_includes response, "authorization: Bearer trusted"
      assert_includes response, "x-untrusted"
      assert_includes response, "authorization"
    ensure
      client&.close
      server&.close
    end
  end

  def test_authorizer_failure_is_fail_closed
    Dir.mktmpdir do |root|
      socket_path = File.join(root, "authorizer.sock")
      server = LittleGhost::Network::AuthorizerServer.new(
        socket_path:,
        authorizer: ->(request:) { raise "unavailable" }
      ).start

      client = UNIXSocket.new(socket_path)
      client.write("GET / HTTP/1.1\r\nHost: example.com:443\r\n\r\n")

      assert_includes client.read, "HTTP/1.0 503 Service Unavailable"
    ensure
      client&.close
      server&.close
    end
  end

  def test_authorizer_decisions_reject_header_injection_and_routing_mutations
    assert_raises(LittleGhost::PolicyError) do
      LittleGhost::Network::Decision.allow(set_headers: {"x-safe\r\nx-injected" => "value"})
    end
    assert_raises(LittleGhost::PolicyError) do
      LittleGhost::Network::Decision.allow(set_headers: {"authorization" => "value\r\nx-injected: yes"})
    end
    assert_raises(LittleGhost::PolicyError) do
      LittleGhost::Network::Decision.allow(set_headers: {"host" => "internal.example"})
    end
  end

  def test_facades_listen_in_plaintext_and_originate_tls_to_one_authorized_upstream
    Dir.mktmpdir do |root|
      policy = LittleGhost::Sandbox::NetworkPolicy.new(
        mode: :allowlist,
        authorizer: ->(request:) { LittleGhost::Network::Decision.allow },
        mutation_headers: ["x-api-key"],
        facades: [
          {name: :answers, upstream: "api.example.com", port: 3130, timeout: 0},
          {name: :search, upstream: "search.example.com:8443", socket: File.join(root, "search.sock"), timeout: 1.5}
        ]
      )

      config = LittleGhost::Network::EnvoyConfig.build(
        policy:,
        listener: LittleGhost::Network::EnvoyConfig.pipe_address(File.join(root, "proxy.sock")),
        paths: {authorizer_socket: File.join(root, "authorizer.sock"), trusted_ca: "/etc/ssl/certs/ca-certificates.crt"}
      )
      listeners = config.dig("static_resources", "listeners").to_h { |listener| [listener.fetch("name"), listener] }
      clusters = config.dig("static_resources", "clusters").map { |cluster| cluster.fetch("name") }
      answers = listeners.fetch("little_ghost_facade_answers")
      search = listeners.fetch("little_ghost_facade_search")
      answers_manager = answers.dig("filter_chains", 0, "filters", 0, "typed_config")
      answers_route = answers_manager.dig("route_config", "virtual_hosts", 0, "routes", 0)
      search_route = search.dig("filter_chains", 0, "filters", 0, "typed_config", "route_config", "virtual_hosts", 0, "routes", 0)
      authorizer = answers_manager.fetch("http_filters").first.fetch("typed_config")

      assert_equal({"socket_address" => {"address" => "127.0.0.1", "port_value" => 3130}}, answers.fetch("address"))
      assert_equal File.join(root, "search.sock"), search.dig("address", "pipe", "path")
      assert_nil answers.dig("filter_chains", 0, "transport_socket")
      assert_equal %w[envoy.filters.http.ext_authz envoy.filters.http.dynamic_forward_proxy envoy.filters.http.router],
        answers_manager.fetch("http_filters").map { |filter| filter.fetch("name") }
      assert_equal({"cluster" => "little_ghost_facade_egress", "timeout" => "0s"}, answers_route.fetch("route"))
      assert_equal "1.500s", search_route.dig("route", "timeout")
      assert_equal "api.example.com",
        answers_route.dig("typed_per_filter_config", "envoy.filters.http.dynamic_forward_proxy", "host_rewrite_literal")
      assert_equal "search.example.com:8443",
        search_route.dig("typed_per_filter_config", "envoy.filters.http.dynamic_forward_proxy", "host_rewrite_literal")
      assert_equal [{"key" => "x-little-ghost-facade-upstream", "value" => "api.example.com:443"}],
        authorizer.dig("http_service", "authorization_request", "headers_to_add")
      assert_includes authorizer.dig("disallowed_headers", "patterns"), {"exact" => "x-little-ghost-facade-upstream"}
      assert_includes authorizer.dig("disallowed_headers", "patterns"), {"exact" => "x-api-key"}
      assert_equal [{"exact" => "x-api-key"}], authorizer.dig("http_service", "authorization_response", "allowed_upstream_headers", "patterns")
      assert_includes clusters, "little_ghost_authorizer"
      facade_cluster = config.dig("static_resources", "clusters").find { |cluster| cluster.fetch("name") == "little_ghost_facade_egress" }
      assert_equal "envoy.transport_sockets.tls", facade_cluster.dig("transport_socket", "name")
      refute_includes JSON.generate(config), "envoy.filters.http.buffer"
      explicit = listeners.fetch("little_ghost_explicit_proxy")
      explicit_routes = explicit.dig("filter_chains", 0, "filters", 0, "typed_config", "route_config", "virtual_hosts", 0, "routes")
      assert(explicit_routes.all? { |route| route.dig("direct_response", "status") == 403 })
    end
  end

  def test_inspected_routes_use_per_host_timeouts_and_can_forward_every_header
    Dir.mktmpdir do |root|
      policy = LittleGhost::Sandbox::NetworkPolicy.new(
        mode: :allowlist,
        allow: ["git.example.com:443", "downloads.example.com:443"],
        inspection: :http,
        authorizer: ->(request:) { LittleGhost::Network::Decision.allow },
        forward_headers: :all,
        timeouts: {"git.example.com" => 300}
      )

      config = LittleGhost::Network::EnvoyConfig.build(
        policy:,
        listener: LittleGhost::Network::EnvoyConfig.pipe_address(File.join(root, "proxy.sock")),
        paths: {
          interceptor_socket: File.join(root, "interceptor.sock"),
          authorizer_socket: File.join(root, "authorizer.sock"),
          certificate_chain: File.join(root, "leaf.crt"),
          private_key: File.join(root, "leaf.key"),
          trusted_ca: "/etc/ssl/certs/ca-certificates.crt"
        }
      )
      interceptor = config.dig("static_resources", "listeners").find { |listener| listener.fetch("name") == "little_ghost_tls_interceptor" }
      manager = interceptor.dig("filter_chains", 0, "filters", 0, "typed_config")
      timeouts = manager.dig("route_config", "virtual_hosts").to_h do |virtual_host|
        [virtual_host.fetch("domains").first, virtual_host.dig("routes", 0, "route", "timeout")]
      end
      authorizer = manager.fetch("http_filters").first.fetch("typed_config")

      assert_equal({"git.example.com" => "300s", "downloads.example.com" => "0s"}, timeouts)
      assert_equal [{"safe_regex" => {"regex" => ".*"}}], authorizer.dig("allowed_headers", "patterns")
      assert_nil authorizer.dig("http_service", "authorization_request", "headers_to_add")
    end
  end

  def test_network_policy_validates_facades
    authorizer = ->(request:) { LittleGhost::Network::Decision.allow }

    assert_raises(LittleGhost::PolicyError) do
      LittleGhost::Sandbox::NetworkPolicy.new(mode: :allowlist, facades: [{name: :answers, upstream: "api.example.com", port: 3130}])
    end
    assert_raises(LittleGhost::PolicyError) do
      LittleGhost::Sandbox::NetworkPolicy.new(mode: :none, facades: [{name: :answers, upstream: "api.example.com", port: 3130}])
    end
    assert_raises(LittleGhost::PolicyError) do
      LittleGhost::Sandbox::NetworkPolicy.new(
        mode: :allowlist,
        authorizer:,
        facades: [{name: :a, upstream: "api.example.com", port: 3130}, {name: :b, upstream: "api.example.org", port: 3130}]
      )
    end
    [
      {name: "Answers", upstream: "api.example.com", port: 3130},
      {name: :answers, upstream: "127.0.0.1", port: 3130},
      {name: :answers, upstream: "api.example.com", port: 3130, socket: "/tmp/answers.sock"},
      {name: :answers, upstream: "api.example.com", socket: "answers.sock"},
      {name: :answers, upstream: "api.example.com", port: 70_000},
      {name: :answers, upstream: "api.example.com", port: 3130, timeout: -1}
    ].each do |facade|
      assert_raises(LittleGhost::PolicyError, facade.inspect) { LittleGhost::Network::Facade.coerce(facade) }
    end
  end

  def test_run_scoped_envoy_gateway_rejects_facades
    policy = LittleGhost::Sandbox::NetworkPolicy.new(
      mode: :allowlist,
      authorizer: ->(request:) { LittleGhost::Network::Decision.allow },
      facades: [{name: :answers, upstream: "api.example.com", port: 3130}]
    )

    error = assert_raises(LittleGhost::CapabilityError) { LittleGhost::Network::EnvoyGateway.new(policy:) }

    assert_match(/write_configuration/, error.message)
  end

  def test_write_configuration_writes_a_private_envoy_file
    Dir.mktmpdir do |root|
      hosts = LittleGhost::Network::HostPolicy.new { host("api.example.com") { inject { {"x-api-key" => "unused"} } } }
      policy = hosts.network_policy(facades: [{name: :answers, upstream: "api.example.com", port: 3130}])
      path = File.join(root, "envoy.json")

      returned = LittleGhost::Network::EnvoyGateway.write_configuration(
        path:,
        policy:,
        listener: File.join(root, "proxy.sock"),
        paths: {authorizer_socket: File.join(root, "authorizer.sock"), trusted_ca: "/etc/ssl/certs/ca-certificates.crt"}
      )
      config = JSON.parse(File.read(path))

      assert_equal path, returned
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal ["envoy.json"], Dir.children(root)
      assert_equal %w[little_ghost_explicit_proxy little_ghost_facade_answers],
        config.dig("static_resources", "listeners").map { |listener| listener.fetch("name") }
      refute_includes File.read(path), "unused"
      assert_raises(LittleGhost::PolicyError) do
        LittleGhost::Network::EnvoyGateway.write_configuration(path:, policy:, listener: File.join(root, "proxy.sock"))
      end
      validate_with_envoy(path)
    end
  end

  def test_authorizer_server_serves_until_the_stop_io_is_readable
    Dir.mktmpdir do |root|
      socket_path = File.join(root, "authorizer.sock")
      received = Queue.new
      server = LittleGhost::Network::AuthorizerServer.new(
        socket_path:,
        authorizer: lambda do |request:|
          received << request
          LittleGhost::Network::Decision.allow(set_headers: {"x-api-key" => "trusted"})
        end,
        mode: 0o660
      )
      stop_reader, stop_writer = IO.pipe
      serving = Thread.new { server.serve(stop_io: stop_reader) }
      Timeout.timeout(5) { sleep 0.01 until File.socket?(socket_path) }

      assert_equal 0o660, File.stat(socket_path).mode & 0o777
      client = UNIXSocket.new(socket_path)
      client.write(
        "POST /v1/answers HTTP/1.1\r\nHost: 127.0.0.1:3130\r\n" \
        "X-Little-Ghost-Facade-Upstream: api.example.com:443\r\n\r\n"
      )
      response = client.read
      request = received.pop

      assert_equal "api.example.com", request.host
      refute request.headers.key?("x-little-ghost-facade-upstream")
      assert_includes response, "x-api-key: trusted"
      removals = response[/^x-envoy-auth-headers-to-remove: (.*)\r$/, 1].split(", ")
      assert_includes removals, "authorization"
      assert_includes removals, "x-little-ghost-facade-upstream"
      refute_includes removals, "x-api-key"

      stop_writer.write(".")
      assert serving.join(5)
      refute File.exist?(socket_path)
    ensure
      client&.close
      stop_writer&.close
      stop_reader&.close
      serving&.kill
    end
  end

  private

  def validate_with_envoy(path)
    envoy = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |directory| File.join(directory, "envoy") }
      .find { |candidate| File.executable?(candidate) }
    return unless envoy

    result = LittleGhost::Sandbox::ProcessRunner.run(
      command: [envoy, "--mode", "validate", "--config-path", path],
      timeout: 30,
      max_output_bytes: 100_000,
      environment: {"PATH" => ENV.fetch("PATH", "")}
    )
    assert result.success?, result.stderr
  end
end
