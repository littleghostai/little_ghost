# frozen_string_literal: true

require "bundler/setup"
require "little_ghost"

LittleGhost.configure do |config|
  config.providers = {
    ollama: {
      adapter: :openai_compatible,
      base_url: "http://localhost:11434/v1/",
      api_key: "ollama",
      api: :responses,
      allow_insecure_http: true
    }
  }
end

class CustomerSupportAgent < LittleGhost::Agent
  model "ollama:qwen3.8"
  system_prompt "Answer customer questions clearly and concisely."
end

run = CustomerSupportAgent.ask("Draft a friendly greeting for a customer.")
if run.completed?
  puts run.response
else
  warn "Agent failed (#{run.outcome}): #{run.error&.full_message || "unknown error"}"
  exit 1
end
