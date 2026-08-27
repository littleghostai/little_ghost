# frozen_string_literal: true

class ProjectTools
  def self.tools(binding)
    [LittleGhost::Tools::Filesystem.tools(binding), LittleGhost::Tools::Shell]
  end
end
