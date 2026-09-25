# frozen_string_literal: true

require "json"
require "uri"

module LittleGhost
  module Providers
    module DecisionHTTP # :nodoc:
      private

      def send_decision(request, endpoint:, model:, api_key:)
        request.cancellation_token&.raise_if_cancelled!
        base_url = @decision_base_url.to_s
        base_url += "/" unless base_url.end_with?("/")
        payload = {
          model:,
          state: request.state,
          questions: request.questions.to_h do |question|
            id = question.fetch(:id)
            fields = question.except(:id)
            [id, fields]
          end
        }
        body = (@decision_transport || @transport).request(
          uri: URI.join(base_url, endpoint),
          method: :post,
          headers: {"Authorization" => "Bearer #{api_key}", "Content-Type" => "application/json"},
          body: JSON.generate(payload),
          cancellation_token: request.cancellation_token,
          deadline: request.deadline,
          label: "Decision request"
        )
        data = JSON.parse(body)
        answers = data.fetch("answers")
        expected_ids = request.questions.map { |question| question.fetch(:id) }.sort
        unless answers.is_a?(Hash) && answers.keys.sort == expected_ids
          raise ProtocolError, "Decision provider returned unexpected or incomplete answers"
        end
        normalized = answers.to_h do |id, answer|
          question = request.questions.find { |item| item.fetch(:id) == id }
          [id, normalize_answer(question, answer)]
        end
        usage_data = data["usage"] || {}
        DecisionResult.new(
          answers: normalized,
          usage: Usage.new(input_tokens: usage_data["input_tokens"], output_tokens: usage_data["output_tokens"]),
          metadata: {model: data["model"], id: data["id"], provider: data["provider"], cost: data["cost"]}
        )
      rescue JSON::ParserError, KeyError, TypeError => error
        raise ProtocolError, "Decision provider returned an invalid response (#{error.class})"
      end

      def normalize_answer(question, raw)
        raise ProtocolError, "Decision provider returned an invalid answer" unless raw.is_a?(Hash)

        field = question.fetch(:type).to_s
        raise ProtocolError, "Decision provider returned an answer with the wrong type" unless raw["type"] == field

        value = raw[field]
        valid = case field
        when "choice"
          criteria = question[:criteria]
          options = criteria.is_a?(Hash) ? criteria.keys : Array(criteria)
          value.is_a?(String) && options.any? { |item| item.to_s == value }
        when "noul" then value.is_a?(Numeric) && value.finite? && value.between?(0, 1)
        when "score" then value.is_a?(Numeric) && value.finite?
        end
        raise ProtocolError, "Decision provider returned an invalid #{field} answer" unless valid

        if %w[choice score].include?(field)
          confidence = raw["confidence"]
          probabilities = raw["probabilities"]
          unless confidence.is_a?(Numeric) && confidence.finite? && confidence.between?(0, 1) &&
              probabilities.is_a?(Hash) && probabilities.values.all? { |probability| probability.is_a?(Numeric) && probability.finite? && probability.between?(0, 1) }
            raise ProtocolError, "Decision provider returned invalid #{field} probabilities"
          end
          raise ProtocolError, "Decision provider returned an invalid score legend" if field == "score" && !raw["legend"].is_a?(Hash)
        end

        DecisionAnswer.new(
          type: question.fetch(:type),
          value:,
          probabilities: raw["probabilities"] || {},
          confidence: raw["confidence"],
          legend: raw["legend"]
        )
      end
    end
  end
end
