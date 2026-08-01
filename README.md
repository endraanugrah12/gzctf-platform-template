# GZCTF platform template

Scaffolding to run a [GZCTF](https://github.com/GZTimeWalker/GZCTF) instance.

## Docker compose

```sh
make wizard         # interactive prompts → writes .env + appsettings.json
make setup          # creates the external `traefik` docker network
make platform-up    # starts gzctf + db + cache + traefik
```

The wizard prints the auto-generated admin password at the end — copy
it before closing the terminal. Then log in at `https://PUBLIC_ENTRY`
as user `Admin`.

`make help` lists every target. SMTP / captcha / private-registry
credentials can also be configured later under `/admin/settings`.

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
$EDITOR k8s/05-traefik-config.yaml  # set ACME email
$EDITOR k8s/30-gzctf-config.yaml    # set secrets, hostname, control private IP
$EDITOR k8s/50-ingress.yaml         # set hostname

make KUBECTL='sudo k3s kubectl' k8s-apply
sudo k3s kubectl -n gzctf rollout status deploy/gzctf
```

The Kubernetes path uses the custom GZCTF image and carries over the A&D SSH
jump, restricted WireGuard gateway, honeypot listeners, first-boot admin seed,
submission-evidence policy, and PlatformProxy routing. See
[`k8s/README.md`](k8s/README.md) for
node placement, firewall ports, storage, RBAC, and the remaining provider
limitations.
