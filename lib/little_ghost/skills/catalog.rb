# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "yaml"
require_relative "resource_root"

module LittleGhost
  module Skills
    # A Catalog lets an agent discover focused instructions without putting every
    # skill in its prompt. The model sees short descriptions first and can load a
    # skill's full instructions when the task calls for them.
    #
    #   catalog = LittleGhost::Skills::Catalog.new(paths: ["app/skills"])
    #   catalog.names # => ["refund_policy", "search_orders"]
    #   catalog.discovery_prompt.include?("refund_policy") # => true
    #   catalog.tool # a LittleGhost::Tool that loads full instructions on demand
    #
    # Each immediate child directory may contain one +SKILL.md+ with YAML front
    # matter whose +name+ matches the directory name. A symbolic link that
    # escapes its root or an oversized file raises ConfigurationError. Linked
    # skill directories and manifests, unsafe or mismatched names, and invalid
    # UTF-8 or YAML are skipped before instructions reach a model, and each
    # skip emits a +little_ghost.skills.skill_skipped+ warning through Events
    # with the directory name and a +reason+. Optional resource listings are
    # limited by count and depth.
    #
    # === Layering skill roots
    #
    # When several roots define the same skill name, +precedence+ decides the
    # result: +:last+ (the default) lets a later root override an earlier one,
    # +:first+ keeps the earliest definition, and +:error+ raises
    # ConfigurationError. List roots so the one you trust most wins.
    #
    #   catalog = LittleGhost::Skills::Catalog.new(
    #     paths: [shared_skills, repository_skills, "app/skills"],
    #     precedence: :last
    #   )
    #   catalog.materialize("/srv/run/skills") # => "/srv/run/skills"
    #
    # #materialize copies the resolved skills into one directory, so a Sandbox
    # can expose a single read-only path instead of every source root.
    #
    # === Choosing skill sources
    #
    # Skill files become model instructions, so keep configured roots under
    # application control and non-user-writable. The +allowed-tools+ field tells
    # the model what a skill expects; the Agent's Tool list and each Tool's
    # application checks still decide what can run. For a <tt>workspace://</tt>
    # resource root, the Catalog verifies the named read-only grant and rejects
    # direct writable aliases it can identify. LittleGhost cannot identify every
    # alias created by an outer container or mount namespace, so the application
    # must not expose the same files through another writable bind mount.
    class Catalog
      include Enumerable

      class InvalidSkillError < ConfigurationError # :nodoc:
        attr_reader :reason

        def initialize(message = nil, reason: :invalid_manifest)
          super(message)
          @reason = reason
        end
      end
      private_constant :InvalidSkillError

      DEFAULT_MAX_SKILLS = 1_000 # :nodoc:
      DEFAULT_MAX_FILE_BYTES = 1_000_000 # :nodoc:
      DEFAULT_MAX_RESOURCE_FILES = 20 # :nodoc:
      MAX_RESOURCE_DEPTH = 3 # :nodoc:
      RESOURCE_DIRECTORIES = %w[scripts references assets].freeze # :nodoc:
      SAFE_NAME_PATTERN = /\A[a-zA-Z0-9_-]+\z/ # :nodoc:
      PRECEDENCES = %i[last first error].freeze # :nodoc:
      DEFAULT_MAX_MATERIALIZED_BYTES = 100_000_000 # :nodoc:
      DEFAULT_MAX_MATERIALIZED_FILES = 10_000 # :nodoc:
      STAGING_PREFIX = ".little_ghost-staging-" # :nodoc:

      # Loads valid skills immediately using the supplied safety limits.
      # +resource_root+ may be an absolute process-visible path. A
      # <tt>workspace://name</tt> reference also requires +workspace+ and
      # +sandbox+; it must resolve to every configured skill root through a
      # read-only file-tool grant. +precedence+ is +:last+, +:first+, or
      # +:error+ and decides which root wins when several define one name.
      def initialize(
        paths:,
        precedence: :last,
        max_skills: DEFAULT_MAX_SKILLS,
        max_file_bytes: DEFAULT_MAX_FILE_BYTES,
        max_resource_files: DEFAULT_MAX_RESOURCE_FILES,
        only: nil,
        resource_root: nil,
        workspace: nil,
        sandbox: nil,
        prompt_renderer: nil
      )
        @paths = PathSet.new(paths)
        @precedence = precedence
        unless PRECEDENCES.include?(@precedence)
          raise ArgumentError, "precedence must be one of: #{PRECEDENCES.join(", ")}"
        end
        @max_skills = positive_integer(max_skills, :max_skills)
        @max_file_bytes = positive_integer(max_file_bytes, :max_file_bytes)
        @max_resource_files = positive_integer(max_resource_files, :max_resource_files)
        @only = Array(only).map(&:to_s).freeze if only
        @resource_root = ResourceRoot.normalize(resource_root)
        @prompt_renderer = prompt_renderer
        @framework_prompts = FrameworkPrompts.new
        validate_workspace_resource_root!(workspace, sandbox)
        @skills = load_skills
        validate_workspace_resource_aliases!(sandbox)
      end

      # Yields each Skill in lookup order.
      def each(&block)
        @skills.each_value(&block)
      end

      # Finds the named Skill. When no Skill matches, the ConfigurationError
      # names the available skills so the caller can correct the lookup.
      def fetch(name)
        @skills.fetch(name.to_s) do
          raise ConfigurationError, framework_prompt("skills/feedback/unknown", name: name.to_s, available: names)
        end
      end

      # Lists immutable skill names in lookup order.
      def names
        @skills.keys.freeze
      end

      # Produces the Markdown, metadata-only prompt used for discovery.
      def discovery_prompt
        return "" if @skills.empty?

        framework_prompt(
          "skills/discovery/instructions",
          skills: @skills.each_value.map do |skill|
            {name: skill.name, description: skill.description, location: skill.path}
          end
        )
      end

      # Exposes full instructions on demand through a +skills+ Tool.
      def tool
        catalog = self
        Tool.define(
          name: "skills",
          description: framework_prompt("skills/tools/activate/description"),
          input_schema: {
            type: "object",
            properties: {
              skill_name: {
                type: "string",
                description: framework_prompt("skills/tools/activate/inputs/name/description")
              }
            },
            required: ["skill_name"],
            additionalProperties: false
          }
        ) do |input|
          catalog.format(catalog.fetch(input.fetch("skill_name")))
        rescue ConfigurationError => error
          raise ToolError, error.message
        end
      end

      # Formats one Skill, including allowed tools, compatibility, and bounded
      # resource paths.
      def format(skill)
        framework_prompt(
          "skills/tools/activate/content",
          instructions: skill.instructions,
          allowed_tools: skill.allowed_tools,
          compatibility: skill.compatibility,
          location: skill.path,
          resources: skill_resources(skill)
        )
      end

      # Copies each Skill in the catalog into +destination+ and returns the
      # destination's real path. Each Skill lands in <tt>destination/name</tt>
      # with its +SKILL.md+ and its +scripts+, +references+, and +assets+
      # directories; other files in the Skill directory are not copied.
      # Regular files and directories are copied with group and world write
      # permission removed. Symbolic links and special files are skipped, so a
      # copied Skill never points outside its directory.
      #
      # A complete copy replaces an entry with the same name by rename; other
      # entries are left in place. Concurrent calls for one destination run
      # one at a time, and each call removes entries whose names start with
      # <tt>.little_ghost-staging-</tt> left by an interrupted earlier call.
      #
      # +max_bytes+ and +max_files+ bound the whole copy, and resource
      # directories may nest at most three levels. ConfigurationError is
      # raised, leaving earlier entries in place, when a limit is exceeded,
      # when the destination overlaps a configured skill root, when a file
      # cannot be read or written, or when a Skill changed after it was
      # loaded.
      def materialize(
        destination,
        max_bytes: DEFAULT_MAX_MATERIALIZED_BYTES,
        max_files: DEFAULT_MAX_MATERIALIZED_FILES
      )
        budget = {
          max_bytes: positive_integer(max_bytes, :max_bytes),
          max_files: positive_integer(max_files, :max_files),
          bytes: 0,
          files: 0
        }
        reject_overlapping_destination!(prospective_realpath(destination), destination)
        FileUtils.mkdir_p(destination, mode: 0o700)
        real_destination = File.realpath(destination)
        reject_overlapping_destination!(real_destination, destination)
        File.open(real_destination, File::RDONLY) do |lock|
          lock.flock(File::LOCK_EX)
          Dir.children(real_destination).each do |name|
            remove_quietly(File.join(real_destination, name)) if name.start_with?(STAGING_PREFIX)
          end
          @skills.each_value { |skill| materialize_skill(skill, real_destination, budget) }
        end
        real_destination
      rescue SystemCallError => error
        raise ConfigurationError, "Skills could not be materialized into #{destination}: #{error.message}"
      end

      private

      def prospective_realpath(path)
        path = File.expand_path(path)
        missing = []
        until File.exist?(path) || File.symlink?(path)
          parent = File.dirname(path)
          break if parent == path

          missing.unshift(File.basename(path))
          path = parent
        end
        File.join(File.realpath(path), *missing)
      end

      def reject_overlapping_destination!(real_destination, destination)
        overlapping = @paths.any? do |root|
          next false unless Dir.exist?(root.path)

          real_root = File.realpath(root.path)
          inside_root?(real_destination, real_root) || inside_root?(real_root, real_destination)
        end
        raise ConfigurationError, "Skill destination overlaps a skill path: #{destination}" if overlapping
      end

      def materialize_skill(skill, destination, budget)
        source = File.dirname(skill.source_path)
        source_stat = File.lstat(source)
        staging = Dir.mktmpdir("#{STAGING_PREFIX}#{skill.name}-", destination)
        copy_file(skill.source_path, File.join(staging, "SKILL.md"), File.lstat(skill.source_path), budget)
        RESOURCE_DIRECTORIES.each do |name|
          resource = File.join(source, name)
          stat = File.lstat(resource)
          copy_directory(resource, File.join(staging, name), stat, budget, depth: 1) if stat.directory?
        rescue Errno::ENOENT
          next
        end
        verify_unchanged!(source, source_stat)
        verify_materialized_manifest!(skill, File.join(staging, "SKILL.md"))
        File.chmod((source_stat.mode & 0o755) | 0o700, staging)
        replace_entry(staging, File.join(destination, skill.name))
        staging = nil
      rescue InvalidSkillError
        raise ConfigurationError, "Skill changed before it could be materialized: #{skill.name}"
      ensure
        remove_quietly(staging) if staging
      end

      def copy_directory(source, target, expected_stat, budget, depth:)
        if depth > MAX_RESOURCE_DEPTH
          raise ConfigurationError, "Skill resources exceed #{MAX_RESOURCE_DEPTH} directory levels: #{source}"
        end

        Dir.mkdir(target, 0o700)
        Dir.children(source).sort.each do |name|
          source_path = File.join(source, name)
          target_path = File.join(target, name)
          stat = File.lstat(source_path)
          if stat.directory?
            copy_directory(source_path, target_path, stat, budget, depth: depth + 1)
          elsif stat.file?
            copy_file(source_path, target_path, stat, budget)
          end
        end
        verify_unchanged!(source, expected_stat)
        File.chmod((expected_stat.mode & 0o755) | 0o700, target)
      end

      def copy_file(source, target, expected_stat, budget)
        budget[:files] += 1
        if budget[:files] > budget[:max_files]
          raise ConfigurationError, "Skill materialization exceeds #{budget[:max_files]} files"
        end

        File.open(source, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |input|
          stat = input.stat
          raise InvalidSkillError unless stat.file? && same_file?(stat, expected_stat)

          remaining = budget[:max_bytes] - budget[:bytes]
          File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |output|
            copied = IO.copy_stream(input, output, remaining + 1)
            if copied > remaining
              raise ConfigurationError, "Skill materialization exceeds #{budget[:max_bytes]} bytes"
            end

            budget[:bytes] += copied
            output.chmod(stat.mode & 0o755)
          end
        end
      rescue Errno::ELOOP
        raise InvalidSkillError
      end

      def verify_unchanged!(path, expected_stat)
        raise InvalidSkillError unless same_file?(File.lstat(path), expected_stat)
      rescue Errno::ENOENT
        raise InvalidSkillError
      end

      def same_file?(stat, expected_stat)
        stat.ftype == expected_stat.ftype && stat.dev == expected_stat.dev && stat.ino == expected_stat.ino
      end

      def verify_materialized_manifest!(skill, path)
        raise InvalidSkillError if File.size(path) > @max_file_bytes

        manifest = parse_manifest(File.read(path, encoding: "UTF-8"), path)
        loaded = skill.to_h.slice(:name, :description, :instructions, :allowed_tools, :compatibility)
        raise InvalidSkillError unless manifest == loaded
      end

      def replace_entry(staging, target)
        retired = "#{staging}-retired"
        if File.exist?(target) || File.symlink?(target)
          File.rename(target, retired)
        else
          retired = nil
        end
        begin
          File.rename(staging, target)
        rescue SystemCallError
          restore_entry(retired, target) if retired
          raise
        end
        remove_quietly(retired) if retired
      end

      def restore_entry(retired, target)
        File.rename(retired, target)
      rescue SystemCallError
        nil
      end

      def remove_quietly(path)
        FileUtils.remove_entry_secure(path) if File.exist?(path) || File.symlink?(path)
      rescue SystemCallError, ArgumentError
        nil
      end

      def load_skills
        missing_root = @paths.find { |root| !Dir.exist?(root.path) && !root.boundary }
        raise Errno::ENOENT, missing_root.path if missing_root
        @paths.each do |root|
          next unless Dir.exist?(root.path)

          real_root = File.realpath(root.path)
          next if boundary_allows?(real_root, root.boundary)

          raise ConfigurationError, "Skill root escapes its configured boundary: #{root.path}"
        end

        paths = @paths.flat_map do |root|
          next [] unless Dir.exist?(root.path)

          Dir.glob(File.join(root.path, "*", "SKILL.md")).sort
        end
        raise ConfigurationError, "Skill catalog exceeds #{@max_skills} skills" if paths.length > @max_skills

        paths.each_with_object({}) do |path, loaded|
          skill = begin
            parse(path)
          rescue InvalidSkillError => error
            warn_skipped(path, error.reason)
            next
          rescue SystemCallError
            warn_skipped(path, :unreadable)
            next
          end
          next if @only && !@only.include?(skill.name)

          existing = loaded[skill.name]
          next if existing && @precedence == :first
          if existing && @precedence == :error
            raise ConfigurationError,
              "Skill #{skill.name} is defined more than once: #{existing.source_path}, #{skill.source_path}"
          end

          loaded[skill.name] = skill
        end.freeze
      end

      def warn_skipped(path, reason)
        directory = File.basename(File.dirname(path))
        return if @only && !@only.include?(directory)

        Events.warn("little_ghost.skills.skill_skipped", skill: directory, reason:)
      end

      def parse(path)
        real_path = File.realpath(path)
        root = @paths.find do |candidate|
          next false unless Dir.exist?(candidate.path)

          real_root = File.realpath(candidate.path)
          inside_root?(real_path, real_root) && boundary_allows?(real_root, candidate.boundary)
        end
        raise ConfigurationError, "Skill path escapes its configured root: #{path}" unless root
        if File.symlink?(path) || File.symlink?(File.dirname(path))
          raise InvalidSkillError.new("Skill is a symbolic link: #{path}", reason: :symbolic_link)
        end
        root_path = File.realpath(root.path)
        raise ConfigurationError, "Skill exceeds #{@max_file_bytes} bytes: #{path}" if File.size(real_path) > @max_file_bytes

        manifest = parse_manifest(File.read(real_path, encoding: "UTF-8"), path)
        unless manifest.fetch(:name) == File.basename(File.dirname(path))
          raise InvalidSkillError.new("Skill name must match its directory: #{path}", reason: :name_mismatch)
        end

        Skill.new(
          **manifest,
          path: agent_path(real_path, root_path), source_path: real_path
        )
      end

      def parse_manifest(text, path)
        raise InvalidSkillError, "Skill is not valid UTF-8: #{path}" unless text.valid_encoding?

        match = text.match(/\A---\s*\n(.*?)\n---\s*\n(.*)\z/m)
        raise InvalidSkillError, "Skill must have YAML front matter: #{path}" unless match

        metadata = YAML.safe_load(match[1], permitted_classes: [], aliases: false) || {}
        raise InvalidSkillError, "Skill front matter must be a mapping: #{path}" unless metadata.is_a?(Hash)

        name = metadata["name"].to_s.strip
        description = metadata["description"].to_s.strip
        raise InvalidSkillError, "Skill name is required: #{path}" if name.empty?
        raise InvalidSkillError, "Skill description is required: #{path}" if description.empty?
        raise InvalidSkillError, "Skill name contains unsafe characters: #{path}" unless SAFE_NAME_PATTERN.match?(name)
        raise InvalidSkillError, "Skill description must be one line: #{path}" if description.match?(/[\r\n]/)

        allowed_tools = metadata["allowed-tools"] || metadata["allowed_tools"]
        allowed_tools = allowed_tools.split if allowed_tools.is_a?(String)
        allowed_tools = Array(allowed_tools).map(&:to_s).freeze
        compatibility = metadata["compatibility"]&.to_s
        {name:, description:, instructions: match[2].strip, allowed_tools:, compatibility:}
      rescue Psych::Exception => error
        raise InvalidSkillError, "Invalid skill front matter in #{path}: #{error.message}"
      end

      def inside_root?(path, root)
        path == root || path.start_with?("#{root}#{File::SEPARATOR}")
      end

      def boundary_allows?(path, boundary)
        return true unless boundary

        boundary = File.realpath(boundary)
        inside_root?(path, boundary)
      end

      def skill_resources(skill)
        directory = File.dirname(skill.source_path)
        files = RESOURCE_DIRECTORIES.flat_map do |name|
          root = File.join(directory, name)
          next [] unless File.directory?(root) && !File.symlink?(root)

          resource_files(root, prefix: name)
        end.sort
        files.map! { |path| resource_path(skill, path) } if @resource_root
        return files if files.length <= @max_resource_files

        [
          *files.first(@max_resource_files),
          framework_prompt("skills/resources/notices/truncated", max_files: @max_resource_files)
        ]
      end

      def resource_files(directory, prefix:, depth: 0)
        return [] if depth >= MAX_RESOURCE_DEPTH

        Dir.children(directory).sort.flat_map do |name|
          path = File.join(directory, name)
          relative = "#{prefix}/#{name}"
          stat = File.lstat(path)
          if stat.directory? && !stat.symlink?
            resource_files(path, prefix: relative, depth: depth + 1)
          elsif stat.file?
            [relative]
          else
            []
          end
        rescue Errno::ENOENT, Errno::EACCES
          []
        end
      rescue Errno::ENOENT, Errno::EACCES
        []
      end

      def positive_integer(value, name)
        integer = Integer(value)
        raise ArgumentError, "#{name} must be positive" unless integer.positive?

        integer
      end

      def validate_workspace_resource_root!(workspace, sandbox)
        return unless @resource_root&.start_with?("workspace://")
        unless workspace && sandbox
          raise ConfigurationError, "workspace resource_root requires a Workspace and Sandbox"
        end
        unless sandbox.workspace.equal?(workspace)
          raise ConfigurationError, "workspace resource_root requires the Sandbox bound to its Workspace"
        end

        physical_root = File.realpath(workspace.resolve(@resource_root))
        source_roots = @paths.filter_map do |root|
          File.realpath(root.path) if Dir.exist?(root.path)
        end
        unless source_roots.all? { |source_root| source_root == physical_root }
          raise ConfigurationError, "workspace resource_root must map to each skill path"
        end
        unless sandbox.allows?(:filesystem_read, @resource_root) &&
            !sandbox.allows?(:filesystem_write, @resource_root)
          raise ConfigurationError, "workspace resource_root must be tool-readable and read-only"
        end
        if writable_tool_grants(sandbox).any? do |grant|
          source = File.realpath(grant.source)
          source == physical_root || source.start_with?("#{physical_root}#{File::SEPARATOR}")
        end
          raise ConfigurationError, "workspace resource_root must not contain writable file grants"
        end
        @workspace_physical_root = physical_root
      rescue Errno::ENOENT, KeyError, ArgumentError => error
        raise ConfigurationError, "workspace resource_root is not available: #{error.message}"
      end

      def validate_workspace_resource_aliases!(sandbox)
        return unless @workspace_physical_root

        protected_identities = protected_directory_identities
        aliased = writable_tool_grants(sandbox).any? do |grant|
          stat = File.stat(grant.source)
          protected_identities.include?([stat.dev, stat.ino])
        end
        if aliased
          raise ConfigurationError, "workspace resource_root must not contain writable file grants"
        end
      rescue Errno::ENOENT, Errno::EACCES => error
        raise ConfigurationError, "workspace resource_root is not available: #{error.message}"
      end

      def framework_prompt(key, **locals)
        return @prompt_renderer.call(key, **locals) if @prompt_renderer

        @framework_prompts.render(key, locals:)
      end

      def writable_tool_grants(sandbox)
        grants = sandbox.respond_to?(:process_grants) ? sandbox.process_grants : sandbox.scope.process_grants
        grants.select { |grant| grant.tool_visible? && grant.writable? }
      end

      def protected_directory_identities
        directories = [@workspace_physical_root]
        @skills.each_value do |skill|
          skill_directory = File.dirname(skill.source_path)
          directories << skill_directory
          RESOURCE_DIRECTORIES.each do |name|
            resource_root = File.join(skill_directory, name)
            collect_resource_directories(resource_root, directories) if File.directory?(resource_root)
          end
        end
        directories.uniq.to_h do |directory|
          stat = File.stat(directory)
          [[stat.dev, stat.ino], true]
        end
      end

      def collect_resource_directories(directory, directories, depth = 0)
        return if depth >= MAX_RESOURCE_DEPTH || File.symlink?(directory)

        directories << directory
        Dir.children(directory).each do |name|
          child = File.join(directory, name)
          collect_resource_directories(child, directories, depth + 1) if File.directory?(child)
        rescue Errno::ENOENT, Errno::EACCES
          next
        end
      end

      def agent_path(source_path, source_root)
        return source_path unless @resource_root

        relative = source_path.delete_prefix("#{source_root}#{File::SEPARATOR}")
        File.join(@resource_root, relative)
      end

      def resource_path(skill, relative)
        File.join(File.dirname(skill.path), relative)
      end
    end
  end
end
