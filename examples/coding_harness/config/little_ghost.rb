# frozen_string_literal: true

LittleGhost.configure do |config|
  config.service_name "coding_harness"
  config.providers = {
    ollama: {
      adapter: :openai_compatible,
      base_url: "http://localhost:11434/v1/",
      api_key: "ollama",
      api: :responses,
      allow_insecure_http: true
    }
  }
  config.sandbox = {
    provider: :native,
    files: {root: :read_write}
  }
end
