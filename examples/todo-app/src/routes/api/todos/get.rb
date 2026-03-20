Tina4.get "/api/todos" do |request, response|
  todos = Todo.all(limit: 100)
  response.json(todos.map(&:to_h), Tina4::HTTP_OK)
end
