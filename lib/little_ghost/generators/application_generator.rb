# frozen_string_literal: true

require "fileutils"
require_relative "../version"

module LittleGhost
  module Generators # :nodoc:
    # Creates one conventional standalone LittleGhost application.
    class ApplicationGenerator # :nodoc:
      class Error < StandardError; end # :nodoc:
      class InvalidNameError < Error; end # :nodoc:
      class DestinationExistsError < Error; end # :nodoc:
      class GenerationError < Error; end # :nodoc:

      NAME_PATTERN = /\A[A-Za-z](?:[A-Za-z0-9]|[-_](?=[A-Za-z0-9]))*\z/ # :nodoc:
      TEMPLATE_ROOT = File.expand_path("templates/application", __dir__) # :nodoc:
      EMPTY_DIRECTORIES = %w[app/assemblies app/tools app/skills].freeze # :nodoc:

      attr_reader :directory_name

      def initialize(name:, current_directory: Dir.pwd, template_root: TEMPLATE_ROOT, dependency_path: nil)
        @name = name.to_s
        @current_directory = File.expand_path(current_directory)
        @template_root = File.expand_path(template_root)
        @dependency_path = dependency_path && File.expand_path(dependency_path)
        @directory_name = normalize_name
        @class_name = directory_name.split("_").map(&:capitalize).join
      end

      def generate
        destination = File.join(current_directory, directory_name)
        raise DestinationExistsError, "#{destination} already exists" if File.symlink?(destination) || File.exist?(destination)

        identity = nil
        begin
          Dir.mkdir(destination, 0o700)
        rescue Errno::EEXIST
          raise DestinationExistsError, "#{destination} already exists"
        rescue SystemCallError => error
          raise GenerationError, "Could not create #{directory_name}: #{error.message}"
        end

        begin
          identity = directory_identity(destination)
          files = rendered_files
          create_directories(destination, identity, files)
          create_files(destination, identity, files)
          directory_mode = File.stat(File.join(destination, "app")).mode & 0o777
          verify_destination!(destination, identity)
          yield(destination) if block_given?
          restore_directory_mode(destination, identity, directory_mode)
          destination
        rescue Error
          remove_created_destination(destination, identity) if identity
          raise
        rescue => error
          remove_created_destination(destination, identity) if identity
          raise GenerationError, "Could not create #{directory_name}: #{error.message}"
        end
      end

      private

      attr_reader :name, :current_directory, :template_root, :class_name, :dependency_path

      def normalize_name
        unless NAME_PATTERN.match?(name)
          raise InvalidNameError, "APP_NAME must begin with a letter and contain only letters, numbers, hyphens, or underscores"
        end

        normalized = name
          .gsub(/([A-Z\d]+)([A-Z][a-z])/, "\\1_\\2")
          .gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
          .tr("-", "_")
          .downcase
        raise InvalidNameError, "APP_NAME must identify a Ruby constant" unless /\A[a-z][a-z0-9_]*\z/.match?(normalized)

        normalized
      end

      def create_directories(destination, identity, files)
        files
          .each_key
          .map { |relative_destination| File.dirname(relative_destination) }
          .reject { |directory| directory == "." }
          .flat_map { |directory| directory.split("/").each_index.map { |index| directory.split("/").first(index + 1).join("/") } }
          .uniq
          .sort_by { |directory| directory.count("/") }
          .each do |directory|
            verify_destination!(destination, identity)
            Dir.mkdir(File.join(destination, directory))
          end
      end

      def create_files(destination, identity, files)
        files.each do |relative_destination, contents|
          create_file(destination, identity, relative_destination, contents)
        end
      end

      def create_file(destination, identity, relative_destination, contents)
        verify_destination!(destination, identity)
        target = File.join(destination, relative_destination)
        File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
          file.write(contents)
          file.chmod(0o755) if relative_destination == "bin/little_ghost"
        end
      end

      def template_destinations
        [
          ["Gemfile.tt", "Gemfile"],
          ["README.md.tt", "README.md"],
          ["gitignore.tt", ".gitignore"],
          ["config/little_ghost.rb.tt", "config/little_ghost.rb"],
          ["app/agents/application_agent.rb.tt", "app/agents/#{directory_name}_agent.rb"],
          ["app/prompts/application/system.erb.tt", "app/prompts/#{directory_name}/system.erb"],
          ["bin/application.tt", "bin/little_ghost"],
          *EMPTY_DIRECTORIES.map { |directory| ["keep.tt", "#{directory}/.keep"] }
        ]
      end

      def rendered_files
        template_destinations.to_h do |template, relative_destination|
          [relative_destination, render(File.binread(File.join(template_root, template)))]
        end
      end

      def render(template)
        template
          .gsub("{{DIRECTORY_NAME}}", directory_name)
          .gsub("{{CLASS_NAME}}", class_name)
          .gsub("{{LITTLE_GHOST_DEPENDENCY}}", little_ghost_dependency)
          .gsub("{{VERSION}}", VERSION)
      end

      def little_ghost_dependency
        return %(gem "little_ghost", path: #{dependency_path.dump}) if dependency_path

        %(gem "little_ghost", "~> #{VERSION}")
      end

      def directory_identity(destination)
        stat = File.lstat(destination)
        raise GenerationError, "Destination changed during generation" unless stat.directory? && !stat.symlink?

        [stat.dev, stat.ino].freeze
      end

      def restore_directory_mode(destination, identity, mode, nofollow_supported: File.const_defined?(:NOFOLLOW))
        if nofollow_supported
          File.open(destination, File::RDONLY | File::NOFOLLOW) do |directory|
            stat = directory.stat
            raise GenerationError, "Destination changed during generation" unless [stat.dev, stat.ino] == identity

            directory.chmod(mode)
          end
        else
          verify_destination!(destination, identity)
          File.chmod(mode, destination)
        end
      end

      def verify_destination!(destination, identity)
        raise GenerationError, "Destination changed during generation" unless directory_identity(destination) == identity
      rescue Errno::ENOENT
        raise GenerationError, "Destination changed during generation"
      end

      def remove_created_destination(destination, identity)
        return unless directory_identity(destination) == identity

        FileUtils.remove_entry_secure(destination)
      rescue Errno::ENOENT, GenerationError
        nil
      end
    end
  end
end
