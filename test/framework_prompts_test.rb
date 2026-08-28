# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

class FrameworkPromptsTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("little-ghost-framework-prompts")
    @runtime_root = File.join(@directory, "runtime")
    @invocation_root = File.join(@directory, "invocation")
    FileUtils.mkdir_p([@runtime_root, @invocation_root])
    @prompts = LittleGhost::FrameworkPrompts.new(paths: [@runtime_root])
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_uses_invocation_then_agent_then_runtime_then_bundled_precedence
    assert_includes @prompts.render("agent/system/default"), "helpful agent"

    write(@runtime_root, "little_ghost/agent/system/default.erb", "runtime")
    assert_equal "runtime", @prompts.render("agent/system/default")

    write(@runtime_root, "customer_support/little_ghost/agent/system/default.erb", "agent")
    assert_equal "agent", @prompts.render("agent/system/default", agent_path: "customer_support")

    write(@invocation_root, "little_ghost/agent/system/default.erb", "invocation")
    trusted = LittleGhost::TrustedPath.new(path: @invocation_root)
    assert_equal "invocation", @prompts.render(
      "agent/system/default",
      agent_path: "customer_support",
      invocation_paths: [trusted]
    )
  end

  def test_renders_documented_locals_and_rejects_unknown_locals
    assert_equal "Unknown Tool: search", @prompts.render("tools/feedback/unknown", locals: {name: "search"})

    error = assert_raises(ArgumentError) do
      @prompts.render("tools/feedback/unknown", locals: {name: "search", secret: "value"})
    end
    assert_includes error.message, "secret"
  end

  def test_rejects_blank_required_overrides
    write(@runtime_root, "little_ghost/agent/system/default.erb", "\n")

    assert_raises(LittleGhost::PromptTemplateError) do
      @prompts.render("agent/system/default")
    end
  end

  def test_catalog_sources_exist
    refute_empty LittleGhost::FrameworkPrompts.entries
    LittleGhost::FrameworkPrompts.entries.each do |entry|
      assert File.file?(@prompts.source(entry)), entry.key
    end
  end

  def test_catalog_uses_only_canonical_hierarchical_keys
    keys = LittleGhost::FrameworkPrompts.entries.map(&:key)

    assert_equal keys.length, keys.uniq.length
    keys.each { |key| assert_match(%r{\A[a-z0-9_]+(?:/[a-z0-9_]+)+\z}, key) }
    refute keys.any? { |key| %w[tool tool_loop schema].include?(key.split("/").first) }
    assert_includes keys, "tools/built_in/read_file/description"
    assert_includes keys, "tools/validation/schema/type"
    assert_includes keys, "structured_output/repair/request"

    assert_raises(ArgumentError) { @prompts.render("tool/unknown", locals: {name: "search"}) }
  end

  def test_bundled_templates_document_usage_and_locals_in_invisible_headers
    LittleGhost::FrameworkPrompts.entries.each do |entry|
      source = File.binread(@prompts.source(entry))

      assert source.start_with?("<%#\n# Key: #{entry.key}\n"), entry.key
      assert_includes source, "# Purpose: #{entry.summary}.\n"
      assert_includes source, "\n# Used: "
      assert_includes source, "\n# Locals:\n"
      entry.locals.each { |local| assert_match(/^# - #{local}: .+$/, source, entry.key) }
      assert_includes source, "\n# Constraints:\n# - Must render non-blank.\n"
      assert_includes source, "\n-%>\n"
    end
  end

  def test_bundled_template_headers_do_not_change_rendered_output
    rendered = @prompts.render("agent/system/default")

    assert_equal "You are a helpful agent. Follow the caller's request, use available tools when they improve accuracy, and do not claim work you did not complete.", rendered
    refute_includes rendered, "Key:"
    refute rendered.start_with?("\n")
  end

  private

  def write(root, name, content)
    path = File.join(root, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end
