Tina4.get "/api/todos/{id}" do |request, response|
  todo = Todo.find(request.params[:id])
  if todo
    response.json(todo.to_h, Tina4::HTTP_OK)
  else
    response.json({ error: "Not found" }, Tina4::HTTP_NOT_FOUND)
  end
end
