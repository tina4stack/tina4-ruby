# frozen_string_literal: true

# Backward compatibility: Tina4::Debug is now Tina4::Log
require_relative "log"

module Tina4
  Debug = Log
end
