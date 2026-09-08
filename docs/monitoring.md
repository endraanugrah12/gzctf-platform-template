# Performance and resource monitoring

The optional `monitoring/` Compose project monitors one Linux Docker host. It runs independently of the platform: enabling or stopping it does not restart GZCTF, its database, or challenge containers. It also works on the backup challenge VPS without installing GZCTF there.

## Included

| Component | Purpose | Local address |
| --- | --- | --- |
| Prometheus | Scrapes metrics every 30 seconds and evaluates resource alerts | `127.0.0.1:19090` |
| Grafana | Provisioned **GZCTF → GZCTF — Host and Containers** dashboard | `127.0.0.1:13000` |
| Node Exporter | Host CPU, RAM, load, disk, and network metrics | `127.0.0.1:19100` |
| cAdvisor | Docker container CPU, working-set RAM, limits, and network usage | `127.0.0.1:18080` |

The dashboard covers platform services and dynamically created Docker challenges discovered by cAdvisor. Short-lived containers may disappear between scrapes. Network panels report throughput, not a billing-grade monthly transfer total. Shared host-network containers can report the same host interface traffic; do not sum their network usage as independent totals.

Grafana opens the system dashboard as its default home page. Its 20 panels include summary cards for uptime, recently observed Docker containers, available RAM/root disk, swap usage, and firing-alert count, plus CPU/memory/network/disk-I/O charts. The firing-alert count displays zero when no alert is firing; the alert-detail chart can legitimately have no data. Recently observed containers are not an application-health count.

Direct dashboard link through your SSH tunnel: `http://localhost:13000/d/gzctf-system`. If a saved personal/organization home preference overrides the default, use that link or change the home dashboard in Grafana preferences. After updating Compose, apply the new default with `docker compose --project-directory monitoring -f monitoring/compose.yml up -d grafana`; a simple container restart does not apply changed environment variables.

Included Prometheus alerts cover unreachable scrape targets, sustained high host CPU, low available RAM, low disk space, and containers near configured memory limits. View them on Prometheus's **Alerts** page. **No email/Discord/Telegram delivery is configured.** Alertmanager or Grafana contact points/rules need a separate configuration before notifications are sent.

This is infrastructure monitoring, not application tracing, log aggregation, database-query statistics, player analytics, or challenge-response validation. A healthy exporter does not prove GZCTF or a challenge is responding correctly. There is no automatic container restart/failover action or per-container disappearance alert. Use an external uptime checker for whole-VPS failure: monitoring on the failed host cannot report its own outage.

## Install

Requires native Linux, rootful Docker Engine, a recent Docker Compose plugin, Make, and OpenSSL. Rootless Docker, Docker Desktop, nondefault Docker data directories, and nested VPS environments may need different exporter mounts; review before deploying. These files do not install Kubernetes monitoring.

From the template repository:

```bash
make monitoring-init
make monitoring-check
make monitoring-up
make monitoring-status
```

Use `make SUDO=sudo monitoring-up` if your operator cannot run Docker directly. Initialization generates a random Grafana password in ignored `monitoring/.env` with mode 600; rerunning it preserves existing credentials. Open that file privately with your editor. Never commit it or paste it into support messages. Grafana username: `admin`.

Before startup, check `sudo docker info --format '{{.DockerRootDir}}'`. If it is not `/var/lib/docker`, add `DOCKER_DATA_ROOT=/your/actual/path` to `monitoring/.env`. For example, Snap Docker commonly uses `/var/snap/docker/common/var-lib-docker`. The directory is mounted at its original path so cAdvisor can follow Docker's reported locations. Do not create an empty `/var/lib/docker` as a substitute.

Docker's containerd image store additionally requires access to its containerd socket. The default is `/run/containerd/containerd.sock`; if Docker uses a different socket, set `CONTAINERD_SOCKET=/actual/host/socket` in `monitoring/.env`. Common alternatives are `/var/run/docker/containerd/containerd.sock` and, for Snap Docker, `/run/snap.docker/containerd/containerd.sock`. Verify the actual socket with your Docker installation configuration. cAdvisor accesses it through the existing read-only host-root mount and uses Docker's `moby` namespace. A green exporter target with no named container metrics can indicate this socket is wrong.

Snap Docker can also present its own filesystem namespace as `/`, causing incorrect root-disk capacity metrics. On affected installations set `HOST_ROOT=/var/lib/snapd/hostfs` for Node Exporter (the host root visible to the Snap daemon). Validate reported root filesystem capacity against `df -B1 /`; a healthy scrape alone does not detect this mismatch. Ordinary Docker Engine installations should retain the default `HOST_ROOT=/`. cAdvisor retains its runtime root view to access `/proc`; host filesystem dashboards intentionally use Node Exporter instead.

`monitoring-check` validates Compose, the Prometheus configuration/rules, and rule regression tests. It may pull the pinned Prometheus image. `monitoring-up` performs those checks first, then starts only this monitoring project.

Ports are intentionally fixed across Compose, Prometheus, and Grafana provisioning. If any are already occupied, change all corresponding references before starting. Do not change the bind addresses to `0.0.0.0` just to access a dashboard.

## Access through SSH

Run on your laptop, replacing the SSH login/host:

```bash
ssh -N \
  -L 13000:127.0.0.1:13000 \
  -L 19090:127.0.0.1:19090 \
  ubuntu@YOUR_VPS_IP
```

