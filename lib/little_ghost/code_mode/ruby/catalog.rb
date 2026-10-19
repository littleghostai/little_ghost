# frozen_string_literal: true

require "json"

module LittleGhost
  module CodeMode
    module Ruby # :nodoc:
      class Catalog < CodeMode::Catalog # :nodoc:
        RESERVED_METHODS = %w[call parallel exec wait stop text finish all_tools].freeze

        def initialize(specifications)
          super(specifications, normalize: method(:normalize), reserved: RESERVED_METHODS)
        end

        def declarations
          definitions.map { |definition| render_tool(definition.fetch("specification")) }.join("\n\n")
        end

        def host_definitions
          definitions.map { |definition| JSON.parse(JSON.generate(definition.fetch("specification"))) }
        end

        private

        def render_tool(tool)
          tool = tool.transform_keys(&:to_sym)
          schema = (tool[:input_schema] || {}).transform_keys(&:to_s)
          properties = (schema["properties"] || {}).transform_keys(&:to_s)
          required = Array(schema["required"]).map(&:to_s)
          arguments = properties.map do |name, _child|
            required.include?(name) ? "#{name}:" : "#{name}: nil"
          end
          signature = "tools.#{normalize(tool.fetch(:name))}(#{arguments.join(", ")})"
          output = tool[:output_schema] || tool[:returns]
          parameters = properties.map do |name, child|
            presence = required.include?(name) ? "required" : "optional"
            description = child.to_h.transform_keys(&:to_s)["description"]
            details = [presence, description].compact.join("; ")
            "# @param #{name} [#{schema_type(child)}] #{details}#{schema_constraints(child)}"
          end
          [tool[:description], signature, *parameters, ("# @return [#{schema_type(output)}]" if output)].compact.join("\n")
        end

        def normalize(name)
          name.to_s.gsub(/[^a-zA-Z0-9_]/, "_").sub(/\A(?=\d)/, "tool_")
        end

        def schema_type(schema)
          return "untyped" unless schema.is_a?(Hash)

          schema = schema.transform_keys(&:to_s)
          return schema["const"].inspect if schema.key?("const")
          return schema["enum"].map(&:inspect).join(" | ") if schema["enum"]

          alternatives = schema["anyOf"] || schema["oneOf"]
          return alternatives.map { |child| schema_type(child) }.uniq.join(" | ") if alternatives
          if schema["allOf"]
            return schema["allOf"].map do |child|
              type = schema_type(child)
              type.include?(" | ") ? "(#{type})" : type
            end.join(" & ")
          end

          types = Array(schema["type"])
          return types.map { |type| schema_type(schema.merge("type" => type)) }.uniq.join(" | ") if types.length > 1

          case types.first
          when "string" then "String"
          when "integer" then "Integer"
          when "number" then "Numeric"
          when "boolean" then "bool"
          when "null" then "nil"
          when "array" then array_type(schema)
          when "object" then object_type(schema)
          else schema.key?("properties") ? object_type(schema) : "untyped"
          end
        end

        def array_type(schema)
          items = schema["items"]
          return "[#{items.map { |child| schema_type(child) }.join(", ")}]" if items.is_a?(Array)

          "Array[#{schema_type(items)}]"
        end

        def object_type(schema)
          fields = (schema["properties"] || {}).map { |name, child| "#{name}: #{schema_type(child)}" }
          return "{#{fields.join(", ")}}" unless fields.empty?

          additional = schema["additionalProperties"]
          additional.is_a?(Hash) ? "Hash[String, #{schema_type(additional)}]" : "Hash[String, untyped]"
        end

        def schema_constraints(schema)
          return "" unless schema.is_a?(Hash)

          schema = schema.transform_keys(&:to_s)
          values = %w[default minimum maximum minLength maxLength].filter_map do |key|
            "#{key}=#{schema[key].inspect}" if schema.key?(key)
          end
          values.empty? ? "" : " (#{values.join(", ")})"
        end
      end
    end
  end
end
