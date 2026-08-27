# frozen_string_literal: true

require_relative "version"
require_relative "generators/application_generator"
require "bundler"
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

    def usage_error(message)
      stderr.puts("Error: #{message}")
      stderr.write(USAGE)
      1
    end
  end
end
