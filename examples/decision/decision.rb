# frozen_string_literal: true

require "bundler/setup"
require "json"
require "little_ghost"

LittleGhost.configure do |config|
  config.providers = {
    primary: {
      adapter: :openrouter,
      api_key: ENV.fetch("OPENROUTER_API_KEY"),
      decision_api: :decisions
    }
  }
end

class BuildTriage < LittleGhost::Decision
  model "primary:~typesafe/jev-latest"
  choice :route, instructions: "Choose the next action for this failed build.",
    criteria: {
      retry: "The failure looks temporary and the build should be run again.",
      inspect: "The cause needs investigation before trying again.",
      escalate: "The failure needs attention from the team responsible for the system."
    }
  noul :urgent,
    instructions: "Does this need attention before the next scheduled build?"
  score :impact,
    instructions: "How much does this failure affect the release?",
    criteria: [
      "Minor interruption with a straightforward workaround.",
      "Important delay that requires investigation.",
      "Release-blocking failure with no safe workaround."
    ]
end

state = {
  status: "failed",
  consecutive_failures: 3,
  last_error: "dependency download timed out"
}
result = BuildTriage.ask(state)
answers = result.answers.to_h do |id, answer|
  details = case answer.type
  when :choice
    {type: answer.type, choice: answer.choice, probabilities: answer.probabilities, confidence: answer.confidence}
  when :noul
    {type: answer.type, noul: answer.noul}
  when :score
    {
      type: answer.type,
      score: answer.score,
      legend: answer.legend,
      probabilities: answer.probabilities,
      confidence: answer.confidence
    }
  end
  [id, details]
end

puts JSON.pretty_generate(answers:, usage: result.usage.to_h, metadata: result.metadata)
