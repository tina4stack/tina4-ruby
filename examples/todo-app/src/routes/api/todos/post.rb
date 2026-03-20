Tina4.post "/api/todos" do |request, response|
  todo = Todo.create(request.body)
  response.json(todo.to_h, Tina4::HTTP_CREATED)
end
