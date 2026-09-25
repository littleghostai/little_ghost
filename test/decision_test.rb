# frozen_string_literal: true

require "test_helper"

class DecisionTest < Minitest::Test
  class Transport
    attr_reader :captured_request

    def initialize(response)
      @response = response
    end

    def request(**request)
      @captured_request = request
      @response
    end
  end

  def test_typesafe_posts_typed_questions_and_normalizes_answers
    transport = Transport.new(JSON.generate(
      model: "jev-latest",
      answers: {"fit" => {type: "choice", choice: "yes", probabilities: {yes: 0.9}, confidence: 0.9}},
      usage: {input_tokens: 12, output_tokens: 2}
    ))
    provider = LittleGhost::Providers::Typesafe.new(api_key: "secret", model: "jev-latest", transport:)
    request = LittleGhost::DecisionRequest.new(
      state: {candidate: "application"},
      questions: [{id: "fit", type: :choice, instructions: "Choose the outcome", criteria: %w[yes no]}]
    )

    result = provider.decide(request)

    assert_equal "https://api.typesafe.ai/v1/systemone", transport.captured_request[:uri].to_s
    assert_equal "Bearer secret", transport.captured_request[:headers]["Authorization"]
    payload = JSON.parse(transport.captured_request[:body])
    assert_equal "jev-latest", payload.fetch("model")
    assert_equal "application", payload.dig("state", "candidate")
    assert_equal "Choose the outcome", payload.dig("questions", "fit", "instructions")
    assert_equal({"yes" => nil, "no" => nil}, payload.dig("questions", "fit", "criteria"))
    assert_equal "yes", result.answers.fetch("fit").choice
    assert_equal 12, result.usage.input_tokens
  end

  def test_typesafe_preserves_custom_base_path_without_trailing_slash
    transport = Transport.new(JSON.generate(answers: {"present" => {type: "noul", noul: 0.0}}))
    provider = LittleGhost::Providers::Typesafe.new(
      api_key: "secret", model: "jev-latest", base_url: "https://typesafe.example/v1", transport:
    )

    provider.decide(LittleGhost::DecisionRequest.new(
      state: "state", questions: [{id: "present", type: :noul, instructions: "Is it present?"}]
    ))

    assert_equal "https://typesafe.example/v1/systemone", transport.captured_request[:uri].to_s
  end

  def test_openrouter_decision_routes
    [
      [:decisions, "https://openrouter.ai/api/alpha/decisions", "https://openrouter.ai/api/v1/"],
      [:system_one, "https://openrouter.ai/api/v1/systemone", "https://openrouter.ai/api/v1/"],
      [:decisions, "https://openrouter.example/api/alpha/decisions", "https://openrouter.example/api/v1"],
      [:system_one, "https://openrouter.example/api/v1/systemone", "https://openrouter.example/api/v1"]
    ].each do |route, endpoint, base_url|
      transport = Transport.new(JSON.generate(model: "jev", answers: {"present" => {type: "noul", noul: 0.0}}))
      provider = LittleGhost::Providers::OpenRouter.new(
        api_key: "secret", model: "~typesafe/jev-latest", decision_api: route, transport:,
        base_url:
      )
      provider.decide(LittleGhost::DecisionRequest.new(
        state: "candidate profile", questions: [{id: "present", type: :noul, instructions: "Is this present?"}]
      ))
      assert_equal endpoint, transport.captured_request[:uri].to_s
    end
  end

  def test_rejects_answer_outside_choice_criteria
    provider = LittleGhost::Providers::Typesafe.new(
      api_key: "secret", model: "jev-latest",
      transport: Transport.new(JSON.generate(answers: {"pick" => {type: "choice", choice: "maybe"}}))
    )
    request = LittleGhost::DecisionRequest.new(
      state: "state", questions: [{id: "pick", type: :choice, instructions: "Pick", criteria: %w[yes no]}]
    )

    assert_raises(LittleGhost::ProtocolError) { provider.decide(request) }
  end

  def test_keeps_numeric_noul_probability_and_weighted_score
    provider = LittleGhost::Providers::Typesafe.new(
      api_key: "secret",
      model: "jev-latest",
      transport: Transport.new(JSON.generate(answers: {
        "urgent" => {type: "noul", noul: 0.95},
        "quality" => {type: "score", score: 1.05, legend: {"0" => "low", "1" => "high"},
                      probabilities: {"0" => 0.1, "1" => 0.9}, confidence: 0.9}
      }))
    )
    result = provider.decide(LittleGhost::DecisionRequest.new(
      state: "state",
      questions: [
        {id: "urgent", type: :noul, instructions: "Is it urgent?"},
        {id: "quality", type: :score, instructions: "Rate it", criteria: %w[low high]}
      ]
    ))

    assert_in_delta 0.95, result.answers.fetch("urgent").noul
    assert_in_delta 1.05, result.answers.fetch("quality").score
  end

  def test_rejects_unrequested_answer_ids_as_a_protocol_error
    provider = LittleGhost::Providers::Typesafe.new(
      api_key: "secret",
      model: "jev-latest",
      transport: Transport.new(JSON.generate(answers: {
        "present" => {type: "noul", noul: 0.0},
        "unexpected" => {type: "noul", noul: 0.0}
      }))
    )

    error = assert_raises(LittleGhost::ProtocolError) do
      provider.decide(LittleGhost::DecisionRequest.new(
        state: "state", questions: [{id: "present", type: :noul, instructions: "Is it present?"}]
      ))
    end

    assert_equal "Decision provider returned unexpected or incomplete answers", error.message
  end

  def test_decision_class_declares_mixed_typed_questions
    decision_class = Class.new(LittleGhost::Decision) do
      model "typesafe:jev-latest"
      choice :route, instructions: "Choose a route", criteria: %w[keep review]
      noul :urgent, instructions: "Is this urgent?"
      score :quality, instructions: "Rate the quality", criteria: %w[accuracy usefulness]
    end

    assert_equal %i[choice noul score], decision_class.questions.map { |question| question[:type] }
    assert_equal %w[route urgent quality], decision_class.questions.map { |question| question[:id] }
    assert_raises(ArgumentError) do
      Class.new(LittleGhost::Decision) do
        choice :x, instructions: "Pick one", criteria: %w[a b]
        choice :x, instructions: "Pick one", criteria: %w[a b]
      end
    end
  end
end
