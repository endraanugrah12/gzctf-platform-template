#!/bin/bash
# WireGuard sidecar entrypoint.
#
# Responsibilities:
#   1. On first boot: generate the server keypair into /config so GZCTF can
#      read the pubkey and embed it in client .conf files.
#   2. Wait for GZCTF to write the initial /config/wg0.conf with the server
#      [Interface] block + zero or more [Peer] blocks.
#   3. Bring up the wg0 interface.
#   4. Watch wg0.conf for changes (GZCTF's AdWireGuardSyncService rewrites it
#      whenever the AdVpnPeer table changes) and run `wg syncconf` so the
#      change applies in-place.
#
# Everything else (peer cleanup, key revocation) is driven by the GZCTF side
# rewriting wg0.conf; the sidecar is intentionally dumb.

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-/config}"
WG_CONF="${CONFIG_DIR}/wg0.conf"
SERVER_PRIV="${CONFIG_DIR}/server.key"
SERVER_PUB="${CONFIG_DIR}/server.pub"
INTERFACE="${WG_INTERFACE:-wg0}"
CHALLENGE_NAMESPACE="${CHALLENGE_NAMESPACE:-gzctf-challenges}"
WG_FORWARD_CHAIN="GZCTF_WG_DEST"
K8S_TOKEN_FILE="/var/run/secrets/kubernetes.io/serviceaccount/token"
K8S_CA_FILE="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

mkdir -p "$CONFIG_DIR"

if [[ ! -f "$SERVER_PRIV" ]]; then
  echo "[wg-sidecar] no server keypair found, generating new keys"
  wg genkey | tee "$SERVER_PRIV" | wg pubkey > "$SERVER_PUB"
  chmod 600 "$SERVER_PRIV"
fi

echo "[wg-sidecar] server pubkey: $(cat "$SERVER_PUB")"

# Hand our container ID to GZCTF's AdVpnTopology so it can auto-attach us to
# the discovered challenge networks. Docker sets the container's hostname to
# the short container ID by default. We write the full ID via /proc when
# available (works inside Docker; gracefully falls back to /etc/hostname).
SIDECAR_ID_FILE="${CONFIG_DIR}/sidecar.id"
if [[ -r /proc/self/cgroup ]] && grep -oE '[a-f0-9]{64}' /proc/self/cgroup | head -1 > "$SIDECAR_ID_FILE" 2>/dev/null \
   && [[ -s "$SIDECAR_ID_FILE" ]]; then
  :
else
  cat /etc/hostname > "$SIDECAR_ID_FILE"
fi
echo "[wg-sidecar] container ID written to $SIDECAR_ID_FILE: $(cat "$SIDECAR_ID_FILE")"

# Pre-flight: enable IPv4 forwarding inside the netns so traffic from VPN
# clients can route into the A&D challenge network.
if [[ -w /proc/sys/net/ipv4/ip_forward ]]; then
  echo 1 > /proc/sys/net/ipv4/ip_forward || true
fi

# Wait for GZCTF to seed the config the first time. GZCTF's
# AdWireGuardSyncService writes wg0.conf right after detecting the server
# keypair, so this normally takes <1s after first boot. Cap the wait so we
# don't block forever if the sync service is broken.
for i in {1..120}; do
  if [[ -f "$WG_CONF" ]]; then
    break
  fi
  if (( i == 1 )); then
    echo "[wg-sidecar] waiting for $WG_CONF (written by GZCTF's AdWireGuardSyncService)..."
  fi
  sleep 1
done

if [[ ! -f "$WG_CONF" ]]; then
  echo "[wg-sidecar] FATAL: $WG_CONF never appeared after 120s. Is GZCTF running?"
  exit 1
fi

echo "[wg-sidecar] bringing up $INTERFACE"
wg-quick up "$WG_CONF" || {
  echo "[wg-sidecar] wg-quick up failed; dumping config:"
  cat "$WG_CONF" || true
  exit 1
}

