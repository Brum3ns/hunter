# hunter — Rails scaffold + Docker dev environment (design)

Date: 2026-06-23

## Purpose

`hunter` is a web app + API for bug-bounty vulnerability management. PostgreSQL
stores users, settings, and config. MongoDB (later) holds vulnerability results
read through the Rails API. This spec covers **only the scaffolding pass**: get a
Rails 8 app running under Docker with live reload. Vulnerability models and the
Mongo-backed API are deliberately out of scope and will be designed separately.

The Docker files were copied from a prior project (`scope`) and carry
scope-specific baggage (a Go CLI build stage, a mounted `scope` binary, a
`scope:keys:verify` task). Those are removed here.

## Stack

- Ruby 3.3.6, Rails 8
- PostgreSQL 18
- Tailwind CSS, Hotwire (Turbo + Stimulus, Rails 8 defaults)
- Rails 8 built-in authentication (username/password, no email)
- App lives in `web/`

## Components

### 1. Rails app (`web/`)
- Rails 8 app, PostgreSQL adapter, Tailwind, Hotwire defaults.
- Built-in auth generator: `User` + `Session`, **username/password only, no
  email**. Seed a default `admin/admin` user in `db/seeds.rb`.
- Rake task `users:reset_password USERNAME=... PASSWORD=...` for CLI-only
  password reset (no web reset flow, no SMTP).
- `database.yml` reads `DB_HOST / DB_PORT / DB_USERNAME / DB_PASSWORD` from env.
- A single authenticated landing page on a dark zinc theme to prove login +
  Tailwind work end-to-end. No vulnerability features.
- `Procfile.dev` runs `rails server -b 0.0.0.0 -p 5000` and
  `tailwindcss:watch` in parallel.

### 2. Dockerfile
- Single stage on `ruby:3.3.6-slim` (Go build stage removed).
- Build deps: `build-essential libpq-dev libyaml-dev postgresql-client git curl`.
- `bundle install` + `gem install foreman`. Copy `web/`. Asset precompile only
  when `RAILS_ENV=production`. Exposes port 5000.

### 3. docker-compose.yaml (dev)
- `db`: `postgres:18-alpine`, volume `db-data:/var/lib/postgresql`, healthcheck.
- `mongo`: `mongo:8`, volume `mongo-data:/data/db`, healthcheck — kept running
  as a **dormant** service (not wired to Rails yet).
- `web`: builds the Dockerfile, mounts `./web:/app` for live reload, runs
  `db:prepare && db:migrate && db:seed && foreman start -f Procfile.dev`.
  Host port 5000. No `scope:keys:verify`, no scope binary mount, no `SCOPE_*`
  env. `MONGO_*` env is passed through (unused now, ready for later).
- `.env.example` documents the variables.

## Out of scope (separate brainstorm)
- `mongo` gem / Mongo connection from Rails
- Vulnerability models, controllers, and `/api/v1/*` endpoints
- Production compose / deployment

## Success criteria
- `docker compose up --build` brings up db, mongo, and web.
- Visiting `http://127.0.0.1:5000` serves the app; login with `admin/admin`
  works; Tailwind styles render; editing a file in `web/` hot-reloads.
