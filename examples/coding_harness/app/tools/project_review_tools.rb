# frozen_string_literal: true

class ProjectReviewTools
  def self.tools(_binding)
    [
      LittleGhost::Tools::Filesystem::ReadFile,
      LittleGhost::Tools::Filesystem::ListFiles
    ]
  end
end
