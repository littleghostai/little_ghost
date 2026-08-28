# frozen_string_literal: true

module LittleGhost
  module Subagents
    class ControlTool < Tool # :nodoc:
      class_attribute :framework_description_reference
      class_attribute :framework_schema_references, default: {}.freeze
      class_attribute :framework_prompt_manager

      class << self
        def framework_prompts(description:, schema: {}, manager: nil)
          self.framework_description_reference = description
          self.framework_schema_references = schema.freeze
          self.framework_prompt_manager = manager
          renderer = FrameworkPrompts.new
          self.description(renderer.render_reference(description))
          resolved_schema = schema.reduce(input_schema) do |value, (path, reference)|
            replace_schema_value(value, Array(path), renderer.render_reference(reference))
          end
          input_schema(resolved_schema)
        end

        private

        def replace_schema_value(value, path, replacement)
          key, *remaining = path
          return replacement unless key
          return value.merge(key => replacement).freeze if remaining.empty?

          value.merge(key => replace_schema_value(value.fetch(key), remaining, replacement)).freeze
        end
      end

      def description
        render_reference(self.class.framework_description_reference)
      end

      def input_schema
        self.class.framework_schema_references.reduce(self.class.input_schema) do |schema, (path, reference)|
          replace(schema, Array(path), render_reference(reference))
        end.freeze
      end

      def specification = {name: tool_name, description:, input_schema:}.freeze

      private

      def render_reference(reference)
        if agent
          self.class.framework_prompt_manager&.bind_prompt_renderer(agent.method(:render_framework_prompt))
          agent.render_framework_prompt(reference.key, **reference.locals)
        else
          FrameworkPrompts.new.render(reference.key, locals: reference.locals)
        end
      end

      def replace(value, path, replacement)
        key, *remaining = path
        return replacement unless key
        return value.merge(key => replacement).freeze if remaining.empty?

        value.merge(key => replace(value.fetch(key), remaining, replacement)).freeze
      end
    end
  end
end
