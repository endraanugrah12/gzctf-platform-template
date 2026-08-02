# GZCTF on Kubernetes / K3s

This directory deploys the customized GZCTF platform to Kubernetes. The
recommended small-event layout is one K3s server for the platform and one K3s
agent for challenge workloads:

```text
Internet
  |
  | TCP 80/443
  v
gzctf-control
  - K3s server and Traefik
  - GZCTF, PostgreSQL, Redis
  - persistent platform files
  - BuildKit challenge-image builder
  - HTTP challenge-route watcher
  |
  | private VPC
  v
gzctf-worker
  - K3s agent
  - player challenge pods
```

HTTP challenge instances receive a per-team HTTPS hostname under a wildcard
DNS suffix. The route watcher probes each challenge Service and creates a
Traefik Ingress only when the backend speaks HTTP. Raw TCP challenges retain a
Kubernetes NodePort instead of using GZCTF's WebSocket proxy.

This is a two-node deployment, not a highly available deployment. Losing the
control VM makes the platform and its local persistent volumes unavailable.

## Requirements

- Two Linux VMs in the same private network. Ubuntu 24.04 is tested.
- A static public IPv4 address on the control VM.
- A platform hostname such as `ctf.example.com` and a wildcard challenge record
  such as `*.chall.ctf.example.com`, both pointing to that address.
- A Cloudflare API token scoped to the DNS zone with `Zone:DNS:Edit` and
  `Zone:Zone:Read`. Traefik uses it only for ACME DNS-01 records.
- Outbound internet access from both VMs for images and package downloads.
- `git`, `make`, `curl`, and `openssl` on the control VM.
- At least 4 vCPU / 8 GiB RAM on the control VM. BuildKit can use up to an
  additional 2 vCPU / 3 GiB while building challenges.
- Worker capacity appropriate for the event. 8 vCPU / 16 GiB RAM is a useful
  starting point, but challenge resource limits determine the real capacity.

The control VM needs enough disk for PostgreSQL, uploaded files, K3s images,
and the BuildKit cache. Start with at least 80 GiB; use more for large events.

## Network rules

For a GCP VPC, allow only the paths below. Restrict private rules to the cluster
subnet or, preferably, the two node network tags.

| Source | Target | Ports | Purpose |
|---|---|---|---|
| Internet | control VM | TCP 80, 443 | Platform and HTTP challenge routes |
| Private subnet | control VM | TCP 6443 | Kubernetes API / agent join |
| Private subnet | both nodes | TCP 10250 | Kubelet communication |
| Private subnet | both nodes | UDP 8472 | Flannel VXLAN |
| worker VM | control VM | TCP 8080 | A&D flag-pull endpoint |
| IAP or trusted admin ranges | both nodes | TCP 22 | SSH administration |

Optional A&D access also needs UDP 51820 and TCP 22022 from the Internet to the
control VM. Only expose the honeypot ports listed later if the event actually
uses them. Never expose PostgreSQL, Redis, TCP 6443, TCP 8080, TCP 10250, or UDP
8472 publicly.

Raw TCP instances use NodePorts in TCP `30000-32767`. Leave that range closed
unless an event actually has raw TCP challenges. If it is needed, expose it on
the control VM only and restrict source ranges where practical. Kubernetes
forwards those NodePorts to challenge pods on the worker.

## 1. Install K3s

Install the K3s server on the control VM. Leave it untainted during initial K3s
startup so the bundled Traefik installation and its local-path volume are
created on the control node while it is the only node in the cluster. The
control taint is added immediately before the GZCTF manifests are applied.

```bash
CONTROL_PRIVATE_IP=$(hostname -I | awk '{print $1}')

curl -sfL https://get.k3s.io | sudo sh -s - server \
  --node-name gzctf-control \
  --node-ip "$CONTROL_PRIVATE_IP" \
  --secrets-encryption
```

Wait for the bundled ingress controller before joining the worker:

```bash
until sudo k3s kubectl -n kube-system get deployment traefik \
  >/dev/null 2>&1; do
  sleep 5
done

sudo k3s kubectl -n kube-system rollout status \
  deployment/traefik --timeout=300s
```

Read the private IP and agent join token:

