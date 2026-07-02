# PEMK dedicated server image. Build context is the REPO ROOT (the image needs
# both server/ and the shared protocol/ vendored lib), so build with:
#   docker build -f server/Dockerfile -t pemk-server .
# or via server/docker-compose.yml (context: ..).
FROM ruby:3.1-slim

# libpq5 at runtime; build toolchain only to compile the pg native ext, then drop.
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libpq-dev libpq5 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install gems first (cached layer) — Gemfile lives in server/.
COPY server/Gemfile server/Gemfile.lock* ./
RUN bundle config set --local without 'development test' \
 && bundle install

# Vendored wire protocol (shared byte-for-byte with the mkxp-z plugin) + the app.
COPY protocol/ ./protocol/
COPY server/ ./

EXPOSE 9998

# Migrate then boot. (compose overrides this; kept here so a bare `docker run` works.)
CMD ["sh", "-c", "bundle exec rake db:migrate && bundle exec ruby bin/pemk_server.rb"]
