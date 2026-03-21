# === Build Stage ===
FROM ruby:3.3-alpine AS builder

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    libffi-dev \
    gcompat

WORKDIR /app

# Copy dependency definition first (layer caching)
COPY Gemfile Gemfile.lock* ./

# Install gems
RUN bundle config set --local without 'development test' && \
    bundle install --jobs 4 --retry 3

# Copy application code
COPY . .

# === Runtime Stage ===
FROM ruby:3.3-alpine

# Runtime packages only
RUN apk add --no-cache libffi gcompat

WORKDIR /app

# Copy installed gems
COPY --from=builder /usr/local/bundle /usr/local/bundle

# Copy application code
COPY --from=builder /app /app

EXPOSE 7147

# Swagger defaults (override with env vars in docker-compose/k8s if needed)
ENV SWAGGER_TITLE="Tina4 API"
ENV SWAGGER_VERSION="0.1.0"
ENV SWAGGER_DESCRIPTION="Auto-generated API documentation"

# Start the server on all interfaces
CMD ["bundle", "exec", "tina4ruby", "start", "-p", "7147", "-h", "0.0.0.0"]