```bash
echo "$CONTROL_PRIVATE_IP"
sudo cat /var/lib/rancher/k3s/server/node-token
```

Treat the token as a cluster administrator credential and back it up securely.

On the worker VM, replace both placeholders and join the cluster:

```bash
export CONTROL_PRIVATE_IP='10.20.0.2'
export K3S_TOKEN='paste-the-control-node-token'

curl -sfL https://get.k3s.io | sudo env \
  K3S_URL="https://${CONTROL_PRIVATE_IP}:6443" \
  K3S_TOKEN="$K3S_TOKEN" \
  sh -s - agent \
  --node-name gzctf-worker
```

Back on the control VM, verify both nodes:

```bash
sudo k3s kubectl get nodes -o wide
```

Both must be `Ready`. The optional label below is useful for operators, but
placement does not depend on it; the control-node taint enforces separation.

```bash
sudo k3s kubectl label node gzctf-worker ctf-role=challenge --overwrite
```

## 2. Configure DNS

Create these `A` records pointing to the control VM's static public IPv4:

```text
ctf.example.com
*.chall.ctf.example.com
```

Do not create an `AAAA` record unless the VM and firewall are actually
configured for public IPv6.

Start with both records set to **DNS only**. After Traefik has obtained the
platform and wildcard certificates and direct HTTPS works, the Cloudflare proxy
can be enabled with SSL/TLS mode set to **Full (strict)**.

The included resolver uses DNS-01, so certificate issuance does not depend on
port 80. Keep port 80 open if HTTP-to-HTTPS redirects are enabled.

## 3. Generate the deployment

Run this on the control VM:

```bash
sudo apt update
sudo apt install -y git make curl openssl

git clone https://github.com/endraanugrah12/gzctf-platform-template.git
cd gzctf-platform-template
```

The deployment includes WireGuard and SSH helpers for A&D challenges. Prepare
the host before applying the manifests:

```bash
sudo modprobe wireguard
test -c /dev/net/tun
```

Run the interactive wizard:

```bash
make wizard
```

Choose `k8s` and provide:

- the public hostname without `https://`;
- the challenge wildcard suffix without `*.` (for example,
  `chall.ctf.example.com`);
- a Cloudflare DNS API token with `Zone:DNS:Edit` and `Zone:Zone:Read`;
- a Let's Encrypt email address;
- the control VM's private IPv4 address;
- the Kubernetes control node name, normally `gzctf-control`;
- the K3s Service CIDR, normally `10.43.0.0/16`.

The wizard generates secrets and rendered manifests in `k8s/generated/`. The
directory is mode `0700`, its files are mode `0600`, and it is gitignored. Store
the printed administrator password immediately.

Back up `k8s/generated/` securely. In particular, do not rotate the generated
XOR key after credentials have been saved in GZCTF. Registry passwords stored
with the old key will become unreadable.

## 4. Deploy

Taint the control node now that Traefik is initialized. The `NoSchedule` taint
keeps ordinary challenge pods on the worker, while every platform Deployment
has the matching toleration and an explicit control-node selector:

```bash
sudo k3s kubectl taint node gzctf-control \
  CriticalAddonsOnly=true:NoSchedule --overwrite

make KUBECTL='sudo k3s kubectl' k8s-apply

sudo k3s kubectl -n gzctf rollout status \
  deployment/gzctf --timeout=600s
```

Do not use `NoExecute`. The K3s local-path provisioner creates short-lived
helper pods on the node selected for a PVC.

Check placement and storage:

```bash
sudo k3s kubectl -n gzctf get pods,pvc -o wide
sudo k3s kubectl -n gzctf-challenges get pods -o wide
sudo k3s kubectl get ingress -A
```

PostgreSQL, Redis, GZCTF, Traefik, the challenge-proxy watcher, WireGuard, and
SSH jump should run on the control node. Player challenge pods should run on
the worker after a challenge is launched.

Retrieve the initial administrator password if it was not recorded:

```bash
sudo k3s kubectl -n gzctf get secret gzctf-secrets \
  -o jsonpath='{.data.admin-password}' | base64 -d
echo
```

Open the configured HTTPS hostname, log in as `Admin`, and change the password.

