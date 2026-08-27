# frozen_string_literal: true

class ProjectReadTools
  def self.tools(_binding)
    [
      LittleGhost::Tools::Filesystem::ReadFile,
      LittleGhost::Tools::Filesystem::ListFiles
    ]
  end
end
