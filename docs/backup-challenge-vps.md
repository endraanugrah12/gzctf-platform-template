# Backup challenge services on a second VPS

## 1. What this setup does

Keep the existing GZCTF website, PostgreSQL, Redis, and primary challenges on **VPS 1**. Run independent backup challenge containers on **VPS 2**. When a primary challenge fails, privately give affected players the backup address. Players still submit flags and evidence to the original GZCTF website.

This is **manual challenge-service failover**, not a mirrored platform, automatic failover, or live replication. No Kubernetes or second GZCTF installation is required.

| Service | VPS 1 | VPS 2 |
| --- | --- | --- |
| Website, accounts, scores, evidence | Existing GZCTF | Not installed |
| Shared/static container | Primary service | Same image and accepted flag |
| Per-team dynamic container | Primary instance | Separate backup with that team's assigned flag |
| Flag submissions | Original website | Never submitted here |

If VPS 1 itself goes offline, backup challenges can remain reachable, but **the website and flag submission will be unavailable** until VPS 1 recovers. Existing TCP connections and application state do not transfer.

Scope: ordinary Jeopardy challenges. Attack & Defense, rotating flags, King of the Hill, and multi-service challenges need separate coordination; do not apply this simple recipe unchanged.

## 2. Before starting

These instructions assume a regular Linux VM on GCP, not GKE, and Bash on both machines.

Prepare:

- SSH access and administrator privileges on both VPSs.
- Docker Engine and Docker Compose on VPS 2.
- Enough RAM, CPU, disk, and port capacity for all backup instances you plan to keep running.
- A stable external IP on VPS 2, preferably reserved in GCP.
- The exact primary image version and challenge runtime requirements.
- A private operator record mapping game, challenge, team, backup port, and provisioning date. **Do not put flags in that record.**

Use a dedicated challenge VM. Do not place production credentials, unrelated services, or the platform database on it. Challenges intentionally handle hostile player input.

