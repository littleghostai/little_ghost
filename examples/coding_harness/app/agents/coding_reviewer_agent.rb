# frozen_string_literal: true

class CodingReviewerAgent < LittleGhost::Agent
  model "ollama:qwen3.8"
  tools ProjectReviewTools
  result_schema(
    {
      type: "object",
      properties: {
        complete: {type: "boolean"},
        summary: {type: "string"},
        feedback: {type: "string"}
      },
      required: %w[complete summary feedback],
      additionalProperties: false
    },
    name: "coding_review"
  )
end
