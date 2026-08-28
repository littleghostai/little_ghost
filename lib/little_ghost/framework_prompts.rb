# frozen_string_literal: true

module LittleGhost
  # FrameworkPrompts resolves LittleGhost-authored model-facing text through the
  # same trusted ERB lookup rules as application prompt views.
  class FrameworkPrompts # :nodoc:
    TEMPLATE_ROOT = File.expand_path("prompts", __dir__)
    PREFIX = "little_ghost"
    GROUP_SUMMARIES = {
      "agent" => "Default Agent instructions and interjection prompts",
      "artifacts" => "Artifact presentation, storage, and failure prompts",
      "assembly" => "Assembly Tool descriptions and routing feedback",
      "code_mode" => "Code-mode instructions, Tools, feedback, and failures",
      "context_management" => "Conversation context-management prompts",
      "graph" => "Graph predecessor-context formatting",
      "mcp" => "MCP Tool descriptions and failure messages",
      "output" => "Shared model-visible output formatting",
      "sandbox" => "Sandbox filesystem, process, and policy feedback",
      "skills" => "Skill discovery and activation prompts",
      "structured_output" => "Structured-result Tools, repair, and validation",
      "subagents" => "Subagent Tools, feedback, and lifecycle messages",
      "swarm" => "Swarm handoff prompts",
      "tools" => "Shared and built-in Tool prompts",
      "workspace" => "Workspace feedback"
    }.freeze
    SEGMENT_SUMMARIES = {
      "artifacts" => "Artifact-related prompts",
      "activate" => "Skill activation Tool prompts",
      "batch" => "Artifact batch validation",
      "built_in" => "Built-in LittleGhost Tools",
      "context" => "Model-visible execution context",
      "discovery" => "Skill discovery",
      "exec" => "Code-mode exec Tool prompts",
      "errors" => "Operational failure messages",
      "feedback" => "Expected model-correctable feedback",
      "filesystem" => "Filesystem operations",
      "format" => "Reusable model-visible fragments",
      "fallback" => "Fallback Tool prompts",
      "handoff" => "Agent handoff behavior",
      "headings" => "Model-visible section headings",
      "inputs" => "Tool input descriptions",
      "interjections" => "Agent interjection behavior",
      "interject" => "Subagent interjection Tool prompts",
      "javascript" => "JavaScript code mode",
      "loop" => "Repeated Tool-call handling",
      "list" => "Subagent listing Tool prompts",
      "notices" => "Informational model-visible notices",
      "persistence" => "Persisted conversation representations",
      "policy" => "Sandbox policy enforcement",
      "presentation" => "Artifact presentation to the model",
      "process" => "Sandboxed process execution",
      "repair" => "Structured-result repair",
      "result" => "Structured-result Tool prompts",
      "resources" => "Skill resources",
      "ruby" => "Ruby code mode",
      "send" => "Subagent messaging Tool prompts",
      "schema" => "JSON Schema validation",
      "storage" => "Artifact storage",
      "spawn" => "Subagent spawning Tool prompts",
      "stop" => "Code-mode stop Tool prompts",
      "summary" => "Conversation summarization",
      "system" => "System instructions",
      "tools" => "Model-callable Tool prompts",
      "truncation" => "Bounded output truncation",
      "validation" => "Local validation feedback",
      "wait" => "Wait Tool prompts"
    }.freeze

    Entry = Data.define(:key, :summary, :locals, :required) do
      def initialize(key:, summary:, locals: [], required: false)
        super(
          key: String(key).freeze,
          summary: String(summary).freeze,
          locals: Array(locals).map(&:to_sym).freeze,
          required: required == true
        )
      end

      def relative_path = File.join(PREFIX, "#{key}.erb")
    end

    Reference = Data.define(:key, :locals) do
      def initialize(key:, locals: {})
        super(key: String(key).freeze, locals: FrameworkPrompts.immutable_copy(locals))
      end
    end

    ENTRIES = [
      Entry.new(key: "agent/system/default", summary: "Default system instruction", required: true),
      Entry.new(key: "agent/interjections/instructions", summary: "Instruction preceding an interjection", required: true),
      Entry.new(key: "context_management/summary/system_instruction", summary: "Conversation summarizer system instruction", required: true),
      Entry.new(key: "context_management/summary/request", summary: "Conversation summarizer request", required: true),
      Entry.new(key: "structured_output/tools/result/description", summary: "Terminal structured-result Tool description", required: true),
      Entry.new(key: "structured_output/repair/request", summary: "Structured-result repair request", locals: %i[tool schema_name repairs_remaining feedback], required: true),
      Entry.new(key: "structured_output/repair/feedback/schema_errors", summary: "Structured-result Tool repair feedback", locals: %i[errors], required: true),
      Entry.new(key: "structured_output/repair/feedback/invalid_result", summary: "Agent structured-result Tool repair feedback", required: true),
      Entry.new(key: "structured_output/persistence/format/redaction", summary: "Persisted structured-result placeholder", locals: %i[schema_name], required: true),
      Entry.new(key: "structured_output/validation/feedback/missing_tool", summary: "Missing structured-result Tool validation feedback", required: true),
      Entry.new(key: "structured_output/validation/feedback/multiple_tools", summary: "Repeated structured-result Tool validation feedback", required: true),
      Entry.new(key: "structured_output/validation/feedback/tool_not_exclusive", summary: "Non-exclusive structured-result Tool validation feedback", required: true),
      Entry.new(key: "structured_output/validation/feedback/invalid_json", summary: "Invalid structured-result JSON feedback", required: true),
      Entry.new(key: "structured_output/validation/feedback/too_large", summary: "Oversized structured-result feedback", required: true),
      Entry.new(key: "structured_output/validation/feedback/too_deep", summary: "Overly nested structured-result feedback", required: true),
      Entry.new(key: "structured_output/validation/feedback/too_complex", summary: "Overly complex structured-result feedback", required: true),
      Entry.new(key: "tools/loop/notices/warning", summary: "Repeated Tool-call warning", required: true),
      Entry.new(key: "tools/loop/notices/final_warning", summary: "Final repeated Tool-call warning", required: true),
      Entry.new(key: "tools/loop/notices/termination", summary: "Repeated Tool-call termination reason", locals: %i[tool_name], required: true),
      Entry.new(key: "tools/feedback/invalid_input", summary: "Invalid Tool input feedback", locals: %i[errors], required: true),
      Entry.new(key: "tools/errors/unexpected_failure", summary: "Sanitized unexpected Tool failure", locals: %i[error_class], required: true),
      Entry.new(key: "tools/errors/unserializable_result", summary: "Unserializable Tool result feedback", required: true),
      Entry.new(key: "tools/feedback/unknown", summary: "Unknown Tool feedback", locals: %i[name], required: true),
      Entry.new(key: "assembly/tools/fallback/description", summary: "Fallback assembly Tool description", locals: %i[name], required: true),
      Entry.new(key: "assembly/feedback/transition_only", summary: "Assembly transition Tool validation feedback", required: true),
      Entry.new(key: "graph/context/headings/original_task", summary: "Graph original-task heading", required: true),
      Entry.new(key: "graph/context/headings/previous_inputs", summary: "Graph predecessor-input heading", required: true),
      Entry.new(key: "graph/context/format/previous_input", summary: "Graph predecessor label", locals: %i[name output], required: true),
      Entry.new(key: "graph/context/format/failed_input", summary: "Graph predecessor failure", locals: %i[error_class], required: true),
      Entry.new(key: "swarm/tools/handoff/description", summary: "Swarm handoff Tool description", locals: %i[descriptions], required: true),
      Entry.new(key: "swarm/handoff/notice", summary: "Swarm handoff Tool result", locals: %i[agent_id], required: true),
      Entry.new(key: "swarm/handoff/request", summary: "Swarm handoff input", locals: %i[from message context], required: true),
      Entry.new(key: "artifacts/presentation/format/references", summary: "Artifact reference appendix", locals: %i[references], required: true),
      Entry.new(key: "artifacts/presentation/format/reference", summary: "Artifact reference line", locals: %i[reference media_type bytes], required: true),
      Entry.new(key: "artifacts/presentation/format/workspace_references", summary: "Workspace artifact reference appendix", locals: %i[references], required: true),
      Entry.new(key: "artifacts/presentation/notices/full_result", summary: "Stored full-result notice", locals: %i[artifact preview], required: true),
      Entry.new(key: "artifacts/presentation/notices/storage_failed", summary: "Oversized-result storage failure notice", locals: %i[preview], required: true),
      Entry.new(key: "artifacts/errors/preparation_failed", summary: "Artifact preparation failure feedback", locals: %i[error_class], required: true),
      Entry.new(key: "artifacts/errors/resolver_invalid", summary: "Invalid artifact resolver feedback", required: true),
      Entry.new(key: "artifacts/errors/value_unstorable", summary: "Unstorable artifact value feedback", required: true),
      Entry.new(key: "artifacts/batch/feedback/batch_too_many", summary: "Artifact batch-count limit feedback", locals: %i[maximum], required: true),
      Entry.new(key: "artifacts/batch/feedback/item_too_large", summary: "Artifact size-limit feedback", locals: %i[maximum], required: true),
      Entry.new(key: "artifacts/batch/feedback/batch_too_large", summary: "Artifact batch-size limit feedback", locals: %i[maximum], required: true),
      Entry.new(key: "output/truncation/marker", summary: "Middle-truncation marker", locals: %i[removed_tokens], required: true),
      Entry.new(key: "mcp/tools/fallback/description", summary: "MCP Tool fallback description", locals: %i[server_name], required: true),
      Entry.new(key: "mcp/errors/request_failed", summary: "MCP request failure feedback", required: true),
      Entry.new(key: "mcp/errors/transformation_unserializable", summary: "MCP transformation serialization feedback", required: true),
      Entry.new(key: "code_mode/ruby/instructions", summary: "Ruby code-mode instructions", locals: %i[declarations], required: true),
      Entry.new(key: "code_mode/javascript/instructions", summary: "JavaScript code-mode instructions", locals: %i[declarations], required: true),
      Entry.new(key: "code_mode/tools/exec/description", summary: "Code-mode exec Tool description", required: true),
      Entry.new(key: "code_mode/tools/wait/description", summary: "Code-mode wait Tool description", required: true),
      Entry.new(key: "code_mode/tools/stop/description", summary: "Code-mode stop Tool description", required: true),
      Entry.new(key: "code_mode/tools/wait/inputs/max_output_tokens/description", summary: "Wait Tool observation-token input description", required: true),
      Entry.new(key: "code_mode/tools/stop/inputs/max_output_tokens/description", summary: "Stop Tool observation-token input description", required: true),
      Entry.new(key: "code_mode/artifacts/format/references", summary: "Code-mode artifact reference appendix", locals: %i[references], required: true),
      Entry.new(key: "subagents/tools/spawn/description", summary: "Spawn-subagent Tool description", required: true),
      Entry.new(key: "subagents/tools/send/description", summary: "Subagent follow-up Tool description", required: true),
      Entry.new(key: "subagents/tools/interject/description", summary: "Subagent interjection Tool description", required: true),
      Entry.new(key: "subagents/tools/wait/description", summary: "Wait-for-subagents Tool description", required: true),
      Entry.new(key: "subagents/tools/list/description", summary: "List-subagents Tool description", required: true),
      Entry.new(key: "subagents/tools/spawn/inputs/kind/description", summary: "Subagent kind input description", locals: %i[kinds], required: true),
      Entry.new(key: "subagents/tools/spawn/inputs/task_name/description", summary: "Subagent task-name input description", required: true),
      Entry.new(key: "subagents/tools/spawn/inputs/task/description", summary: "Subagent task input description", required: true),
      Entry.new(key: "subagents/tools/spawn/inputs/spawn_mode/description", summary: "Subagent spawn-mode input description", required: true),
      Entry.new(key: "subagents/tools/send/inputs/id/description", summary: "Subagent identity input description", required: true),
      Entry.new(key: "subagents/tools/send/inputs/message/description", summary: "Subagent follow-up input description", required: true),
      Entry.new(key: "subagents/tools/send/inputs/send_mode/description", summary: "Subagent follow-up mode input description", required: true),
      Entry.new(key: "subagents/tools/interject/inputs/active_id/description", summary: "Active-subagent identity input description", required: true),
      Entry.new(key: "subagents/tools/interject/inputs/message/description", summary: "Subagent interjection input description", required: true),
      Entry.new(key: "subagents/tools/wait/inputs/ids/description", summary: "Subagent wait-list input description", required: true),
      Entry.new(key: "skills/discovery/instructions", summary: "Available-skill discovery section", locals: %i[skills], required: true),
      Entry.new(key: "skills/tools/activate/description", summary: "Skill activation Tool description", required: true),
      Entry.new(key: "skills/tools/activate/inputs/name/description", summary: "Skill-name input description", required: true),
      Entry.new(key: "skills/feedback/unknown", summary: "Unknown-skill Tool feedback", locals: %i[name available], required: true),
      Entry.new(key: "skills/tools/activate/content", summary: "Activated skill instructions and metadata", locals: %i[instructions allowed_tools compatibility location resources], required: true),
      Entry.new(key: "skills/resources/notices/truncated", summary: "Truncated skill-resource listing marker", locals: %i[max_files], required: true),
      Entry.new(key: "tools/built_in/read_file/description", summary: "Read-file Tool description", required: true),
      Entry.new(key: "tools/built_in/list_files/description", summary: "List-files Tool description", required: true),
      Entry.new(key: "tools/built_in/write_file/description", summary: "Write-file Tool description", required: true),
      Entry.new(key: "tools/built_in/replace_in_file/description", summary: "Replace-in-file Tool description", required: true),
      Entry.new(key: "tools/built_in/shell/description", summary: "Shell Tool description", required: true),
      Entry.new(key: "tools/built_in/write_todos/description", summary: "Todo-planning Tool description", required: true),
      Entry.new(key: "tools/built_in/write_todos/feedback/single_progress", summary: "Todo progress validation feedback", required: true),
      Entry.new(key: "tools/built_in/write_todos/feedback/unique_ids", summary: "Todo identifier validation feedback", required: true),
      Entry.new(key: "tools/validation/schema/type", summary: "Schema type validation feedback", locals: %i[path types], required: true),
      Entry.new(key: "tools/validation/schema/enum", summary: "Schema enum validation feedback", locals: %i[path values], required: true),
      Entry.new(key: "tools/validation/schema/minimum", summary: "Schema numeric minimum feedback", locals: %i[path minimum], required: true),
      Entry.new(key: "tools/validation/schema/maximum", summary: "Schema numeric maximum feedback", locals: %i[path maximum], required: true),
      Entry.new(key: "tools/validation/schema/required", summary: "Schema required-property feedback", locals: %i[path], required: true),
      Entry.new(key: "tools/validation/schema/additional_property", summary: "Schema additional-property feedback", locals: %i[path], required: true),
      Entry.new(key: "tools/validation/schema/min_length", summary: "Schema string minimum-length feedback", locals: %i[path minimum], required: true),
      Entry.new(key: "tools/validation/schema/max_length", summary: "Schema string maximum-length feedback", locals: %i[path maximum], required: true),
      Entry.new(key: "tools/validation/schema/invalid_format", summary: "Schema string-format feedback", locals: %i[path], required: true),
      Entry.new(key: "tools/validation/schema/invalid_pattern", summary: "Schema pattern-definition feedback", locals: %i[path], required: true),
      Entry.new(key: "tools/validation/schema/min_items", summary: "Schema array minimum-size feedback", locals: %i[path minimum], required: true),
      Entry.new(key: "tools/validation/schema/max_items", summary: "Schema array maximum-size feedback", locals: %i[path maximum], required: true),
      Entry.new(key: "code_mode/feedback/not_active", summary: "Missing active code-mode program feedback", required: true),
      Entry.new(key: "code_mode/feedback/closed", summary: "Closed code-mode resource feedback", locals: %i[resource], required: true),
      Entry.new(key: "code_mode/feedback/control_active", summary: "Concurrent code-mode control feedback", required: true),
      Entry.new(key: "code_mode/feedback/program_active", summary: "Existing active code-mode program feedback", required: true),
      Entry.new(key: "code_mode/feedback/limit_exceeded", summary: "Code-mode limit feedback", locals: %i[limit], required: true),
      Entry.new(key: "code_mode/feedback/program_timed_out", summary: "Code-mode program timeout feedback", required: true),
      Entry.new(key: "code_mode/errors/execution_failed", summary: "Code-mode execution failure feedback", locals: %i[error_class message], required: true),
      Entry.new(key: "code_mode/feedback/unavailable_tool", summary: "Unavailable code-mode Tool feedback", locals: %i[name], required: true),
      Entry.new(key: "code_mode/feedback/arguments_object", summary: "Code-mode Tool argument-shape feedback", required: true),
      Entry.new(key: "code_mode/feedback/unknown_program", summary: "Unknown code-mode program feedback", locals: %i[id], required: true),
      Entry.new(key: "code_mode/errors/cleanup_failed", summary: "Code-mode cleanup failure feedback", required: true),
      Entry.new(key: "code_mode/errors/brokered_close", summary: "Brokered code-mode close feedback", required: true),
      Entry.new(key: "subagents/errors/create_failed", summary: "Subagent creation failure", required: true),
      Entry.new(key: "subagents/errors/restore_failed", summary: "Subagent restoration failure", required: true),
      Entry.new(key: "subagents/feedback/message_type", summary: "Subagent message type feedback", required: true),
      Entry.new(key: "subagents/feedback/message_limit", summary: "Subagent message length feedback", locals: %i[limit], required: true),
      Entry.new(key: "subagents/feedback/interjection_unsupported", summary: "Unsupported subagent interjection feedback", locals: %i[id], required: true),
      Entry.new(key: "subagents/feedback/not_running", summary: "Inactive subagent interjection feedback", locals: %i[id], required: true),
      Entry.new(key: "subagents/feedback/interjection_limit", summary: "Subagent interjection count feedback", locals: %i[id], required: true),
      Entry.new(key: "subagents/feedback/interjection_chars_limit", summary: "Subagent interjection length feedback", locals: %i[limit], required: true),
      Entry.new(key: "subagents/feedback/list_limit", summary: "Subagent list limit feedback", locals: %i[maximum], required: true),
      Entry.new(key: "subagents/feedback/unknown_kind", summary: "Unknown subagent kind feedback", locals: %i[kind], required: true),
      Entry.new(key: "subagents/feedback/invalid_cursor", summary: "Invalid subagent cursor feedback", required: true),
      Entry.new(key: "subagents/feedback/duplicate_path", summary: "Duplicate subagent path feedback", locals: %i[path], required: true),
      Entry.new(key: "subagents/errors/turn_failed", summary: "Subagent turn failure", required: true),
      Entry.new(key: "subagents/notices/turn_cancelled", summary: "Subagent turn cancellation", required: true),
      Entry.new(key: "subagents/errors/previous_turn_failed", summary: "Queued subagent turn failure", required: true),
      Entry.new(key: "subagents/feedback/turn_capacity", summary: "Subagent turn capacity feedback", required: true),
      Entry.new(key: "subagents/feedback/queue_capacity", summary: "Subagent queue capacity feedback", locals: %i[id], required: true),
      Entry.new(key: "subagents/feedback/identity_capacity", summary: "Subagent identity capacity feedback", required: true),
      Entry.new(key: "subagents/feedback/duplicate_ids", summary: "Duplicate selected subagent feedback", required: true),
      Entry.new(key: "subagents/feedback/inactive", summary: "Inactive persisted subagent feedback", locals: %i[id], required: true),
      Entry.new(key: "subagents/feedback/unknown_id", summary: "Unknown subagent identity feedback", locals: %i[id], required: true),
      Entry.new(key: "subagents/feedback/terminal_identity", summary: "Terminal subagent identity feedback", locals: %i[id status], required: true),
      Entry.new(key: "subagents/feedback/invalid_mode", summary: "Invalid subagent delivery mode feedback", required: true),
      Entry.new(key: "code_mode/ruby/feedback/parallel_callables", summary: "Ruby parallel-call validation feedback", required: true),
      Entry.new(key: "code_mode/javascript/errors/execution_limit", summary: "JavaScript execution-limit host diagnostic", required: true),
      Entry.new(key: "code_mode/javascript/errors/memory_limit", summary: "JavaScript memory-limit host diagnostic", required: true),
      Entry.new(key: "code_mode/javascript/errors/cleanup_failed", summary: "JavaScript cleanup host diagnostic", required: true),
      Entry.new(key: "code_mode/javascript/errors/pending_calls_limit", summary: "JavaScript pending-call host diagnostic", required: true),
      Entry.new(key: "code_mode/javascript/errors/active_programs_limit", summary: "JavaScript active-program host diagnostic", required: true),
      Entry.new(key: "code_mode/javascript/errors/invalid_request", summary: "Invalid JavaScript host-request diagnostic", locals: %i[detail], required: true),
      Entry.new(key: "subagents/feedback/task_name_limit", summary: "Subagent task-name length feedback", locals: %i[maximum], required: true),
      Entry.new(key: "subagents/feedback/task_name_invalid", summary: "Subagent task-name format feedback", required: true),
      Entry.new(key: "code_mode/javascript/errors/source_size_limit", summary: "JavaScript source-size host diagnostic", required: true),
      Entry.new(key: "code_mode/javascript/errors/tools_array", summary: "JavaScript Tool-catalog host diagnostic", required: true),
      Entry.new(key: "workspace/feedback/path_changed", summary: "Changed workspace-path feedback", locals: %i[name], required: true),
      Entry.new(key: "artifacts/storage/errors/workspace_unavailable", summary: "Unavailable artifact workspace feedback", required: true),
      Entry.new(key: "artifacts/storage/feedback/too_large", summary: "Stored artifact size-limit feedback", locals: %i[maximum], required: true),
      Entry.new(key: "artifacts/storage/feedback/count_limit", summary: "Stored artifact count-limit feedback", locals: %i[maximum], required: true),
      Entry.new(key: "artifacts/storage/feedback/total_limit", summary: "Stored artifact total-size feedback", locals: %i[maximum], required: true),
      Entry.new(key: "artifacts/storage/feedback/destination_exists", summary: "Existing artifact destination feedback", required: true),
      Entry.new(key: "artifacts/storage/errors/destination_unsafe", summary: "Unsafe artifact destination feedback", required: true),
      Entry.new(key: "artifacts/storage/errors/secure_unavailable", summary: "Unavailable secure artifact storage feedback", required: true),
      Entry.new(key: "artifacts/storage/errors/workspace_unsafe", summary: "Unsafe artifact workspace feedback", required: true),
      Entry.new(key: "artifacts/storage/errors/workspace_changed", summary: "Changed artifact workspace feedback", required: true),
      Entry.new(key: "sandbox/process/feedback/executable_required", summary: "Missing executable feedback", required: true),
      Entry.new(key: "sandbox/process/feedback/command_timed_out", summary: "Sandbox command timeout feedback", locals: %i[timeout], required: true),
      Entry.new(key: "sandbox/filesystem/errors/workspace_root_changed", summary: "Changed sandbox workspace feedback", required: true),
      Entry.new(key: "sandbox/process/feedback/program_timed_out", summary: "Sandbox program timeout feedback", locals: %i[timeout], required: true),
      Entry.new(key: "sandbox/process/feedback/program_memory_exceeded", summary: "Sandbox program memory-limit feedback", locals: %i[bytes], required: true),
      Entry.new(key: "sandbox/process/errors/program_supervisor_failed", summary: "Sandbox supervisor failure feedback", locals: %i[error_class], required: true),
      Entry.new(key: "sandbox/process/feedback/program_output_exceeded", summary: "Sandbox program output-limit feedback", locals: %i[bytes], required: true),
      Entry.new(key: "sandbox/filesystem/feedback/mount_missing", summary: "Missing sandbox mount feedback", required: true),
      Entry.new(key: "sandbox/filesystem/feedback/file_read_limit", summary: "Sandbox read-limit feedback", required: true),
      Entry.new(key: "sandbox/filesystem/feedback/invalid_utf8", summary: "Invalid UTF-8 sandbox file feedback", required: true),
      Entry.new(key: "sandbox/filesystem/feedback/symlink_path", summary: "Sandbox symbolic-link path feedback", required: true),
      Entry.new(key: "sandbox/filesystem/feedback/path_missing", summary: "Missing sandbox path feedback", required: true),
      Entry.new(key: "sandbox/filesystem/feedback/directory_listing_limit", summary: "Sandbox directory-listing limit feedback", required: true),
      Entry.new(key: "sandbox/filesystem/feedback/path_traverses_symlink", summary: "Sandbox path traversal feedback", required: true),
      Entry.new(key: "sandbox/filesystem/feedback/not_directory", summary: "Non-directory sandbox path feedback", required: true),
      Entry.new(key: "sandbox/filesystem/feedback/read_only", summary: "Read-only sandbox feedback", required: true),
      Entry.new(key: "sandbox/filesystem/feedback/write_limit", summary: "Sandbox write-limit feedback", required: true),
      Entry.new(key: "sandbox/filesystem/feedback/write_target_symlink", summary: "Sandbox write-target symbolic-link feedback", required: true),
      Entry.new(key: "sandbox/filesystem/feedback/write_parent_missing", summary: "Missing sandbox write-parent feedback", required: true),
      Entry.new(key: "sandbox/filesystem/feedback/replace_empty", summary: "Empty sandbox replacement feedback", required: true),
      Entry.new(key: "sandbox/filesystem/feedback/text_not_found", summary: "Missing sandbox replacement text feedback", locals: %i[path], required: true),
      Entry.new(key: "sandbox/filesystem/feedback/text_multiple", summary: "Ambiguous sandbox replacement text feedback", locals: %i[path], required: true),
      Entry.new(key: "sandbox/filesystem/feedback/outside_scope", summary: "Out-of-scope sandbox path feedback", required: true),
      Entry.new(key: "sandbox/filesystem/feedback/entry_required", summary: "Sandbox entry-path feedback", required: true),
      Entry.new(key: "sandbox/filesystem/feedback/mount_escape", summary: "Sandbox mount-escape feedback", required: true),
      Entry.new(key: "sandbox/filesystem/feedback/null_byte", summary: "Sandbox null-byte path feedback", required: true),
      Entry.new(key: "sandbox/filesystem/feedback/parent_escape", summary: "Sandbox parent-path escape feedback", required: true),
      Entry.new(key: "sandbox/filesystem/errors/mount_changed", summary: "Changed sandbox mount feedback", required: true),
      Entry.new(key: "sandbox/filesystem/errors/secure_traversal_unavailable", summary: "Unavailable secure sandbox traversal feedback", required: true),
      Entry.new(key: "sandbox/filesystem/feedback/not_file", summary: "Non-file sandbox path feedback", required: true),
      Entry.new(key: "sandbox/filesystem/feedback/multiply_linked", summary: "Multiply-linked sandbox file feedback", required: true),
      Entry.new(key: "sandbox/policy/feedback/feature_denied", summary: "Denied sandbox feature feedback", locals: %i[feature], required: true)
    ].to_h { |entry| [entry.key, entry] }.freeze

    class << self
      def entries = ENTRIES.values

      def group_summary(path)
        value = String(path)
        GROUP_SUMMARIES[value] || SEGMENT_SUMMARIES.fetch(File.basename(value)) do
          File.basename(value).split("_").map(&:capitalize).join(" ")
        end
      end

      def for_runtime(runtime)
        return runtime.framework_prompts if defined?(Runtime) && runtime.is_a?(Runtime)

        new
      end

      def entry(key)
        ENTRIES.fetch(key.to_s) { raise ArgumentError, "Unknown framework prompt: #{key}" }
      end

      def reference(key, **locals)
        entry(key)
        Reference.new(key: key.to_s, locals:)
      end

      def immutable_copy(value)
        case value
        when Hash
          value.to_h { |key, child| [immutable_copy(key), immutable_copy(child)] }.freeze
        when Array
          value.map { |child| immutable_copy(child) }.freeze
        when String
          value.dup.freeze
        when Symbol, Numeric, true, false, nil
          value
        else
          raise ArgumentError, "framework prompt locals must contain only immutable data"
        end
      end
    end

    def initialize(paths: [])
      @paths = Array(paths).map do |path|
        path.is_a?(Lookup::Root) ? path : Lookup::Root.new(path: path.to_s)
      end.freeze
      @resolvers = {}.freeze
      @resolvers_mutex = Mutex.new
    end

    def render(key, locals: {}, invocation_paths: [], agent_path: nil)
      entry = self.class.entry(key)
      values = self.class.immutable_copy(locals)
      unknown = values.keys.map(&:to_sym) - entry.locals
      unless unknown.empty?
        raise ArgumentError, "Unknown locals for framework prompt #{entry.key}: #{unknown.join(", ")}"
      end

      rendered = resolver(agent_path).render(
        File.join(PREFIX, entry.key),
        locals: values,
        invocation_paths:
      )
      rendered = rendered.chomp
      if entry.required && rendered.strip.empty?
        raise PromptTemplateError, "Framework prompt cannot be blank: #{entry.key}"
      end
      rendered
    end

    def render_reference(reference, **scope)
      render(reference.key, locals: reference.locals, **scope)
    end

    def source(entry_or_key)
      entry = entry_or_key.is_a?(Entry) ? entry_or_key : self.class.entry(entry_or_key)
      File.join(TEMPLATE_ROOT, entry.relative_path)
    end

    private

    def resolver(agent_path)
      logical_path = agent_path.to_s
      cached = @resolvers[logical_path]
      return cached if cached

      @resolvers_mutex.synchronize do
        @resolvers[logical_path] || begin
          scoped = if logical_path.empty?
            []
          else
            @paths.map do |root|
              Lookup::Root.new(path: File.join(root.path, logical_path), boundary: root.boundary)
            end
          end
          resolved = PromptResolver.new(paths: [*scoped, *@paths, TEMPLATE_ROOT])
          @resolvers = @resolvers.merge(logical_path => resolved).freeze
          resolved
        end
      end
    end
  end
end
