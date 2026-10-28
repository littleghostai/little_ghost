# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "little_ghost/tools"

class ToolsTest < Minitest::Test
  def test_filesystem_provider_exposes_writable_operations
    Dir.mktmpdir do |directory|
      registry = filesystem_registry(unrestricted_sandbox(directory, policy: writable_policy))

      assert_equal %w[read_file list_files write_file replace_in_file], registry.names
      assert registry.fetch("write_file").execute({"path" => "note.txt", "content" => "hello"}).success?
      assert_equal "hello", registry.fetch("read_file").execute({"path" => "note.txt"}).content
      assert registry.fetch("replace_in_file").execute({
        "path" => "note.txt", "old_text" => "hello", "new_text" => "ghost"
      }).success?
      assert_equal "ghost", File.read(File.join(directory, "note.txt"))
    end
  end

  def test_filesystem_provider_omits_writes_for_a_read_only_sandbox
    Dir.mktmpdir do |directory|
      registry = filesystem_registry(unrestricted_sandbox(directory))

      assert_equal %w[read_file list_files], registry.names
    end
  end

  def test_filesystem_provider_rejects_paths_outside_the_root
    Dir.mktmpdir do |directory|
      result = filesystem_registry(unrestricted_sandbox(directory)).fetch("read_file").execute({"path" => "../secret"})

      assert result.error?
    end
  end

  def test_filesystem_provider_does_not_follow_symlinks
    Dir.mktmpdir do |directory|
      Dir.mktmpdir do |outside|
        target = File.join(outside, "secret.txt")
        File.write(target, "original")
        File.symlink(target, File.join(directory, "link.txt"))
        registry = filesystem_registry(unrestricted_sandbox(directory, policy: writable_policy))

        assert registry.fetch("write_file").execute({"path" => "link.txt", "content" => "changed"}).error?
        assert_equal "original", File.read(target)
      end
    end
  end

  def test_exclusive_filesystem_provider_marks_every_tool_exclusive
    Dir.mktmpdir do |directory|
      registry = filesystem_registry(
        unrestricted_sandbox(directory, policy: writable_policy),
        LittleGhost::Tools::Filesystem::Exclusive
      )

      assert registry.all?(&:exclusive?)
    end
  end

  def test_shell_uses_the_context_sandbox_without_shell_expansion
    Dir.mktmpdir do |directory|
      sandbox = unrestricted_sandbox(directory)
      registry = LittleGhost::ToolRegistry.new(
        [LittleGhost::Tools::Shell], binding: LittleGhost::Tool::Binding.new(sandbox:)
      )

      result = registry.fetch("shell").execute({"command" => [RbConfig.ruby, "-e", "puts ARGV.first", "$(whoami)"]})

      assert result.success?
      assert_equal "$(whoami)\n", JSON.parse(result.content).fetch("stdout")
    end
  end

  def test_shell_does_not_inherit_parent_environment
    Dir.mktmpdir do |directory|
      previous = ENV["LITTLE_GHOST_SECRET_TEST"]
      ENV["LITTLE_GHOST_SECRET_TEST"] = "credential"
      sandbox = unrestricted_sandbox(directory)
      registry = LittleGhost::ToolRegistry.new(
        [LittleGhost::Tools::Shell], binding: LittleGhost::Tool::Binding.new(sandbox:)
      )

      result = registry.fetch("shell").execute({"command" => [RbConfig.ruby, "-e", "print ENV['LITTLE_GHOST_SECRET_TEST'].to_s"]})

      assert_equal "", JSON.parse(result.content).fetch("stdout")
    ensure
      ENV["LITTLE_GHOST_SECRET_TEST"] = previous
    end
  end

  def test_shell_defaults_to_an_argument_vector_with_a_fixed_timeout
    schema = LittleGhost::Tools::Shell.input_schema

    assert_equal "array", schema.dig("properties", "command", "type")
    refute schema.fetch("properties").key?("timeout_seconds")
    assert_includes LittleGhost::Tools::Shell.description, "30"
  end

  def test_string_mode_runs_the_command_through_the_shell
    Dir.mktmpdir do |directory|
      tool_class = Class.new(LittleGhost::Tools::Shell) { command_mode :string }
      registry = shell_registry(tool_class, unrestricted_sandbox(directory))

      result = registry.fetch("shell").execute({"command" => "printf ghost | tr g G"})

      assert result.success?
      assert_equal "Ghost", JSON.parse(result.content).fetch("stdout")
      assert_equal "string", tool_class.input_schema.dig("properties", "command", "type")
      refute_equal LittleGhost::Tools::Shell.description, tool_class.description
    end
  end

  def test_configured_timeout_lets_the_model_choose_within_the_maximum
    tool_class = Class.new(LittleGhost::Tools::Shell) { timeout default: 120, maximum: 900 }

    timeout_schema = tool_class.input_schema.dig("properties", "timeout_seconds")

    assert_equal 900, timeout_schema.fetch("maximum")
    assert_includes tool_class.description, "900"
  end

  def test_requested_timeout_is_passed_to_the_sandbox_and_null_uses_the_default
    tool_class = Class.new(LittleGhost::Tools::Shell) { timeout default: 120, maximum: 900 }
    sandbox = RecordingSandbox.new
    registry = shell_registry(tool_class, sandbox)

    registry.fetch("shell").execute({"command" => ["true"], "timeout_seconds" => 600})
    registry.fetch("shell").execute({"command" => ["true"], "timeout_seconds" => nil})
    over_limit = registry.fetch("shell").execute({"command" => ["true"], "timeout_seconds" => 901})

    assert_equal [600, 120], sandbox.timeouts
    assert over_limit.error?
  end

  def test_timeout_seconds_is_rejected_when_the_timeout_is_fixed
    sandbox = RecordingSandbox.new
    registry = shell_registry(LittleGhost::Tools::Shell, sandbox)

    result = registry.fetch("shell").execute({"command" => ["true"], "timeout_seconds" => 5})

    assert result.error?
    assert_empty sandbox.timeouts
  end

  def test_sandbox_execution_errors_are_reported
    sandbox = RecordingSandbox.new(error: "sandbox unavailable")
    registry = shell_registry(LittleGhost::Tools::Shell, sandbox)

    output = JSON.parse(registry.fetch("shell").execute({"command" => ["true"]}).content)

    assert_equal "sandbox unavailable", output.fetch("error")
    refute output.fetch("success")
  end

  def test_invalid_shell_configuration_is_rejected
    assert_raises(ArgumentError) { Class.new(LittleGhost::Tools::Shell) { command_mode :bash } }
    assert_raises(ArgumentError) { Class.new(LittleGhost::Tools::Shell) { timeout default: 0 } }
    assert_raises(ArgumentError) { Class.new(LittleGhost::Tools::Shell) { timeout default: 60, maximum: 30 } }
    assert_raises(ArgumentError) { Class.new(LittleGhost::Tools::Shell) { max_output_bytes(-1) } }
  end

  def test_subclass_configuration_does_not_change_the_base_tool
    Class.new(LittleGhost::Tools::Shell) do
      command_mode :string
      timeout default: 60, maximum: 120
    end

    assert_equal :argv, LittleGhost::Tools::Shell.command_mode
    assert_nil LittleGhost::Tools::Shell.timeout_maximum_value
  end

  private

  class RecordingSandbox
    attr_reader :timeouts

    def initialize(error: nil)
      @error = error
      @timeouts = []
    end

    def execute_program(_command, timeout:, **)
      @timeouts << timeout
      LittleGhost::Sandbox::Execution.new(stdout: "", stderr: "", exit_code: @error ? nil : 0, error: @error)
    end
  end

  def shell_registry(tool_class, sandbox)
    LittleGhost::ToolRegistry.new([tool_class], binding: LittleGhost::Tool::Binding.new(sandbox:))
  end

  def filesystem_registry(sandbox, provider = LittleGhost::Tools::Filesystem)
    LittleGhost::ToolRegistry.new([provider], binding: LittleGhost::Tool::Binding.new(sandbox:))
  end

  def unrestricted_sandbox(directory, **options)
    LittleGhost::Sandboxes::Unrestricted.new(
      workspace: LittleGhost::Workspace.new(root: directory),
      **options
    )
  end

  def writable_policy
    {files: {root: :read_write}, network: :inherit}
  end
end