### Test without public DNS

Use a Kubernetes port-forward when DNS or TLS is not ready:

```bash
sudo k3s kubectl -n gzctf port-forward service/gzctf 8080:80
```

In another terminal:

```bash
curl -I http://127.0.0.1:8080
```

This tests GZCTF directly and bypasses Traefik, Let's Encrypt, Cloudflare, and
the GCP public firewall.

### Verify challenge routing

This fork forces `ContainerProvider.PortMappingType=Default` whenever the
active provider is Kubernetes. The runtime override is applied after the
database configuration provider, so a migrated
`ContainerProvider:PortMappingType=PlatformProxy` row cannot silently restore
WebSocket proxy mode. If `PublicChallengeRouteConfig.BaseDomain` is empty, it
defaults to `chall.<ContainerProvider.PublicEntry>`.

Verify the effective client configuration before launching an instance:

```bash
curl -fsS https://ctf.example.com/api/config | jq \
  '{portMapping, challengeBaseDomain}'
```

The result must report `Default` and the expected challenge base domain. An
instance created before this takes effect retains its old UUID proxy entry and
ClusterIP Service; destroy and recreate it after upgrading.

Launch an HTTP challenge, then check its Service and generated Ingress:

```bash
sudo k3s kubectl -n gzctf-challenges get service,ingress
sudo k3s kubectl -n gzctf logs deployment/challenge-proxy --tail=100
```

Challenges in the **Web** category display and copy the generated
`https://<instance-host>/` route on the normal HTTPS port, 443. Different Web
instances are separated by hostname, not by public port. Keep browser-based
challenges in that category so the client can present the correct route.

Pwn and every other category retain `host:NodePort` for raw TCP clients and do
not show the browser-open action. Arbitrary TCP protocols cannot be transported
through an HTTP Ingress. HTTP detection and Ingress creation can take up to
about 10 seconds after the challenge begins responding.

The watcher image is published by this repository's helper-image workflow:

```text
ghcr.io/endraanugrah12/gzctf-k8s-challenge-proxy:main
```

Make this GHCR package public before deployment, or add an image-pull secret to
the `challenge-proxy` Deployment.

## 5. Configure Kubernetes challenge builds

Repository-bound challenge builds run through the pod-local BuildKit sidecar
and must push their images to a registry that the worker can pull from.

Open:

```text
https://YOUR_HOST/admin/settings
```

Select **Build push**, enable **Push built images to a registry**, and use the
following values for a personal GitHub account:

```text
Server:        ghcr.io
Namespace:     your-lowercase-github-user-or-organization
Username:      your-github-username
Password/PAT:  a classic GitHub PAT with write:packages
```

Do not enter the GitHub account password. GZCTF creates and refreshes the
matching image-pull secret in `gzctf-challenges` after a successful build and
again when the platform starts. The separate **Registry pull** setting is only
needed for other private challenge images not built by this pipeline.

The BuildKit daemon is a privileged container because Ubuntu 24.04 blocks the
rootless daemon's user namespace by default. Its API is exposed only through a
shared pod-local Unix socket, but repository Dockerfiles still execute on
cluster infrastructure. Bind only administrator-controlled repositories.

Verify BuildKit:

```bash
sudo k3s kubectl -n gzctf logs deployment/gzctf \
  -c buildkitd --tail=100
```

## 6. Configure repository binding

Open:

```text
https://YOUR_HOST/admin/repo-bindings
```

For a private GitHub repository, use a fine-grained token restricted to that
repository with read-only **Contents** permission. Enter the repository URL,
branch (normally `main`), scan interval, and token, then run the first scan.

The scanner discovers every `.gzevent` and imports challenge packages beneath
that event. A package containing the following property is retained in Git but
is not created or updated by repository scans:

```yaml
ignore: true
```

Important repository behavior:

- A binding fetches the whole Git repository; it is not a sparse checkout.
- Removing a challenge directory prevents future imports but does not delete
  the existing GZCTF challenge row. Delete that row once in the admin UI.
- `ignore: true` is useful when a template should remain in Git without being
  synchronized.
