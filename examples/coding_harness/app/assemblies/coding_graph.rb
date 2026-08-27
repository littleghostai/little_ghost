# frozen_string_literal: true

class CodingGraph < LittleGhost::Graph
  node :plan, CodingPlannerAgent
  node :execute, CodingWorkerAgent
  node :confirm, CodingReviewerAgent
  node :report, CodingReporterAgent

  start :plan
  edge :plan, :execute, input: lambda { |state|
    <<~PROMPT
      User request:
      #{state.input.text}

      Plan:
      #{state.previous_result.text}
    PROMPT
  }
  edge :execute, :confirm, input: lambda { |state|
    <<~PROMPT
      User request:
      #{state.input.text}

      Plan:
      #{state.result(:plan).text}

      Worker's report:
      #{state.previous_result.text}
    PROMPT
  }
  edge :confirm, :report, if: ->(state) { state.result(:confirm).output.fetch("complete") }, input: lambda { |state|
    review = state.previous_result.output
    <<~PROMPT
      User request:
      #{state.input.text}

      Verified result:
      #{review.fetch("summary")}
    PROMPT
  }
  edge :confirm, :execute, input: lambda { |state|
    review = state.previous_result.output
    <<~PROMPT
      User request:
      #{state.input.text}

      Original plan:
      #{state.result(:plan).text}

      Review feedback to address:
      #{review.fetch("feedback")}
    PROMPT
  }
  finish :report
  max_steps 10
end