# In Kubernetes the client config routes the Service CIDR through this pod.
# Restrict forwarding to Services created by GZCTF in the challenge namespace;
# otherwise the same route would also expose postgres, redis, and kube-system.
refresh_k8s_destinations() {
  local api token selector services pods service_rules pod_rules rules
  api="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS:-443}"
  token="$(cat "$K8S_TOKEN_FILE")"
  selector="labelSelector=gzctf.gzti.me%2FResourceId"

  if ! services="$(curl -fsS --max-time 5 --cacert "$K8S_CA_FILE" \
      -H "Authorization: Bearer ${token}" \
      "${api}/api/v1/namespaces/${CHALLENGE_NAMESPACE}/services?${selector}")" || \
     ! pods="$(curl -fsS --max-time 5 --cacert "$K8S_CA_FILE" \
      -H "Authorization: Bearer ${token}" \
      "${api}/api/v1/namespaces/${CHALLENGE_NAMESPACE}/pods?${selector}")"; then
    echo "[wg-sidecar] service discovery failed; keeping the existing forwarding rules" >&2
    return 1
  fi

  service_rules="$(printf '%s' "$services" | jq -r '
    .items[]
    | select(.spec.clusterIP != null and .spec.clusterIP != "None")
    | .spec.clusterIP as $ip
    | .spec.ports[]
    | select((.protocol // "TCP") == "TCP")
    | [$ip, (.port | tostring)] | @tsv')"
  # kube-proxy normally DNATs a ClusterIP before the filter/FORWARD hook, so
  # allow the backing pod IP as well as the Service IP.
  pod_rules="$(printf '%s' "$pods" | jq -r '
    .items[]
    | select(.status.podIP != null)
    | .status.podIP as $ip
    | .spec.containers[0].ports[]?
    | select((.protocol // "TCP") == "TCP")
    | [$ip, (.containerPort | tostring)] | @tsv')"
  rules="${service_rules}"$'\n'"${pod_rules}"

  # Rebuild fail-closed. A transient API failure above leaves the previous
  # known-good rules in place; an empty successful result permits nothing.
  iptables -F "$WG_FORWARD_CHAIN"
  iptables -A "$WG_FORWARD_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  while IFS=$'\t' read -r ip port; do
    [[ -z "$ip" || -z "$port" ]] && continue
    iptables -A "$WG_FORWARD_CHAIN" -d "${ip}/32" -p tcp --dport "$port" -j ACCEPT
  done <<< "$rules"
  iptables -A "$WG_FORWARD_CHAIN" -j DROP
}

start_k8s_forward_filter() {
  [[ -n "${KUBERNETES_SERVICE_HOST:-}" ]] || return 0
  [[ -r "$K8S_TOKEN_FILE" && -r "$K8S_CA_FILE" ]] || {
    echo "[wg-sidecar] Kubernetes credentials missing; refusing VPN forwarding" >&2
    return 1
  }

  iptables -N "$WG_FORWARD_CHAIN" 2>/dev/null || true
  iptables -F "$WG_FORWARD_CHAIN"
  iptables -A "$WG_FORWARD_CHAIN" -j DROP
  iptables -C FORWARD -i "$INTERFACE" -j "$WG_FORWARD_CHAIN" 2>/dev/null || \
    iptables -I FORWARD 1 -i "$INTERFACE" -j "$WG_FORWARD_CHAIN"
  refresh_k8s_destinations || true

  (
    while true; do
      sleep 10
      refresh_k8s_destinations || true
    done
  ) &
  K8S_FILTER_PID=$!
  echo "[wg-sidecar] Kubernetes forwarding restricted to labelled challenge Services"
}

start_k8s_forward_filter

# Graceful teardown on SIGTERM/SIGINT.
cleanup() {
  echo "[wg-sidecar] received signal, bringing $INTERFACE down"
  if [[ -n "${K8S_FILTER_PID:-}" ]]; then
    kill "$K8S_FILTER_PID" 2>/dev/null || true
    iptables -D FORWARD -i "$INTERFACE" -j "$WG_FORWARD_CHAIN" 2>/dev/null || true
    iptables -F "$WG_FORWARD_CHAIN" 2>/dev/null || true
    iptables -X "$WG_FORWARD_CHAIN" 2>/dev/null || true
  fi
  wg-quick down "$WG_CONF" || true
  exit 0
}
trap cleanup SIGTERM SIGINT

echo "[wg-sidecar] watching $WG_CONF for changes"
while inotifywait -qq -e close_write,moved_to "$CONFIG_DIR"; do
  if [[ -f "$WG_CONF" ]]; then
    echo "[wg-sidecar] $(date -Iseconds) — config changed, running wg syncconf"
    if ! wg syncconf "$INTERFACE" <(wg-quick strip "$WG_CONF"); then
      echo "[wg-sidecar] wg syncconf failed — leaving previous config in place"
    fi
  fi
done
