# frozen_string_literal: true

module LittleGhost
  # Provider-neutral inputs for one typed decision operation.
  #
  # State and questions are trusted application inputs. Question ids are
  # normalized to strings and must be unique.
  DecisionRequest = Data.define(:state, :questions, :cancellation_token, :deadline) do # :nodoc:
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
          if criteria.is_a?(Array)
            labels = criteria.map(&:to_s)
            raise ArgumentError, "choice criteria labels must be unique" unless labels.uniq.length == labels.length

            item[:criteria] = labels.to_h { |label| [label, nil] }
          else
            labels = criteria.keys.map(&:to_s)
            raise ArgumentError, "choice criteria labels must be unique" unless labels.uniq.length == labels.length

            valid_criteria = criteria.all? do |label, description|
              valid_label = label.is_a?(String) || label.is_a?(Symbol)
              valid_description = description.nil? || description.is_a?(String) ||
                description.is_a?(Hash) || description.is_a?(Array)
              valid_label && valid_description
            end
            raise ArgumentError, "choice criteria must map labels to descriptions" unless valid_criteria
          end
        elsif type == :score
          criteria = item[:criteria]
          raise ArgumentError, "score criteria must contain between two and ten levels" unless criteria.is_a?(Array) && (2..10).cover?(criteria.length)
          valid_levels = criteria.all? { |level| level.is_a?(String) || level.is_a?(Hash) || level.is_a?(Array) }
          raise ArgumentError, "score criteria must be descriptions" unless valid_levels
        elsif !item[:criteria].nil?
          criteria = item[:criteria]
          valid_criteria = criteria.is_a?(Hash) && criteria.all? do |key, description|
            %w[true false].include?(key.to_s) &&
              (description.is_a?(String) || description.is_a?(Hash) || description.is_a?(Array))
          end
          raise ArgumentError, "noul criteria must map true or false to descriptions" unless valid_criteria
        end
        item.freeze
      end
      raise ArgumentError, "at least one decision question is required" if normalized.empty?
      ids = normalized.map { |item| item[:id] }
      raise ArgumentError, "decision question ids must be unique" unless ids.uniq.length == ids.length

      super(state:, questions: normalized.freeze, cancellation_token:, deadline:)
    end
  end

  # Carries the state, questions, and request controls passed to a decision
  # provider.
  class DecisionRequest < Data # :doc:
    ##
    # :attr_reader: state
    # Application state evaluated by the provider.

    ##
    # :attr_reader: questions
    # Frozen question declarations, each with a string +id+.

    ##
    # :attr_reader: cancellation_token
    # Token the provider checks while the request runs.

    ##
    # :attr_reader: deadline
    # Optional request deadline passed to the provider.

    ##
    # :singleton-method: new
    # :call-seq:
    #   new(state:, questions:, cancellation_token: Support::CancellationToken.new, deadline: nil) -> DecisionRequest
    #
    # Validates and freezes question declarations before a provider request.
  end

  # A validated, provider-neutral answer to a typed decision question.
  #
  # +value+ contains the choice label, a numeric noul probability from 0 to 1,
  # or a numeric score according to +type+. The type-specific readers return
  # +nil+ for other answer types.
  DecisionAnswer = Data.define(:type, :value, :probabilities, :confidence, :legend) do # :nodoc:
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

  # One typed answer returned by a decision provider.
  class DecisionAnswer < Data # :doc:
    ##
    # :attr_reader: type
    # Answer type: +:choice+, +:noul+, or +:score+.

    ##
    # :attr_reader: value
    # Selected label, yes probability, or probability-weighted score.

    ##
    # :attr_reader: probabilities
    # Option or level probabilities for Choice and Score answers.

    ##
    # :attr_reader: confidence
    # Confidence value for Choice and Score answers.

    ##
    # :attr_reader: legend
    # Level descriptions for Score answers.

    ##
    # :method: choice
    # Returns the selected label for a Choice answer, or +nil+ for another type.

    ##
    # :method: noul
    # Returns the yes probability from 0 to 1 for a Noul answer, or +nil+ for another type.

    ##
    # :method: score
    # Returns the probability-weighted value for a Score answer, or +nil+ for another type.
  end

  # Results returned by a decision model, keyed by question id.
  #
  # Provider metadata contains bounded response identifiers, model details,
  # and reported cost when available; it excludes request state and question text.
  DecisionResult = Data.define(:answers, :usage, :metadata) do # :nodoc:
    def initialize(answers:, usage: Usage.new, metadata: {})
      super(answers: answers.to_h.freeze, usage:, metadata: metadata.to_h.freeze)
    end
  end

  # Carries validated answers and token usage from one decision call.
  class DecisionResult < Data # :doc:
    ##
    # :attr_reader: answers
    # Frozen question-id to DecisionAnswer mapping.

    ##
    # :attr_reader: usage
    # Normalized token usage for the provider request.

    ##
    # :attr_reader: metadata
    # Frozen provider metadata such as model, request id, provider, and cost.
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
