# Deployment

Tina4 Ruby includes a Dockerfile, environment configuration, CORS, rate limiting, structured logging, graceful shutdown, and a dependency injection container for production deployments.

## Dockerfile

The generated Dockerfile uses a multi-stage build with Alpine Linux.

```dockerfile
# === Build Stage ===
FROM ruby:3.3-alpine AS builder

RUN apk add --no-cache build-base libffi-dev gcompat

WORKDIR /app

COPY Gemfile Gemfile.lock* ./
RUN bundle config set --local without 'development test' && \
    bundle install --jobs 4 --retry 3

COPY . .

# === Runtime Stage ===
FROM ruby:3.3-alpine

RUN apk add --no-cache libffi gcompat

WORKDIR /app

COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY --from=builder /app /app

EXPOSE 7147

CMD ["bundle", "exec", "tina4ruby", "start", "-p", "7147", "-h", "0.0.0.0"]
```

Build and run:

```bash
docker build -t myapp .
docker run -p 7147:7147 --env-file .env myapp
```

## Environment Configuration (.env)

Tina4 loads `.env` automatically on startup. Supports environment-specific files via `ENVIRONMENT` variable.

```
# .env
PROJECT_NAME="My App"
VERSION="1.0.0"
TINA4_LANGUAGE="en"
TINA4_DEBUG_LEVEL="[TINA4_LOG_INFO]"
SECRET="change-me-in-production"
API_KEY="your-api-key"
DATABASE_URL="sqlite://app.db"
DATABASE_USERNAME=""
DATABASE_PASSWORD=""

# Environment-specific: .env.production, .env.staging
# Set ENVIRONMENT=production to load .env.production
```

Debug levels: `[TINA4_LOG_ALL]`, `[TINA4_LOG_DEBUG]`, `[TINA4_LOG_INFO]`, `[TINA4_LOG_WARNING]`, `[TINA4_LOG_ERROR]`, `[TINA4_LOG_NONE]`

## CORS Configuration

Configure CORS via environment variables.

```
TINA4_CORS_ORIGINS="https://myapp.com,https://admin.myapp.com"
TINA4_CORS_METHODS="GET, POST, PUT, PATCH, DELETE, OPTIONS"
TINA4_CORS_HEADERS="Content-Type, Authorization, Accept"
TINA4_CORS_CREDENTIALS="true"
TINA4_CORS_MAX_AGE="86400"
```

Default is `*` (all origins allowed). CORS headers are applied automatically to all responses. OPTIONS preflight requests return 204 with the configured headers.

## Rate Limiting

```ruby
limiter = Tina4::RateLimiter.new(
  limit: 100,   # max requests per window (default: 100)
  window: 60    # window in seconds (default: 60)
)

Tina4.before("/api") do |request, response|
  limiter.apply(request.ip, response)
end
```

Or configure via environment:

```
TINA4_RATE_LIMIT=200
TINA4_RATE_WINDOW=60
```

Rate limit headers are added to every response:

```
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 95
X-RateLimit-Reset: 1711234567
Retry-After: 42           # only on 429
```

## Logging

Tina4 logs to both console and `logs/debug.log`. In production (`TINA4_ENV=production`), logs are JSON-formatted.

```ruby
Tina4::Log.info("Server started")
Tina4::Log.debug("Processing request", request.path)
Tina4::Log.warning("Slow query detected")
Tina4::Log.error("Database connection lost")
```

Development output:
```
[2026-03-20 14:30:00] [INFO] Server started
```

Production JSON output:
```json
{"timestamp":"2026-03-20T14:30:00.000+00:00","level":"info","message":"Server started","framework":"tina4-ruby","version":"3.0.0"}
```

Log rotation: files rotate at 10MB, keeping 10 rotated files. Old files are gzip-compressed automatically.

Configure max size via environment:
```
TINA4_LOG_MAX_SIZE=20971520
```

## Dependency Injection Container

Register and resolve services globally.

```ruby
# Register a concrete instance
Tina4.register(:mailer, MailService.new)

# Register a lazy factory (called once, memoized)
Tina4.register(:cache) { Redis.new(url: ENV["REDIS_URL"]) }

# Resolve
mailer = Tina4.resolve(:mailer)
cache = Tina4.resolve(:cache)

# Check registration
Tina4::Container.registered?(:mailer)  # => true
```

## Health Check

A built-in `/health` endpoint is registered automatically on startup.

```
GET /health
# => 200 OK with health status
```

## Graceful Shutdown

Tina4 handles `SIGTERM` and `SIGINT` signals for graceful shutdown, cleaning up database connections and other resources.

## Puma Configuration

Tina4 uses Puma as the production server (falls back to WEBrick if Puma is not available).

```ruby
# Puma settings (configured automatically)
# Bind: tcp://0.0.0.0:7147
# Threads: 0-16
# Workers: 0 (single process)
```

Add `puma` to your Gemfile for production:

```ruby
gem "puma", "~> 6.0"
```

## Docker Compose Example

```yaml
version: "3.8"

services:
  app:
    build: .
    ports:
      - "7147:7147"
    environment:
      - DATABASE_URL=postgres://db:5432/myapp
      - DATABASE_USERNAME=user
      - DATABASE_PASSWORD=pass
      - TINA4_ENV=production
      - TINA4_DEBUG_LEVEL=[TINA4_LOG_INFO]
      - SECRET=your-production-secret
    depends_on:
      - db

  db:
    image: postgres:16-alpine
    environment:
      - POSTGRES_USER=user
      - POSTGRES_PASSWORD=pass
      - POSTGRES_DB=myapp
    volumes:
      - pgdata:/var/lib/postgresql/data

volumes:
  pgdata:
```

## .gitignore

The generated `.gitignore` excludes sensitive and generated files:

```
.env
.keys/
logs/
sessions/
.queue/
*.db
vendor/
```

## .dockerignore

```
.git
.env
.keys/
logs/
sessions/
.queue/
*.db
*.gem
tmp/
spec/
vendor/bundle
```