For an Ubuntu VM, install Docker using the [official Ubuntu instructions](https://docs.docker.com/engine/install/ubuntu/). Do not remove an existing Docker installation or other packages blindly. Verify:

```bash
sudo docker version
sudo docker compose version
```

The commands below use `sudo docker`; Docker access is effectively host-administrator access.

## 3. Plan ports and the GCP firewall

Example mapping—replace these numbers with your own:

| Backup | Internal listening port | VPS 2 public port | Player address |
| --- | --- | --- | --- |
| Shared web challenge | 5000 | 25009 | `http://VPS2_IP:25009` |
| Challenge 8, team 42 | 8011 | 24042 | `nc VPS2_IP 24042` |
| Challenge 8, team 43 | 8011 | 24043 | `nc VPS2_IP 24043` |

**5000 is not mandatory.** The internal port must match the application's actual listener. Different containers can all listen internally on 8011, but each needs a distinct published host port. A port alone does not identify a team across every challenge; keep an explicit allocation list.

In Google Cloud Console:

1. Find VPS 2 under **Compute Engine → VM instances**.
2. Add a network tag such as `ctf-challenge-backup` to that VM.
3. In the VM's VPC, create an ingress allow firewall rule targeting that tag.
4. Initially allow only your testing IP range, with the specific TCP ports you will publish.
5. When ready for players, allow their source ranges. For a public competition, `0.0.0.0/0` means anyone on IPv4 can reach those ports—use it only for intended public challenge endpoints.
6. Keep SSH restricted to operator access or your existing IAP setup. Do not expose Docker's daemon, PostgreSQL, or Redis.

Open UDP separately only if a challenge requires it. IPv6 needs its own deliberate configuration. See [GCP firewall instructions](https://docs.cloud.google.com/firewall/docs/using-firewalls).

Docker-published ports can bypass UFW filtering. Do not treat UFW alone as the boundary; use GCP's firewall and a reviewed Docker-compatible host policy. See [Docker firewall behavior](https://docs.docker.com/engine/network/packet-filtering-firewalls/).

GCP maps the external IP to the VM; do not bind a container to an external IP that is not assigned to a local interface. Publishing `24042:8011` uses the host's interfaces. See [Docker port publishing](https://docs.docker.com/engine/network/port-publishing/).

## 4. Identify the primary instance on VPS 1

Do this while the original instance still exists. Do not stop or recreate a player's instance just to prepare a backup.

This fork labels Docker challenge containers with `ChallengeId` and `TeamId`. List candidates without displaying flags:

```bash
sudo docker ps --filter label=ChallengeId \
  --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Ports}}'
```

Select one, then confirm its identity:

```bash
PRIMARY_CONTAINER='REPLACE_WITH_CONTAINER_ID'
sudo docker inspect --format \
  'challenge={{index .Config.Labels "ChallengeId"}} team={{index .Config.Labels "TeamId"}} image={{.Image}}' \
  "$PRIMARY_CONTAINER"
sudo docker port "$PRIMARY_CONTAINER"
```

Record the internal port, protocol, image, and team. Review the challenge source/configuration for custom commands, dependencies, volume mounts, environment variables, memory limits, and outbound-network requirements. The generic Compose template below does not reproduce these automatically.

Do not post an unfiltered `docker inspect` result: environment variables can contain flags and other secrets.

## 5. Transfer the exact image

If both servers can pull the image from a registry, use the **same immutable digest** on both, not a changing `latest` tag. Authenticate privately for private registries.

Otherwise, export the primary container's original image from VPS 1. This transfers image layers, **not** the running container's filesystem or volumes:

```bash
BACKUP_SSH='ubuntu@REPLACE_WITH_VPS2_IP'
IMAGE_ID=$(sudo docker inspect --format '{{.Image}}' "$PRIMARY_CONTAINER")

# Example tag for one challenge revision; choose your own unique revision.
sudo docker tag "$IMAGE_ID" ctf-backup/challenge8:revision1

```

Prepare a directory owned by your operator account on VPS 2:

```bash
# Run on VPS 2.
sudo install -d -m 700 -o "$(id -un)" -g "$(id -gn)" /srv/ctf-backups
```

Then, on VPS 1:

```bash
umask 077
sudo docker image save ctf-backup/challenge8:revision1 | gzip > challenge8-revision1.tar.gz
scp challenge8-revision1.tar.gz "$BACKUP_SSH":/srv/ctf-backups/
```

On VPS 2:

```bash
sudo docker image load -i /srv/ctf-backups/challenge8-revision1.tar.gz
sudo docker image inspect ctf-backup/challenge8:revision1 --format '{{.Id}}'
```

Compare that ID with `IMAGE_ID` from VPS 1. Both machines must support the image architecture. An image can contain a static flag or private challenge source; keep the archive private and remove temporary archives when no longer needed.

Do not use `docker commit` as a substitute for a reviewed state backup: it can capture player modifications and does not include mounted volume data.

## 6. Preserve the correct flag

### Shared/static container

Use the same accepted flag and original image. If the flag is baked into the image, no flag environment override may be needed. If the application expects an environment variable or a mounted flag file, reproduce that mechanism.

Do not assume every challenge has only one accepted flag or that the container's startup environment is the authoritative flag source. Check the challenge configuration.

### Per-team dynamic container

Create **one backup per team/challenge instance**, using the exact flag issued by GZCTF. Never generate a new flag independently, copy only the flag template, or reuse another team's flag.

For ordinary environment-injected instances, this fork sets `GZCTF_FLAG` and the compatibility alias `CTF_FLAG`, plus runtime metadata. On VPS 1, capture just these values into a private file without printing them:

```bash
umask 077
mkdir -p backup-secrets
sudo docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$PRIMARY_CONTAINER" \
  | awk '/^(GZCTF_FLAG|CTF_FLAG|GZCTF_TEAM_ID|GZCTF_USER_ID|GZCTF_CHALLENGE_ID|GZCTF_GAME_ID|CTF_HOST|CTF_PORT)=/' \
  > backup-secrets/c8-t42.env
chmod 600 backup-secrets/c8-t42.env

# Checks presence without displaying the flag. Stop if this fails.
grep -q '^GZCTF_FLAG=.' backup-secrets/c8-t42.env
```

This approach assumes ordinary single-line environment values. Custom/multiline secrets and file-mounted flags require a challenge-specific procedure. Review extra application variables separately rather than copying every secret from the host.

On VPS 2:

```bash
mkdir -p /srv/ctf-backups/c8-t42/secrets
chmod 700 /srv/ctf-backups/c8-t42 /srv/ctf-backups/c8-t42/secrets
```

On VPS 1:

```bash
scp backup-secrets/c8-t42.env "$BACKUP_SSH":/srv/ctf-backups/c8-t42/secrets/runtime.env
```

On VPS 2:

```bash
chmod 600 /srv/ctf-backups/c8-t42/secrets/runtime.env
```

Never commit these files, share them with players, or paste them into support chats. Docker administrators can still inspect container environment variables.

**Lifecycle warning:** a backup is valid only while its flag remains accepted for that team. Recheck after primary restarts, instance destruction/recreation, flag regeneration, challenge edits, or game resets. Do not assume a backup's independent restart policy renews its GZCTF instance lifetime. If the primary is already gone and you do not have its assigned flag, resolve the current assignment through authorized platform administration before launching a replacement; do not guess.

## 7. Create the backup container on VPS 2

Create `/srv/ctf-backups/c8-t42/compose.yml` with your editor:

```yaml
services:
  challenge:
    image: ctf-backup/challenge8:revision1
    pull_policy: never
    restart: unless-stopped
    ports:
      - "24042:8011/tcp"
    env_file:
      - path: ./secrets/runtime.env
        format: raw
    environment:
      CTF_HOST: "0.0.0.0"
      CTF_PORT: "8011"
    mem_limit: 256m
    cpus: 1.0
    pids_limit: 128
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks:
      - instance

networks:
  instance:
    driver: bridge
```

`env_file.format: raw` requires Docker Compose 2.30.0 or newer and preserves literal values such as `$` in flags. Upgrade an older Compose version rather than silently changing secret interpretation. See [Compose env_file documentation](https://docs.docker.com/reference/compose-file/services/#env_file).

Adjust ports, image, limits, and application configuration. `CTF_PORT` is only a convention: an application that ignores it must be configured through its actual startup settings. The service must listen on `0.0.0.0` inside the container, not just `127.0.0.1`. Dockerfile `EXPOSE` alone does not start a listener.

For a shared static backup, use a separate directory/project and its own image/port. Remove `env_file` if the image needs no injected configuration; otherwise provide the reviewed static configuration. For another team, create another directory with that team's environment file and a different public port. Never mount a writable volume shared between teams.

Start this instance:

```bash
cd /srv/ctf-backups/c8-t42
sudo docker compose -p backup-c8-t42 config --quiet
sudo docker compose -p backup-c8-t42 up -d
sudo docker compose -p backup-c8-t42 ps
sudo docker compose -p backup-c8-t42 logs --tail 50
```

Logs may contain challenge secrets; review them privately. Avoid `docker compose config` without `--quiet`, because rendered output can contain environment values.

The security settings are a starting point, not proof of isolation. Some images require specific capabilities or writable paths; validate requirements individually instead of enabling privileged mode. Never mount the Docker socket, use host networking, or pass platform credentials into challenge containers. Separate bridge networks reduce accidental cross-team sharing but do not replace reviewed host, egress, and cloud-network controls. Restrict access from challenge workloads to management services, unrelated private networks, and cloud metadata; do not attach a privileged GCP service account to this VM.

## 8. Test before giving players the address

Run from VPS 2 first, using the relevant protocol:

```bash
# TCP listener check only—not a full application test.
nc -vz 127.0.0.1 24042

# For a web backup, use its actual published port and expected path.
curl --max-time 5 -i http://127.0.0.1:25009/
```

Then repeat from your laptop or another external network:

```bash
nc -vz REPLACE_WITH_VPS2_IP 24042
curl --max-time 5 -i http://REPLACE_WITH_VPS2_IP:25009/
```

For TCP, interact with the expected greeting/menu using `nc REPLACE_WITH_VPS2_IP 24042`. A successful connect alone does not prove the application works. For HTTP, confirm expected content and functionality, not merely that a port opens.

Validate flag acceptance using a designated test team/challenge before the event. Do not submit an organizer test solve on behalf of a competing team. Confirm privately that the backup's assigned flag matches the platform's accepted flag without disclosing it to players.

Direct web access here is **HTTP**, not HTTPS. For HTTPS, configure a backup DNS name, valid certificate, and reverse proxy separately. Existing wildcard routing on VPS 1 does not automatically cover VPS 2. Applications requiring secure cookies, OAuth callback URLs, or a configured public URL may need additional changes; do not send sensitive credentials over plain HTTP.

## 9. Manual failover procedure

1. Identify the failed challenge and affected team(s).
2. Verify the corresponding backup application responds externally.
3. Confirm the current flag assignment and backup configuration still match.
4. For a shared service, publish its backup URL/command in the challenge description or announcement.
5. For dynamic services, send each team only its own backup endpoint through your private support channel. Do not publish a global list of team endpoints.
6. Tell players to submit on the original GZCTF site, with the same solver/LLM evidence requirements.
7. Record which backup is active and when you handed it out. Avoid switching a team back mid-session without coordination.

Example team-specific message:

```text
Challenge 8 backup for Team 42:
nc BACKUP_IP 24042

Continue submitting flags and required evidence on the original CTF website.
Your previous connection/state is not transferred. Please contact organizers
before destroying or recreating your original instance while using this backup.
```

The current GZCTF UI will still show the primary connection. These manual containers are not registered in its instance inventory: platform readiness polling, extension timers, cleanup, and stop buttons **do not manage them**. Do not change the global PublicEntry just to redirect one team; it does not transfer an instance or establish flag synchronization.

Backup endpoints are not inherently authenticated: a unique port is not access control. Match the challenge's intended exposure and account for players discovering other ports.

## 10. State, maintenance, and cleanup

- Keep backups warm before an incident if you need immediate availability. Creating one for every team consumes roughly another full set of challenge resources; alternatively pre-stage images and provision selected backups manually when needed.
- This procedure copies image and reviewed startup configuration only. Application databases, uploaded files, and writable container state remain independent. Stateful services need application-consistent backup/restore with isolated per-team volumes; do not copy a live database directory blindly.
- Update backup images and assigned flags when relevant primary configuration changes. Test each revised image before switching players.
- Budget disk and monitor `sudo docker stats --no-stream` and `sudo docker system df`. Resource limits in the example do not impose a writable-layer disk quota.
- After the event or a team's retirement, stop its backup deliberately:

```bash
cd /srv/ctf-backups/c8-t42
sudo docker compose -p backup-c8-t42 down
```

Remove unneeded secret files according to your retention policy and remove unused public firewall rules. Do not run a broad Docker prune on a shared server as part of this procedure. Keep image archives only as long as needed, protected as potentially sensitive data.

## 11. Troubleshooting

| Symptom | Check |
| --- | --- |
| Local connection fails | Container logs, application bind address, actual internal port, startup time, resource limits |
| Local works; public times out | GCP rule target tag, VPC, source range, protocol/port, host firewall, external IP |
| Connection refused | No published listener, stopped container, wrong destination port |
| HTTP 404 | Wrong path, host-header requirement, wrong service, or reverse-proxy route; test the application directly |
| Container repeatedly restarts | Missing environment/file/dependency, incompatible hardening, insufficient memory |
| Flag rejected | Wrong team, stale assignment, template copied instead of issued flag, extra application override, wrong challenge |
| GZCTF Stop does nothing to backup | Expected: this is a manually managed container on VPS 2 |
| VPS 1 entirely offline | Backup service can run, but this design does not restore the GZCTF website or submissions |

## 12. Go-live checklist

- [ ] VPS 2 has Docker and a supported Compose version.
- [ ] Stable address and narrowly scoped GCP firewall rules are configured.
- [ ] Backup images match reviewed primary revisions.
- [ ] Internal listeners and host-port allocation are verified.
- [ ] Each dynamic backup has the correct current team flag.
- [ ] Secrets remain outside Git and operator messages.
- [ ] Isolation, egress, metadata access, and resource limits are reviewed.
- [ ] External application checks pass; staging flag acceptance is verified.
- [ ] Players know the original website remains the submission endpoint.
- [ ] Operators understand manual lifecycle, state loss, and cleanup responsibilities.

No provisioning, firewall changes, secret export, or remote deployment is performed by adding this guide. Execute the steps deliberately on the indicated VPS after replacing placeholders.
