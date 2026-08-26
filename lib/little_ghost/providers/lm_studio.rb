# frozen_string_literal: true

require_relative "openai_compatible"
require_relative "lm_studio/catalog_source"

module LittleGhost
  module Providers
    # LMStudio connects LittleGhost to an LM Studio server through its
    # OpenAI-compatible API. Generation, embeddings, retries, cancellation, and
    # deadlines use the shared compatible transport.
    #
    #   provider = LittleGhost::Providers::LMStudio.new(
    #     model: "google/gemma-3-4b",
    #     allow_insecure_http: true
    #   )
    #
    # The default endpoint is LM Studio's local server. Pass +api_key+ when the
    # server requires authentication. Plain HTTP remains an explicit opt-in.
    class LMStudio < OpenAICompatible
      # Default endpoint for LM Studio's OpenAI-compatible API.
      DEFAULT_BASE_URL = "http://localhost:1234/v1/"
      DEFAULT_API_KEY = "lm-studio" # :nodoc:

      # Configures an LM Studio client. All OpenAICompatible options apply.
      # The placeholder API key is suitable only when LM Studio authentication
      # is disabled.
      def initialize(api_key: DEFAULT_API_KEY, base_url: DEFAULT_BASE_URL, **arguments)
        super
      end

      # Uses refreshed LM Studio model metadata when available. Before a
      # catalog refresh, the compatible endpoint retains its permissive
      # capability contract.
      def capabilities(metadata: {})
        parameters = metadata[:supported_parameters] || metadata["supported_parameters"]
        return super unless parameters.is_a?(Array)

        values = parameters.map(&:to_s)
        ModelCapabilities.new(
          native_structured_output: values.include?("structured_outputs"),
          tools: values.include?("tools"),
          tool_choice: values.include?("tool_choice"),
          supported_parameters: values
        )
      end

      private

      def embedding_provider_name = "LM Studio"
    end
  end
end
