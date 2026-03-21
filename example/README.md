# Tina4 Ruby Example Application

A simple example showing routing, ORM, templates, and JSON APIs.

## Setup

```bash
cd tina4-ruby
bundle install
```

## Run

```bash
cd example
ruby app.rb
```

Visit http://localhost:7147

## Routes

| Method | Path             | Description              |
|--------|------------------|--------------------------|
| GET    | /                | Welcome page (template)  |
| GET    | /api/hello       | JSON greeting            |
| GET    | /api/users       | List all users           |
| GET    | /api/users/{id}  | Get user by ID           |
| POST   | /api/users       | Create a new user        |

## Project Structure

```
example/
  app.rb                  # Entry point
  .env                    # Environment config
  orm/
    user.rb               # User ORM model
  routes/
    index.rb              # GET / welcome page
    api.rb                # JSON API routes
  templates/
    index.twig            # Welcome page template
```

## More Info

https://tina4.com
