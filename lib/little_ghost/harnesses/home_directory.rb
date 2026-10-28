# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "tmpdir"

module LittleGhost
  module Harnesses
    # Creates and removes the private, temporary home directories that
    # harnesses use when the application does not configure a persistent one.
    module HomeDirectory # :nodoc:
      PREFIX = ".little-ghost-harness-home-"

      module_function

      # Creates a private directory beneath a Workspace directory that +sandbox+
      # lets processes write and returns {host:, child:} paths. +root+ names
      # the Workspace path (+:root+ for the Workspace root); nil selects the
      # first writable runtime path. +host+ allows a host temporary directory
      # when there is no Sandbox or it has no writable runtime path.
      def create(sandbox:, root: nil, host: false)
        if sandbox.nil? || (host && !writable_runtime_path?(sandbox))
          path = File.realpath(Dir.mktmpdir(PREFIX))
          return {host: path.freeze, child: path.freeze}.freeze
        end

        mount, directory = writable_location(sandbox, root)
        host = File.join(directory, "#{PREFIX}#{SecureRandom.hex(12)}")
        Dir.mkdir(host, 0o700)
        child = File.join(mount.target, host.delete_prefix(mount.source).delete_prefix(File::SEPARATOR))
        {host: host.freeze, child: child.freeze}.freeze
      end

      # Removes a directory returned by #create without following links the
      # harness left inside it. Raises CleanupError when removal fails.
      def remove(paths)
        host = paths.fetch(:host)
        stat = File.lstat(host)
        return unless stat.directory? && File.basename(host).start_with?(PREFIX)

        make_removable(host)
        FileUtils.rm_r(host, secure: true)
      rescue Errno::ENOENT
        nil
      rescue SystemCallError, ArgumentError => error
        raise CleanupError, "harness home could not be removed: #{error.class}"
      end

      def writable_location(sandbox, root)
        workspace = sandbox.workspace
        candidates = if root
          [(root.to_sym == :root) ? workspace.root : workspace.path(root)]
        else
          sandbox.effective_policy.runtime_paths.filter_map { |name, access| workspace.path(name) if access == :read_write }
        end
        grants = sandbox.respond_to?(:process_grants) ? sandbox.process_grants : sandbox.effective_policy.process_grants(workspace)
        candidates.each do |directory|
          directory = File.expand_path(directory)
          mount = grants.select(&:writable?).find do |grant|
            directory == grant.source || directory.start_with?("#{grant.source}#{File::SEPARATOR}")
          end
          return [mount, directory] if mount
        end
        raise ConfigurationError,
          "harness home needs a Workspace path the sandbox lets processes write; configure home_root: or a persistent home:"
      rescue KeyError
        raise ConfigurationError, "harness home_root #{root.inspect} is not a Workspace path"
      end

      def writable_runtime_path?(sandbox)
        writable_location(sandbox, nil)
        true
      rescue ConfigurationError
        false
      end

      def make_removable(directory)
        File.chmod(0o700, directory)
        Dir.each_child(directory) do |name|
          path = File.join(directory, name)
          make_removable(path) if File.lstat(path).directory?
        end
      end
    end
  end
end
