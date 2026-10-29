# frozen_string_literal: true

require "json"

module LittleGhost
  module Harnesses
    # Runs Claude Code in non-interactive print mode with
    # <tt>--output-format stream-json</tt>.
    #
    # The command uses <tt>--bare</tt>, so the tool ignores hooks, skills, and
    # settings found in the working directory, and
    # <tt>--strict-mcp-config</tt>, so it starts with only the request's
    # +mcp_servers+, whose tools are allowed. Automatic updates and
    # nonessential traffic are disabled, and configuration lives under +home+.
    #
    # In +:isolated+ mode the allowed tools run without permission prompts
    # and +ANTHROPIC_API_KEY+ is the placeholder. In +:native_guards+ mode the
    # command uses <tt>--permission-mode dontAsk</tt>, so only the allowed
    # tools run and everything else is denied; the default list allows file
    # and search tools and denies shell and web access. Claude Code then
    # authenticates from the inherited environment, such as
    # +ANTHROPIC_API_KEY+.
    #
    # +defaults+ accepts:
    #
    # [+:base_url+]
    #   Sets +ANTHROPIC_BASE_URL+, for example a Network::Facade address.
    # [+:api_key+]
    #   Placeholder sent as +ANTHROPIC_API_KEY+ in +:isolated+ mode. A
    #   gateway replaces it.
    # [+:model+]
    #   Model used when the request does not name one.
    # [+:allowed_tools+, +:disallowed_tools+]
    #   Claude Code tool names. In +:isolated+ mode the defaults allow file,
    #   search, shell, and subagent tools and disallow web access.
    #
    # Claude Code enforces +budget_usd+ and +max_turns+ itself and reports
    # cost, turns, and token usage in its final result.
    class ClaudeCode < Base
      harness_id :claude_code
      default_executable "claude"
      supported_versions ">= 2.1"

      ALLOWED_TOOLS = %w[Bash Read Edit Write Glob Grep Agent].freeze # :nodoc:
      DISALLOWED_TOOLS = %w[WebFetch WebSearch].freeze # :nodoc:
      NATIVE_ALLOWED_TOOLS = %w[Read Edit Write Glob Grep].freeze # :nodoc:
      NATIVE_DISALLOWED_TOOLS = %w[Bash WebFetch WebSearch].freeze # :nodoc:
      RESULT_STATUSES = {
        "error_max_turns" => :turns_exceeded,
        "error_max_budget_usd" => :budget_exceeded
      }.freeze # :nodoc:

      # Returns the Claude Code command line for +request+.
      def command(request)
        arguments = [
          executable, "-p", "--bare",
          "--allowedTools", allowed_tools(request).join(","),
          "--disallowedTools", Array(defaults.fetch(:disallowed_tools, isolated? ? DISALLOWED_TOOLS : NATIVE_DISALLOWED_TOOLS)).join(","),
          *(isolated? ? ["--permission-prompts", "none"] : ["--permission-mode", "dontAsk"]),
          "--strict-mcp-config", "--mcp-config", JSON.generate({mcpServers: request.mcp_servers.transform_values { |url| {type: "http", url:} }})
        ]
        arguments.push("--max-budget-usd", request.budget_usd.to_s) if request.budget_usd
        arguments.push("--max-turns", request.max_turns.to_s) if request.max_turns
        request.add_dirs.each { |directory| arguments.push("--add-dir", directory) }
        model = request.model || defaults[:model]
        arguments.push("--model", model.to_s) if model
        arguments.push("--append-system-prompt", request.instructions) if request.instructions
        arguments.push("--resume", request.session_id) if request.session_id
        arguments.push("--output-format", "stream-json", "--verbose")
        arguments.concat(positional(request.prompt))
      end

      # Returns Claude Code's configuration and update settings, and in
      # +:isolated+ mode its credential placeholder.
      def environment(request)
        values = {
          "CLAUDE_CONFIG_DIR" => File.join(home, ".claude"),
          "DISABLE_AUTOUPDATER" => "1",
          "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1"
        }
        values["ANTHROPIC_API_KEY"] = api_key if isolated?
        values["ANTHROPIC_BASE_URL"] = defaults[:base_url].to_s if defaults[:base_url]
        values
      end

      # Parses one stream-json message.
      def parse_line(line, state)
        data = JSON.parse(line)
        return [] unless data.is_a?(Hash)

        state.session_id = data["session_id"] if data["session_id"].is_a?(String)
        case data["type"]
        when "system" then system_events(data, state)
        when "assistant" then assistant_events(data)
        when "user" then tool_result_events(data)
        when "result" then result_events(data, state)
        else []
        end
      end

      private

      def allowed_tools(request)
        Array(defaults.fetch(:allowed_tools, isolated? ? ALLOWED_TOOLS : NATIVE_ALLOWED_TOOLS)) +
          request.mcp_servers.keys.map { |name| "mcp__#{name}" }
      end

      def system_events(data, state)
        return [] unless data["subtype"] == "init"

        state.model = data["model"]
        [{kind: :start, model: data["model"], version: data["claude_code_version"]}.compact]
      end

      def assistant_events(data)
        content = message_content(data)
        return [] unless content.is_a?(Array)

        content.filter_map do |block|
          next unless block.is_a?(Hash)

          case block["type"]
          when "text" then {kind: :text, text: block["text"].to_s}
          when "tool_use" then {kind: :tool_call, id: block["id"], name: block["name"], input: block["input"]}
          end
        end
      end

      def tool_result_events(data)
        content = message_content(data)
        return [] unless content.is_a?(Array)

        content.filter_map do |block|
          next unless block.is_a?(Hash) && block["type"] == "tool_result"

          {kind: :tool_result, id: block["tool_use_id"], error: !!block["is_error"], output: text_content(block["content"])}
        end
      end

      def result_events(data, state)
        state.text = data["result"] if data["result"].is_a?(String)
        state.cost_usd = data["total_cost_usd"] if data["total_cost_usd"].is_a?(Numeric)
        state.turns = data["num_turns"] if data["num_turns"].is_a?(Integer)
        state.stop_reason = data["subtype"]
        state.status = if data["subtype"] == "success"
          data["is_error"] ? :failed : :completed
        else
          RESULT_STATUSES.fetch(data["subtype"], :failed)
        end
        usage = data["usage"]
        if usage.is_a?(Hash)
          state.usage = Usage.new(
            input_tokens: usage["input_tokens"],
            output_tokens: usage["output_tokens"],
            cache_read_tokens: usage["cache_read_input_tokens"],
            cache_write_tokens: usage["cache_creation_input_tokens"]
          )
        end
        [{kind: :usage, **state.usage.to_h, cost_usd: state.cost_usd}]
      end

      def message_content(data)
        message = data["message"]
        message["content"] if message.is_a?(Hash)
      end

      def text_content(content)
        return content if content.is_a?(String)
        return "" unless content.is_a?(Array)

        content.filter_map { |block| block["text"] if block.is_a?(Hash) && block["type"] == "text" }.join("\n")
      end
    end
  end
end
