# === Build Stage ===
FROM ruby:3.3-alpine AS builder

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    libffi-dev \
    gcompat

WORKDIR /app

# The WHOLE tree, before bundle install. This deliberately gives up the usual
# copy-the-Gemfile-first layer caching, because this repo IS the gem and the
# Gemfile's line 3 is `gemspec name: "tina4ruby"`. That makes bundler resolve
# this directory as a local path gem, and a path gem must be complete when it is
# resolved. Both partial copies fail, in different ways:
#
#   Gemfile + lock only  -> "[!] There was an error parsing `Gemfile`: There are
#                            no gemspecs at /app. Bundler cannot continue."
#   + *.gemspec + version.rb -> installs, but the gemspec's
#                            spec.files = Dir.glob("{lib,exe}/**/*") is evaluated
#                            AT THAT MOMENT, so exe/ is empty, no executable is
#                            registered, and the container dies on boot with
#                            "bundler: command not found: tina4ruby".
#
# The second one is the dangerous shape: the image BUILDS CLEANLY and only fails
# when you run it. Copy everything, then install.
COPY . .

# Install gems
RUN bundle config set --local without 'development test' && \
    bundle install --jobs 4 --retry 3

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

# Swagger defaults. These MUST carry the TINA4_ prefix.
#
# They were previously set un-prefixed (SWAGGER_TITLE, SWAGGER_VERSION,
# SWAGGER_DESCRIPTION), which are the v2/v3.11-era LEGACY names. lib/tina4/env.rb
# maps them to their TINA4_ forms and Tina4.check_legacy_env_vars! REFUSES to boot
# when it finds any of them. So this image shipped the exact misconfiguration the
# framework rejects, and every container exited 2 during startup, before serving
# a single request. Nothing caught it because no CI ever ran the image.
ENV TINA4_SWAGGER_TITLE="Tina4 API"
ENV TINA4_SWAGGER_VERSION="0.1.0"
ENV TINA4_SWAGGER_DESCRIPTION="Auto-generated API documentation"

# Required. Tina4::WebServer#start refuses to run unless it was launched by the
# tina4 CLI (--managed) or this is set -- it prints "Tina4 must be started with
# the tina4 CLI" and exits 1. A container has no CLI supervising it, so without
# this the image cannot boot. Python and PHP already set it; Ruby did not.
ENV TINA4_OVERRIDE_CLIENT=true
ENV TINA4_DEBUG=false

# --production selects puma. Without it cmd_start falls through to WEBrick, so a
# PRODUCTION image was serving from the development server.
CMD ["bundle", "exec", "tina4ruby", "start", "-p", "7147", "-h", "0.0.0.0", "--production"]