Keep the SSH session open. Visit `http://localhost:13000`, log in, then open **Dashboards → GZCTF**. Prometheus is at `http://localhost:19090`; check **Status → Target health** (or `/targets`) for three healthy targets. Allow two or three scrapes for metrics; rate panels need multiple samples.

No new public firewall rule or wildcard DNS record is needed. Loopback is deliberate because metrics can reveal challenge names, team identifiers, host details, and service topology. A public reverse proxy would require a separate reviewed TLS/authentication configuration; do not route unauthenticated Prometheus or exporters through Traefik.

Grafana's initial password is applied only when its database is initialized. After changing it through Grafana, editing `.env` does not reset the existing account. Use Grafana's documented administrator password-reset procedure if needed; do not delete the data volume to reset a password.

## Host visibility and security

Host networking lets Node Exporter observe host network interfaces and lets Prometheus scrape private loopback listeners. Node Exporter also uses the host PID namespace and a read-only root mount. cAdvisor uses host cgroups, a read-only host root/data mount, and the Docker socket to discover containers. It is not configured as privileged by default.

The root mount uses private propagation for compatibility with hosts whose root is not a shared/slave mount. Restart Node Exporter after mounting additional host filesystems if they are missing from its metrics.

These are **trusted operator services with sensitive host access**. A read-only Docker socket mount does not turn the Docker API into a read-only API. A compromised exporter could have serious host impact. Do not share exporter access with players or mount these resources in challenge containers. Some host configurations require adjusted cAdvisor permissions; diagnose missing metrics instead of immediately enabling privileged mode.

Container label collection is restricted to Compose service, challenge ID, and team ID metadata. Environment-variable metrics are not enabled. Nonetheless, challenge names and host metadata remain visible to monitoring administrators. Grafana is not connected to GZCTF authentication: manage its users separately.

References: [Node Exporter container setup](https://github.com/prometheus/node_exporter#docker), [cAdvisor host requirements](https://github.com/google/cadvisor/blob/master/docs/running.md), and [Grafana Docker configuration](https://grafana.com/docs/grafana/latest/setup-grafana/installation/docker/).

## Resource limits and retention

The four containers have memory ceilings of 512 MiB (Prometheus), 256 MiB (Grafana), 128 MiB (Node Exporter), and 256 MiB (cAdvisor). Actual usage varies, and many challenge containers increase exporter and time-series load. Budget approximately another 1 GiB of headroom initially and measure; do not assume these limits fit a small VPS already near capacity.

Prometheus retains up to seven days of samples, subject to a 1 GB block-retention threshold. **This is not a hard volume quota**: the write-ahead log, active head, and temporary compaction data need extra disk. Reserve several GB, particularly during image pulls. Logs rotate at 10 MB with three files per service. Grafana dashboards/accounts and Prometheus data use separate named volumes.

Tune retention flags in `monitoring/compose.yml` and scrape intervals in `monitoring/prometheus/prometheus.yml` as necessary. Prometheus does not have a public configuration reload endpoint enabled: validate and restart just it after editing configuration:

```bash
make monitoring-check
docker compose --project-directory monitoring -f monitoring/compose.yml restart prometheus
```

The dashboard and datasource are provisioned from Git. Duplicate the dashboard in Grafana if you want a personal editable copy, or edit the tracked JSON. Never store credentials in a dashboard file.

## Backup VPS

Clone this template onto VPS 2 and run the same monitoring targets there. There is no need to clone the companion GZCTF source, run the platform wizard, or start the platform for monitoring alone.

Use a second SSH tunnel with different laptop ports:

```bash
ssh -N \
  -L 13001:127.0.0.1:13000 \
  -L 19091:127.0.0.1:19090 \
  ubuntu@BACKUP_VPS_IP
```

VPS 2's Grafana is then at `http://localhost:13001`. The two installations are independent: this does not aggregate both hosts in one dashboard or synchronize challenge instances. Central monitoring needs private connectivity and additional scrape/datasource configuration; do not expose exporters publicly as a shortcut.

## Operations and verification

```bash
make monitoring-status
make monitoring-logs
curl --fail http://127.0.0.1:19090/-/ready
curl --fail http://127.0.0.1:13000/api/health
curl --fail http://127.0.0.1:19090/api/v1/targets
```

Check that host memory matches `free`, CPU count matches the VPS, and cAdvisor exposes named container series. `up == 1` alone is not sufficient to prove Docker discovery is working. If the dashboard lacks containers, inspect cAdvisor logs, cgroup compatibility, Docker API compatibility, and `/var/lib/docker` location. High container counts may require increasing the scrape sample limit or exporter memory limit. Check for OOM/restarts before increasing limits on an already constrained host.

Stopping keeps historical data and accounts:

```bash
make monitoring-down
```

`make platform-down` does not stop monitoring; `make monitoring-down` does not stop the platform. Do not add `--volumes` unless you intend to delete monitoring history/accounts. Stop Grafana before taking a filesystem backup of its SQLite data, and use an appropriate consistent backup approach for the metric store.

Image versions are pinned in Compose. Review upstream release/security notes before deliberately updating them, then pull and recreate this project. Existing platform update targets do not upgrade monitoring images.

Local regression tests:

```bash
python3 -m unittest discover -s tests -p 'test_monitoring.py' -v
make monitoring-check
```
