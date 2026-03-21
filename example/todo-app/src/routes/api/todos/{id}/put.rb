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
