# frozen_string_literal: true

class CodingReporterAgent < LittleGhost::Agent
  model "ollama:qwen3.8"
  system_prompt "Briefly report what changed and which checks passed. Do not claim work that the review did not verify."
end
