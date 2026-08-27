# frozen_string_literal: true

class CodingPlannerAgent < LittleGhost::Agent
  model "ollama:qwen3.8"
  tools ProjectReadTools
end
