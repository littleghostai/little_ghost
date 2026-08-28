# frozen_string_literal: true

require_relative "version"
require_relative "generators/application_generator"
require_relative "framework_prompts"
require "bundler"
require "fileutils"
require "pathname"

module LittleGhost
  class BundleInstaller # :nodoc:
    def initialize(stdout:, stderr:, executable: nil, process_runner: nil)
      @stdout = stdout
      @stderr = stderr
      @executable = executable || -> { Gem.bin_path("bundler", "bundle") }
      @process_runner = process_runner || method(:run_bundle)
    end

    def install(root)
      executable = @executable.call
      environment = {"BUNDLE_GEMFILE" => File.join(root, "Gemfile")}
      if (bundle_path = ENV["BUNDLE_PATH"])
        environment["BUNDLE_PATH"] = Pathname.new(bundle_path).absolute? ? bundle_path : File.expand_path(bundle_path, root)
      end
      status = @process_runner.call(environment, executable, root)
      status.success?
    rescue Gem::Exception, SystemCallError => error
      @stderr.puts("Could not run bundle install: #{error.message}")
      false
    end

    private

    def run_bundle(environment, executable, root)
      Bundler.with_unbundled_env do
        process = Process.spawn(environment, executable, "install", chdir: root, out: @stdout, err: @stderr)
        Process.wait2(process).last
      end
    end
  end

  # Command-line entrypoint for generating standalone LittleGhost applications.
  class CLI # :nodoc:
    USAGE = <<~TEXT
      Usage:
        little_ghost new APP_NAME
        little_ghost console
        little_ghost prompts list [PREFIX] [--all]
        little_ghost prompts show KEY
        little_ghost prompts copy KEY [--root ROOT] [--agent LOGICAL_PATH]
        little_ghost prompts copy --all [--root ROOT] [--agent LOGICAL_PATH]
        little_ghost --version
        little_ghost --help
    TEXT

    def initialize(
      arguments,
      stdout: $stdout,
      stderr: $stderr,
      current_directory: Dir.pwd,
      generator_class: Generators::ApplicationGenerator,
      bundle_installer: nil,
      console_runner: nil,
      source_path: nil
    )
      @arguments = Array(arguments).dup
      @stdout = stdout
      @stderr = stderr
      @current_directory = File.expand_path(current_directory)
      @generator_class = generator_class
      @bundle_installer = bundle_installer || BundleInstaller.new(stdout:, stderr:)
      @console_runner = console_runner
      @source_path = source_path
    end

    def run
      case arguments.first
      when "--help", "-h", nil
        return usage_error("--help does not accept arguments") if arguments.length > 1

        stdout.write(USAGE)
        0
      when "--version", "-v"
        return usage_error("--version does not accept arguments") if arguments.length > 1

        stdout.puts("little_ghost #{VERSION}")
        0
      when "new"
        generate_application
      when "console"
        open_console
      when "prompts"
        manage_prompts
      else
        usage_error("Unknown command: #{arguments.first}")
      end
    end

    private

    attr_reader :arguments, :stdout, :stderr, :current_directory, :generator_class, :bundle_installer, :source_path

    def generate_application
      return usage_error("APP_NAME is required") if arguments.length == 1
      return usage_error("new accepts exactly one APP_NAME") if arguments.length > 2

      application = generator_class.new(name: arguments.fetch(1), current_directory:, dependency_path: source_path)
      stdout.puts("Running bundle install...")
      bundle_installed = false
      destination = application.generate do |staging|
        bundle_installed = bundle_installer.install(staging)
      end
      stdout.puts("Created #{destination}")
      unless bundle_installed
        stderr.puts("Error: bundle install failed; the application was created at #{destination}")
        return 1
      end
      stdout.puts("Run `cd #{application.directory_name} && bin/little_ghost console` to get started.")
      0
    rescue Generators::ApplicationGenerator::Error => error
      stderr.puts("Error: #{error.message}")
      1
    end

    def open_console
      return usage_error("console does not accept arguments") if arguments.length > 1

      runner = @console_runner
      unless runner
        require_relative "console"
        runner = Console.method(:start)
      end
      runner.call(root: current_directory)
      0
    rescue LittleGhost::Error, LoadError, SystemCallError => error
      stderr.puts("Error: #{error.message}")
      1
    end

    def manage_prompts
      case arguments.fetch(1, nil)
      when "list"
        list_prompts
      when "show"
        show_prompt
      when "copy"
        copy_prompts
      when nil
        usage_error("prompts requires list, show, or copy")
      else
        usage_error("Unknown prompts command: #{arguments.fetch(1)}")
      end
    end

    def list_prompts
      options = parse_list_options(arguments.drop(2))
      return 1 unless options

      entries = FrameworkPrompts.entries.sort_by(&:key)
      prefix = options.fetch(:prefix)
      if prefix && entries.any? { |entry| entry.key == prefix }
        return usage_error("#{prefix} is a template; use prompts show #{prefix}")
      end
      matches = entries.select { |entry| !prefix || entry.key.start_with?("#{prefix}/") }
      return usage_error("Unknown framework prompt prefix: #{prefix}") if matches.empty?

      if options.fetch(:all)
        matches.each { |entry| stdout.puts("#{entry.key}\t#{entry.summary}") }
        return 0
      end

      grouped = {}
      leaves = []
      matches.each do |entry|
        remainder = prefix ? entry.key.delete_prefix("#{prefix}/") : entry.key
        segment, nested = remainder.split("/", 2)
        if nested
          path = [prefix, segment].compact.join("/")
          grouped[path] = grouped.fetch(path, 0) + 1
        else
          leaves << entry
        end
      end
      grouped.sort.each do |path, count|
        noun = (count == 1) ? "template" : "templates"
        stdout.puts("#{path}/\t#{FrameworkPrompts.group_summary(path)}\t#{count} #{noun}")
      end
      leaves.each { |entry| stdout.puts("#{entry.key}\t#{entry.summary}") }
      0
    end

    def parse_list_options(values)
      options = {prefix: nil, all: false}
      values.each do |value|
        if value == "--all"
          return list_usage_error("--all may only be specified once") if options.fetch(:all)

          options[:all] = true
        elsif value.start_with?("-")
          return list_usage_error("Unknown option: #{value}")
        elsif options[:prefix]
          return list_usage_error("prompts list accepts at most one PREFIX")
        else
          prefix = value.sub(%r{/\z}, "")
          unless prefix.match?(/\A[a-z0-9_]+(?:\/[a-z0-9_]+)*\z/)
            return list_usage_error("PREFIX must be a lowercase logical path")
          end

          options[:prefix] = prefix
        end
      end
      options
    end

    def list_usage_error(message)
      usage_error(message)
      nil
    end

    def show_prompt
      return usage_error("KEY is required") if arguments.length == 2
      return usage_error("prompts show accepts exactly one KEY") if arguments.length > 3

      entry = prompt_entry(arguments.fetch(2))
      return 1 unless entry

      stdout.write(File.binread(FrameworkPrompts.new.source(entry)))
      0
    rescue SystemCallError => error
      stderr.puts("Error: Could not read bundled prompt: #{error.message}")
      1
    end

    def copy_prompts
      options = parse_copy_options(arguments.drop(2))
      return 1 unless options

      entries = if options.fetch(:all)
        FrameworkPrompts.entries.sort_by(&:key)
      else
        entry = prompt_entry(options.fetch(:key))
        return 1 unless entry

        [entry]
      end
      root = prompt_root(options.fetch(:root))
      return 1 unless root

      catalog = FrameworkPrompts.new
      sources = entries.map { |entry| [entry, catalog.source(entry)] }
      missing_source = sources.find { |_entry, source| !File.file?(source) }
      if missing_source
        stderr.puts("Error: Bundled prompt is missing: #{missing_source.fetch(0).key}")
        return 1
      end
      root = canonical_prompt_root(root)
      copies = sources.map do |entry, source|
        destination = prompt_destination(root, options.fetch(:agent), entry)
        [entry, source, secure_prompt_destination(root, destination)]
      end
      existing = copies.find { |_entry, _source, destination| File.exist?(destination) || File.symlink?(destination) }
      if existing
        stderr.puts("Error: Refusing to overwrite existing path: #{existing.fetch(2)}")
        return 1
      end

      copies.each do |entry, source, destination|
        copied = copy_prompt(source, destination, root:)
        stdout.puts("Copied #{entry.key} to #{copied}")
      end
      0
    rescue InvalidPromptTemplateError, SystemCallError => error
      stderr.puts("Error: Could not copy bundled prompt: #{error.message}")
      1
    end

    def parse_copy_options(values)
      options = {all: false, key: nil, root: "app/prompts", agent: nil}
      provided = {}
      index = 0
      while index < values.length
        value = values.fetch(index)
        case value
        when "--all"
          return copy_usage_error("--all may only be specified once") if options.fetch(:all)

          options[:all] = true
        when "--root", "--agent"
          option = value.delete_prefix("--").to_sym
          return copy_usage_error("#{value} may only be specified once") if provided[option]

          provided[option] = true
          index += 1
          argument = values[index]
          return copy_usage_error("#{value} requires a value") if argument.nil? || argument.start_with?("--")

          options[option] = argument
        else
          return copy_usage_error("Unknown option: #{value}") if value.start_with?("-")
          return copy_usage_error("prompts copy accepts one KEY or --all") if options[:key]

          options[:key] = value
        end
        index += 1
      end

      return copy_usage_error("Choose either KEY or --all") if options.fetch(:all) && options[:key]
      return copy_usage_error("KEY or --all is required") unless options.fetch(:all) || options[:key]
      return copy_usage_error("--root cannot be blank") if options.fetch(:root).strip.empty?
      if options[:agent] && !options.fetch(:agent).match?(/\A[a-z0-9_]+(?:\/[a-z0-9_]+)*\z/)
        return copy_usage_error("--agent must be a lowercase logical path")
      end

      options
    end

    def copy_usage_error(message)
      usage_error(message)
      nil
    end

    def prompt_entry(key)
      FrameworkPrompts.entry(key)
    rescue ArgumentError
      stderr.puts("Error: Unknown framework prompt: #{key}")
      nil
    end

    def prompt_root(value)
      if value.include?("\0")
        stderr.puts("Error: --root contains an invalid null byte")
        return nil
      end

      root = File.expand_path(value, current_directory)
      if File.symlink?(root)
        stderr.puts("Error: --root cannot be a symbolic link: #{root}")
        return nil
      end
      if File.exist?(root) && !File.directory?(root)
        stderr.puts("Error: --root is not a directory: #{root}")
        return nil
      end
      root
    end

    def prompt_destination(root, agent, entry)
      File.join(root, agent.to_s, entry.relative_path)
    end

    def canonical_prompt_root(root)
      missing = []
      cursor = root
      until File.exist?(cursor)
        if File.symlink?(cursor)
          raise InvalidPromptTemplateError, "prompt destination contains a symbolic link: #{cursor}"
        end

        parent = File.dirname(cursor)
        raise InvalidPromptTemplateError, "prompt destination has no existing ancestor" if parent == cursor

        missing << File.basename(cursor)
        cursor = parent
      end
      if File.symlink?(cursor) || !File.directory?(cursor)
        raise InvalidPromptTemplateError, "prompt destination ancestor is not a real directory: #{cursor}"
      end

      current = File.realpath(cursor)
      missing.reverse_each do |component|
        candidate = File.join(current, component)
        if File.symlink?(candidate)
          raise InvalidPromptTemplateError, "prompt destination contains a symbolic link: #{candidate}"
        end
        Dir.mkdir(candidate, 0o755) unless File.exist?(candidate)
        raise InvalidPromptTemplateError, "prompt destination component is not a directory: #{candidate}" unless File.directory?(candidate)

        current = File.realpath(candidate)
      end
      current
    end

    def copy_prompt(source, destination, root:)
      target = secure_prompt_destination(root, destination)
      unless target == destination && inside_prompt_root?(target, root)
        raise InvalidPromptTemplateError, "prompt destination escapes its root"
      end

      File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
        file.write(File.binread(source))
      end
      target
    end

    def secure_prompt_destination(root, destination)
      relative_parent = File.dirname(destination).delete_prefix("#{root}/")
      parent = secure_prompt_directory(root, relative_parent)
      File.join(parent, File.basename(destination))
    end

    def secure_prompt_directory(root, relative)
      current = root
      relative.split(File::SEPARATOR).reject(&:empty?).each do |component|
        candidate = File.join(current, component)
        if File.symlink?(candidate)
          raise InvalidPromptTemplateError, "prompt destination contains a symbolic link: #{candidate}"
        end
        Dir.mkdir(candidate, 0o755) unless File.exist?(candidate)
        raise InvalidPromptTemplateError, "prompt destination component is not a directory: #{candidate}" unless File.directory?(candidate)

        current = File.realpath(candidate)
        unless inside_prompt_root?(current, root)
          raise InvalidPromptTemplateError, "prompt destination escapes its root"
        end
      end
      current
    end

    def inside_prompt_root?(path, root)
      path == root || path.start_with?("#{root}#{File::SEPARATOR}")
    end

    def usage_error(message)
      stderr.puts("Error: #{message}")
      stderr.write(USAGE)
      1
    end
  end
end
