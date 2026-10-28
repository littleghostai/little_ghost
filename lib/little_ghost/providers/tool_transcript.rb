# frozen_string_literal: true

require "json"

module LittleGhost
  module Providers
    # Renders tool calls that a provider cannot send natively as plain-text
    # transcripts, keeping the conversation faithful and the request valid.
    #
    # Some provider APIs reject a request whose history contains tool-call or
    # tool-result blocks for a tool the request does not declare. That happens
    # whenever a request is sent without tools, such as a context summary, or
    # after a model called a tool outside the offered set.
    module ToolTranscript # :nodoc:
      module_function

      # Returns +messages+ with every ToolUse for which the block returns false,
      # its ToolResult, and any ToolResult without a preceding ToolUse rewritten
      # as Content::Text. Results pair with calls in order, so a repeated call
      # id is decided per occurrence. Unchanged messages are returned as is.
      def rewrite(messages)
        pending = Hash.new { |hash, id| hash[id] = [] }
        messages.map do |message|
          content = message.content.map do |block|
            case block
            when Content::ToolUse
              native = yield(block)
              pending[block.id] << [native, block.name]
              native ? block : Content::Text.new(text: tool_use_text(block))
            when Content::ToolResult
              native, name = pending[block.tool_use_id].shift
              native ? block : Content::Text.new(text: tool_result_text(block, name))
            else
              block
            end
          end
          (content == message.content) ? message : Message.new(role: message.role, content:, metadata: message.metadata)
        end
      end

      def tool_use_text(tool_use)
        prompts.render(
          "output/format/tool_call",
          locals: {name: tool_use.name, id: tool_use.id, input: JSON.generate(tool_use.input)}
        )
      end

      def tool_result_text(result, name)
        output = Array(result.content).map { |block| block.is_a?(Content::Text) ? block.text : block.to_s }.join
        prompts.render(
          "output/format/tool_result",
          locals: {name: name.to_s, id: result.tool_use_id, error: result.status == :error, output:}
        )
      end

      def prompts
        @prompts ||= FrameworkPrompts.new
      end
    end
  end
end
