# Todo App — Tina4 Ruby

Minimal todo API demonstrating Tina4 conventions.

## Run

```bash
cd examples/todo-app
bundle install
ruby app.rb
```

## API

| Method | Path               | Description   |
|--------|--------------------|---------------|
| GET    | /api/todos         | List todos    |
| POST   | /api/todos         | Create todo   |
| GET    | /api/todos/{id}    | Get one todo  |
| PUT    | /api/todos/{id}    | Update todo   |
| DELETE | /api/todos/{id}    | Delete todo   |

## Structure

```
app.rb                              # Entry point
src/models/todo.rb                  # Todo ORM model
src/routes/api/todos/get.rb         # GET  /api/todos
src/routes/api/todos/post.rb        # POST /api/todos
src/routes/api/todos/{id}/get.rb    # GET  /api/todos/{id}
src/routes/api/todos/{id}/put.rb    # PUT  /api/todos/{id}
src/routes/api/todos/{id}/delete.rb # DELETE /api/todos/{id}
src/templates/index.html            # Frond template
```

## Cross-Framework Parity

This exact same structure, API, and patterns exist in all 4 Tina4 frameworks:

| File             | Python          | PHP             | Node.js         | Ruby            |
|------------------|-----------------|-----------------|-----------------|-----------------|
| Entry point      | `app.py`        | `index.php`     | `app.ts`        | `app.rb`        |
| Model            | `todo.py`       | `Todo.php`      | `todo.ts`       | `todo.rb`       |
| Routes           | `get.py` etc.   | `get.php` etc.  | `get.ts` etc.   | `get.rb` etc.   |
| Template         | `index.html`    | `index.html`    | `index.html`    | `index.html`    |
| Response pattern | `response()`    | `$response()`   | `response()`    | `response.json` |
| HTTP constants   | `HTTP_OK`       | `HTTP_OK`       | `HTTP_OK`       | `Tina4::HTTP_OK`|
