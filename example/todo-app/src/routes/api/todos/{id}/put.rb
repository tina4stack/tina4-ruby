# Copyright (c) 2026 Code Infinity
# SPDX-License-Identifier: MPL-2.0
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

Tina4.put "/api/todos/{id}" do |request, response|
  todo = Todo.find(request.params[:id])
  if todo
    todo.title = request.body["title"] if request.body["title"]
    todo.completed = request.body["completed"] if request.body.key?("completed")
    todo.save
    response.json(todo.to_h, Tina4::HTTP_OK)
  else
    response.json({ error: "Not found" }, Tina4::HTTP_NOT_FOUND)
  end
end
