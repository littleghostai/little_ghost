# frozen_string_literal: true

require "fileutils"
require "open3"
require "stringio"
require "tmpdir"
require "test_helper"
require "little_ghost/cli"

class CLITest < Minitest::Test
  class RecordingBundleInstaller
    attr_reader :gemfiles, :root_modes

    def initialize(result: true)
      @result = result
      @gemfiles = []
      @root_modes = []
    end

    def install(root)
      gemfiles << File.read(File.join(root, "Gemfile"))
      root_modes << (File.stat(root).mode & 0o777)
      File.write(File.join(root, "Gemfile.lock"), "LOCKFILE\n") if @result
      @result
    end
  end

  def test_help_and_version
    stdout = StringIO.new
    stderr = StringIO.new

    assert_equal 0, LittleGhost::CLI.new(["--help"], stdout:, stderr:).run
    assert_includes stdout.string, "little_ghost new APP_NAME"
    assert_includes stdout.string, "little_ghost prompts copy --all"
    assert_empty stderr.string

    stdout = StringIO.new
    assert_equal 0, LittleGhost::CLI.new(["--version"], stdout:, stderr:).run
    assert_equal "little_ghost #{LittleGhost::VERSION}\n", stdout.string
  end

  def test_packaged_executable_dispatches_to_the_cli
    repository_root = File.expand_path("..", __dir__)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      File.join(repository_root, "exe/little_ghost"),
      "--help"
    )

    assert_predicate status, :success?
    assert_includes stdout, "little_ghost new APP_NAME"
    assert_empty stderr
  end

  def test_missing_unknown_and_extra_arguments_are_usage_errors
    [
      [["new"], "APP_NAME is required"],
      [["unknown"], "Unknown command"],
      [["new", "One", "Two"], "exactly one"],
      [["console", "extra"], "does not accept arguments"],
      [["--help", "extra"], "does not accept arguments"]
    ].each do |arguments, message|
      stdout = StringIO.new
      stderr = StringIO.new

      assert_equal 1, LittleGhost::CLI.new(arguments, stdout:, stderr:).run
      assert_empty stdout.string
      assert_includes stderr.string, message
      assert_includes stderr.string, "Usage:"
    end
  end

  def test_generates_normalized_applications
    {
      "MyApp" => ["my_app", "MyAppAgent"],
      "my_app" => ["my_app", "MyAppAgent"],
      "my-app" => ["my_app", "MyAppAgent"],
      "HTTPClient2" => ["http_client2", "HttpClient2Agent"]
    }.each do |name, (directory_name, agent_class)|
      Dir.mktmpdir do |directory|
        stdout = StringIO.new
        stderr = StringIO.new
        bundle_installer = RecordingBundleInstaller.new

        assert_equal 0, LittleGhost::CLI.new(
          ["new", name],
          stdout:,
          stderr:,
          current_directory: directory,
          bundle_installer:
        ).run
        root = File.join(directory, directory_name)
        assert_generated_tree(root, directory_name)
        assert_includes File.read(File.join(root, "app/agents/#{directory_name}_agent.rb")), "class #{agent_class}"
        assert_includes stdout.string, "Created #{root}"
        assert_includes stdout.string, "Running bundle install"
        assert_equal [File.read(File.join(root, "Gemfile"))], bundle_installer.gemfiles
        assert_equal [0o700], bundle_installer.root_modes
        assert_empty stderr.string
      end
    end
  end

  def test_preserves_generated_application_when_bundle_install_fails
    Dir.mktmpdir do |directory|
      stderr = StringIO.new
      bundle_installer = RecordingBundleInstaller.new(result: false)

      status = LittleGhost::CLI.new(
        ["new", "MyApp"],
        stdout: StringIO.new,
        stderr:,
        current_directory: directory,
        bundle_installer:
      ).run

      root = File.join(directory, "my_app")
      assert_equal 1, status
      assert_path_exists root
      assert_equal [File.read(File.join(root, "Gemfile"))], bundle_installer.gemfiles
      refute_path_exists File.join(root, "Gemfile.lock")
      assert_includes stderr.string, "bundle install failed"
      assert_includes stderr.string, root
    end
  end

  def test_reports_a_bundle_executable_failure
    Dir.mktmpdir do |directory|
      stderr = StringIO.new
      bundle_installer = LittleGhost::BundleInstaller.new(
        stdout: StringIO.new,
        stderr:,
        executable: -> { raise Gem::Exception, "Bundler is unavailable" }
      )

      status = LittleGhost::CLI.new(
        ["new", "MyApp"],
        stdout: StringIO.new,
        stderr:,
        current_directory: directory,
        bundle_installer:
      ).run

      root = File.join(directory, "my_app")
      assert_equal 1, status
      assert_path_exists root
      refute_path_exists File.join(root, "Gemfile.lock")
      assert_includes stderr.string, "Bundler is unavailable"
      assert_includes stderr.string, "bundle install failed"
    end
  end

  def test_preserves_relative_bundle_artifacts
    Dir.mktmpdir do |directory|
      installer = Object.new
      installer.define_singleton_method(:install) do |root|
        FileUtils.mkdir_p(File.join(root, "vendor/bundle"))
        File.write(File.join(root, "vendor/bundle/installed.txt"), "installed")
        File.write(File.join(root, "Gemfile.lock"), "LOCKFILE\n")
        true
      end

      status = LittleGhost::CLI.new(
        ["new", "MyApp"],
        stdout: StringIO.new,
        stderr: StringIO.new,
        current_directory: directory,
        bundle_installer: installer
      ).run

      assert_equal 0, status
      assert_equal "installed", File.read(File.join(directory, "my_app/vendor/bundle/installed.txt"))
    end
  end

  def test_resolves_a_relative_bundle_path_inside_the_application
    Dir.mktmpdir do |directory|
      root = File.join(directory, "my_app")
      Dir.mkdir(root)
      environments = []
      successful_status = Object.new
      successful_status.define_singleton_method(:success?) { true }
      runner = lambda do |environment, _executable, _root|
        environments << environment
        successful_status
      end
      installer = LittleGhost::BundleInstaller.new(
        stdout: StringIO.new,
        stderr: StringIO.new,
        executable: -> { "bundle" },
        process_runner: runner
      )
      previous_bundle_path = ENV["BUNDLE_PATH"]
      ENV["BUNDLE_PATH"] = "vendor/bundle"

      assert installer.install(root)
      assert_equal File.join(root, "vendor/bundle"), environments.fetch(0).fetch("BUNDLE_PATH")
    ensure
      ENV["BUNDLE_PATH"] = previous_bundle_path
    end
  end

  def test_console_runs_for_the_current_application
    Dir.mktmpdir do |directory|
      roots = []
      runner = ->(root:) { roots << root }

      status = LittleGhost::CLI.new(
        ["console"],
        stdout: StringIO.new,
        stderr: StringIO.new,
        current_directory: directory,
        console_runner: runner
      ).run

      assert_equal 0, status
      assert_equal [File.expand_path(directory)], roots
    end
  end

  def test_rejects_unsafe_and_invalid_names_without_creating_files
    ["two words", "../escape", "path/name", "path.name", "-leading", "trailing-", "two--parts", "éclair"].each do |name|
      Dir.mktmpdir do |directory|
        stdout = StringIO.new
        stderr = StringIO.new

        assert_equal 1, LittleGhost::CLI.new(["new", name], stdout:, stderr:, current_directory: directory).run
        assert_empty Dir.children(directory)
        assert_empty stdout.string
        assert_includes stderr.string, "APP_NAME"
      end
    end
  end

  def test_preserves_an_existing_destination
    Dir.mktmpdir do |directory|
      destination = File.join(directory, "my_app")
      FileUtils.mkdir_p(destination)
      marker = File.join(destination, "keep.txt")
      File.write(marker, "unchanged")
      stderr = StringIO.new

      assert_equal 1, LittleGhost::CLI.new(["new", "MyApp"], stdout: StringIO.new, stderr:, current_directory: directory).run
      assert_equal "unchanged", File.read(marker)
      assert_includes stderr.string, "already exists"
    end
  end

  def test_reports_an_unavailable_parent_as_a_generation_error
    Dir.mktmpdir do |directory|
      missing_parent = File.join(directory, "missing")
      stderr = StringIO.new

      status = LittleGhost::CLI.new(
        ["new", "MyApp"],
        stdout: StringIO.new,
        stderr:,
        current_directory: missing_parent,
        bundle_installer: RecordingBundleInstaller.new
      ).run

      assert_equal 1, status
      assert_includes stderr.string, "Could not create my_app"
      assert_includes stderr.string, "No such file or directory"
    end
  end

  def test_removes_only_the_new_destination_when_generation_fails
    Dir.mktmpdir do |directory|
      templates = File.join(directory, "templates")
      FileUtils.mkdir_p(templates)
      marker = File.join(directory, "keep.txt")
      File.write(marker, "unchanged")
      generator = LittleGhost::Generators::ApplicationGenerator.new(
        name: "BrokenApp",
        current_directory: directory,
        template_root: templates
      )

      error = assert_raises(LittleGhost::Generators::ApplicationGenerator::GenerationError) { generator.generate }

      assert_includes error.message, "Could not create broken_app"
      refute_path_exists File.join(directory, "broken_app")
      assert_equal "unchanged", File.read(marker)
    end
  end

  def test_does_not_write_to_or_remove_a_replaced_destination
    Dir.mktmpdir do |directory|
      generator_class = Class.new(LittleGhost::Generators::ApplicationGenerator) do
        attr_reader :replacement, :displaced

        private

        def create_directories(destination, identity, files)
          @replacement = destination
          @displaced = "#{destination}.displaced"
          File.rename(destination, displaced)
          Dir.mkdir(destination)
          File.write(File.join(destination, "keep.txt"), "replacement")
          super
        end
      end
      generator = generator_class.new(name: "MyApp", current_directory: directory)

      error = assert_raises(LittleGhost::Generators::ApplicationGenerator::GenerationError) { generator.generate }

      assert_includes error.message, "Destination changed during generation"
      assert_equal "replacement", File.read(File.join(generator.replacement, "keep.txt"))
      assert_path_exists generator.displaced
    end
  end

  def test_generation_failure_never_publishes_a_partial_destination
    Dir.mktmpdir do |directory|
      templates = File.join(directory, "templates")
      FileUtils.mkdir_p(templates)
      generator = LittleGhost::Generators::ApplicationGenerator.new(
        name: "BrokenApp",
        current_directory: directory,
        template_root: templates
      )

      assert_raises(LittleGhost::Generators::ApplicationGenerator::GenerationError) { generator.generate }

      refute_path_exists File.join(directory, "broken_app")
      assert_empty Dir.glob(File.join(directory, ".broken_app-*"))
    end
  end

  def test_child_path_collision_removes_the_partial_application
    Dir.mktmpdir do |directory|
      generator_class = Class.new(LittleGhost::Generators::ApplicationGenerator) do
        private

        def create_directories(destination, identity, files)
          Dir.mkdir(File.join(destination, "app"))
          super
        end
      end
      generator = generator_class.new(name: "MyApp", current_directory: directory)

      error = assert_raises(LittleGhost::Generators::ApplicationGenerator::GenerationError) { generator.generate }

      assert_includes error.message, "File exists"
      refute_path_exists File.join(directory, "my_app")
    end
  end

  def test_directory_mode_restoration_has_a_portable_fallback
    Dir.mktmpdir do |directory|
      destination = File.join(directory, "staging")
      Dir.mkdir(destination, 0o700)
      stat = File.lstat(destination)
      identity = [stat.dev, stat.ino]
      generator = LittleGhost::Generators::ApplicationGenerator.new(name: "MyApp", current_directory: directory)

      generator.send(:restore_directory_mode, destination, identity, 0o755, nofollow_supported: false)

      assert_equal 0o755, File.stat(destination).mode & 0o777
    end
  end

  def test_directory_mode_restoration_rejects_a_different_inode
    Dir.mktmpdir do |directory|
      destination = File.join(directory, "staging")
      Dir.mkdir(destination, 0o700)
      generator = LittleGhost::Generators::ApplicationGenerator.new(name: "MyApp", current_directory: directory)

      error = assert_raises(LittleGhost::Generators::ApplicationGenerator::GenerationError) do
        generator.send(:restore_directory_mode, destination, [-1, -1], 0o755)
      end

      assert_includes error.message, "Destination changed during generation"
      assert_equal 0o700, File.stat(destination).mode & 0o777
    end
  end

  def test_generated_ruby_is_valid_and_local_command_uses_the_application_bundle
    Dir.mktmpdir do |directory|
      repository_root = File.expand_path("..", __dir__)
      reference = File.join(directory, "reference")
      Dir.mkdir(reference)
      generator = LittleGhost::Generators::ApplicationGenerator.new(
        name: "MyApp",
        current_directory: directory,
        dependency_path: repository_root
      )
      root = generator.generate
      binary = File.join(root, "bin/little_ghost")
      agent = File.join(root, "app/agents/my_app_agent.rb")
      config = File.join(root, "config/little_ghost.rb")

      [binary, agent, config].each do |file|
        _output, status = Open3.capture2e(RbConfig.ruby, "-c", file)
        assert_predicate status, :success?, file
      end

      assert_equal File.stat(reference).mode & 0o777, File.stat(root).mode & 0o777

      assert_includes File.read(File.join(root, "Gemfile")), %(gem "little_ghost", path: #{repository_root.dump})
      bundle_environment = {}
      if (configured_bundle_path = Bundler.settings[:path])
        bundle_environment["BUNDLE_PATH"] = File.expand_path(configured_bundle_path.to_s, repository_root)
      end
      bundle_output, bundle_status = Bundler.with_unbundled_env do
        Open3.capture2e(
          bundle_environment.merge("BUNDLE_GEMFILE" => File.join(root, "Gemfile")),
          Gem.bin_path("bundler", "bundle"),
          "install",
          "--local",
          chdir: root
        )
      end
      assert_predicate bundle_status, :success?, bundle_output

      output, status = Bundler.with_unbundled_env do
        Open3.capture2e(
          bundle_environment.merge("BUNDLE_GEMFILE" => File.join(repository_root, "Gemfile")),
          RbConfig.ruby,
          binary,
          "--help"
        )
      end
      assert_predicate status, :success?, output
      assert_includes output, "little_ghost console"

      output, status = Bundler.with_unbundled_env do
        Open3.capture2e(
          bundle_environment.merge("BUNDLE_GEMFILE" => File.join(repository_root, "Gemfile")),
          RbConfig.ruby,
          binary,
          "console",
          stdin_data: "puts LittleGhost.runtime.settings.fetch(:service_name)\nputs MyAppAgent.name\nexit\n"
        )
      end
      assert_predicate status, :success?, output
      assert_includes output, "my_app"
      assert_includes output, "MyAppAgent"
    end
  end

  def test_lists_and_shows_bundled_framework_prompts
    stdout = StringIO.new
    stderr = StringIO.new

    assert_equal 0, LittleGhost::CLI.new(["prompts", "list"], stdout:, stderr:).run
    lines = stdout.string.lines
    assert_equal lines.sort, lines
    assert_includes lines, "agent/\tDefault Agent instructions and interjection prompts\t2 templates\n"
    assert_includes lines, "output/\tShared model-visible output formatting\t1 template\n"
    assert_empty stderr.string

    stdout = StringIO.new
    assert_equal 0, LittleGhost::CLI.new(["prompts", "list", "agent"], stdout:, stderr:).run
    assert_equal [
      "agent/interjections/\tAgent interjection behavior\t1 template\n",
      "agent/system/\tSystem instructions\t1 template\n"
    ], stdout.string.lines

    stdout = StringIO.new
    assert_equal 0, LittleGhost::CLI.new(["prompts", "list", "agent/system"], stdout:, stderr:).run
    assert_equal "agent/system/default\tDefault system instruction\n", stdout.string

    stdout = StringIO.new
    assert_equal 0, LittleGhost::CLI.new(["prompts", "list", "agent", "--all"], stdout:, stderr:).run
    assert_includes stdout.string, "agent/system/default\tDefault system instruction\n"
    assert_includes stdout.string, "agent/interjections/instructions\tInstruction preceding an interjection\n"

    stdout = StringIO.new
    assert_equal 0, LittleGhost::CLI.new(
      ["prompts", "show", "agent/system/default"],
      stdout:,
      stderr:
    ).run
    assert_equal File.binread(
      LittleGhost::FrameworkPrompts.new.source("agent/system/default")
    ), stdout.string
    assert stdout.string.start_with?("<%#\n# Key: agent/system/default\n")
    assert_empty stderr.string
  end

  def test_prompt_list_rejects_template_keys_unknown_prefixes_and_unsafe_arguments
    {
      ["prompts", "list", "agent/system/default"] => "use prompts show agent/system/default",
      ["prompts", "list", "not/a/prefix"] => "Unknown framework prompt prefix",
      ["prompts", "list", "../escape"] => "PREFIX must be a lowercase logical path",
      ["prompts", "list", "agent", "extra"] => "at most one PREFIX",
      ["prompts", "list", "--wat"] => "Unknown option",
      ["prompts", "list", "--all", "--all"] => "--all may only be specified once"
    }.each do |arguments, expected|
      stdout = StringIO.new
      stderr = StringIO.new

      assert_equal 1, LittleGhost::CLI.new(arguments, stdout:, stderr:).run
      assert_empty stdout.string
      assert_includes stderr.string, expected
    end
  end

  def test_copies_a_framework_prompt_to_the_default_runtime_location
    Dir.mktmpdir do |directory|
      stdout = StringIO.new
      stderr = StringIO.new

      assert_equal 0, LittleGhost::CLI.new(
        ["prompts", "copy", "agent/system/default"],
        stdout:,
        stderr:,
        current_directory: directory
      ).run

      destination = File.join(directory, "app/prompts/little_ghost/agent/system/default.erb")
      assert_equal File.binread(
        LittleGhost::FrameworkPrompts.new.source("agent/system/default")
      ), File.binread(destination)
      assert_includes stdout.string, destination
      assert_empty stderr.string
    end
  end

  def test_copies_to_an_agent_scoped_custom_root
    Dir.mktmpdir do |directory|
      stdout = StringIO.new
      stderr = StringIO.new

      assert_equal 0, LittleGhost::CLI.new(
        [
          "prompts", "copy", "agent/interjections/instructions",
          "--root", "config/prompts", "--agent", "admin/customer_support"
        ],
        stdout:,
        stderr:,
        current_directory: directory
      ).run

      destination = File.join(
        directory,
        "config/prompts/admin/customer_support/little_ghost/agent/interjections/instructions.erb"
      )
      assert_path_exists destination
      assert_includes stdout.string, destination
      assert_empty stderr.string
    end
  end

  def test_copy_all_refuses_existing_destinations_before_writing_any_prompt
    Dir.mktmpdir do |directory|
      existing = File.join(directory, "prompts/little_ghost/agent/interjections/instructions.erb")
      FileUtils.mkdir_p(File.dirname(existing))
      File.write(existing, "keep me")
      stdout = StringIO.new
      stderr = StringIO.new

      assert_equal 1, LittleGhost::CLI.new(
        ["prompts", "copy", "--all", "--root", "prompts"],
        stdout:,
        stderr:,
        current_directory: directory
      ).run

      assert_equal "keep me", File.read(existing)
      assert_empty stdout.string
      assert_includes stderr.string, "Refusing to overwrite"
      assert_equal [existing], Dir.glob(File.join(directory, "prompts/**/*")).reject { |path| File.directory?(path) }
    end
  end

  def test_copy_all_writes_every_catalog_entry
    Dir.mktmpdir do |directory|
      stdout = StringIO.new
      stderr = StringIO.new

      assert_equal 0, LittleGhost::CLI.new(
        ["prompts", "copy", "--all"],
        stdout:,
        stderr:,
        current_directory: directory
      ).run

      copied = Dir.glob(File.join(directory, "app/prompts/little_ghost/**/*.erb"))
      assert_equal LittleGhost::FrameworkPrompts.entries.length, copied.length
      assert_equal copied.length, stdout.string.lines.length
      assert_empty stderr.string
    end
  end

  def test_prompt_commands_reject_unknown_keys_and_unsafe_arguments
    [
      ["prompts"],
      ["prompts", "unknown"],
      ["prompts", "show"],
      ["prompts", "show", "not/a/key"],
      ["prompts", "copy"],
      ["prompts", "copy", "--all", "agent/system/default"],
      ["prompts", "copy", "agent/system/default", "--root"],
      ["prompts", "copy", "agent/system/default", "--agent", "../escape"],
      ["prompts", "copy", "agent/system/default", "--force"]
    ].each do |arguments|
      Dir.mktmpdir do |directory|
        stdout = StringIO.new
        stderr = StringIO.new

        assert_equal 1, LittleGhost::CLI.new(
          arguments,
          stdout:,
          stderr:,
          current_directory: directory
        ).run
        assert_empty stdout.string
        assert_includes stderr.string, "Error:"
        assert_empty Dir.children(directory)
      end
    end
  end

  def test_copy_rejects_a_root_that_is_not_a_directory
    Dir.mktmpdir do |directory|
      root = File.join(directory, "prompts")
      File.write(root, "keep me")
      stdout = StringIO.new
      stderr = StringIO.new

      assert_equal 1, LittleGhost::CLI.new(
        ["prompts", "copy", "agent/system/default", "--root", root],
        stdout:,
        stderr:,
        current_directory: directory
      ).run

      assert_equal "keep me", File.read(root)
      assert_empty stdout.string
      assert_includes stderr.string, "--root is not a directory"
    end
  end

  def test_copy_refuses_symlinked_destination_components
    [
      ["app/prompts/little_ghost", []],
      ["app/prompts/admin", ["--agent", "admin/customer_support"]]
    ].each do |relative_symlink, arguments|
      Dir.mktmpdir do |directory|
        outside = Dir.mktmpdir
        symlink = File.join(directory, relative_symlink)
        FileUtils.mkdir_p(File.dirname(symlink))
        File.symlink(outside, symlink)
        stdout = StringIO.new
        stderr = StringIO.new

        assert_equal 1, LittleGhost::CLI.new(
          ["prompts", "copy", "agent/system/default", *arguments],
          stdout:,
          stderr:,
          current_directory: directory
        ).run

        assert_empty stdout.string
        assert_includes stderr.string, "symbolic link"
        assert_empty Dir.children(outside)
      ensure
        FileUtils.remove_entry(outside) if outside && File.exist?(outside)
      end
    end
  end

  def test_gem_packages_bundled_framework_prompt_templates
    specification = Gem::Specification.load(File.expand_path("../little_ghost.gemspec", __dir__))
    packaged = specification.files.grep(%r{\Alib/little_ghost/prompts/.+\.erb\z})

    assert_equal LittleGhost::FrameworkPrompts.entries.length, packaged.length
    assert_includes packaged, "lib/little_ghost/prompts/little_ghost/agent/system/default.erb"
  end

  private

  def assert_generated_tree(root, directory_name)
    expected = [
      ".gitignore",
      "Gemfile",
      "Gemfile.lock",
      "README.md",
      "app/agents/#{directory_name}_agent.rb",
      "app/assemblies/.keep",
      "app/prompts/#{directory_name}/system_prompt.erb",
      "app/skills/.keep",
      "app/tools/.keep",
      "bin/little_ghost",
      "config/little_ghost.rb"
    ]
    actual = Dir.glob(File.join(root, "**/*"), File::FNM_DOTMATCH)
      .reject { |path| [".", ".."].include?(File.basename(path)) || File.directory?(path) }
      .map { |path| path.delete_prefix("#{root}/") }
      .sort

    assert_equal expected.sort, actual
    assert_equal 0o755, File.stat(File.join(root, "bin/little_ghost")).mode & 0o777
    assert_includes File.read(File.join(root, "Gemfile")), "~> #{LittleGhost::VERSION}"
    assert_includes File.read(File.join(root, "README.md")), "OPENROUTER_API_KEY"
  end
end
