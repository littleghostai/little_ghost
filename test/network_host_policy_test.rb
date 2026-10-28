# frozen_string_literal: true

require "test_helper"

class NetworkHostPolicyTest < Minitest::Test
  def request(method: "GET", host: "api.example.com", path: "/", headers: {})
    LittleGhost::Network::Request.new(method:, scheme: "https", host:, port: 443, path:, headers:)
  end

  def test_host_rules_restrict_methods_and_paths
    hosts = LittleGhost::Network::HostPolicy.new do
      host "api.example.com" do
        methods :post
        paths "/v1/answers", "/v1/articles/*"
      end
    end

    assert hosts.authorize(request(method: "POST", path: "/v1/answers")).allowed
    assert hosts.authorize(request(method: "POST", path: "/v1/articles/42?locale=en")).allowed
    refute hosts.authorize(request(method: "GET", path: "/v1/answers")).allowed
    refute hosts.authorize(request(method: "POST", path: "/v1/answers/extra")).allowed
    refute hosts.authorize(request(method: "POST", path: "/v1/admin")).allowed
    assert_equal 403, hosts.authorize(request(method: "POST", path: "/v1/admin")).status
  end

  def test_unknown_hosts_use_the_default_rule_or_are_denied
    with_default = LittleGhost::Network::HostPolicy.new do
      host("api.example.com") {}
      default { methods :get, :head }
    end
    without_default = LittleGhost::Network::HostPolicy.new { host("api.example.com") {} }

    assert with_default.authorize(request(host: "downloads.example.com")).allowed
    refute with_default.authorize(request(method: "PUT", host: "downloads.example.com")).allowed
    assert with_default.authorize(request(method: "DELETE")).allowed
    refute without_default.authorize(request(host: "downloads.example.com")).allowed
  end

  def test_deny_paths_win_and_match_regardless_of_case_or_encoding
    hosts = LittleGhost::Network::HostPolicy.new do
      host "git.example.com" do
        deny_paths %r{/git-receive-pack\z}, "/Admin*"
      end
    end

    assert hosts.authorize(request(host: "git.example.com", path: "/repo.git/info/refs")).allowed
    refute hosts.authorize(request(host: "git.example.com", path: "/repo.git/git-receive-pack")).allowed
    refute hosts.authorize(request(host: "git.example.com", path: "/repo.git/GIT-RECEIVE-PACK")).allowed
    refute hosts.authorize(request(host: "git.example.com", path: "/repo.git/git-receive%2Dpack")).allowed
    refute hosts.authorize(request(host: "git.example.com", path: "/ADMIN/users")).allowed
  end

  def test_paths_that_cannot_be_matched_safely_are_rejected
    hosts = LittleGhost::Network::HostPolicy.new { host("api.example.com") { paths "/v1/*" } }

    [
      "/v1/../admin",
      "/v1/%2e%2e/admin",
      "/v1/%252e%252e/admin",
      "/v1/%25252525252e/admin",
      "/v1/a\\b",
      "/v1/%00",
      "/v1/%ff",
      "/v1//answers",
      "/v1/answers/..;/admin",
      "v1/answers"
    ].each do |path|
      decision = hosts.authorize(request(path:))

      refute decision.allowed, path
      assert_equal 400, decision.status, path
    end
  end

  def test_requirements_must_all_pass
    leased = false
    hosts = LittleGhost::Network::HostPolicy.new do
      host "api.example.com" do
        require { leased }
        require { |request| request.method == "POST" }
      end
    end

    refute hosts.authorize(request(method: "POST")).allowed
    leased = true
    assert hosts.authorize(request(method: "POST")).allowed
    refute hosts.authorize(request(method: "GET")).allowed
  end

  def test_inject_replaces_client_credentials_and_removes_the_rest
    hosts = LittleGhost::Network::HostPolicy.new do
      host "api.example.com" do
        inject { |request| {"x-api-key" => "key-for-#{request.host}"} }
      end
    end

    decision = hosts.authorize(request(headers: {
      "x-api-key" => "placeholder",
      "authorization" => "Bearer placeholder",
      "content-type" => "application/json",
      "x-trace" => "1"
    }))

    assert decision.allowed
    assert_equal({"x-api-key" => "key-for-api.example.com"}, decision.set_headers)
    assert_equal ["authorization"], decision.remove_headers
  end

  def test_pass_headers_removes_unlisted_client_headers_except_protocol_headers
    hosts = LittleGhost::Network::HostPolicy.new do
      host("api.example.com") { pass_headers "content-type", "accept" }
    end

    decision = hosts.authorize(request(headers: {
      "accept" => "*/*",
      "content-type" => "application/json",
      "content-length" => "2",
      "host" => "api.example.com",
      "x-envoy-internal" => "true",
      "x-request-id" => "abc",
      "x-trace" => "1",
      "x-forwarded-user" => "admin",
      "cookie" => "session=value"
    }))

    assert decision.allowed
    assert_equal %w[cookie x-forwarded-user x-trace], decision.remove_headers.sort
    assert_equal :all, hosts.forward_headers
  end

  def test_method_restrictions_remove_method_override_headers
    hosts = LittleGhost::Network::HostPolicy.new do
      host("api.example.com") { methods :get }
      host("open.example.com") {}
    end
    headers = {"x-http-method-override" => "DELETE"}

    assert_equal ["x-http-method-override"], hosts.authorize(request(headers:)).remove_headers
    assert_empty hosts.authorize(request(host: "open.example.com", headers:)).remove_headers
  end

  def test_policy_derives_gateway_settings
    hosts = LittleGhost::Network::HostPolicy.new do
      host "api.example.com" do
        inject("x-api-key", "x-client-version") { {"x-api-key" => "key", "x-client-version" => "2"} }
        timeout 0
      end
      host("downloads.example.com") { timeout 120.5 }
      default { methods :get }
    end

    assert_equal %w[api.example.com downloads.example.com], hosts.hosts
    assert_equal({"api.example.com" => 0, "downloads.example.com" => 120.5}, hosts.timeouts)
    assert_equal %w[x-api-key x-client-version], hosts.mutation_headers
    assert_equal [], hosts.forward_headers

    policy = hosts.network_policy(
      allow: ["downloads.example.com:443"],
      facades: [{name: :answers, upstream: "api.example.com", port: 3130}]
    )

    assert_equal :http, policy.inspection
    assert_equal ["downloads.example.com:443"], policy.allow
    assert_equal hosts.authorizer, policy.authorizer
    assert_equal %w[x-api-key x-client-version], policy.mutation_headers
    assert_equal "api.example.com:443", policy.facades.first.upstream
    assert_equal :connect, hosts.network_policy(facades: policy.facades).inspection
  end

  def test_injection_failures_fail_closed_without_disclosing_values
    hosts = LittleGhost::Network::HostPolicy.new do
      host("api.example.com") { inject { {"x-api-key" => "secret-value", "x-other" => "secret-value"} } }
      host("empty.example.com") { inject { {"x-api-key" => ""} } }
    end

    undeclared = assert_raises(LittleGhost::PolicyError) { hosts.authorize(request) }
    empty = assert_raises(LittleGhost::PolicyError) { hosts.authorize(request(host: "empty.example.com")) }

    refute_includes undeclared.message, "secret-value"
    assert_includes empty.message, "x-api-key"
  end

  def test_authorizer_is_compatible_with_network_policies_and_the_authorizer_server
    hosts = LittleGhost::Network::HostPolicy.new { host("api.example.com") {} }

    assert hosts.authorizer.call(request: request).allowed
    assert_predicate hosts, :frozen?
  end

  def test_invalid_declarations_are_rejected
    assert_raises(LittleGhost::PolicyError) { LittleGhost::Network::HostPolicy.new }
    assert_raises(LittleGhost::PolicyError) { LittleGhost::Network::HostPolicy.new {} }
    assert_raises(LittleGhost::PolicyError) { LittleGhost::Network::HostPolicy.new { host("*.example.com") {} } }
    assert_raises(LittleGhost::PolicyError) { LittleGhost::Network::HostPolicy.new { host("127.0.0.1") {} } }
    assert_raises(LittleGhost::PolicyError) do
      LittleGhost::Network::HostPolicy.new do
        host("api.example.com") {}
        host("API.example.com") {}
      end
    end
    assert_raises(LittleGhost::PolicyError) { LittleGhost::Network::HostPolicy.new { host("api.example.com") { paths "v1" } } }
    assert_raises(LittleGhost::PolicyError) { LittleGhost::Network::HostPolicy.new { host("api.example.com") { paths "/v1/*/x" } } }
    assert_raises(LittleGhost::PolicyError) do
      LittleGhost::Network::HostPolicy.new { host("api.example.com") { pass_headers "authorization" } }
    end
    assert_raises(LittleGhost::PolicyError) { LittleGhost::Network::HostPolicy.new { host("api.example.com") { timeout(-1) } } }
    assert_raises(LittleGhost::PolicyError) { LittleGhost::Network::HostPolicy.new { host("api.example.com") { methods "get /" } } }
  end
end
