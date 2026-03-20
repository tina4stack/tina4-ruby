Tina4.delete "/api/todos/{id}" do |request, response|
  todo = Todo.find(request.params[:id])
  if todo
    todo.delete
    response.json({ message: "Deleted" }, Tina4::HTTP_OK)
  else
    response.json({ error: "Not found" }, Tina4::HTTP_NOT_FOUND)
  end
end
