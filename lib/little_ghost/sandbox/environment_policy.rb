# frozen_string_literal: true

require "pathname"

module LittleGhost
  class Sandbox
    # Declares which environment values a Sandbox may pass to child processes.
    #
    # A Policy supplies a scrubbed locale and path baseline when its environment
    # option is omitted. Declaring an EnvironmentPolicy replaces that baseline.
    # Workspace routing variables are added separately.
    # Enabling inheritance here only permits it; an individual process call
    # must also opt in.
    #
    # See the {Workspaces and Sandboxes guide}[rdoc-ref:docs/guides/sandboxing.md]
    # for defaults and host-path considerations.
    class EnvironmentPolicy
      DEFAULT_PATH = "/usr/local/bin:/usr/bin:/bin" # :nodoc:

      # Builds the safe baseline used when no environment policy is declared.
      def self.default(environment: ENV) # :nodoc:
        lang = environment.fetch("LANG", "C.UTF-8")
        lc_all = environment.fetch("LC_ALL", lang)
        path = environment.fetch("PATH", DEFAULT_PATH)
        path = path.split(File::PATH_SEPARATOR).select do |entry|
          !entry.empty? && Pathname.new(entry).absolute?
        end.uniq.join(File::PATH_SEPARATOR)
        path = DEFAULT_PATH if path.empty?

        new(values: {"LANG" => lang, "LC_ALL" => lc_all, "PATH" => path})
      end

      # Returns +value+ unchanged or builds a policy from a Hash.
      def self.coerce(value)
        return value if value.is_a?(self)
        raise PolicyError, "sandbox environment must be a Hash" unless value.is_a?(Hash)

        if value.key?(:set) || value.key?("set") || value.key?(:inherit) || value.key?("inherit")
          values = value[:set] || value["set"] || {}
          inherit = value.fetch(:inherit, value.fetch("inherit", false))
        else
          values = value
          inherit = false
        end
        new(inherit:, values:)
      end

      # Builds an environment policy with explicit String-compatible +values+.
      def initialize(inherit: false, values: {})
        raise PolicyError, "sandbox environment values must be a Hash" unless values.is_a?(Hash)

        @inherit = !!inherit
        @values = values.to_h { |key, value| [String(key).freeze, String(value).freeze] }.freeze
        freeze
      end

      # Explicit child environment values, before Workspace routing values are added.
      attr_reader :values

      # Indicates whether a process call may opt into inheriting host values.
      def inherit? = @inherit
      # Returns the explicit child environment values.
      def to_h = values
    end
  end
end
