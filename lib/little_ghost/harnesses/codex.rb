# frozen_string_literal: true

require "json"

module LittleGhost
  module Harnesses
    # Runs Codex with <tt>codex exec --json</tt>.
    #
    # In +:isolated+ mode Codex's own command sandbox is disabled
    # (<tt>--sandbox danger-full-access</tt>) because it cannot nest inside an
    # isolating Sandbox; the LittleGhost Sandbox that runs the harness is the
    # boundary, and +OPENAI_API_KEY+ is the placeholder. In +:native_guards+
    # mode Codex runs commands in its own sandbox (<tt>--sandbox
    # workspace-write</tt>) without network access, and authenticates from the
    # inherited environment, such as +OPENAI_API_KEY+ or +CODEX_API_KEY+.
    #
    # Approval prompts are disabled in both modes, so a command that needs
    # more access than Codex's sandbox allows fails instead of asking. The
    # update check is off, MCP servers are replaced by the request's
    # +mcp_servers+, notification commands are cleared on the command line,
    # and configuration lives under +home+. Other settings in a persistent home's
    # <tt>config.toml</tt> still apply.
    #
    # +defaults+ accepts:
    #
    # [+:base_url+]
    #   An OpenAI-compatible Responses API base URL, for example a
    #   Network::Facade address ending in <tt>/v1</tt>. The harness registers
    #   it as a model provider on the command line.
    # [+:api_key+]
    #   Placeholder sent as +OPENAI_API_KEY+. A gateway replaces it.
    # [+:model+]
    #   Model used when the request does not name one.
    #
    # Codex reports token usage but not cost, so +budget_usd+ cannot stop it.
    # One <tt>exec</tt> usually completes a single turn that contains every
    # command and edit, so +max_turns+ does not bound its work either; rely on
    # +timeout+.
    class Codex < Base
      harness_id :codex
      default_executable "codex"
      supported_versions ">= 0.50"

      PROVIDER = "little_ghost" # :nodoc:

      # Returns the Codex command line for +request+.
      def command(request)
        arguments = [
          executable, "exec", "--json",
          "-C", ".",
          *sandbox_arguments,
          "-c", 'approval_policy="never"',
          "-c", "check_for_update_on_startup=false",
          "-c", "mcp_servers=#{mcp_servers(request)}",
          "-c", "notify=[]",
          "--skip-git-repo-check",
          "-o", File.join(home, "last-message.md")
        ]
        if defaults[:base_url]
          arguments.push(
            "-c", "model_provider=#{toml(PROVIDER)}",
            "-c", "model_providers.#{PROVIDER}.name=#{toml("LittleGhost")}",
            "-c", "model_providers.#{PROVIDER}.base_url=#{toml(defaults[:base_url].to_s)}",
            "-c", "model_providers.#{PROVIDER}.env_key=#{toml("OPENAI_API_KEY")}",
            "-c", "model_providers.#{PROVIDER}.wire_api=#{toml("responses")}"
          )
        end
        model = request.model || defaults[:model]
        arguments.push("-m", model.to_s) if model
        request.add_dirs.each { |directory| arguments.push("--add-dir", directory) }
        arguments.push("resume", request.session_id) if request.session_id
        arguments.concat(positional(prompt_with_instructions(request)))
      end

      # Returns Codex's home and, in +:isolated+ mode, its credential
      # placeholder.
      def environment(request)
        values = {"CODEX_HOME" => File.join(home, ".codex")}
        values["OPENAI_API_KEY"] = api_key if isolated?
        values
      end

      # Parses one <tt>exec --json</tt> event.
      def parse_line(line, state)
        data = JSON.parse(line)
        return [] unless data.is_a?(Hash)

        case data["type"]
        when "thread.started"
          state.session_id = data["thread_id"] if data["thread_id"].is_a?(String)
          [{kind: :start}]
        when "item.started" then item_started(data["item"])
        when "item.completed" then item_completed(data["item"], state)
        when "turn.completed" then turn_completed(data["usage"], state)
        when "turn.failed"
          state.status = :failed
          state.stop_reason = "turn_failed"
          []
        when "error"
          state.stop_reason ||= "error"
          []
        else []
        end
      end

      private

      def item_started(item)
        return [] unless item.is_a?(Hash)

        case item["type"]
        when "command_execution"
          [{kind: :tool_call, id: item["id"], name: "command_execution", input: item["command"]}]
        when "mcp_tool_call"
          [{kind: :tool_call, id: item["id"], name: [item["server"], item["tool"]].compact.join("."), input: item["arguments"]}]
        when "web_search"
          [{kind: :tool_call, id: item["id"], name: "web_search", input: item["query"]}]
        else []
        end
      end

      def item_completed(item, state)
        return [] unless item.is_a?(Hash)

        case item["type"]
        when "agent_message"
          state.text = item["text"].to_s
          [{kind: :text, text: state.text}]
        when "command_execution"
          [{
            kind: :tool_result,
            id: item["id"],
            error: item["status"] == "failed" || (item["exit_code"].is_a?(Integer) && !item["exit_code"].zero?),
            output: item["aggregated_output"].to_s
          }]
        when "file_change"
          changes = Array(item["changes"]).filter_map { |change| "#{change["kind"]} #{change["path"]}" if change.is_a?(Hash) }
          [
            {kind: :tool_call, id: item["id"], name: "file_change", input: changes.join("\n")},
            {kind: :tool_result, id: item["id"], error: item["status"] == "failed", output: changes.join("\n")}
          ]
        when "mcp_tool_call"
          [{kind: :tool_result, id: item["id"], error: item["status"] == "failed", output: item["result"] || item["error"]}]
        else []
        end
      end

      def turn_completed(usage, state)
        state.turns = state.turns.to_i + 1
        state.stop_reason = "turn_completed"
        return [] unless usage.is_a?(Hash)

        cached = usage["cached_input_tokens"].to_i
        state.add_usage(
          input_tokens: [usage["input_tokens"].to_i - cached, 0].max,
          output_tokens: usage["output_tokens"],
          cache_read_tokens: cached
        )
        [{kind: :usage, **state.usage.to_h}]
      end

      def mcp_servers(request)
        entries = request.mcp_servers.map { |name, url| "#{name}={url=#{toml(url)}}" }
        "{#{entries.join(",")}}"
      end

      def sandbox_arguments
        return ["--sandbox", "danger-full-access"] if isolated?

        ["--sandbox", "workspace-write", "-c", "sandbox_workspace_write.network_access=false"]
      end

      def toml(value)
        JSON.generate(value)
      end
    end
  end
end
