# frozen_string_literal: true

require "test_helper"

class LMStudioCatalogSourceTest < Minitest::Test
  class FakeHTTPClient
    attr_reader :requests
    attr_writer :response

    def initialize(response)
      @response = response
      @requests = []
    end

    def request(**request)
      requests << request
      @response
    end
  end

  def test_refresh_normalizes_llms_embeddings_and_loaded_instances
    client = FakeHTTPClient.new(catalog_response)
    catalog = LittleGhost::Models::Catalog.new(sources: [source(client:)])

    result = catalog.refresh!
    llm = catalog.details("desktop:google/gemma-test")
    embedding = catalog.details("desktop:nomic-embed")

    assert_empty result.fetch(:errors)
    assert_equal %w[desktop:google/gemma-test desktop:nomic-embed], result.fetch(:updated)
    assert_equal "llm", llm[:model_type]
    assert_equal 4096, llm.context_window
    assert_equal 262_144, llm[:max_context_length]
    assert_equal %w[text image], llm.input_modalities
    assert_equal %w[structured_outputs temperature tools tool_choice reasoning], llm.supported_parameters
    assert_equal 2, llm[:loaded_instances].length
    assert_equal "Q4_K_M", llm[:quantization].fetch(:name)
    assert_equal({allowed_options: %w[off on], default: "on"}, llm[:reasoning])
    assert_equal "embedding", embedding[:model_type]
    assert_equal false, embedding[:loaded]
    assert_nil embedding.context_window
    assert_equal [], embedding.supported_parameters
    assert_equal "2026-08-26T12:00:00Z", llm.observed_at

    request = client.requests.fetch(0)
    assert_equal "http://localhost:1234/api/v1/models", request.fetch(:uri).to_s
    assert_equal "Bearer secret", request.fetch(:headers).fetch("Authorization")
    assert_equal true, request.fetch(:allow_insecure_http)
  end

  def test_target_refresh_filters_models_and_ignores_other_connections
    client = FakeHTTPClient.new(catalog_response)
    source = source(client:)

    records = source.refresh(target: LittleGhost::Models::Target.parse("desktop:nomic-embed"))
    ignored = source.refresh(target: LittleGhost::Models::Target.parse("other:nomic-embed"))

    assert_equal ["desktop:nomic-embed"], records.keys
    assert_empty ignored
    assert_equal 1, client.requests.length
  end

  def test_refresh_clears_loaded_context_and_marks_removed_models_unavailable
    client = FakeHTTPClient.new(catalog_response)
    catalog = LittleGhost::Models::Catalog.new(sources: [source(client:)])

    catalog.refresh!
    response = JSON.parse(catalog_response)
    response.fetch("models").first["loaded_instances"] = []
    client.response = JSON.generate(response)

    catalog.refresh!
    unloaded = catalog.details("desktop:google/gemma-test")

    assert_equal false, unloaded[:loaded]
    assert_empty unloaded[:loaded_instances]
    assert_nil unloaded.context_window

    client.response = JSON.generate(models: [])
    result = catalog.refresh!
    removed = catalog.details("desktop:google/gemma-test")

    assert_includes result.fetch(:updated), "desktop:google/gemma-test"
    assert_equal false, removed[:available]
    assert_equal false, removed[:loaded]
    assert_empty removed[:loaded_instances]
    assert_nil removed.context_window
  end

  def test_target_refresh_marks_a_missing_model_unavailable
    client = FakeHTTPClient.new(catalog_response)
    catalog = LittleGhost::Models::Catalog.new(sources: [source(client:)])
    target = "desktop:google/gemma-test"

    catalog.refresh!(target:)
    client.response = JSON.generate(models: [])

    result = catalog.refresh!(target:)

    assert_equal [target], result.fetch(:updated)
    assert_empty result.fetch(:errors)
    assert_equal false, catalog.details(target)[:available]
    assert_nil catalog.details(target).context_window
  end

  def test_target_refresh_ignores_malformed_unrelated_models
    response = JSON.parse(catalog_response)
    response.fetch("models") << {"key" => "broken", "type" => "unsupported"}
    client = FakeHTTPClient.new(JSON.generate(response))

    records = source(client:).refresh(target: LittleGhost::Models::Target.parse("desktop:google/gemma-test"))

    assert_equal ["desktop:google/gemma-test"], records.keys
    assert_equal true, records.fetch("desktop:google/gemma-test").fetch(:available)
    assert_equal "Gemma Test", records.fetch("desktop:google/gemma-test").fetch(:display_name)
  end

  def test_invalid_catalog_raises_a_content_safe_provider_error
    sentinel = "SENSITIVE_PROVIDER_FRAGMENT"
    client = FakeHTTPClient.new(%({"models":[{"key":"#{sentinel}"}]}))

    error = assert_raises(LittleGhost::ProviderError) { source(client:).refresh }

    assert_equal "LM Studio returned an invalid model catalog", error.message
    refute_includes error.message, sentinel
  end

  private

  def source(client:)
    LittleGhost::Providers::LMStudio::CatalogSource.new(
      provider: "desktop",
      credential_resolver: -> {
        {
          "api_key" => "secret",
          "base_url" => "http://localhost:1234/v1/",
          "allow_insecure_http" => true
        }
      },
      clock: -> { Time.utc(2026, 8, 26, 12) },
      http_client: client
    )
  end

  def catalog_response
    JSON.generate(models: [
      {
        type: "llm",
        publisher: "google",
        key: "google/gemma-test",
        display_name: "Gemma Test",
        architecture: "gemma",
        quantization: {name: "Q4_K_M", bits_per_weight: 4},
        size_bytes: 17_000,
        params_string: "4B",
        loaded_instances: [
          {id: "gemma-a", config: {context_length: 8192, parallel: 2}},
          {id: "gemma-b", config: {context_length: 4096, flash_attention: true}}
        ],
        max_context_length: 262_144,
        format: "gguf",
        capabilities: {
          vision: true,
          trained_for_tool_use: true,
          reasoning: {allowed_options: %w[off on], default: "on"}
        },
        variants: ["google/gemma-test@q4_k_m"],
        selected_variant: "google/gemma-test@q4_k_m"
      },
      {
        type: "embedding",
        publisher: "nomic",
        key: "nomic-embed",
        display_name: "Nomic Embed",
        quantization: nil,
        size_bytes: 500,
        params_string: nil,
        loaded_instances: [],
        max_context_length: 2048,
        format: "gguf"
      }
    ])
  end
end
