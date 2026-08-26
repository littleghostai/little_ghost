# frozen_string_literal: true

# Loads LittleGhost's optional Model Context Protocol client. Applications add
# the official +mcp+ gem and the dependencies for their chosen transport before
# requiring this entrypoint. Requiring +little_ghost+ alone does not load them.
require_relative "../little_ghost"

begin
  require "mcp"
rescue LoadError => error
  raise LittleGhost::DependencyError,
    "MCP integration requires the optional mcp gem. Add `gem \"mcp\", \"~> 1.3\"` to your bundle.",
    cause: error
end

require "rubygems/requirement"
require "rubygems/version"

requirement = Gem::Requirement.new("~> 1.3")
unless requirement.satisfied_by?(Gem::Version.new(::MCP::VERSION))
  raise LittleGhost::DependencyError,
    "MCP integration requires mcp #{requirement}; the bundle loaded #{::MCP::VERSION}."
end

begin
  require "json_schemer"
rescue LoadError => error
  raise LittleGhost::DependencyError,
    "MCP schema validation requires the optional json_schemer gem. " \
      "Add `gem \"json_schemer\", \"~> 2.5\"` to your bundle.",
    cause: error
end

require_relative "mcp/types"
require_relative "mcp/client"
require_relative "mcp/toolset"
