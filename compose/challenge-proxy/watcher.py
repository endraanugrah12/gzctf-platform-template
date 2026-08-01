import json
import os
import re
import socket
import time
from http.client import HTTPConnection
from pathlib import Path
from urllib.parse import quote


DOCKER_SOCKET = os.environ.get("DOCKER_SOCKET", "/var/run/docker.sock")
OUTPUT_DIR = Path(os.environ.get("OUTPUT_DIR", "/dynamic"))
ROUTE_BASE_DOMAIN = os.environ.get("ROUTE_BASE_DOMAIN", "chal.example.com").strip(".")
NETWORK_PREFIX = os.environ.get("CHALLENGE_NETWORK_PREFIX", "challenges").strip()
POLL_SECONDS = max(2, int(os.environ.get("POLL_SECONDS", "10")))


class UnixHTTPConnection(HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(DOCKER_SOCKET)


def docker_get(path: str):
    conn = UnixHTTPConnection("localhost")
    conn.request("GET", path)
    resp = conn.getresponse()
    body = resp.read()
    conn.close()
    if resp.status >= 400:
        raise RuntimeError(f"Docker API {resp.status} for {path}: {body.decode(errors='ignore')}")
    return json.loads(body or b"null")


def slugify(value: str) -> str:
    value = value.lower()
    value = re.sub(r"[^a-z0-9-]+", "-", value)
    value = re.sub(r"-{2,}", "-", value)
    return value.strip("-") or "challenge"


def extract_internal_port(info: dict) -> int | None:
    ports = (((info.get("NetworkSettings") or {}).get("Ports")) or {})
    for key in ports.keys():
        port = key.split("/", 1)[0]
        if port.isdigit():
            return int(port)
    exposed = (((info.get("Config") or {}).get("ExposedPorts")) or {})
    for key in exposed.keys():
        port = key.split("/", 1)[0]
        if port.isdigit():
            return int(port)
    return None


def extract_public_port(info: dict, internal_port: int) -> int | None:
    ports = (((info.get("NetworkSettings") or {}).get("Ports")) or {})
    bindings = ports.get(f"{internal_port}/tcp") or []
    for binding in bindings:
        value = binding.get("HostPort")
        if value and value.isdigit():
            return int(value)
    return None


def extract_container_ip(info: dict) -> str | None:
    networks = (((info.get("NetworkSettings") or {}).get("Networks")) or {})
    preferred = (f"{NETWORK_PREFIX}-open", f"{NETWORK_PREFIX}-isolated")
    for name in preferred:
        candidate = networks.get(name)
        if candidate and candidate.get("IPAddress"):
            return candidate["IPAddress"]
    for candidate in networks.values():
        if candidate.get("IPAddress"):
            return candidate["IPAddress"]
    return None


def is_http_service(ip: str, port: int) -> bool:
    payload = b"HEAD / HTTP/1.0\r\nHost: probe\r\n\r\n"
    try:
        with socket.create_connection((ip, port), timeout=2) as sock:
            sock.sendall(payload)
            data = sock.recv(32)
    except OSError:
        return False
    return data.startswith(b"HTTP/")


def build_routes():
    filters = quote(json.dumps({"label": ["ChallengeId"]}))
    containers = docker_get(f"/containers/json?filters={filters}")
    routers = {}
    services = {}
    routes = []

    for container in containers:
        if container.get("State") != "running":
            continue

        info = docker_get(f"/containers/{container['Id']}/json")
        labels = ((info.get("Config") or {}).get("Labels")) or {}
        challenge_id = labels.get("ChallengeId")
        team_id = labels.get("TeamId")
        if not challenge_id or not team_id:
            continue

        ip_addr = extract_container_ip(info)
        port = extract_internal_port(info)
        if not ip_addr or not port:
            continue

        name = (info.get("Name") or "").lstrip("/")
        slug = slugify(labels.get("ChallengeSlug") or name.split("_", 1)[0])
        host = f"{slug}-c{challenge_id}-t{team_id}.{ROUTE_BASE_DOMAIN}"
        route_id = slugify(f"{slug}-c{challenge_id}-t{team_id}")

        metadata = {
            "container_name": name,
            "container_id": container["Id"][:12],
            "challenge_id": challenge_id,
            "team_id": team_id,
            "internal_ip": ip_addr,
            "internal_port": port,
            "public_port": extract_public_port(info, port),
            "host": host,
            "https_url": f"https://{host}/",
        }

        if is_http_service(ip_addr, port):
            routers[route_id] = {
                "rule": f"Host(`{host}`)",
                "entryPoints": ["websecure"],
                "service": route_id,
                "tls": {"certResolver": "cloudflare"},
            }
            services[route_id] = {
                "loadBalancer": {
                    "servers": [{"url": f"http://{ip_addr}:{port}"}],
                    "passHostHeader": True,
                }
            }
            metadata["proxied"] = True
        else:
            metadata["proxied"] = False
            metadata["reason"] = "non-http backend"

        routes.append(metadata)

    return {"http": {"routers": routers, "services": services}}, routes


def atomic_write(path: Path, data: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(data, encoding="utf-8")
    temp.replace(path)


def emit_yaml(config: dict) -> str:
    lines = ["http:", "  routers:"]
    routers = (((config.get("http") or {}).get("routers")) or {})
    services = (((config.get("http") or {}).get("services")) or {})

    if not routers:
        lines.append("    {}")
    else:
        for key, router in sorted(routers.items()):
            lines.extend(
                [
                    f"    {key}:",
                    f"      rule: \"{router['rule']}\"",
                    "      entryPoints:",
                    "        - websecure",
                    f"      service: {router['service']}",
                    "      tls:",
                    "        certResolver: cloudflare",
                ]
            )

    lines.append("  services:")
    if not services:
        lines.append("    {}")
    else:
        for key, service in sorted(services.items()):
            server = service["loadBalancer"]["servers"][0]["url"]
            lines.extend(
                [
                    f"    {key}:",
                    "      loadBalancer:",
                    "        passHostHeader: true",
                    "        servers:",
                    f"          - url: \"{server}\"",
                ]
            )

    return "\n".join(lines) + "\n"


def main():
    config_path = OUTPUT_DIR / "challenges.yml"
    routes_path = OUTPUT_DIR / "routes.json"
    while True:
        try:
            config, routes = build_routes()
            atomic_write(config_path, emit_yaml(config))
            atomic_write(routes_path, json.dumps({"generated_at": int(time.time()), "routes": routes}, indent=2))
        except Exception as exc:
            print(f"[challenge-proxy-watcher] {exc}", flush=True)
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
