# frozen_string_literal: true
# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.


class User < Tina4::ORM
  table_name "users"
  integer_field :id, primary_key: true, auto_increment: true
  string_field  :first_name
  string_field  :last_name
  string_field  :email
  integer_field :age, nullable: true
end
