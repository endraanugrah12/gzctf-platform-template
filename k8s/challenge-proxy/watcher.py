import json
import os
import re
import socket
import ssl
import time
from http.client import HTTPSConnection
from urllib.parse import quote


API_HOST = os.environ["KUBERNETES_SERVICE_HOST"]
API_PORT = int(os.environ.get("KUBERNETES_SERVICE_PORT_HTTPS", "443"))
NAMESPACE = os.environ.get("CHALLENGE_NAMESPACE", "gzctf-challenges")
ROUTE_BASE_DOMAIN = os.environ.get("ROUTE_BASE_DOMAIN", "chall.example.com").strip(".").lower()
POLL_SECONDS = max(2, int(os.environ.get("POLL_SECONDS", "10")))
TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
RESOURCE_LABEL = "gzctf.gzti.me/ResourceId"
MANAGED_LABEL = "app.kubernetes.io/managed-by"
MANAGER_NAME = "gzctf-challenge-proxy"


def api_request(method: str, path: str, payload: dict | None = None, content_type: str = "application/json"):
    with open(TOKEN_PATH, encoding="utf-8") as token_file:
        token = token_file.read().strip()

    body = json.dumps(payload).encode() if payload is not None else None
    context = ssl.create_default_context(cafile=CA_PATH)
    conn = HTTPSConnection(API_HOST, API_PORT, context=context, timeout=10)
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    if body is not None:
        headers["Content-Type"] = content_type
    conn.request(method, path, body=body, headers=headers)
    response = conn.getresponse()
    response_body = response.read()
    conn.close()
    data = json.loads(response_body) if response_body else None
    return response.status, data


def slugify(value: str) -> str:
    value = value.lower()
    value = re.sub(r"[^a-z0-9-]+", "-", value)
    value = re.sub(r"-{2,}", "-", value)
    return (value.strip("-") or "challenge")[:40].rstrip("-")


def instance_label(slug: str, challenge_id: str, team_id: str) -> str:
    suffix = f"-c{challenge_id}-t{team_id}"
    max_slug_length = max(1, 63 - len(suffix))
    route_slug = slugify(slug)[:max_slug_length].rstrip("-") or "c"
    return f"{route_slug}{suffix}"


def is_http_service(ip_address: str, port: int) -> bool:
    payload = b"HEAD / HTTP/1.0\r\nHost: probe\r\n\r\n"
    try:
        with socket.create_connection((ip_address, port), timeout=2) as sock:
            sock.sendall(payload)
            data = sock.recv(32)
    except OSError:
        return False
    return data.startswith(b"HTTP/")


def route_details(service: dict):
    metadata = service.get("metadata") or {}
    labels = metadata.get("labels") or {}
    annotations = metadata.get("annotations") or {}
    spec = service.get("spec") or {}
    ports = spec.get("ports") or []
    challenge_id = labels.get("gzctf.gzti.me/ChallengeId")
    team_id = labels.get("gzctf.gzti.me/TeamId")
    cluster_ip = spec.get("clusterIP")
    if not challenge_id or not team_id or not cluster_ip or cluster_ip == "None" or not ports:
        return None

    port = ports[0].get("port")
    if not isinstance(port, int):
        return None

    slug = annotations.get("gzctf.gzti.me/ChallengeSlug") or metadata.get("name", "challenge")
    host = f"{instance_label(slug, challenge_id, team_id)}.{ROUTE_BASE_DOMAIN}"
    return cluster_ip, port, host


