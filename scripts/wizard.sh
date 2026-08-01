#!/bin/sh
# Interactive first-time setup for the GZCTF platform template.
#
# Prompts the operator for:
#   - PUBLIC_ENTRY            (required)
#   - ACME email              (required for Let's Encrypt)
#   - Admin seed password     (auto-generated, printed at the end)
#
# Sensible defaults / auto-generated:
#   - WORKSPACE = gzctf-<random 8 hex>
#   - XOR_KEY   = openssl rand -hex 32
#
# Writes compose/.env + compose/appsettings.json. Refuses to
# overwrite existing files — operator must delete them first.
#
# Pure POSIX sh; only deps are openssl (random) + sed (substitution).

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

ENV_FILE="compose/.env"
APP_FILE="compose/appsettings.json"
APP_EXAMPLE="compose/appsettings.example.json"

if [ -f "$APP_FILE" ]; then
    echo "✗ $APP_FILE already exists." >&2
    echo "  Delete it (and optionally $ENV_FILE) to run the wizard again." >&2
    exit 1
fi

if [ ! -f "$APP_EXAMPLE" ]; then
    echo "✗ $APP_EXAMPLE missing — can't render from template." >&2
    exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
    echo "✗ openssl is required (used for password + XOR-key generation)." >&2
    exit 1
fi

# Colors — only when stdout is a terminal.
if [ -t 1 ]; then
    BOLD=$(printf '\033[1m')
    DIM=$(printf '\033[2m')
    RESET=$(printf '\033[0m')
    GREEN=$(printf '\033[32m')
    YELLOW=$(printf '\033[33m')
else
    BOLD=""; DIM=""; RESET=""; GREEN=""; YELLOW=""
fi

prompt() {
    # $1 = prompt text, $2 = default (optional), $3 = output var name
    _label=$1
    _default=${2:-}
    _var=$3
    if [ -n "$_default" ]; then
        printf "%s%s%s [%s%s%s]: " "$BOLD" "$_label" "$RESET" "$DIM" "$_default" "$RESET"
    else
        printf "%s%s%s: " "$BOLD" "$_label" "$RESET"
    fi
    read -r _value || _value=""
    if [ -z "$_value" ] && [ -n "$_default" ]; then
        _value=$_default
    fi
    eval "$_var=\$_value"
}

prompt_yn() {
    # $1 = prompt text, $2 = default y/n, $3 = output var ("y"/"n")
    _label=$1
    _default=$2
    _var=$3
    if [ "$_default" = "y" ]; then _hint="Y/n"; else _hint="y/N"; fi
    printf "%s%s%s [%s%s%s]: " "$BOLD" "$_label" "$RESET" "$DIM" "$_hint" "$RESET"
    read -r _ans || _ans=""
    if [ -z "$_ans" ]; then _ans=$_default; fi
    case "$_ans" in
        y|Y|yes|YES) eval "$_var=y" ;;
        *)           eval "$_var=n" ;;
    esac
}

# Hidden read (no echo) for passwords. Falls back to plain read on
# shells without stty.
prompt_secret() {
    _label=$1
    _var=$2
    if command -v stty >/dev/null 2>&1 && [ -t 0 ]; then
        printf "%s%s%s: " "$BOLD" "$_label" "$RESET"
        _old_stty=$(stty -g 2>/dev/null) || _old_stty=""
        stty -echo 2>/dev/null || true
        read -r _value || _value=""
        [ -n "$_old_stty" ] && stty "$_old_stty" 2>/dev/null
        echo
    else
        printf "%s%s%s (input visible): " "$BOLD" "$_label" "$RESET"
        read -r _value || _value=""
    fi
    eval "$_var=\$_value"
}

cat <<EOF
${GREEN}${BOLD}GZCTF platform first-time setup${RESET}
${DIM}This wizard will create compose/.env and compose/appsettings.json
with sensible defaults. You can edit either file by hand later.${RESET}

EOF

# ---------------------------------------------------------------------------
# Required
# ---------------------------------------------------------------------------
echo "${BOLD}1. Public hostname${RESET}"
echo "${DIM}   The domain participants type into their browser. No https://, no path.${RESET}"
while :; do
    prompt "   PUBLIC_ENTRY" "ctf.example.com" PUBLIC_ENTRY
    case "$PUBLIC_ENTRY" in
        *.*) break ;;
        *) echo "${YELLOW}   Hostname must contain at least one dot.${RESET}" ;;
    esac
done

