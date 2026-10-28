# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class SkillsTest < Minitest::Test
  def test_discovers_and_loads_skill_instructions
    Dir.mktmpdir do |directory|
      skill_directory = File.join(directory, "review")
      Dir.mkdir(skill_directory)
      File.write(File.join(skill_directory, "SKILL.md"), <<~MARKDOWN)
        ---
        name: review
        description: Review code carefully
        allowed-tools: Read Grep
        compatibility: Ruby 3.3+
        ---
        Read every changed file.
      MARKDOWN
      FileUtils.mkdir_p(File.join(skill_directory, "references", "nested"))
      File.write(File.join(skill_directory, "references", "nested", "guide.md"), "Guide")

      catalog = LittleGhost::Skills::Catalog.new(paths: directory)

      assert_equal ["review"], catalog.names
      assert_includes catalog.discovery_prompt, "**Name:** review"
      assert_includes catalog.discovery_prompt, "**Description:** Review code carefully"
      result = catalog.tool.new.execute({"skill_name" => "review"})
      assert_includes result.content, "Read every changed file."
      assert_includes result.content, "Allowed tools: Read, Grep"
      assert_includes result.content, "Compatibility: Ruby 3.3+"
      assert_includes result.content, "Location: #{File.realpath(File.join(skill_directory, "SKILL.md"))}"
      assert_includes result.content, "references/nested/guide.md"
      assert_equal ["skill_name"], catalog.tool.input_schema.fetch("required")
    end
  end

  def test_unknown_skill_error_names_available_skills
    Dir.mktmpdir do |directory|
      %w[review security].each do |name|
        skill_directory = File.join(directory, name)
        Dir.mkdir(skill_directory)
        File.write(
          File.join(skill_directory, "SKILL.md"),
          "---\nname: #{name}\ndescription: #{name}\n---\nInstructions"
        )
      end
      catalog = LittleGhost::Skills::Catalog.new(paths: directory)

      result = catalog.tool.new.execute({
        "skill_name" => "review pr https://example.test/pull/123"
      })

      assert result.error?
      assert_equal(
        "Unknown skill: review pr https://example.test/pull/123. Available skills: review, security",
        result.content
      )
      assert_instance_of LittleGhost::ToolError, result.error
    end
  end

  def test_unknown_skill_error_omits_available_skills_for_an_empty_catalog
    Dir.mktmpdir do |directory|
      catalog = LittleGhost::Skills::Catalog.new(paths: directory)

      error = assert_raises(LittleGhost::ConfigurationError) { catalog.fetch("review") }

      assert_equal "Unknown skill: review", error.message
    end
  end

  def test_skips_malformed_skills_without_hiding_valid_siblings
    Dir.mktmpdir do |directory|
      skills = {
        "valid" => "---\nname: valid\ndescription: Valid skill\n---\nUseful instructions",
        "missing-front-matter" => "instructions",
        "malformed-yaml" => "---\nname: [\ndescription: Broken YAML\n---\nBroken",
        "invalid-name" => "---\nname: invalid/name\ndescription: Unsafe name\n---\nBroken"
      }
      skills.each do |name, contents|
        skill_directory = File.join(directory, name)
        Dir.mkdir(skill_directory)
        File.write(File.join(skill_directory, "SKILL.md"), contents)
      end

      catalog = LittleGhost::Skills::Catalog.new(paths: directory)

      assert_equal ["valid"], catalog.names
      assert_equal "Useful instructions", catalog.fetch("valid").instructions
    end
  end

  def test_skips_an_unreadable_skill_without_hiding_valid_siblings
    Dir.mktmpdir do |directory|
      %w[valid unreadable].each do |name|
        skill_directory = File.join(directory, name)
        Dir.mkdir(skill_directory)
        File.write(
          File.join(skill_directory, "SKILL.md"),
          "---\nname: #{name}\ndescription: #{name}\n---\nInstructions"
        )
      end
      unreadable_path = File.realpath(File.join(directory, "unreadable", "SKILL.md"))
      original_read = File.method(:read)

      catalog = File.stub(:read, lambda { |path, *args, **options|
        raise Errno::EACCES, path if path == unreadable_path

        original_read.call(path, *args, **options)
      }) do
        LittleGhost::Skills::Catalog.new(paths: directory)
      end

      assert_equal ["valid"], catalog.names
    end
  end

  def test_catalog_skill_limit_counts_invalid_entries
    Dir.mktmpdir do |directory|
      2.times do |index|
        skill_directory = File.join(directory, "invalid-#{index}")
        Dir.mkdir(skill_directory)
        File.write(File.join(skill_directory, "SKILL.md"), "instructions")
      end

      error = assert_raises(LittleGhost::ConfigurationError) do
        LittleGhost::Skills::Catalog.new(paths: directory, max_skills: 1)
      end

      assert_equal "Skill catalog exceeds 1 skills", error.message
    end
  end

  def test_later_paths_override_duplicate_skill_names
    Dir.mktmpdir do |first_root|
      Dir.mktmpdir do |second_root|
        [
          [first_root, "First instructions"],
          [second_root, "Second instructions"]
        ].each do |root, instructions|
          directory = File.join(root, "review")
          Dir.mkdir(directory)
          File.write(
            File.join(directory, "SKILL.md"),
            "---\nname: review\ndescription: Review code\n---\n#{instructions}"
          )
        end

        catalog = LittleGhost::Skills::Catalog.new(paths: [first_root, second_root])

        assert_equal "Second instructions", catalog.fetch("review").instructions
        assert_equal File.realpath(File.join(second_root, "review", "SKILL.md")), catalog.fetch("review").path
        assert_equal File.realpath(File.join(second_root, "review", "SKILL.md")), catalog.fetch("review").source_path
      end
    end
  end

  def test_exposes_agent_paths_without_changing_physical_skill_access
    Dir.mktmpdir do |first_root|
      Dir.mktmpdir do |second_root|
        first_directory = File.join(first_root, "review")
        second_directory = File.join(second_root, "deploy")
        FileUtils.mkdir_p(File.join(first_directory, "references"))
        Dir.mkdir(second_directory)
        File.write(
          File.join(first_directory, "SKILL.md"),
          "---\nname: review\ndescription: Review code\n---\nRead the guide."
        )
        File.write(File.join(first_directory, "references", "guide.md"), "Guide")
        File.write(
          File.join(second_directory, "SKILL.md"),
          "---\nname: deploy\ndescription: Deploy code\n---\nDeploy safely."
        )

        catalog = LittleGhost::Skills::Catalog.new(
          paths: [first_root, second_root],
          resource_root: "/skills"
        )

        review = catalog.fetch("review")
        assert_equal "/skills/review/SKILL.md", review.path
        assert_equal File.realpath(File.join(first_directory, "SKILL.md")), review.source_path
        assert_includes catalog.discovery_prompt, "**Location:** /skills/review/SKILL.md"
        result = catalog.tool.new.execute({"skill_name" => "review"})
        assert_includes result.content, "Location: /skills/review/SKILL.md"
        assert_includes result.content, "/skills/review/references/guide.md"
        assert_equal "/skills/deploy/SKILL.md", catalog.fetch("deploy").path
      end
    end
  end

  def test_rejects_relative_resource_roots
    Dir.mktmpdir do |directory|
      error = assert_raises(ArgumentError) do
        LittleGhost::Skills::Catalog.new(paths: directory, resource_root: "skills")
      end

      assert_equal "resource_root must be an absolute path or workspace:// reference", error.message
    end
  end

  def test_maps_skill_locations_to_workspace_references
    Dir.mktmpdir do |directory|
      skill_directory = File.join(directory, "review")
      FileUtils.mkdir_p(File.join(skill_directory, "references"))
      File.write(
        File.join(skill_directory, "SKILL.md"),
        "---\nname: review\ndescription: Review code\n---\nRead the guide."
      )
      File.write(File.join(skill_directory, "references", "guide.md"), "Guide")

      workspace, sandbox = workspace_resources(directory)
      catalog = LittleGhost::Skills::Catalog.new(
        paths: directory,
        resource_root: "workspace://skills",
        workspace:,
        sandbox:
      )

      assert_equal "workspace://skills/review/SKILL.md", catalog.fetch("review").path
      result = catalog.tool.new.execute({"skill_name" => "review"})
      assert_includes result.content, "Location: workspace://skills/review/SKILL.md"
      assert_includes result.content, "workspace://skills/review/references/guide.md"
    ensure
      workspace&.close
    end
  end

  def test_agent_uses_the_runtime_workspace_resource_root
    Dir.mktmpdir do |directory|
      skill_directory = File.join(directory, "review")
      Dir.mkdir(skill_directory)
      File.write(
        File.join(skill_directory, "SKILL.md"),
        "---\nname: review\ndescription: Review code\n---\nRead the guide."
      )
      runtime = Struct.new(
        :skill_paths, :skill_resource_root, :task_runner, :runtime_hooks, :code_mode_configuration
      ).new(
        [directory], "workspace://skills", LittleGhost::Support::TaskRunner.new, [], nil
      )
      workspace, sandbox = workspace_resources(directory)
      run = Struct.new(:runtime, :workspace, :sandbox).new(runtime, workspace, sandbox)
      agent_class = Class.new(LittleGhost::Agent) do
        system_prompt "Review carefully."
        skills
      end
      agent = agent_class.new(
        model: Object.new.extend(LittleGhost::ModelInterface),
        runtime:,
        run:
      )

      catalog = agent.tools.fetch("skills").catalog
      assert_equal "workspace://skills/review/SKILL.md", catalog.fetch("review").path
    ensure
      agent&.close
      workspace&.close
    end
  end

  def test_rejects_workspace_resource_roots_without_a_bound_workspace
    Dir.mktmpdir do |directory|
      error = assert_raises(LittleGhost::ConfigurationError) do
        LittleGhost::Skills::Catalog.new(paths: directory, resource_root: "workspace://skills")
      end

      assert_equal "workspace resource_root requires a Workspace and Sandbox", error.message
    end
  end

  def test_rejects_workspace_resource_roots_that_map_to_different_content
    Dir.mktmpdir do |directory|
      Dir.mktmpdir do |other|
        workspace, sandbox = workspace_resources(other)

        error = assert_raises(LittleGhost::ConfigurationError) do
          LittleGhost::Skills::Catalog.new(
            paths: directory,
            resource_root: "workspace://skills",
            workspace:,
            sandbox:
          )
        end

        assert_equal "workspace resource_root must map to each skill path", error.message
      ensure
        workspace&.close
      end
    end
  end

  def test_rejects_writable_workspace_resource_roots
    Dir.mktmpdir do |directory|
      workspace = LittleGhost::Workspace.new(
        root: Dir.mktmpdir,
        paths: {skills: directory},
        teardown: method(:remove_workspace_root)
      ).open
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace:,
        policy: {files: {skills: :read_write}, network: :inherit}
      )

      error = assert_raises(LittleGhost::ConfigurationError) do
        LittleGhost::Skills::Catalog.new(
          paths: directory,
          resource_root: "workspace://skills",
          workspace:,
          sandbox:
        )
      end

      assert_equal "workspace resource_root must be tool-readable and read-only", error.message
    ensure
      workspace&.close
    end
  end

  def test_rejects_a_sandbox_bound_to_a_different_workspace
    Dir.mktmpdir do |directory|
      workspace, = workspace_resources(directory)
      other_workspace, sandbox = workspace_resources(directory)

      error = assert_raises(LittleGhost::ConfigurationError) do
        LittleGhost::Skills::Catalog.new(
          paths: directory,
          resource_root: "workspace://skills",
          workspace:,
          sandbox:
        )
      end

      assert_equal "workspace resource_root requires the Sandbox bound to its Workspace", error.message
    ensure
      workspace&.close
      other_workspace&.close
    end
  end

  def test_rejects_writable_grants_nested_inside_a_workspace_resource_root
    Dir.mktmpdir do |directory|
      skill_directory = File.join(directory, "review")
      Dir.mkdir(skill_directory)
      File.write(
        File.join(skill_directory, "SKILL.md"),
        "---\nname: review\ndescription: Review code\n---\nRead carefully."
      )
      workspace = LittleGhost::Workspace.new(
        root: Dir.mktmpdir,
        paths: {skills: directory, mutable_skill: skill_directory},
        teardown: method(:remove_workspace_root)
      ).open
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace:,
        policy: {
          files: {skills: :read_only, mutable_skill: :read_write},
          network: :inherit
        }
      )

      error = assert_raises(LittleGhost::ConfigurationError) do
        LittleGhost::Skills::Catalog.new(
          paths: directory,
          resource_root: "workspace://skills",
          workspace:,
          sandbox:
        )
      end

      assert_equal "workspace resource_root must not contain writable file grants", error.message
    ensure
      workspace&.close
    end
  end

  def test_rejects_writable_grants_that_alias_a_skill_directory
    Dir.mktmpdir do |directory|
      skill_directory = File.join(directory, "review")
      writable_alias = Dir.mktmpdir
      Dir.mkdir(skill_directory)
      File.write(
        File.join(skill_directory, "SKILL.md"),
        "---\nname: review\ndescription: Review code\n---\nRead carefully."
      )
      workspace = LittleGhost::Workspace.new(
        root: Dir.mktmpdir,
        paths: {skills: directory},
        teardown: method(:remove_workspace_root)
      ).open
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace:,
        policy: {files: {skills: :read_only}, network: :inherit}
      )
      grants = sandbox.scope.process_grants
      writable_grant = LittleGhost::Sandbox::Mount.new(
        source: writable_alias,
        target: "/writable-skill-alias",
        access: :read_write
      )
      sandbox.define_singleton_method(:process_grants) { [*grants, writable_grant] }
      original_stat = File.method(:stat)
      physical_alias = File.realpath(writable_alias)

      error = File.stub(:stat, lambda { |path|
        [writable_alias, physical_alias].include?(path) ? original_stat.call(skill_directory) : original_stat.call(path)
      }) do
        assert_raises(LittleGhost::ConfigurationError) do
          LittleGhost::Skills::Catalog.new(
            paths: directory,
            resource_root: "workspace://skills",
            workspace:,
            sandbox:
          )
        end
      end

      assert_equal "workspace resource_root must not contain writable file grants", error.message
    ensure
      workspace&.close
      FileUtils.remove_entry(writable_alias) if writable_alias && Dir.exist?(writable_alias)
    end
  end

  def test_rejects_malformed_workspace_resource_roots
    Dir.mktmpdir do |directory|
      invalid = [
        "workspace://",
        "workspace:///skills",
        "workspace://skills/",
        "workspace://skills/../private",
        "workspace://skills//private",
        "workspace://skills\\private",
        "workspace://skills\0/private"
      ]

      invalid.each do |resource_root|
        error = assert_raises(ArgumentError) do
          LittleGhost::Skills::Catalog.new(paths: directory, resource_root:)
        end
        assert_equal "resource_root must be an absolute path or workspace:// reference", error.message
      end
    end
  end

  def test_rejects_skill_symlinks_that_escape_the_catalog
    Dir.mktmpdir do |directory|
      Dir.mktmpdir do |outside|
        outside_skill = File.join(outside, "SKILL.md")
        File.write(outside_skill, "---\nname: escaped\ndescription: Escaped\n---\nDo things")
        skill_directory = File.join(directory, "escaped")
        Dir.mkdir(skill_directory)
        File.symlink(outside_skill, File.join(skill_directory, "SKILL.md"))

        assert_raises(LittleGhost::ConfigurationError) do
          LittleGhost::Skills::Catalog.new(paths: directory)
        end
      end
    end
  end

  def test_first_precedence_keeps_the_earliest_definition
    Dir.mktmpdir do |first_root|
      Dir.mktmpdir do |second_root|
        write_skill(first_root, "review", body: "First instructions")
        write_skill(second_root, "review", body: "Second instructions")

        catalog = LittleGhost::Skills::Catalog.new(paths: [first_root, second_root], precedence: :first)

        assert_equal "First instructions", catalog.fetch("review").instructions
      end
    end
  end

  def test_error_precedence_rejects_duplicate_names
    Dir.mktmpdir do |first_root|
      Dir.mktmpdir do |second_root|
        write_skill(first_root, "review")
        write_skill(second_root, "review")

        error = assert_raises(LittleGhost::ConfigurationError) do
          LittleGhost::Skills::Catalog.new(paths: [first_root, second_root], precedence: :error)
        end

        assert_includes error.message, "Skill review is defined more than once"
      end
    end
  end

  def test_error_precedence_ignores_duplicates_outside_the_selection
    Dir.mktmpdir do |first_root|
      Dir.mktmpdir do |second_root|
        write_skill(first_root, "review")
        write_skill(second_root, "review")
        write_skill(second_root, "deploy")

        catalog = LittleGhost::Skills::Catalog.new(
          paths: [first_root, second_root], precedence: :error, only: %w[deploy]
        )

        assert_equal ["deploy"], catalog.names
      end
    end
  end

  def test_rejects_unknown_precedence
    Dir.mktmpdir do |directory|
      error = assert_raises(ArgumentError) do
        LittleGhost::Skills::Catalog.new(paths: directory, precedence: :newest)
      end

      assert_equal "precedence must be one of: last, first, error", error.message
    end
  end

  def test_skips_skills_whose_name_differs_from_their_directory
    Dir.mktmpdir do |first_root|
      Dir.mktmpdir do |second_root|
        write_skill(first_root, "review", body: "Trusted instructions")
        write_skill(second_root, "zzz", name: "review", body: "Colliding instructions")

        catalog = LittleGhost::Skills::Catalog.new(paths: [first_root, second_root])

        assert_equal ["review"], catalog.names
        assert_equal "Trusted instructions", catalog.fetch("review").instructions
      end
    end
  end

  def test_skips_linked_skill_directories_and_manifests_inside_the_root
    Dir.mktmpdir do |directory|
      write_skill(directory, "review")
      File.symlink(File.join(directory, "review"), File.join(directory, "linked"))
      Dir.mkdir(File.join(directory, "manifest"))
      File.write(File.join(directory, "manifest.md"), "---\nname: manifest\ndescription: Linked\n---\nText")
      File.symlink(File.join(directory, "manifest.md"), File.join(directory, "manifest", "SKILL.md"))

      catalog = LittleGhost::Skills::Catalog.new(paths: directory)

      assert_equal ["review"], catalog.names
    end
  end

  def test_materializes_layered_skills_into_one_directory
    Dir.mktmpdir do |shared_root|
      Dir.mktmpdir do |application_root|
        Dir.mktmpdir do |destination|
          write_skill(shared_root, "review", body: "Shared review")
          write_skill(shared_root, "deploy", body: "Shared deploy")
          write_skill(application_root, "review", body: "Application review")
          FileUtils.mkdir_p(File.join(shared_root, "deploy", "scripts", "nested"))
          File.write(File.join(shared_root, "deploy", "scripts", "nested", "check.sh"), "exit 0")
          File.chmod(0o775, File.join(shared_root, "deploy", "scripts", "nested", "check.sh"))
          File.write(File.join(destination, "unrelated.txt"), "Kept")
          catalog = LittleGhost::Skills::Catalog.new(paths: [shared_root, application_root])

          materialized = catalog.materialize(destination)

          assert_equal File.realpath(destination), materialized
          assert_equal %w[deploy review unrelated.txt], Dir.children(destination).sort
          assert_includes File.read(File.join(destination, "review", "SKILL.md")), "Application review"
          script = File.join(destination, "deploy", "scripts", "nested", "check.sh")
          assert_equal "exit 0", File.read(script)
          assert_equal 0o755, File.stat(script).mode & 0o777
          assert_equal(
            {"deploy" => "Shared deploy", "review" => "Application review"},
            LittleGhost::Skills::Catalog.new(paths: destination).to_h { |skill| [skill.name, skill.instructions] }
          )
        end
      end
    end
  end

  def test_materialize_replaces_an_existing_skill_with_the_same_name
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |destination|
        write_skill(root, "review", body: "Current instructions")
        write_skill(destination, "review", body: "Stale instructions")
        File.write(File.join(destination, "review", "stale.md"), "Stale")

        LittleGhost::Skills::Catalog.new(paths: root).materialize(destination)

        assert_equal ["SKILL.md"], Dir.children(File.join(destination, "review"))
        assert_includes File.read(File.join(destination, "review", "SKILL.md")), "Current instructions"
      end
    end
  end

  def test_materialize_copies_only_selected_valid_skills
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |destination|
        write_skill(root, "review")
        write_skill(root, "deploy")
        Dir.mkdir(File.join(root, "empty"))
        FileUtils.touch(File.join(root, "empty", "SKILL.md"))
        Dir.mkdir(File.join(root, "invalid"))
        File.binwrite(File.join(root, "invalid", "SKILL.md"), "---\nname: invalid\ndescription: Invalid\n---\n\xFF".b)

        LittleGhost::Skills::Catalog.new(paths: root, only: %w[review empty invalid]).materialize(destination)

        assert_equal ["review"], Dir.children(destination)
      end
    end
  end

  def test_materialize_skips_symbolic_links_inside_a_skill
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |outside|
        Dir.mktmpdir do |destination|
          write_skill(root, "review")
          File.write(File.join(outside, "secret.txt"), "Outside")
          FileUtils.mkdir_p(File.join(root, "review", "references"))
          File.write(File.join(root, "review", "references", "guide.md"), "Guide")
          File.symlink(File.join(outside, "secret.txt"), File.join(root, "review", "references", "secret.txt"))
          File.symlink(outside, File.join(root, "review", "assets"))

          LittleGhost::Skills::Catalog.new(paths: root).materialize(destination)

          assert_equal %w[SKILL.md references], Dir.children(File.join(destination, "review")).sort
          assert_equal ["guide.md"], Dir.children(File.join(destination, "review", "references"))
        end
      end
    end
  end

  def test_materialize_rejects_a_destination_that_overlaps_a_skill_root
    Dir.mktmpdir do |root|
      write_skill(root, "review")
      catalog = LittleGhost::Skills::Catalog.new(paths: root)

      [File.join(root, "materialized"), File.dirname(root)].each do |destination|
        error = assert_raises(LittleGhost::ConfigurationError) { catalog.materialize(destination) }

        assert_equal "Skill destination overlaps a skill path: #{destination}", error.message
      end
      refute Dir.exist?(File.join(root, "materialized"))
    end
  end

  def test_materialize_rejects_changed_descriptions_and_instructions
    [
      ["---\nname: review\ndescription: Changed\n---\nInstructions", "description"],
      ["---\nname: review\ndescription: review\n---\nChanged instructions", "instructions"]
    ].each do |manifest, field|
      Dir.mktmpdir do |root|
        Dir.mktmpdir do |destination|
          write_skill(root, "review")
          catalog = LittleGhost::Skills::Catalog.new(paths: root)
          File.write(File.join(root, "review", "SKILL.md"), manifest)

          error = assert_raises(LittleGhost::ConfigurationError, field) { catalog.materialize(destination) }

          assert_equal "Skill changed before it could be materialized: review", error.message
          assert_empty Dir.children(destination)
        end
      end
    end
  end

  def test_materialize_copies_only_the_manifest_and_resource_directories
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |destination|
        write_skill(root, "review")
        File.write(File.join(root, "review", "notes.md"), "Notes")
        FileUtils.mkdir_p(File.join(root, "review", "build"))
        FileUtils.mkdir_p(File.join(root, "review", "references"))
        File.write(File.join(root, "review", "references", "guide.md"), "Guide")

        LittleGhost::Skills::Catalog.new(paths: root).materialize(destination)

        assert_equal %w[SKILL.md references], Dir.children(File.join(destination, "review")).sort
      end
    end
  end

  def test_materialize_enforces_byte_file_and_depth_limits
    Dir.mktmpdir do |root|
      write_skill(root, "review")
      FileUtils.mkdir_p(File.join(root, "review", "assets"))
      File.write(File.join(root, "review", "assets", "large.bin"), "x" * 5_000)
      catalog = LittleGhost::Skills::Catalog.new(paths: root)

      {
        {max_bytes: 1_000} => "Skill materialization exceeds 1000 bytes",
        {max_files: 1} => "Skill materialization exceeds 1 files"
      }.each do |limits, message|
        Dir.mktmpdir do |destination|
          error = assert_raises(LittleGhost::ConfigurationError) { catalog.materialize(destination, **limits) }

          assert_equal message, error.message
          assert_empty Dir.children(destination)
        end
      end

      deep = File.join(root, "review", "scripts", "a", "b", "c")
      FileUtils.mkdir_p(deep)
      File.write(File.join(deep, "run.sh"), "exit 0")
      Dir.mktmpdir do |destination|
        error = assert_raises(LittleGhost::ConfigurationError) { catalog.materialize(destination) }

        assert_includes error.message, "Skill resources exceed 3 directory levels"
      end
    end
  end

  def test_materialize_keeps_the_previous_copy_when_a_replacement_fails
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |destination|
        write_skill(root, "review", body: "Current instructions")
        write_skill(destination, "review", body: "Previous instructions")
        FileUtils.mkdir_p(File.join(root, "review", "assets"))
        File.write(File.join(root, "review", "assets", "large.bin"), "x" * 5_000)

        assert_raises(LittleGhost::ConfigurationError) do
          LittleGhost::Skills::Catalog.new(paths: root).materialize(destination, max_bytes: 1_000)
        end

        assert_equal ["review"], Dir.children(destination)
        assert_includes File.read(File.join(destination, "review", "SKILL.md")), "Previous instructions"
      end
    end
  end

  def test_materialize_fails_on_unreadable_resources
    skip "root can read any file" if Process.uid.zero?

    Dir.mktmpdir do |root|
      Dir.mktmpdir do |destination|
        write_skill(root, "review")
        FileUtils.mkdir_p(File.join(root, "review", "references"))
        unreadable = File.join(root, "review", "references", "private.md")
        File.write(unreadable, "Private")
        File.chmod(0o000, unreadable)

        error = assert_raises(LittleGhost::ConfigurationError) do
          LittleGhost::Skills::Catalog.new(paths: root).materialize(destination)
        end

        assert_includes error.message, "Skills could not be materialized into #{destination}"
        assert_empty Dir.children(destination)
      ensure
        File.chmod(0o600, unreadable) if unreadable
      end
    end
  end

  def test_materialize_skips_named_pipes_without_blocking
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |destination|
        write_skill(root, "review")
        FileUtils.mkdir_p(File.join(root, "review", "scripts"))
        File.mkfifo(File.join(root, "review", "scripts", "pipe"))

        Timeout.timeout(5) { LittleGhost::Skills::Catalog.new(paths: root).materialize(destination) }

        assert_empty Dir.children(File.join(destination, "review", "scripts"))
      end
    end
  end

  def test_materialize_wraps_file_system_errors
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |parent|
        write_skill(root, "review")
        destination = File.join(parent, "file")
        File.write(destination, "Not a directory")

        error = assert_raises(LittleGhost::ConfigurationError) do
          LittleGhost::Skills::Catalog.new(paths: root).materialize(destination)
        end

        assert_includes error.message, "Skills could not be materialized into #{destination}"
      end
    end
  end

  def test_concurrent_materializations_of_one_destination_succeed
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |destination|
        write_skill(root, "review")
        write_skill(root, "deploy")
        FileUtils.mkdir_p(File.join(root, "review", "references"))
        20.times { |index| File.write(File.join(root, "review", "references", "guide-#{index}.md"), "Guide") }
        catalog = LittleGhost::Skills::Catalog.new(paths: root)

        threads = 4.times.map { Thread.new { 5.times { catalog.materialize(destination) } } }
        Timeout.timeout(30) { threads.each(&:join) }

        assert_equal %w[deploy review], Dir.children(destination).sort
        assert_equal 20, Dir.children(File.join(destination, "review", "references")).length
      end
    end
  end

  def test_materialize_removes_staging_entries_left_by_an_interrupted_call
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |destination|
        write_skill(root, "review")
        FileUtils.mkdir_p(File.join(destination, ".little_ghost-staging-review-stale", "references"))

        LittleGhost::Skills::Catalog.new(paths: root).materialize(destination)

        assert_equal ["review"], Dir.children(destination)
      end
    end
  end

  def test_warns_when_a_skill_is_skipped
    Dir.mktmpdir do |directory|
      write_skill(directory, "review")
      File.symlink(File.join(directory, "review"), File.join(directory, "linked"))
      write_skill(directory, "notes", name: "review")
      events = []
      listener = Object.new
      listener.define_singleton_method(:emit) { |event| events << event }

      LittleGhost::Events.subscribed(listener) { LittleGhost::Skills::Catalog.new(paths: directory) }

      skipped = events.select { |event| event[:name] == "little_ghost.skills.skill_skipped" }
      assert_equal(
        [["linked", "symbolic_link"], ["notes", "name_mismatch"]],
        skipped.map { |event| [event.dig(:payload, :skill), event.dig(:payload, :reason).to_s] }.sort
      )
    end
  end

  def test_materialize_rejects_a_manifest_that_changed_after_loading
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |destination|
        write_skill(root, "review")
        catalog = LittleGhost::Skills::Catalog.new(paths: root)
        File.write(File.join(root, "review", "SKILL.md"), "---\nname: deploy\ndescription: Swapped\n---\nText")

        error = assert_raises(LittleGhost::ConfigurationError) { catalog.materialize(destination) }

        assert_equal "Skill changed before it could be materialized: review", error.message
        assert_empty Dir.children(destination)
      end
    end
  end

  private

  def write_skill(root, directory, name: directory, body: "Instructions")
    FileUtils.mkdir_p(File.join(root, directory))
    File.write(File.join(root, directory, "SKILL.md"), "---\nname: #{name}\ndescription: #{name}\n---\n#{body}")
  end

  def workspace_resources(skill_root)
    workspace = LittleGhost::Workspace.new(
      root: Dir.mktmpdir,
      paths: {skills: skill_root},
      teardown: method(:remove_workspace_root)
    ).open
    sandbox = LittleGhost::Sandboxes::Unrestricted.new(
      workspace:,
      policy: {files: {skills: :read_only}, network: :inherit}
    )
    [workspace, sandbox]
  end

  def remove_workspace_root(workspace:, **)
    FileUtils.remove_entry(workspace.root) if Dir.exist?(workspace.root)
  end
end
