# Kubernetes / k3s deployment

Apply-in-order manifests for running GZCTF on k3s (or any other k8s
distribution). Mirrors the docker-compose path under `compose/` but
swaps the `ContainerProvider` to `Kubernetes` so challenge instances
spawn as pods inside the `gzctf-challenges` namespace instead of via
the host's docker socket.

## Quick start

```sh
# 1. From the repository root, run the interactive setup and choose k8s.
make wizard

# 2. Validate and apply the generated manifests in dependency order.
make KUBECTL='sudo k3s kubectl' k8s-apply

# 3. Watch the gzctf pod come up
sudo k3s kubectl -n gzctf rollout status deploy/gzctf
```

The wizard asks for the public hostname, ACME email, control VM private IP,
control node name, and K3s Service CIDR. It generates all secrets and renders
the result under `k8s/generated/`. That directory is mode `0700`, its files are
mode `0600`, and it is gitignored.

Back up the generated directory securely after setup. In particular, losing or
rotating the generated XOR key makes encrypted registry and repository
credentials already stored in PostgreSQL unreadable.

### Secrets

The normal wizard handles secrets automatically. To manage them manually,
remove the Secret document from your generated `30-gzctf-config.yaml` and
create it separately:

```sh
sudo k3s kubectl apply -f k8s/generated/00-namespace.yaml

sudo k3s kubectl -n gzctf create secret generic gzctf-secrets \
  --from-literal=postgres-password="$(openssl rand -hex 16)" \
  --from-literal=xor-key="$(openssl rand -hex 32)" \
  --from-literal=admin-password="Aa1$(openssl rand -hex 12)" \
  --from-literal=ad-ssh-internal-secret="$(openssl rand -hex 32)" \
  --from-literal=smtp-username="" \
  --from-literal=smtp-password=""

# Do not subsequently apply the Secret document from
# 30-gzctf-config.yaml; it would replace these separately managed values.
```

Read the admin password back when you need to log in:

```sh
sudo k3s kubectl -n gzctf get secret gzctf-secrets -o jsonpath='{.data.admin-password}' | base64 -d
```

> **Don't rotate `xor-key` after first boot** — gzctf uses it to
> encrypt repo-binding PATs + registry passwords at rest. Changing
> the key after data lands breaks every encrypted value in the DB.

GZCTF will be reachable at the hostname configured in `50-ingress.yaml`
once Traefik's ACME resolver issues a TLS certificate. Port 80 must remain
publicly reachable for the HTTP-01 challenge.

## What's here

| File | Purpose |
|---|---|
| `00-namespace.yaml` | Two namespaces: `gzctf` (platform) + `gzctf-challenges` (where challenge pods land) |
| `05-traefik-config.yaml` | Persistent Let's Encrypt resolver for k3s Traefik |
| `10-postgres.yaml` | PVC + Deployment + Service for postgres 17 |
| `20-redis.yaml` | Deployment + Service for redis (cache) |
| `30-gzctf-config.yaml` | ConfigMap holding `appsettings.json` (Kubernetes provider mode) + Secret for db password + ServiceAccount with RBAC for spawning challenge pods |
| `35-ad-network-policy.yaml` | A&D pod-to-pod, checker, and restricted WireGuard ingress |
| `40-gzctf.yaml` | PVC for `/app/files` + Deployment + Service for gzctf |
| `50-ingress.yaml` | Traefik ingress using the built-in ACME resolver |
| `60-ad-access.yaml` | WireGuard and SSH jump access for A&D challenges |

## Differences from the docker-compose path

| Concern | docker-compose (`compose/`) | kubernetes (`k8s/`) |
|---|---|---|
| Challenge spawning | host docker socket | in-cluster ServiceAccount → spawns Pods in `gzctf-challenges` ns |
| Public entry | Traefik container on host | Cluster Ingress |
| Persistence | named docker volumes | PVCs |
| `appsettings.json` | mounted file | ConfigMap |
| Honeypot ports (5432, 6379, etc.) | published on host | host ports on `gzctf-control` |
| `gzcli sync` watcher | `compose.gzcli.yml` overlay | not in scope; run gzcli from a workstation or a sidecar CronJob if you need it |