echo "${DIM}   Challenge instances use this separate wildcard DNS zone (for example chall.$PUBLIC_ENTRY).${RESET}"
prompt "   CHALLENGE_BASE_DOMAIN" "chall.$PUBLIC_ENTRY" CHALLENGE_BASE_DOMAIN

echo
echo "${BOLD}2. ACME email${RESET}"
echo "${DIM}   Let's Encrypt sends cert-expiry warnings here.${RESET}"
prompt "   ACME_EMAIL" "admin@$PUBLIC_ENTRY" ACME_EMAIL

# ---------------------------------------------------------------------------
# Optional — SMTP
# ---------------------------------------------------------------------------
echo
echo "${BOLD}3. SMTP relay (optional)${RESET}"
echo "${DIM}   Enables email verification + password reset.${RESET}"
echo "${DIM}   You can also configure this later under /admin/settings → Email.${RESET}"
prompt_yn "   Configure SMTP now?" "n" CONFIGURE_SMTP

SMTP_HOST=""; SMTP_PORT="587"; SMTP_SENDER=""; SMTP_USER=""; SMTP_PASSWORD=""
if [ "$CONFIGURE_SMTP" = "y" ]; then
    prompt "   SMTP host"                "smtp.gmail.com"     SMTP_HOST
    prompt "   SMTP port"                "587"                SMTP_PORT
    prompt "   From address"             "noreply@$PUBLIC_ENTRY" SMTP_SENDER
    prompt "   SMTP username"            "$SMTP_SENDER"       SMTP_USER
    prompt_secret "   SMTP password"     SMTP_PASSWORD
fi

# ---------------------------------------------------------------------------
# Optional — Captcha
# ---------------------------------------------------------------------------
echo
echo "${BOLD}4. Captcha (optional)${RESET}"
echo "${DIM}   Recommended for public CTFs to slow down account creation bots.${RESET}"
echo "${DIM}   You can also configure this later under /admin/settings → Captcha.${RESET}"
prompt_yn "   Configure Cloudflare Turnstile now?" "n" CONFIGURE_CAPTCHA

TURNSTILE_SITEKEY=""; TURNSTILE_SECRET=""
if [ "$CONFIGURE_CAPTCHA" = "y" ]; then
    prompt "   Turnstile site key" "" TURNSTILE_SITEKEY
    prompt_secret "   Turnstile secret key" TURNSTILE_SECRET
fi

# ---------------------------------------------------------------------------
# Auto-generated values
# ---------------------------------------------------------------------------
WORKSPACE="gzctf-$(openssl rand -hex 4)"
XOR_KEY=$(openssl rand -hex 32)
# Prefix 'Aa1' to satisfy ASP.NET Identity's default password policy
# (requires uppercase + lowercase + digit). Raw hex is all-lowercase
# and would silently fail UserManager.CreateAsync, leaving no Admin
# user at all.
ADMIN_PASSWORD="Aa1$(openssl rand -hex 12)"
# Postgres credential — kept in step between docker-compose's
# POSTGRES_PASSWORD env (consumed on first db init) and gzctf's
# ConnectionStrings.Database. DO NOT rotate later without ALTERing
# the postgres user inside the running db container.
POSTGRES_PASSWORD="Aa1$(openssl rand -hex 16)"

# ---------------------------------------------------------------------------
# Write .env
# ---------------------------------------------------------------------------
cat > "$ENV_FILE" <<EOF
# Generated by scripts/wizard.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ')
PUBLIC_ENTRY=$PUBLIC_ENTRY
CHALLENGE_BASE_DOMAIN=$CHALLENGE_BASE_DOMAIN
WORKSPACE=$WORKSPACE
ACME_EMAIL=$ACME_EMAIL

# Used by gzctf to encrypt registry passwords + repo-binding tokens
# at rest. DO NOT rotate after first boot — breaks every encrypted
# value already in the DB.
XOR_KEY=$XOR_KEY

# Seed password for the initial 'Admin' user. Only consumed on the
# very first boot (when no Admin user exists); ignored afterwards.
# Change the password in the UI after first login.
ADMIN_PASSWORD=$ADMIN_PASSWORD

# Postgres credential. Consumed by the db container on first init AND
# by gzctf's ConnectionStrings (substituted into appsettings.json).
# Rotating this requires ALTER USER inside the running db.
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
EOF
chmod 600 "$ENV_FILE"