def desired_ingress(service: dict, host: str) -> dict:
    metadata = service["metadata"]
    name = metadata["name"]
    return {
        "apiVersion": "networking.k8s.io/v1",
        "kind": "Ingress",
        "metadata": {
            "name": name,
            "namespace": NAMESPACE,
            "labels": {
                MANAGED_LABEL: MANAGER_NAME,
                RESOURCE_LABEL: (metadata.get("labels") or {}).get(RESOURCE_LABEL, name),
            },
            "annotations": {
                "traefik.ingress.kubernetes.io/router.entrypoints": "websecure",
                "traefik.ingress.kubernetes.io/router.tls": "true",
            },
            "ownerReferences": [
                {
                    "apiVersion": "v1",
                    "kind": "Service",
                    "name": name,
                    "uid": metadata["uid"],
                }
            ],
        },
        "spec": {
            "ingressClassName": "traefik",
            "tls": [{"hosts": [host]}],
            "rules": [
                {
                    "host": host,
                    "http": {
                        "paths": [
                            {
                                "path": "/",
                                "pathType": "Prefix",
                                "backend": {
                                    "service": {
                                        "name": name,
                                        "port": {"number": (service.get("spec") or {})["ports"][0]["port"]},
                                    }
                                },
                            }
                        ]
                    },
                }
            ],
        },
    }


def ingress_path(name: str = "") -> str:
    base = f"/apis/networking.k8s.io/v1/namespaces/{NAMESPACE}/ingresses"
    return f"{base}/{name}" if name else base


def ensure_ingress(service: dict, host: str):
    name = service["metadata"]["name"]
    status, current = api_request("GET", ingress_path(name))
    desired = desired_ingress(service, host)
    if status == 404:
        status, data = api_request("POST", ingress_path(), desired)
    elif status < 300:
        current_labels = ((current or {}).get("metadata") or {}).get("labels") or {}
        if current_labels.get(MANAGED_LABEL) != MANAGER_NAME:
            raise RuntimeError(f"Ingress {name} already exists and is not managed by this controller")
        current_spec = (current or {}).get("spec")
        current_annotations = ((current or {}).get("metadata") or {}).get("annotations") or {}
        if current_spec == desired["spec"] and all(
            current_annotations.get(key) == value for key, value in desired["metadata"]["annotations"].items()
        ):
            return
        patch = {"metadata": desired["metadata"], "spec": desired["spec"]}
        status, data = api_request("PATCH", ingress_path(name), patch, "application/merge-patch+json")
    else:
        data = current

    if status >= 300:
        raise RuntimeError(f"Ingress reconcile failed for {name}: HTTP {status}: {data}")
    print(f"[challenge-proxy-watcher] routed https://{host}/", flush=True)


def delete_ingress(name: str):
    status, current = api_request("GET", ingress_path(name))
    if status == 404:
        return
    if status >= 300:
        raise RuntimeError(f"Ingress lookup failed for {name}: HTTP {status}: {current}")
    labels = ((current or {}).get("metadata") or {}).get("labels") or {}
    if labels.get(MANAGED_LABEL) != MANAGER_NAME:
        return

    status, data = api_request("DELETE", ingress_path(name))
    if status not in (200, 202, 404):
        raise RuntimeError(f"Ingress delete failed for {name}: HTTP {status}: {data}")


def reconcile():
    selector = quote(f"{RESOURCE_LABEL}")
    status, response = api_request("GET", f"/api/v1/namespaces/{NAMESPACE}/services?labelSelector={selector}")
    if status >= 300:
        raise RuntimeError(f"Service list failed: HTTP {status}: {response}")

    for service in (response or {}).get("items", []):
        metadata = service.get("metadata") or {}
        annotations = metadata.get("annotations") or {}
        if annotations.get("gzctf.gzti.me/PublicHttpRoute", "false").lower() != "true":
            if metadata.get("name"):
                delete_ingress(metadata["name"])
            continue
        details = route_details(service)
        if details is None:
            continue
        ip_address, port, host = details
        if is_http_service(ip_address, port):
            ensure_ingress(service, host)
        else:
            delete_ingress(service["metadata"]["name"])


def main():
    if not ROUTE_BASE_DOMAIN:
        raise RuntimeError("ROUTE_BASE_DOMAIN must not be empty")
    while True:
        try:
            reconcile()
        except Exception as exc:
            print(f"[challenge-proxy-watcher] {exc}", flush=True)
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
