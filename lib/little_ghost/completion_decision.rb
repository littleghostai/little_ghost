# frozen_string_literal: true

module LittleGhost
  # Accepts an agent's proposed completion or asks it to continue with feedback.
  # Return this value from Agent.before_completion after checking the response
  # against application state. Feedback becomes part of the model conversation;
  # include only information the model may receive.
  class CompletionDecision
    # Accepts the proposed response after this callback's checks pass.
    def self.accept = new(nil)

    # Continues the same invocation with nonblank text feedback.
    # Raises ArgumentError when +feedback+ is not a nonblank String.
    def self.continue(feedback:)
      unless feedback.is_a?(String) && !feedback.strip.empty?
        raise ArgumentError, "completion feedback must be a nonblank String"
      end

      new(feedback.dup.freeze)
    end

    # Feedback to include in the next model request, or +nil+ when accepted.
    attr_reader :feedback

    # Whether this callback accepts the proposed completion.
    def accept? = feedback.nil?

    # Whether the agent should continue its current invocation.
    def continue? = !accept?

    def cancel? = false # :nodoc:
    def replace? = false # :nodoc:

    private_class_method :new

    private

    def initialize(feedback) # :nodoc:
      @feedback = feedback
      freeze
    end
  end
end