## Sizing

The Deployments ship with conservative resource requests/limits
matching the docker-compose `deploy.resources` block. Bump
`spec.template.spec.containers[].resources` if your CTF has > 50
concurrent participants.

## Storage

PVCs default to the cluster's default `StorageClass`. On k3s that's
`local-path` (single-node, on-disk under `/var/lib/rancher/k3s/storage`).
For multi-node clusters set `spec.storageClassName` explicitly on
each PVC (e.g. `longhorn`, `ceph-rbd`, etc.).

## RBAC notes

`30-gzctf-config.yaml` grants gzctf's ServiceAccount namespaced access to
challenge `pods`, `services`, registry `secrets`, and `networkpolicies`, plus
read access to events. A small ClusterRole separately permits listing/creating
the challenge namespace and listing nodes; node addresses are used to block
challenge egress toward the control plane.

The platform never touches the `gzctf` namespace's own resources at
runtime — pod spawning is fully scoped to `gzctf-challenges`. If you
move the challenges namespace, also update the RBAC `namespace:`
field + the `KubernetesConfig.Namespace` setting in the ConfigMap.

## Two-node k3s placement

The manifests expect the platform node name to be `gzctf-control`. They pin
Traefik, GZCTF, postgres, redis, WireGuard, and SSH there and tolerate this
taint:

```sh
kubectl taint node gzctf-control CriticalAddonsOnly=true:NoSchedule
```

Challenge pods do not have that toleration, so they schedule on the worker.
Use `NoSchedule`, not `NoExecute`: the k3s local-path provisioner creates
short-lived helper pods directly on the selected node when preparing PVCs.
Verify this after launching a test challenge with `make k8s-status`.

`Ad.FlagPullBaseUrl` must contain the control VM's private IP, not its DNS
name. The GZCTF pod binds host port 8080 for this worker-to-control path.
Allow TCP 8080 only inside the GCP VPC; do not expose it publicly.

## A&D access

Push this repository once before deployment so GitHub Actions publishes
`gzctf-wireguard:main` and `gzctf-ssh-jump:main` to GHCR. Make both packages
public, or configure an imagePullSecret in `60-ad-access.yaml`.

Load WireGuard on the control VM before applying the access manifest:

```sh
sudo modprobe wireguard
test -c /dev/net/tun
```

WireGuard clients route the default k3s Service CIDR (`10.43.0.0/16`) through
the gateway. The gateway maintains a deny-by-default iptables allowlist from
Services carrying GZCTF's `gzctf.gzti.me/ResourceId` label; platform and
kube-system Services are not forwarded. If your cluster uses a different
Service CIDR, change `Ad.Vpn.AllowedIps` in `30-gzctf-config.yaml`.

Open UDP 51820 and TCP 22022 publicly on the control VM. Honeypot ports are
also bound there, but only add public GCP firewall rules for the listeners you
actually intend to expose.

For the two-node GCP layout, the required paths are:

| Source | Target | Ports |
|---|---|---|
| Internet | control VM | TCP 80, 443, 22022; UDP 51820 |
| worker VM/private subnet | control VM | TCP 6443, 8080, 10250; UDP 8472 |
| control VM/private subnet | worker VM | TCP 10250; UDP 8472 |

Add the honeypot TCP ports (`2222`, `3306`, `5432`, `6379`, `11211`,
`27017`, `9200`) to the public control-VM rule only when you want those
decoys reachable. Keep PostgreSQL and Redis as ClusterIP Services; do not add
public firewall rules for their Kubernetes Service addresses.

## Provider limitations

The Docker challenge-route watcher is intentionally absent. In Kubernetes,
`PlatformProxy` reaches each challenge ClusterIP through the main GZCTF HTTPS
and WebSocket endpoint, so there is no Docker socket or Traefik file to watch.
`PublicChallengeRouteConfig.BaseDomain` is therefore left empty; direct
wildcard challenge subdomains are a Docker-provider feature.

Kubernetes also does not provide Docker-style end-of-game image snapshots,
L2 bridge isolation, or the KotH leader-cooldown iptables hook. GZCTF records a
filesystem change list instead of an image snapshot. These are provider-level
limitations, not missing manifests.