# ---------------------------------------------------------------------------
# Write appsettings.json — sed-substitute placeholders + optional sections
# ---------------------------------------------------------------------------
escape_sed() {
    printf '%s' "$1" | sed 's|[\\&|]|\\&|g'
}
PUBLIC_ENTRY_ESC=$(escape_sed "$PUBLIC_ENTRY")
CHALLENGE_BASE_DOMAIN_ESC=$(escape_sed "${CHALLENGE_BASE_DOMAIN:-}")
XOR_KEY_ESC=$(escape_sed "$XOR_KEY")
POSTGRES_PASSWORD_ESC=$(escape_sed "$POSTGRES_PASSWORD")

sed \
    -e "s|{{\\.PublicEntry}}|$PUBLIC_ENTRY_ESC|g" \
    -e "s|{{\\.ChallengeBaseDomain}}|$CHALLENGE_BASE_DOMAIN_ESC|g" \
    -e "s|{{\\.XorKey}}|$XOR_KEY_ESC|g" \
    -e "s|{{\\.PostgresPassword}}|$POSTGRES_PASSWORD_ESC|g" \
    "$APP_EXAMPLE" > "$APP_FILE"

# Optional substitutions — only patch if operator opted in. The
# example file's EmailConfig + CaptchaConfig sections have inert
# defaults that work, just empty / inactive.
if [ "$CONFIGURE_SMTP" = "y" ]; then
    SMTP_HOST_ESC=$(escape_sed "$SMTP_HOST")
    SMTP_SENDER_ESC=$(escape_sed "$SMTP_SENDER")
    SMTP_USER_ESC=$(escape_sed "$SMTP_USER")
    SMTP_PASSWORD_ESC=$(escape_sed "$SMTP_PASSWORD")
    sed -i \
        -e "s|\"SenderAddress\": \".*\"|\"SenderAddress\": \"$SMTP_SENDER_ESC\"|" \
        -e "s|\"SenderName\": \".*\"|\"SenderName\": \"GZCTF\"|" \
        -e "s|\"UserName\": \"noreply@.*\"|\"UserName\": \"$SMTP_USER_ESC\"|" \
        -e "s|\"Password\": \"-\"|\"Password\": \"$SMTP_PASSWORD_ESC\"|" \
        -e "s|\"Host\": \".*\"|\"Host\": \"$SMTP_HOST_ESC\"|" \
        -e "s|\"Port\": [0-9]*|\"Port\": $SMTP_PORT|" \
        "$APP_FILE"
fi

if [ "$CONFIGURE_CAPTCHA" = "y" ]; then
    TURNSTILE_SITEKEY_ESC=$(escape_sed "$TURNSTILE_SITEKEY")
    TURNSTILE_SECRET_ESC=$(escape_sed "$TURNSTILE_SECRET")
    sed -i \
        -e "s|\"Provider\": \"CloudflareTurnstile\"|\"Provider\": \"CloudflareTurnstile\"|" \
        -e "s|\"SiteKey\": \"\"|\"SiteKey\": \"$TURNSTILE_SITEKEY_ESC\"|" \
        -e "s|\"SecretKey\": \"\"|\"SecretKey\": \"$TURNSTILE_SECRET_ESC\"|" \
        "$APP_FILE"
fi

chmod 600 "$APP_FILE"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
cat <<EOF

${GREEN}${BOLD}✓ Setup complete${RESET}

  PUBLIC_ENTRY  = $PUBLIC_ENTRY
  WORKSPACE     = $WORKSPACE  ${DIM}(auto)${RESET}
  ACME_EMAIL    = $ACME_EMAIL
  XOR_KEY       = ${DIM}(64 random hex, persisted to .env)${RESET}
  SMTP          = $([ "$CONFIGURE_SMTP" = "y" ] && echo "${SMTP_HOST}:${SMTP_PORT} as ${SMTP_USER}" || echo "${DIM}skipped — set later in /admin/settings${RESET}")
  Captcha       = $([ "$CONFIGURE_CAPTCHA" = "y" ] && echo "CloudflareTurnstile" || echo "${DIM}skipped — set later in /admin/settings${RESET}")

${YELLOW}${BOLD}⚠ Admin seed password (write this down — only shown once):${RESET}

    ${BOLD}$ADMIN_PASSWORD${RESET}

  After 'make platform-up', log in at https://$PUBLIC_ENTRY as
  user 'Admin' with that password and change it in the profile menu.

${BOLD}Next:${RESET}
    make setup        ${DIM}# create the external 'traefik' + 'challenges' networks${RESET}
    make platform-up  ${DIM}# start gzctf + db + cache + traefik${RESET}

EOF
