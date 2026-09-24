# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


module Tina4
  module Realtime
    # Workspace - the top-level container for channels (a "team" / "org").
    # Framework-owned table: the tina4_rt_ prefix keeps it clear of an app's own
    # domain tables (mirrors tina4_migration / tina4_sequences + the Python
    # master's tina4_rt_* tables). Ruby is snake_case end to end, so the columns,
    # attributes, and JSON keys are all snake_case with no mapping layer.
    class Workspace < Tina4::ORM
      table_name "tina4_rt_workspaces"

      integer_field :id, primary_key: true, auto_increment: true
      string_field :name, nullable: false, length: 200
      datetime_field :created_at
    end
  end
end