- Directories whose names begin with `.`, including `.example`, are ignored.
- A forced **Scan now** reimports challenges even when the commit SHA is
  unchanged and can enqueue fresh builds.

## Routine operations

### Upgrade an existing generated deployment

`k8s/generated/` is a rendered snapshot, so `git pull` does not add this route
controller to an existing installation automatically. Preserve the generated
database password, XOR key, and A&D secret. Do not rerun the wizard with new
secrets against the existing database.

After pulling this revision:

1. Back up `k8s/generated/`.
2. Copy the new `05-traefik-config.yaml`, `50-ingress.yaml`, and
   `55-challenge-proxy.yaml` templates into `k8s/generated/`.
3. Replace their placeholders with the existing ACME email, control node name,
   platform hostname, challenge base domain, and Cloudflare token.
4. In the existing generated `30-gzctf-config.yaml`, change
   `PortMappingType` to `Default` and set `PublicChallengeRouteConfig.BaseDomain`.
5. Run the normal apply and restart GZCTF so the moving image tag is refreshed.

```bash
make KUBECTL='sudo k3s kubectl' k8s-apply
sudo k3s kubectl -n gzctf rollout restart deployment/gzctf
sudo k3s kubectl -n gzctf rollout status deployment/gzctf --timeout=600s
```

Destroy and recreate any challenge instances that existed before the upgrade;
their Services do not carry the new routing metadata.

### Status and logs

```bash
make KUBECTL='sudo k3s kubectl' k8s-status
make KUBECTL='sudo k3s kubectl' k8s-logs

sudo k3s kubectl -n gzctf logs deployment/gzctf -c gzctf --since=15m
sudo k3s kubectl -n gzctf logs deployment/gzctf -c buildkitd --since=15m
sudo k3s kubectl -n gzctf logs deployment/challenge-proxy --since=15m
sudo k3s kubectl -n kube-system logs deployment/traefik --since=15m
```

### Deploy a newly published GZCTF image

The custom image uses a moving branch tag. Pull repository changes, reapply the
BuildKit patch, and explicitly restart the Deployment so
`imagePullPolicy: Always` resolves the new digest:

```bash
cd ~/gzctf-platform-template
git pull --ff-only

make KUBECTL='sudo k3s kubectl' k8s-buildkit
sudo k3s kubectl -n gzctf rollout restart deployment/gzctf
sudo k3s kubectl -n gzctf rollout status deployment/gzctf --timeout=600s
```

`k8s/generated/` is a rendered snapshot. A later `git pull` does not merge new
base-manifest changes into it. Review template changes before manually carrying
them into the generated files; do not delete and regenerate that directory
without preserving the production secrets.

### Flush Redis

```bash
sudo k3s kubectl -n gzctf exec deployment/redis -- redis-cli FLUSHALL
```

Use this only when troubleshooting stale cache data. PostgreSQL remains the
source of truth.

## Storage and backups

K3s includes Rancher's `local-path` provisioner. Its volumes are node-local,
normally under `/var/lib/rancher/k3s/storage`. The manifests pin all persistent
platform workloads to the control node so local storage is usable in a
two-node cluster.

This does not provide failover. At minimum, back up:

- `k8s/generated/` and the K3s server token;
- PostgreSQL with regular `pg_dump` jobs;
- the `gzctf-files` and `wg-config` PVC contents;
- the control VM with scheduled GCP disk snapshots.

Example PostgreSQL dump:

```bash
sudo k3s kubectl -n gzctf exec deployment/postgres -- \
  pg_dump -U postgres -d gzctf -Fc > gzctf-$(date +%F).dump
```

For real node-level availability, replace `local-path` with a storage system
designed for multi-node use, such as Longhorn or a managed CSI driver, before
creating the PVCs.

### Check PVC node affinity

If a platform pod remains `Pending`, confirm that its local PV belongs to the
control node:

```bash
sudo k3s kubectl get pv \
  -o custom-columns='CLAIM:.spec.claimRef.name,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]'
```

`postgres-data`, `gzctf-files`, and `wg-config` must show the control node. Do
not delete a bound PVC that contains production data. Migrate or restore its
data first. On an empty first-time installation, incorrect PVCs can be deleted
and recreated after fixing node placement.

