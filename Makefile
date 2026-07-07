COMPOSE := docker compose

.PHONY: reseed

reseed:
	$(COMPOSE) down
	$(COMPOSE) rm -fsv db || true
	docker volume rm brighter-compose_pgdata || true
	$(COMPOSE) up -d --wait
	$(COMPOSE) exec -T users-ms uv run python scripts/seed.py
	$(COMPOSE) exec -T properties-ms uv run python scripts/seed.py
	$(COMPOSE) exec -T payments-ms uv run python scripts/seed_dev.py
