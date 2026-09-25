# frozen_string_literal: true

require "bundler/setup"
require "little_ghost"

LittleGhost.configure do |config|
  config.providers = {
    typesafe: {
      adapter: :typesafe,
      api_key: ENV.fetch("TYPESAFE_API_KEY")
    }
  }
end

class BuildTriage < LittleGhost::Decision
  model "typesafe:jev-latest"
  choice :route, instructions: "Choose the next action for this failed build.",
    criteria: %w[retry inspect escalate]
  noul :urgent,
    instructions: "Does this need attention before the next scheduled build?"
end

state = {
  status: "failed",
  consecutive_failures: 3,
  last_error: "dependency download timed out"
}
result = BuildTriage.ask(state)

puts "Route: #{result.answers.fetch("route").choice}"
puts "Urgent probability: #{result.answers.fetch("urgent").noul}"
