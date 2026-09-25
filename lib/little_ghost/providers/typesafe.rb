# frozen_string_literal: true

require_relative "decision_http"

module LittleGhost
  module Providers
    # Direct TypeSafe Jev decision API connection.
    class Typesafe < Base
      include DecisionHTTP

      # The TypeSafe API base URL.
      DEFAULT_BASE_URL = "https://api.typesafe.ai/v1/"

      # Configures a direct Jev connection. Pass +transport+ to supply a custom
      # bounded HTTP client.
      def initialize(api_key:, model:, base_url: DEFAULT_BASE_URL, transport: nil,
        open_timeout: 10, read_timeout: 120, max_response_bytes: Support::HTTPClient::DEFAULT_MAX_RESPONSE_BYTES)
        @model = model
        @decision_api_key = api_key
        @decision_base_url = base_url
        @decision_transport = transport || Support::HTTPClient.new(
          base_url:, open_timeout:, read_timeout:, max_response_bytes:
        )
      end

      def decide(request)
        send_decision(request, endpoint: "systemone", model: @model, api_key: @decision_api_key)
      end

      def stream(_request)
        raise UnsupportedModelOperationError, "TypeSafe supports decisions only"
      end
    end
  end
end
