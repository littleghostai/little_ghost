# frozen_string_literal: true

class CodingWorkerAgent < LittleGhost::Agent
  model "ollama:qwen3.8"
  tools ProjectTools
end
