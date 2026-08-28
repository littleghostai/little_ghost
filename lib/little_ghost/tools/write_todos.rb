# frozen_string_literal: true

module LittleGhost
  module Tools
    # WriteTodos lets an agent share a live plan with the application and the
    # person following its work. Add it like any other tool:
    #
    #   class ResearchAgent < LittleGhost::Agent
    #     tools LittleGhost::Tools::WriteTodos
    #   end
    #
    # Each execution replaces the full plan in RunContext state. Todo IDs remain stable across
    # updates, statuses are +pending+, +in_progress+, or +completed+, and no more
    # than one todo may be in progress. When no context is available, the tool
    # retains fallback state on its instance.
    class WriteTodos < Tool
      tool_name "write_todos"
      description FrameworkPrompts.new.render("tools/built_in/write_todos/description")
      input_schema(
        type: "object",
        properties: {
          plan_title: {type: "string", minLength: 1, maxLength: 80, pattern: "^[^\\x00-\\x1f\\x7f]+$"},
          todos: {
            type: "array",
            maxItems: 20,
            items: {
              type: "object",
              properties: {
                id: {type: "string", minLength: 1, maxLength: 64, pattern: "^[a-z0-9][a-z0-9_-]*$"},
                title: {type: "string", minLength: 1, maxLength: 48, pattern: "^[^\\x00-\\x1f\\x7f]+$"},
                status: {type: "string", enum: %w[pending in_progress completed]},
                details: {type: ["string", "null"], maxLength: 4_000}
              },
              required: %w[id title status],
              additionalProperties: false
            }
          }
        },
        required: %w[plan_title todos],
        additionalProperties: false
      )

      # Trims user-facing titles before normal tool validation and execution.
      def execute(input, context: nil)
        super(normalize_titles(input), context:)
      end

      def description
        framework_prompt("tools/built_in/write_todos/description")
      end

      # Replaces the stored plan after enforcing progress and ID invariants.
      def call(input)
        todos = input.fetch("todos")
        if todos.count { |todo| todo["status"] == "in_progress" } > 1
          raise ToolError, framework_prompt("tools/built_in/write_todos/feedback/single_progress")
        end

        ids = todos.map { |todo| todo.fetch("id") }
        raise ToolError, framework_prompt("tools/built_in/write_todos/feedback/unique_ids") unless ids.uniq.length == ids.length

        if context
          context.state["little_ghost.plan"] ||= empty_plan
          state = context.state.fetch("little_ghost.plan")
        else
          state = @fallback_state ||= empty_plan
        end
        state.replace("plan_title" => input.fetch("plan_title"), "todos" => todos.map(&:dup))
        state.dup
      end

      private

      def normalize_titles(input)
        return input unless input.is_a?(Hash)

        normalized = input.dup
        normalized["plan_title"] = normalized["plan_title"].strip if normalized["plan_title"].is_a?(String)
        if normalized["todos"].is_a?(Array)
          normalized["todos"] = normalized["todos"].map do |todo|
            next todo unless todo.is_a?(Hash)

            todo = todo.dup
            todo["title"] = todo["title"].strip if todo["title"].is_a?(String)
            todo
          end
        end
        normalized
      end

      def empty_plan
        {"plan_title" => nil, "todos" => []}
      end
    end
  end
end
