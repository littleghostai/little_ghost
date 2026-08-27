# frozen_string_literal: true

require "irb"
require_relative "../little_ghost"

module LittleGhost
  class Console # :nodoc:
    def self.start(root:)
      configuration = Configuration.new(root:)
      LittleGhost.with_configuration(configuration) do
        LittleGhost.runtime
        IRB.setup(nil, argv: [])
        IRB::Irb.new.run(IRB.conf)
      end
    end
  end
end
