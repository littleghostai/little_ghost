# frozen_string_literal: true

module LittleGhost
  # Provider-neutral inputs for one typed decision operation.
  #
  # State and questions are trusted application inputs. Question ids are
  # normalized to strings and must be unique.
  DecisionRequest = Data.define(:state, :questions, :cancellation_token, :deadline) do
    def initialize(state:, questions:, cancellation_token: Support::CancellationToken.new, deadline: nil)
      unless state.is_a?(String) || state.is_a?(Hash) || state.is_a?(Array)
        raise ArgumentError, "decision state must be a string, mapping, or array"
      end
      entries = questions.is_a?(Hash) ? questions.map { |id, value| value.to_h.merge(id:) } : Array(questions)
      normalized = entries.map do |question|
        raise ArgumentError, "decision questions must be mappings" unless question.is_a?(Hash)

        item = question.to_h.transform_keys(&:to_sym)
        type = item[:type]&.to_sym
        raise ArgumentError, "decision question type must be :choice, :noul, or :score" unless %i[choice noul score].include?(type)
        item[:type] = type
        item[:id] = item[:id].to_s
        raise ArgumentError, "decision question id is required" if item[:id].empty?
        unless item[:instructions].is_a?(String) || item[:instructions].is_a?(Hash) || item[:instructions].is_a?(Array)
          raise ArgumentError, "decision question instructions are required"
        end
        if type == :choice
          criteria = item[:criteria]
          raise ArgumentError, "choice criteria must be a mapping or array" unless criteria.is_a?(Hash) || criteria.is_a?(Array)
          raise ArgumentError, "choice criteria must contain between one and 255 options" unless (1..255).cover?(criteria.length)
          item[:criteria] = criteria.to_h { |label| [label.to_s, nil] } if criteria.is_a?(Array)
        elsif type == :score
          criteria = item[:criteria]
          raise ArgumentError, "score criteria must contain between two and ten levels" unless criteria.is_a?(Array) && (2..10).cover?(criteria.length)
        elsif item[:criteria] && !item[:criteria].is_a?(Hash)
          raise ArgumentError, "noul criteria must be a mapping"
        end
        item.freeze
      end
      raise ArgumentError, "at least one decision question is required" if normalized.empty?
      ids = normalized.map { |item| item[:id] }
      raise ArgumentError, "decision question ids must be unique" unless ids.uniq.length == ids.length

      super(state:, questions: normalized.freeze, cancellation_token:, deadline:)
    end
  end

  # A validated, provider-neutral answer to a typed decision question.
  #
  # +value+ contains the choice label, a numeric noul probability from 0 to 1,
  # or a numeric score according to +type+. The type-specific readers return
  # +nil+ for other answer types.
  DecisionAnswer = Data.define(:type, :value, :probabilities, :confidence, :legend) do
    def choice
      value if type == :choice
    end

    def noul
      value if type == :noul
    end

    def score
      value if type == :score
    end
  end

  # Results returned by a decision model, keyed by question id.
  #
  # Provider metadata contains bounded response identifiers and model details;
  # it does not include request state or question text.
  DecisionResult = Data.define(:answers, :usage, :metadata) do
    def initialize(answers:, usage: Usage.new, metadata: {})
      super(answers: answers.to_h.freeze, usage:, metadata: metadata.to_h.freeze)
    end
  end

  # Declarative collection of typed questions for one decision request.
  #
  # Subclass and declare a model plus one or more typed questions, then call
  # +.ask(state)+ or instantiate the class and call +#ask(state)+.
  class Decision
    class << self
      def inherited(child) # :nodoc:
        child.instance_variable_set(:@questions, questions.map(&:dup))
        child.instance_variable_set(:@model, model)
      end

      # Selects a direct target or configured model role for this decision.
      def model(value = :__read__)
        return @model if value == :__read__

        @model = value
      end

      # Declares a choice question. Criteria may be an array of labels or a
      # mapping from labels to their descriptions.
      def choice(id, instructions:, criteria:, **options) = add_question(:choice, id, instructions:, criteria:, **options)
      # Declares a yes/no (noul) question, optionally with decision criteria.
      def noul(id, instructions:, criteria: nil, **options) = add_question(:noul, id, instructions:, criteria:, **options)
      # Declares a score question with ordered scoring criteria.
      def score(id, instructions:, criteria:, **options) = add_question(:score, id, instructions:, criteria:, **options)

      # Runs all declared questions against +state+.
      def ask(state, **options)
        LittleGhost.decide(model: model || raise(ConfigurationError, "Decision model is required"), state:, questions:, **options)
      end

      # Returns the immutable question declarations for this class.
      def questions = (@questions ||= []).map(&:dup).freeze

      private

      def add_question(type, id, **attributes)
        raise ArgumentError, "question id is required" if id.to_s.empty?
        raise ArgumentError, "duplicate decision question id: #{id}" if questions.any? { |question| question[:id] == id.to_s }

        (@questions ||= []) << attributes.merge(type:, id: id.to_s).freeze
      end
    end

    # Binds this decision instance to a Runtime.
    def initialize(runtime: LittleGhost.runtime)
      @runtime = runtime
    end

    # Runs this decision's questions against +state+.
    def ask(state, **options)
      @runtime.decide(model: self.class.model || raise(ConfigurationError, "Decision model is required"), state:, questions: self.class.questions, **options)
    end
  end
end
