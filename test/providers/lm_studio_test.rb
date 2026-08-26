# frozen_string_literal: true

require "test_helper"

class LMStudioTest < Minitest::Test
  class CaptureTransport
    attr_reader :request

    def stream(**request)
      @request = request
      yield "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
    end
  end

  def test_requires_explicit_opt_in_for_the_default_http_endpoint
    error = assert_raises(LittleGhost::ConfigurationError) do
      LittleGhost::Providers::LMStudio.new(model: "local-model")
    end

    assert_includes error.message, "allow_insecure_http"
  end

  def test_uses_the_local_responses_endpoint_and_placeholder_key_by_default
    transport = CaptureTransport.new
    provider = LittleGhost::Providers::LMStudio.new(model: "local-model", transport:)

    provider.stream(LittleGhost::ModelRequest.new(messages: [{role: :user, content: "Hello"}])).to_a

    assert_equal :responses, provider.api
    assert_equal "responses", transport.request.fetch(:path)
    assert_equal "Bearer lm-studio", transport.request.fetch(:headers).fetch("Authorization")
  end

  def test_registry_builds_lm_studio_with_a_configured_token
    transport = CaptureTransport.new

    provider = LittleGhost::ProviderRegistry.new.build(
      adapter: :lm_studio,
      model: "local-model",
      configuration: {api_key: "secret", transport:}
    )
    provider.stream(LittleGhost::ModelRequest.new(messages: [])).to_a

    assert_instance_of LittleGhost::Providers::LMStudio, provider
    assert_equal "Bearer secret", transport.request.fetch(:headers).fetch("Authorization")
  end

  def test_uses_precise_refreshed_capabilities_with_a_permissive_fallback
    provider = LittleGhost::Providers::LMStudio.new(model: "local-model", transport: CaptureTransport.new)

    fallback = provider.capabilities
    refreshed = provider.capabilities(
      metadata: {supported_parameters: %w[structured_outputs tools tool_choice reasoning]}
    )

    assert fallback.native_structured_output?
    assert fallback.tools?
    assert fallback.tool_choice?
    assert refreshed.native_structured_output?
    assert refreshed.tools?
    assert refreshed.tool_choice?
    assert refreshed.supports_parameter?(:reasoning)
    refute refreshed.supports_parameter?(:temperature)
  end
end
