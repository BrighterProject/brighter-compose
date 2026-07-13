#!/usr/bin/env bash
# Single entry point for dev-stack seeding.
#
# Runs the per-service seed scripts in dependency order so the result is a
# coherent dev dataset instead of three independent, unrelated fixtures:
#   1. users-ms   — dev users (admin, subscribed owner, unsubscribed owner, regular user)
#   2. payments-ms — active Starter subscription for the *subscribed* dev owner
#   3. properties-ms — property fixtures, owned by that same subscribed dev owner
#
# Usage (from brighter-compose/):
#   ./scripts/seed_all.sh                 # seed on top of whatever's already there
#   ./scripts/seed_all.sh --force         # re-seed properties even if some already exist
#   ./scripts/seed_all.sh --reset         # drop+recreate the DB, then seed fresh
#   ./scripts/seed_all.sh --reset --force # same, plus --force (harmless on a fresh DB)
#
# Requires the dev stack to already be up: `docker compose up -d`.
#
# --reset mirrors brighter-e2e/Makefile's `clean-e2e-db` target: every service
# calls ms_core.setup_app(..., generate_schemas=True), which creates its own
# tables from its models on startup — there is NO manual `tortoise migrate`
# step here. Do not add one: all five services share one physical `brighter`
# database *and* the Tortoise app label "models", so the migration-tracking
# table's UNIQUE(app, name) constraint collides across services (e.g. every
# service's first migration is named "0001_initial") and silently skips
# real per-service migrations. generate_schemas=True sidesteps that table
# entirely. Also re-applies the Bulgarian FTS config
# (brighter-postgres/init-bulgarian-fts.sql) — it's per-database and only
# auto-installed on first Postgres cluster init, so a freshly recreated
# `brighter` database won't have it, and properties-ms's schema generation
# (its FTS columns reference the `bulgarian` search config) fails outright
# without it, silently leaving properties-ms with zero tables.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

RESET=""
FORCE_FLAG=""
for arg in "$@"; do
  case "$arg" in
    --reset) RESET="1" ;;
    --force) FORCE_FLAG="--force" ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

# Must match brighter-users-ms/scripts/seed.py (owner@liberhack.org, the
# subscribed dev owner) and brighter-payments-ms/scripts/seed_dev.py.
DEV_OWNER_SUB_ID="a0000000-0000-0000-0000-000000000002"

FTS_INIT="../brighter-postgres/init-bulgarian-fts.sql"

if [[ -n "$RESET" ]]; then
  echo "==> [reset] Dropping and recreating the brighter database"
  docker compose exec -T db psql -U brighter -d postgres -c \
    "DROP DATABASE IF EXISTS brighter WITH (FORCE);"
  docker compose exec -T db psql -U brighter -d postgres -c "CREATE DATABASE brighter OWNER brighter;"

  echo "==> [reset] Re-applying Bulgarian FTS config (required by properties-ms)"
  docker compose exec -T db psql -U brighter -d brighter < "$FTS_INIT"

  echo "==> [reset] Restarting backend services so each recreates its own schema"
  BACKEND_SERVICES="users-ms properties-ms bookings-ms payments-ms notifications-ms"
  docker compose restart $BACKEND_SERVICES

  echo "==> [reset] Waiting for backend services to report healthy"
  for _ in $(seq 1 60); do
    unhealthy=$(docker compose ps --format '{{.Service}} {{.Health}}' $BACKEND_SERVICES \
      | awk '$2 != "healthy" {print $1}')
    [[ -z "$unhealthy" ]] && break
    sleep 2
  done
  if [[ -n "${unhealthy:-}" ]]; then
    echo "!! Timed out waiting for: $unhealthy" >&2
    exit 1
  fi
fi

echo "==> [1/3] Seeding users-ms (admin, owners, regular user)"
docker compose exec -T users-ms uv run python scripts/seed.py

echo "==> [2/3] Seeding payments-ms (Starter subscription for dev_owner_sub)"
docker compose exec -T payments-ms uv run python scripts/seed_dev.py

echo "==> [3/3] Seeding properties-ms (fixtures owned by dev_owner_sub)"
docker compose exec -T -e SEED_OWNER_ID="${DEV_OWNER_SUB_ID}" properties-ms \
  uv run python scripts/seed.py ${FORCE_FLAG}

echo "==> Done. dev_owner_sub (owner@liberhack.org) now has a subscription and properties."
