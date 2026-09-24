# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

Tina4.get "/api/todos" do |request, response|
  todos = Todo.all(limit: 100)
  response.json(todos.map(&:to_h), Tina4::HTTP_OK)
end
