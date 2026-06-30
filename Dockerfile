# Reproducible image for the Send Invoice web app (WEBrick/Rack, Ruby).
FROM ruby:3.2-slim

ENV LANG=C.UTF-8 \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    PORT=3000 \
    BIND_ADDRESS=0.0.0.0

WORKDIR /app

# Native extension build deps for sqlite3; removed from the final layer is not
# trivial in a single-stage build, so keep the image slim by cleaning apt lists.
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends build-essential libsqlite3-dev libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Install gems first so dependency layers cache across app code changes.
COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY . .

# Persist the SQLite database outside the image layer (see docker-compose).
ENV DATABASE_PATH=/data/send_invoice.sqlite3
RUN mkdir -p /data

EXPOSE 3000

# Simple liveness probe against the app's /health endpoint.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ruby -e "require 'net/http'; exit(Net::HTTP.get_response(URI(\"http://127.0.0.1:#{ENV['PORT']}/health\")).is_a?(Net::HTTPSuccess) ? 0 : 1)" || exit 1

CMD ["bundle", "exec", "ruby", "app.rb"]