## TLS and Cloudflare troubleshooting

A Cloudflare `522` means Cloudflare could not reach the origin; waiting for DNS
propagation does not fix an origin firewall, stale `AAAA` record, or incorrect
IP address.

Check the origin:

```bash
sudo k3s kubectl -n kube-system get pods,service -o wide | grep traefik
sudo k3s kubectl -n kube-system logs deployment/traefik --tail=100
sudo k3s kubectl -n gzctf get ingress
```

Confirm the GCP rule permits public TCP 80/443 to the control VM and that both
the platform and wildcard DNS `A` records contain its static public IP. Check
that the Cloudflare token has `Zone:DNS:Edit` and `Zone:Zone:Read`. Keep the
records DNS-only until the Traefik log shows successful platform and wildcard
certificate issuance.

## Optional A&D access

The helper images are published by this repository's GitHub Actions workflow:

```text
ghcr.io/endraanugrah12/gzctf-wireguard:main
ghcr.io/endraanugrah12/gzctf-ssh-jump:main
```

They must be public or otherwise available through an image-pull secret.
WireGuard clients route the configured K3s Service CIDR through the gateway.
The gateway allows only challenge Services carrying GZCTF's resource label;
platform and `kube-system` Services are not forwarded.

The public optional listeners are:

| Port | Purpose |
|---|---|
| UDP 51820 | WireGuard |
| TCP 22022 | SSH jump access |
| TCP 2222, 3306, 5432, 6379, 11211, 27017, 9200 | Optional honeypots |

If A&D access is not needed, scale the helpers down after deployment and leave
their public firewall ports closed:

```bash
sudo k3s kubectl -n gzctf scale \
  deployment/wireguard deployment/ssh-jump --replicas=0
```

## Manifest reference

| File | Purpose |
|---|---|
| `00-namespace.yaml` | Platform and challenge namespaces |
| `05-traefik-config.yaml` | ACME resolver and control-node placement |
| `10-postgres.yaml` | PostgreSQL PVC, Deployment, and Service |
| `20-redis.yaml` | Redis Deployment and Service |
| `30-gzctf-config.yaml` | Application config, secrets, and RBAC |
| `35-ad-network-policy.yaml` | A&D pod, checker, and WireGuard network policy |
| `40-gzctf.yaml` | GZCTF PVCs, Deployment, and Service |
| `45-buildkit-sidecar-patch.yaml` | Pod-local BuildKit builder patch |
| `50-ingress.yaml` | Public Traefik Ingress |
| `55-challenge-proxy.yaml` | HTTP challenge route watcher and scoped RBAC |
| `60-ad-access.yaml` | WireGuard and SSH jump helpers |

The Makefile applies these in dependency order. `45-buildkit-sidecar-patch.yaml`
is a strategic merge patch and is applied after the generated GZCTF Deployment.

## Kubernetes provider limitations

- Persistent storage is local to the control node unless a different
  `StorageClass` is configured.
- This layout has one K3s server, one PostgreSQL replica, and one GZCTF replica;
  it is not highly available.
- Kubernetes does not provide Docker-style end-of-game image snapshots, L2
  bridge isolation, or the Docker KotH leader-cooldown iptables hook. GZCTF
  records a filesystem change list instead of an image snapshot.
- Automatic friendly routes apply only to HTTP backends. Raw TCP challenges use
  NodePorts and require a deliberate firewall rule for TCP `30000-32767`, or a
  separate TCP access design such as the event VPN.
- The route watcher polls every 10 seconds, so a new HTTP instance is not
  reachable immediately after its pod starts.
- BuildKit uses privileged mode and must only build trusted repository content.

K3s installation and agent-token behavior are documented in the
[K3s quick-start guide](https://docs.k3s.io/quick-start). K3s local volume
behavior is documented under [Volumes and Storage](https://docs.k3s.io/add-ons/storage).
See Traefik's [ACME resolver documentation](https://doc.traefik.io/traefik/reference/install-configuration/tls/certificate-resolvers/acme/)
for wildcard DNS-01 behavior and lego's [Cloudflare provider documentation](https://go-acme.github.io/lego/dns/cloudflare/)
for the required API-token permissions.
