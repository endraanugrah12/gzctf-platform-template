#!/bin/sh
# Render deployment-specific Kubernetes manifests without changing the
# committed templates. The generated directory contains secrets and is ignored.

set -eu
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

SOURCE_DIR=${K8S_SOURCE_DIR:-k8s}
OUTPUT_DIR=${K8S_OUTPUT_DIR:-k8s/generated}

if [ -e "$OUTPUT_DIR" ]; then
    echo "$OUTPUT_DIR already exists; leaving it unchanged." >&2
    echo "Move or remove it before regenerating the deployment configuration." >&2
    exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl is required for secret generation." >&2
    exit 1
fi

if [ -t 1 ]; then
    BOLD=$(printf '\033[1m')
    DIM=$(printf '\033[2m')
    RESET=$(printf '\033[0m')
else
    BOLD=""; DIM=""; RESET=""
fi

prompt() {
    _label=$1
    _default=${2:-}
    _var=$3
    if [ -n "$_default" ]; then
        printf "%s%s%s [%s]: " "$BOLD" "$_label" "$RESET" "$_default"
    else
        printf "%s%s%s: " "$BOLD" "$_label" "$RESET"
    fi
    read -r _value || _value=""
    [ -n "$_value" ] || _value=$_default
    export "$_var=$_value"
}

prompt_secret() {
    _label=$1
    _var=$2
    printf "%s%s%s: " "$BOLD" "$_label" "$RESET"
    if [ -t 0 ]; then
        stty -echo
        read -r _value || _value=""
        stty echo
        printf '\n'
    else
        read -r _value || _value=""
    fi
    export "$_var=$_value"
}

valid_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
            }
        }
    '
}

valid_ipv4_cidr() {
    _cidr=$1
    case "$_cidr" in
        */*) ;;
        *) return 1 ;;
    esac
    _cidr_ip=${_cidr%/*}
    _cidr_prefix=${_cidr##*/}
    case "$_cidr_prefix" in
        ""|*[!0-9]*) return 1 ;;
    esac
    [ "$_cidr_prefix" -le 32 ] || return 1
    valid_ipv4 "$_cidr_ip"
}

escape_sed() {
    printf '%s' "$1" | sed 's#[\\&|]#\\&#g'
}

DETECTED_IP=""
if command -v ip >/dev/null 2>&1; then
    DETECTED_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')
fi
if ! valid_ipv4 "${DETECTED_IP:-}" 2>/dev/null; then
    DETECTED_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi

cat <<EOF
${BOLD}GZCTF Kubernetes first-time setup${RESET}
${DIM}Secrets will be generated into $OUTPUT_DIR and will not be committed.${RESET}

EOF

while :; do
    prompt "Public hostname (without https://)" "" PUBLIC_ENTRY
    case "$PUBLIC_ENTRY" in
        ctf.example.com|""|*/*|*:*|.*|*.|*..*|*[!a-z0-9.-]*)
            echo "Enter a real DNS hostname such as ctf.example.org." >&2 ;;
        *.*)
            if [ "${#PUBLIC_ENTRY}" -le 253 ]; then break; fi
            echo "The hostname is longer than 253 characters." >&2 ;;
        *) echo "The hostname must contain at least one dot." >&2 ;;
    esac
done

while :; do
    prompt "Challenge wildcard base domain" "chall.$PUBLIC_ENTRY" CHALLENGE_BASE_DOMAIN
    case "$CHALLENGE_BASE_DOMAIN" in
        chall.example.com|""|\*.*|*/*|*:*|.*|*.|*..*|*[!a-z0-9.-]*)
            echo "Enter a DNS suffix such as chall.$PUBLIC_ENTRY (without *. or https://)." >&2 ;;
        *.*)
            if [ "${#CHALLENGE_BASE_DOMAIN}" -le 253 ]; then break; fi
            echo "The hostname is longer than 253 characters." >&2 ;;
        *) echo "The hostname must contain at least one dot." >&2 ;;
    esac
done

while :; do
    prompt_secret "Cloudflare DNS API token" CLOUDFLARE_DNS_API_TOKEN
    if [ -n "$CLOUDFLARE_DNS_API_TOKEN" ]; then break; fi
    echo "The Cloudflare DNS API token is required for wildcard TLS." >&2
done

