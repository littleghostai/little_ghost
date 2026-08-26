# frozen_string_literal: true

require_relative "openai_compatible"

module LittleGhost
  module Providers
    # OpenAI connects LittleGhost features to OpenAI models for generation and
    # embeddings. Generation uses the Responses API by default and supports
    # streaming, Tools, and structured results.
    #
    #   provider = LittleGhost::Providers::OpenAI.new(
    #     api_key: ENV.fetch("OPENAI_API_KEY"),
    #     model: ENV.fetch("OPENAI_MODEL")
    #   )
    #
    # Supply <tt>api: :chat_completions</tt> only when a model or integration requires
    # the Chat Completions wire API.
    class OpenAI < OpenAICompatible
      # The OpenAI API endpoint used when +base_url+ is omitted.
      DEFAULT_BASE_URL = "https://api.openai.com/v1/"
      DEFAULT_MAX_EMBEDDING_RESPONSE_BYTES = OpenAICompatible::DEFAULT_MAX_EMBEDDING_RESPONSE_BYTES # :nodoc:

      # Uses the official OpenAI API base URL by default.
      def initialize(base_url: DEFAULT_BASE_URL, **arguments) = super

      private

      def embedding_provider_name = "OpenAI"
    end
  end
end
