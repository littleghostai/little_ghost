# frozen_string_literal: true

require "open3"
require "test_helper"

class OptionalIntegrationsTest < Minitest::Test
  def test_core_require_does_not_load_optional_integrations
    script = <<~RUBY
      require "little_ghost"
      abort if defined?(LittleGhost::AGUI)
      abort if defined?(LittleGhost::SessionStores::AgentCoreMemory)
      abort if defined?(LittleGhost::Tools::Filesystem)
      abort if defined?(LittleGhost::MCP)
      abort if defined?(MCP)
      abort if defined?(LittleGhost::EventSink)
      abort if defined?(LittleGhost::CodeMode::JavascriptEngine)
      abort if defined?(Async)
      abort if $LOADED_FEATURES.any? { |path| path.include?("/async/") || path.end_with?("async.rb") }
      abort if $LOADED_FEATURES.any? { |path| path.end_with?("mini_racer.rb") }
      abort if $LOADED_FEATURES.any? { |path| path.include?("/mcp/") || path.end_with?("/mcp.rb") }
      abort if $LOADED_FEATURES.any? { |path| path.include?("json_schemer") }
      abort if $LOADED_FEATURES.any? { |path| path.include?("faraday") || path.include?("event_stream_parser") }
    RUBY

    _output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", script, chdir: __dir__ + "/..")

    assert status.success?
  end

  def test_javascript_code_mode_has_a_direct_entrypoint
    script = <<~RUBY
      require "little_ghost/code_mode/javascript_engine"
      abort unless LittleGhost::CodeMode.resolve_engine(:javascript) == LittleGhost::CodeMode::JavascriptEngine
    RUBY

    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", script, chdir: __dir__ + "/..")

    assert status.success?, output
  end

  def test_ruby_code_mode_has_a_direct_entrypoint
    script = <<~RUBY
      require "little_ghost/code_mode/ruby_engine"
      abort unless LittleGhost::CodeMode.resolve_engine(:ruby) == LittleGhost::CodeMode::RubyEngine
    RUBY

    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", script, chdir: __dir__ + "/..")

    assert status.success?, output
  end

  def test_javascript_code_mode_reports_its_missing_optional_dependency
    script = <<~RUBY
      module Kernel
        alias_method :little_ghost_original_require, :require
        def require(path)
          raise LoadError, "blocked for test" if path == "mini_racer"
          little_ghost_original_require(path)
        end
      end

      begin
        require "little_ghost/code_mode/javascript_engine"
      rescue LittleGhost::DependencyError => error
        abort unless error.message.include?("mini_racer") && error.message.include?("gem \\"mini_racer\\"")
      else
        abort "expected dependency error"
      end
    RUBY

    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", script, chdir: __dir__ + "/..")

    assert status.success?, output
  end

  def test_integrations_have_explicit_entrypoints
    require "little_ghost/ag_ui"
    require "little_ghost/session_stores/agent_core_memory"
    require "little_ghost/tools"
    require "little_ghost/mcp"

    assert defined?(LittleGhost::AGUI::Adapter)
    assert defined?(LittleGhost::SessionStores::AgentCoreMemory)
    assert defined?(LittleGhost::Tools::Filesystem)
    assert defined?(LittleGhost::Tools::Shell)
    assert defined?(LittleGhost::MCP)
  end

  def test_mcp_entrypoint_loads_the_core_toolset_contract
    script = <<~RUBY
      require "little_ghost/mcp"

      class RemoteTools < LittleGhost::MCP::Toolset
        client do |_binding|
          MCP::Client.new(transport: Object.new)
        end
      end

      class RemoteAgent < LittleGhost::Agent
        tools RemoteTools
      end

      abort unless RemoteAgent.tool_declarations == [RemoteTools]
    RUBY

    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", script, chdir: __dir__ + "/..")

    assert status.success?, output
  end

  def test_mcp_entrypoint_reports_its_missing_optional_sdk
    script = <<~RUBY
      module Kernel
        alias_method :little_ghost_original_require, :require
        def require(path)
          raise LoadError, "blocked for test" if path == "mcp"
          little_ghost_original_require(path)
        end
      end

      begin
        require "little_ghost/mcp"
      rescue LittleGhost::DependencyError => error
        abort unless error.message.include?("mcp") && error.message.include?('gem "mcp", "~> 1.3"')
      else
        abort "expected dependency error"
      end
    RUBY

    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", script, chdir: __dir__ + "/..")

    assert status.success?, output
  end

  def test_mcp_entrypoint_does_not_load_transport_dependencies
    script = <<~RUBY
      require "little_ghost/mcp"
      abort if defined?(Faraday)
      abort if $LOADED_FEATURES.any? { |path| path.include?("faraday") || path.include?("event_stream_parser") }
    RUBY

    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", script, chdir: __dir__ + "/..")

    assert status.success?, output
  end

  def test_published_gem_has_no_mcp_runtime_dependencies
    specification = Gem::Specification.load(File.expand_path("../little_ghost.gemspec", __dir__))
    runtime_dependencies = specification.runtime_dependencies.map(&:name)

    assert_empty runtime_dependencies & %w[mcp json_schemer faraday event_stream_parser]
  end
end