while :; do
    prompt "Let's Encrypt email" "admin@$PUBLIC_ENTRY" ACME_EMAIL
    case "$ACME_EMAIL" in
        *@*.*) break ;;
        *) echo "Enter a valid email address." >&2 ;;
    esac
done

while :; do
    prompt "Control VM private IPv4" "$DETECTED_IP" CONTROL_PRIVATE_IP
    if valid_ipv4 "$CONTROL_PRIVATE_IP"; then break; fi
    echo "Enter the control VM's GCP private IPv4 address." >&2
done

while :; do
    prompt "Kubernetes control node name" "gzctf-control" CONTROL_NODE_NAME
    case "$CONTROL_NODE_NAME" in
        ""|.*|*.|*..*|*[!a-z0-9.-]*)
            echo "Use a lowercase Kubernetes node name." >&2 ;;
        *)
            if [ "${#CONTROL_NODE_NAME}" -le 63 ]; then break; fi
            echo "The node name must be 63 characters or fewer." >&2 ;;
    esac
done

while :; do
    prompt "K3s Service CIDR" "10.43.0.0/16" SERVICE_CIDR
    if valid_ipv4_cidr "$SERVICE_CIDR"; then break; fi
    echo "Enter a valid IPv4 CIDR such as 10.43.0.0/16." >&2
done

POSTGRES_PASSWORD="Aa1$(openssl rand -hex 16)"
XOR_KEY=$(openssl rand -hex 32)
ADMIN_PASSWORD="Aa1$(openssl rand -hex 12)"
AD_SSH_INTERNAL_SECRET=$(openssl rand -hex 32)

PUBLIC_ENTRY_ESC=$(escape_sed "$PUBLIC_ENTRY")
CHALLENGE_BASE_DOMAIN_ESC=$(escape_sed "$CHALLENGE_BASE_DOMAIN")
CLOUDFLARE_DNS_API_TOKEN_ESC=$(escape_sed "$CLOUDFLARE_DNS_API_TOKEN")
ACME_EMAIL_ESC=$(escape_sed "$ACME_EMAIL")
CONTROL_PRIVATE_IP_ESC=$(escape_sed "$CONTROL_PRIVATE_IP")
CONTROL_NODE_NAME_ESC=$(escape_sed "$CONTROL_NODE_NAME")
SERVICE_CIDR_ESC=$(escape_sed "$SERVICE_CIDR")

mkdir -m 700 "$OUTPUT_DIR"
for source in "$SOURCE_DIR"/*.yaml; do
    destination="$OUTPUT_DIR/$(basename "$source")"
    sed \
        -e "s|CHANGE_ME_ACME_EMAIL|$ACME_EMAIL_ESC|g" \
        -e "s|CHANGE_ME_CLOUDFLARE_DNS_API_TOKEN|$CLOUDFLARE_DNS_API_TOKEN_ESC|g" \
        -e "s|CHANGE_ME_postgres_password|$POSTGRES_PASSWORD|g" \
        -e "s|CHANGE_ME_64_hex_chars_xor_key__________________________________|$XOR_KEY|g" \
        -e "s|CHANGE_ME_admin_password|$ADMIN_PASSWORD|g" \
        -e "s|CHANGE_ME_ad_ssh_internal_secret|$AD_SSH_INTERNAL_SECRET|g" \
        -e "s|CHANGE_ME_CONTROL_PRIVATE_IP|$CONTROL_PRIVATE_IP_ESC|g" \
        -e "s|ctf\.example\.com|$PUBLIC_ENTRY_ESC|g" \
        -e "s|chall\.example\.com|$CHALLENGE_BASE_DOMAIN_ESC|g" \
        -e "s|gzctf-control|$CONTROL_NODE_NAME_ESC|g" \
        -e "s|10\.43\.0\.0/16|$SERVICE_CIDR_ESC|g" \
        "$source" > "$destination"
    chmod 600 "$destination"
done

cat <<EOF

${BOLD}Kubernetes configuration generated.${RESET}

  Public URL:        https://$PUBLIC_ENTRY
  Challenge routes:  https://*.$CHALLENGE_BASE_DOMAIN
  Control private IP: $CONTROL_PRIVATE_IP
  Control node:       $CONTROL_NODE_NAME
  Manifests:          $OUTPUT_DIR

${BOLD}Admin seed password (store this now):${RESET}

  $ADMIN_PASSWORD

Next:
  make KUBECTL='sudo k3s kubectl' k8s-apply

After startup, log in as Admin and change the password in the profile menu.
EOF
