PROXY_NETWORK = net-global

.PHONY: up down logs build network certs

up: network
	@docker compose up -d

down:
	@docker compose down

logs:
	@docker compose logs -f

build:
	@docker compose build

network:
	@docker network inspect $(PROXY_NETWORK) >/dev/null 2>&1 || docker network create $(PROXY_NETWORK)
