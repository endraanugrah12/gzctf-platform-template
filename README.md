# Hack-It-Braw GZCTF platform template

This repository is a fork of
[TCP1P/gzctf-platform-template](https://github.com/TCP1P/gzctf-platform-template)
for the Hack-It-Braw deployment. It runs the companion
[endraanugrah12/GZCTF](https://github.com/endraanugrah12/GZCTF/tree/evidence-routes)
fork rather than the upstream GZCTF image.

## Changes in this fork

- **Custom application build.** Compose Makefile targets build the companion
  source as `gzctf-local:big-update` so local patches are included. The published
  `ghcr.io/endraanugrah12/gzctf:evidence-routes` image remains available for other deployments. GitHub Actions also publishes
  the WireGuard, SSH jump, and Kubernetes challenge-route helper images to
  GHCR.
- **Two-node K3s deployment.** `make wizard` can render a control/worker setup
  into `k8s/generated/`. PostgreSQL, Redis, GZCTF, Traefik, persistent files,
  and access helpers stay on the control node; challenge workloads are placed
  on the worker.
- **Per-challenge connection mode.** Any HTTP container challenge can enable
  **Use Public HTTPS Route** and receive a wildcard
  `https://<instance>.chall.example.com` route through Traefik. Raw TCP
  challenges retain `host:NodePort`; their public firewall must deliberately
  allow TCP `30000-32767`. The choice is independent of challenge category and
  can also be set by repository binding with
  `container.usePublicHttpRoute: true`.
- **No Kubernetes WebSocket proxy requirement.** The Kubernetes provider is
  forced to direct port mapping after database-backed configuration is loaded,
  preventing an old `PlatformProxy` setting from restoring `wss://` instance
  entries.
- **Repository builds on Kubernetes.** A pod-local BuildKit sidecar builds
  trusted repository-bound challenges and pushes them to an operator-configured
  registry that worker nodes can pull from.
- **Submission evidence controls.** The custom application adds submission
  evidence storage and review, solver-file handling, and configurable allowed
  LLM share-link hosts, including dotted domain names.
- **A&D access on K3s.** The manifests carry over the restricted WireGuard
  gateway, SSH jump service, honeypot listeners, scoped RBAC, and challenge
  network policy required by the fork's Attack & Defense features.
- **Makefile-driven operations.** The wizard, apply, status, log, and BuildKit
  targets provide a repeatable path for both Docker Compose and K3s installs.

Generated deployment files and secrets under `k8s/generated/` are intentionally
ignored by Git. Consequently, `git pull` updates the templates but does not
rewrite an existing deployment. Review
[`k8s/README.md`](k8s/README.md) before upgrading or exposing firewall ports.

## Docker compose

Clone the companion source into the ignored `gzctf/` directory on a fresh checkout:

```sh
git clone --branch evidence-routes https://github.com/endraanugrah12/GZCTF.git gzctf
```

```sh
make compose-wizard # interactive prompts → writes .env + appsettings.json
make setup          # creates external proxy and challenge networks
make platform-build # compiles the local GZCTF source and frontend
make platform-up    # starts gzctf + db + cache + traefik
```

The wizard prints the auto-generated admin password at the end — copy
it before closing the terminal. Then log in at `https://PUBLIC_ENTRY`
as user `Admin`.

`make help` lists every target. SMTP / captcha / private-registry
credentials can also be configured later under `/admin/settings`.

The game admin page includes **Reset activity** for solves and notifications,
and **Manage challenges** is accessible without joining the game. New challenges
default to 500 points with a 100-point floor; existing scores are preserved.
The public scoreboard stays frozen from the configured freeze time until that
setting is cleared. Admins and monitors see live standings.

Under **Admin → Users → Edit**, **Hide from scoreboard** hides any team containing
that account across all games, including frozen boards and timelines. For Jeopardy,
hidden teams also stop affecting dynamic points and blood bonuses. Submissions and
evidence remain stored; turning the option off restores eligibility.

Player instance panels check readiness before enabling connection details. HTTPS
checks the root URL (including the route and certificate); 404/5xx stay pending.
TCP checks the service's listening port. Checks finish as soon as the endpoint
responds, or offer **Retry check** after roughly 20 seconds. A web application whose
root intentionally returns 404 must provide a working root response for this check.
The Compose route watcher polls every two seconds and updates Traefik only when
routes change.

### Appearance editor

Open **Admin → Appearance** to edit the title prefix, slogan, primary color,
logo/favicon URLs, homepage Markdown, announcement banner, footer, and custom CSS.
Markdown can include links and images. The embedded player homepage previews
unsaved changes in desktop or mobile width. **Save draft** persists work privately;
**Publish design** updates player pages within 30 seconds, without an image rebuild.
**Restore defaults** clears both draft and published overrides and uses the original
Settings branding again. CSS is never applied to admin or account pages.

The draft and published designs are stored separately in the existing database
configuration table. Only admins can read drafts or change designs. This is a
branding/content editor; JavaScript and arbitrary page components are not supported.

## Bring your own container (self-hosted A&D)

For an Attack & Defense challenge you can let each team run the vulnerable
service on **their own machine** instead of the platform hosting one copy per
team. The platform launches only a lightweight **tunnel relay**; the team
connects their service to it with a single outbound command — no public IP,
inbound firewall rule, or VPN on the team's side. The SLA checker, attack proxy,
flag rotation and scoreboard all behave exactly as for a hosted service.

**Enable it** on any A&D challenge by setting `selfHosted: true` in its
`ad:` block (see `challenges/attack-defense/challenge.yml`):

```yaml
type: AttackDefense
container:
  exposePort: 80          # the port your service listens on
ad:
  selfHosted: true        # ← teams run the service themselves
```

**What a team does** (all from the in-game challenge panel):

1. Open the challenge → **Download `setup.sh`**.
2. Run `sh setup.sh`. It pulls the challenge's service image from the platform
   and a tiny agent, writes a `docker-compose.yml`, and `docker compose up`s
   them — the agent dials the platform and the service goes live. Their status
   goes green within a tick.

**Requirements (this template already satisfies them):**

- **Docker provider only.** The relay launch is skipped on Kubernetes, so BYOC
  needs the docker-compose deployment (the `compose/` stack), not `k8s/`.
- **Reachable at `PUBLIC_ENTRY`.** The team's agent connects to
  `wss://PUBLIC_ENTRY/...`; the bundled traefik already routes that host to gzctf
  and proxies the WebSocket — nothing extra to configure.
- **Relay/agent image** is public (`dimasmaualana/gzctf-byoc-relay`) and pulled
  automatically through the mounted docker socket — no registry setup. Override
  it via `Ad:Byoc:RelayImage` / `Ad:Byoc:AgentImage` in `appsettings.json` if you
  self-host the image.
- Make sure the platform image is current: `make pull-gzctf && make update-gzctf`
  (BYOC needs a recent `dimasmaualana/gzctf:develop`).

Teams that prefer to run a *modified* service (rather than the image you ship)
can grab a plain compose instead via the panel's "bring your own service" link.

## Kubernetes / k3s

```sh
make wizard                              # choose k8s; generates ignored manifests + secrets
make KUBECTL='sudo k3s kubectl' k8s-apply
sudo k3s kubectl -n gzctf rollout status deploy/gzctf
```

The Kubernetes path uses the custom GZCTF image and carries over the A&D SSH
jump, restricted WireGuard gateway, honeypot listeners, first-boot admin seed,
submission-evidence policy, direct HTTPS routes, and raw TCP NodePorts. See
[`k8s/README.md`](k8s/README.md) for
node placement, firewall ports, storage, RBAC, and the remaining provider
limitations.
