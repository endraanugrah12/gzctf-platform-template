# GZCTF platform — docker-compose helper targets.
# Pure platform ops; for challenge authoring use gzcli separately.

SUDO ?=
COMPOSE = ${SUDO} docker compose -f compose.yml -f compose.challenge-proxy.yml
COMPOSE_BARE = ${SUDO} docker compose -f compose.yml -f compose.standalone.yml

.PHONY: help wizard setup init-config platform-build platform-up platform-up-no-traefik platform-down platform-restart platform-clean \
        platform-logs gzctf-logs db-logs cache-logs traefik-logs traefik-restart \
        flush-cache pull pull-no-traefik pull-gzctf update update-no-traefik update-gzctf \
        k8s-check k8s-apply k8s-status k8s-logs

KUBECTL ?= kubectl

help:
	@echo "GZCTF platform make targets:"
	@echo ""
	@echo "  wizard           Interactive first-time setup (writes .env + appsettings.json)"
	@echo "  setup            One-time bootstrap: create the external `traefik` + `challenges` networks"
	@echo "  init-config      Generate compose/appsettings.json from the example + .env (auto-runs on platform-up)"
	@echo "  platform-build   Compatibility alias for pull-gzctf (GZCTF image is prebuilt)"
	@echo "  platform-up      Start gzctf + db + cache + traefik (auto-runs init-config if config missing)"
	@echo "  platform-up-no-traefik   Start gzctf + db + cache only, expose gzctf on host port 8080"
	@echo "  platform-down    Stop everything (keeps volumes)"
	@echo "  platform-restart Restart all services"
	@echo "  platform-clean   Stop everything AND drop volumes (data loss)"
	@echo "  pull             Pull the latest image for every service"
	@echo ""
	@echo "  platform-logs    Tail logs for all services"
	@echo "  gzctf-logs       Tail gzctf only"
	@echo "  db-logs          Tail postgres only"
	@echo "  cache-logs       Tail redis only"
	@echo "  traefik-logs     Tail traefik only"
	@echo "  traefik-restart  Restart traefik only"
	@echo ""
	@echo "  flush-cache      Flush redis (rebuilds scoreboard cache on next request)"
	@echo ""
	@echo "Updating images:"
	@echo "  pull-gzctf       Pull the configured GZCTF image (no restart)"
	@echo "  pull             Pull latest of every image incl. traefik (no restart)"
	@echo "  pull-no-traefik  Pull latest of gzctf + postgres + redis (no restart)"
	@echo "  update-gzctf     Build gzctf + recreate just the gzctf container"
	@echo "  update           Pull all + recreate any container with a changed image (traefik mode)"
	@echo "  update-no-traefik  Same as 'update' but for the standalone (no-traefik) mode"
	@echo ""
	@echo "Kubernetes / k3s:"
	@echo "  k8s-check        Refuse deployment while CHANGE_ME placeholders remain"
	@echo "  k8s-apply        Validate and apply all manifests in dependency order"
	@echo "  k8s-status       Show platform and challenge pods with node placement"
	@echo "  k8s-logs         Tail the GZCTF pod"
	@echo ""
	@echo "First-time setup:"
	@echo "  make wizard && make setup && make platform-up"
	@echo "  (the wizard prompts for PUBLIC_ENTRY + optional SMTP/captcha, generates an admin password)"

wizard:
	@sh scripts/wizard.sh

setup:
	@echo "Creating external docker networks 'traefik' + 'challenges' (idempotent)..."
	@${SUDO} docker network inspect traefik >/dev/null 2>&1 \
		|| ${SUDO} docker network create traefik
	@${SUDO} docker network inspect challenges >/dev/null 2>&1 \
		|| ${SUDO} docker network create challenges
	@echo "Done. Run 'make platform-up' to start the platform."

# Generates compose/appsettings.json from the shipped example on
# first run. Idempotent — bails silently if the file already exists.
init-config:
	@sh scripts/init-config.sh

platform-build:
	@$(MAKE) pull-gzctf

platform-up: init-config
	(cd compose && ${COMPOSE} up -d)

# Bring up gzctf + db + cache only — no traefik, no TLS. gzctf is
# reachable on http://<host>:8080.
platform-up-no-traefik: init-config
	(cd compose && ${COMPOSE_BARE} up -d)

platform-down:
	(cd compose && ${COMPOSE} down)

platform-restart: platform-down platform-up

platform-clean:
	(cd compose && ${COMPOSE} down -v)

pull:
	(cd compose && ${COMPOSE} pull)

pull-no-traefik:
	(cd compose && ${COMPOSE_BARE} pull)

pull-gzctf:
	(cd compose && ${COMPOSE} pull gzctf)

# 'up -d' recreates any container whose image digest changed and
# leaves the rest alone. Safe to run while the platform is live —
# only gzctf goes down briefly if its image was updated.
update: pull
	(cd compose && ${COMPOSE} up -d)

update-no-traefik: pull-no-traefik
	(cd compose && ${COMPOSE_BARE} up -d)

# Targeted refresh: only touch the gzctf container; leave traefik
# and the DB/cache running. Works in either traefik or standalone
# mode since both files describe the same gzctf service.
update-gzctf: pull-gzctf
	(cd compose && ${COMPOSE} up -d --no-deps gzctf)

platform-logs:
	(cd compose && ${COMPOSE} logs -f)

gzctf-logs:
	(cd compose && ${COMPOSE} logs -f gzctf)

db-logs:
	(cd compose && ${COMPOSE} logs -f db)

cache-logs:
	(cd compose && ${COMPOSE} logs -f cache)

traefik-logs:
	(cd compose && ${COMPOSE} logs -f traefik)

traefik-restart:
	(cd compose && ${COMPOSE} restart traefik)

flush-cache:
	(cd compose && ${COMPOSE} exec cache redis-cli FLUSHALL)

k8s-check:
	@if grep -nE 'CHANGE_ME|ctf\.example\.com' k8s/*.yaml; then \
		echo "Replace every deployment placeholder before deploying." >&2; \
		exit 1; \
	fi
	@${KUBECTL} apply --dry-run=client -f k8s/00-namespace.yaml \
		-f k8s/05-traefik-config.yaml -f k8s/10-postgres.yaml -f k8s/20-redis.yaml \
		-f k8s/30-gzctf-config.yaml -f k8s/35-ad-network-policy.yaml \
		-f k8s/40-gzctf.yaml -f k8s/50-ingress.yaml \
		-f k8s/60-ad-access.yaml >/dev/null

k8s-apply: k8s-check
	@${KUBECTL} apply -f k8s/00-namespace.yaml
	@${KUBECTL} apply -f k8s/05-traefik-config.yaml
	@${KUBECTL} apply -f k8s/30-gzctf-config.yaml
	@${KUBECTL} apply -f k8s/10-postgres.yaml -f k8s/20-redis.yaml
	@${KUBECTL} apply -f k8s/35-ad-network-policy.yaml
	@${KUBECTL} apply -f k8s/40-gzctf.yaml -f k8s/50-ingress.yaml
	@${KUBECTL} apply -f k8s/60-ad-access.yaml

k8s-status:
	@${KUBECTL} -n gzctf get pods -o wide
	@${KUBECTL} -n gzctf-challenges get pods -o wide

k8s-logs:
	@${KUBECTL} -n gzctf logs -f deployment/gzctf
