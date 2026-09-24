# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

class Todo < Tina4::ORM
  integer_field :id, primary_key: true, auto_increment: true
  string_field :title
  integer_field :completed, default: 0
  datetime_field :created_at
end
