# frozen_string_literal: true

require "json"

module LittleGhost
  module Harnesses
    # Runs OpenCode with <tt>opencode run --format json --agent build</tt>.
    #
    # Every tool permission is granted without prompting, project
    # configuration in the working directory is ignored, automatic updates and
    # sharing are disabled, no MCP servers are configured, and OpenCode's XDG
    # directories live under +home+.
    #
    # +defaults+ accepts:
    #
    # [+:provider+]
    #   OpenCode provider identifier, such as <tt>"openrouter"</tt>. Requests
    #   name models as <tt>provider/model</tt>.
    # [+:base_url+]
    #   Base URL for that provider, for example a Network::Facade address.
    # [+:api_key+]
    #   Placeholder API key for that provider. A gateway replaces it.
    # [+:model+]
    #   Model used when the request does not name one.
    # [+:config+]
    #   Additional OpenCode configuration merged into the generated
    #   configuration.
    #
    # OpenCode reports cost and token usage after each step, so #run stops it
    # when cost exceeds +budget_usd+. Each finished step counts toward
    # +max_turns+.
    class OpenCode < Base
      harness_id :open_code
      default_executable "opencode"
      supported_versions ">= 1.0"

      # Returns the OpenCode command line for +request+.
      def command(request)
        arguments = [executable, "run", "--format", "json", "--agent", "build"]
        model = request.model || defaults[:model]
        arguments.push("--model", model.to_s) if model
        arguments.push("--session", request.session_id) if request.session_id
        arguments.concat(positional(prompt_with_instructions(request)))
      end

      # Returns OpenCode's permission, configuration, and directory settings.
      def environment(request)
        {
          "OPENCODE_PERMISSION" => JSON.generate({"*" => "allow"}),
          "OPENCODE_DISABLE_PROJECT_CONFIG" => "1",
          "OPENCODE_DISABLE_AUTOUPDATE" => "1",
          "OPENCODE_CONFIG_CONTENT" => JSON.generate(configuration(request)),
          "XDG_CONFIG_HOME" => File.join(home, ".config"),
          "XDG_DATA_HOME" => File.join(home, ".local", "share"),
          "XDG_CACHE_HOME" => File.join(home, ".cache"),
          "XDG_STATE_HOME" => File.join(home, ".local", "state")
        }
      end

      # Parses one <tt>run --format json</tt> event.
      def parse_line(line, state)
        data = JSON.parse(line)
        return [] unless data.is_a?(Hash)

        state.session_id = data["sessionID"] if data["sessionID"].is_a?(String)
        part = data["part"].is_a?(Hash) ? data["part"] : {}
        case data["type"]
        when "step_start" then step_start(state)
        when "text"
          state.text = part["text"].to_s
          [{kind: :text, text: state.text}]
        when "tool_use" then tool_events(part)
        when "step_finish" then step_finish(part, state)
        when "error"
          state.status = :failed
          state.stop_reason = data.dig("error", "name") || "error"
          []
        else []
        end
      end

      private

      def configuration(request)
        config = {
          "$schema" => "https://opencode.ai/config.json",
          "autoupdate" => false,
          "share" => "disabled",
          "mcp" => {}
        }
        provider = defaults[:provider]
        if provider && (defaults[:base_url] || defaults.key?(:api_key))
          options = {"apiKey" => api_key}
          options["baseURL"] = defaults[:base_url].to_s if defaults[:base_url]
          config["provider"] = {provider.to_s => {"options" => options}}
        end
        deep_merge(config, defaults.fetch(:config, {}))
      end

      def step_start(state)
        return [] if state.values[:started]

        state.values[:started] = true
        [{kind: :start}]
      end

      def tool_events(part)
        tool_state = part["state"].is_a?(Hash) ? part["state"] : {}
        events = [{kind: :tool_call, id: part["callID"], name: part["tool"], input: tool_state["input"]}]
        case tool_state["status"]
        when "completed"
          events << {kind: :tool_result, id: part["callID"], error: false, output: tool_state["output"].to_s}
        when "error"
          events << {kind: :tool_result, id: part["callID"], error: true, output: tool_state["error"].to_s}
        end
        events
      end

      def step_finish(part, state)
        state.turns = state.turns.to_i + 1
        state.stop_reason = part["reason"] if part["reason"].is_a?(String)
        state.cost_usd = state.cost_usd.to_f + part["cost"] if part["cost"].is_a?(Numeric)
        tokens = part["tokens"].is_a?(Hash) ? part["tokens"] : {}
        cache = tokens["cache"].is_a?(Hash) ? tokens["cache"] : {}
        state.add_usage(
          input_tokens: tokens["input"],
          output_tokens: tokens["output"],
          reasoning_tokens: tokens["reasoning"],
          cache_read_tokens: cache["read"],
          cache_write_tokens: cache["write"]
        )
        [{kind: :usage, **state.usage.to_h, cost_usd: state.cost_usd}]
      end

      def deep_merge(base, overrides)
        overrides.to_h.each_with_object(base.dup) do |(key, value), merged|
          key = key.to_s
          merged[key] = (merged[key].is_a?(Hash) && value.is_a?(Hash)) ? deep_merge(merged[key], value) : value
        end
      end
    end
  end
end
