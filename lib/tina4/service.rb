# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


# Tina4 — The Intelligent Native Application 4ramework
# Copyright (c) 2026 Code Infinity
# License: MPL-2.0 https://mozilla.org/MPL/2.0/

module Tina4
  # Base class for class-based background services managed by
  # {Tina4::ServiceRunner}. Cross-framework parity with PHP `Tina4\Service`
  # and the same shape the documentation has long taught.
  #
  #     class EmailQueueWorker < Tina4::Service
  #       def run
  #         until should_stop?
  #           process_next_job
  #           sleep 1
  #         end
  #       end
  #     end
  #
  #     Tina4::ServiceRunner.register_service("emails", EmailQueueWorker.new)
  #     Tina4::ServiceRunner.start
  #
  # Subclasses MUST override #run. Optionally override #stop for custom
  # shutdown behaviour but always call `super` so the internal flag
  # gets set — the default #should_stop? reads from it.
  class Service
    def initialize
      @running = true
    end

    # Main work loop — subclasses MUST override.
    def run
      raise NotImplementedError, "#{self.class}#run must be implemented by the subclass"
    end

    # Signal this service to stop. The next `should_stop?` check returns true.
    def stop
      @running = false
    end

    # Returns true once #stop has been called. Use inside #run loops as
    # the exit condition:
    #
    #     def run
    #       until should_stop?
    #         # do work
    #       end
    #     end
    def should_stop?
      !@running
    end

    # Return a callable that ServiceRunner can register. Used by
    # ServiceRunner.register_service under the hood.
    def to_proc
      method(:run).to_proc
    end
  end
end
