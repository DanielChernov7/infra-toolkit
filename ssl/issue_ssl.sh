#!/usr/bin/env bash
# Mass-issue Let's Encrypt certs for domains under /var/www/*
# ✅ Adapted for lemp_pipeline.sh
# ✅ No www.<domain> requests (bare domain only)
#
# Usage:
#   sudo /root/issue_random_ssl.sh --email you@example.com [--wwwbase /var/www] [--staging] [--no-redirect] [--dry-run]

set -Eeuo pipefail
IFS=$'\n\t'

WWWBASE="/var/www"
EMAIL=""
USE_STAGING=false
USE_REDIRECT=false
DRY_RUN=false

# ---------- logging helpers ----------
log_ok()  { echo -e "\033[1;32m[OK]\033[0m  $*"; }
log_i()   { echo -e "\033[1;34m[INFO]\033[0m $*"; }
log_w()   { echo -e "\033[1;33m[WARN]\033[0m $*"; }
log_e()   { echo -e "\033[1;31m[ERR]\033[0m  $*"; }

usage() {
  cat <<EOF
Usage: sudo $0 --email you@example.com [--wwwbase /var/www] [--staging] [--no-redirect] [--dry-run]

Options:
  --email <addr>       (required) Contact email for Let's Encrypt.
  --wwwbase <path>     Base dir with per-domain folders. Default: /var/www
  --staging            Use Let's Encrypt staging (safe for tests).
  --no-redirect        Do NOT force HTTP->HTTPS redirect. Default (Cloudflare-safe).
  --redirect           Force HTTP->HTTPS redirect (only if NOT behind Cloudflare).
  --dry-run            Show actions without calling certbot.
  -h, --help           Show this help.

Assumptions:
  * Nginx vhost for domain is at /etc/nginx/sites-enabled/<domain>.conf
  * DNS A record for <domain> must point to THIS server.
EOF
}

is_fqdn() {
  [[ "$1" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]
}

have_vhost_enabled() {
  local dom="$1"
  [[ -f "/etc/nginx/sites-enabled/${dom}.conf" ]]
}

ensure_ufw() {
  log_i "Configuring UFW firewall..."

  if ! command -v ufw &>/dev/null; then
    apt-get install -y ufw
  fi

  ufw allow 22/tcp   comment 'SSH'   >/dev/null
  ufw allow 80/tcp   comment 'HTTP'  >/dev/null
  ufw allow 443/tcp  comment 'HTTPS' >/dev/null
  ufw --force enable >/dev/null

  log_ok "UFW enabled. Open ports: 22 (SSH), 80 (HTTP), 443 (HTTPS)"
}

ensure_tools() {
  export DEBIAN_FRONTEND=noninteractive

  # APT watchdog — убиваем застрявший apt/unattended-upgrades если есть
  local pids
  pids=$(ps -eo pid,cmd | grep -E 'apt-get|dpkg|unattended-upgrade' | grep -v grep | awk '{print $1}' || true)
  if [[ -n "$pids" ]]; then
    log_w "APT is locked by: $pids — force killing..."
    kill -9 $pids 2>/dev/null || true
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock || true
    dpkg --configure -a || true
    apt-get install -f -y || true
    apt-get clean || true
    log_ok "APT lock cleared"
  fi

  apt-get update -y
  apt-get install -y nginx certbot python3-certbot-nginx
  systemctl enable --now nginx
}

trap 'log_e "Unexpected error on line $LINENO"; exit 1' ERR

# ---------- argument parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --email)       EMAIL="${2:-}"; shift 2 ;;
    --wwwbase)     WWWBASE="${2:-}"; shift 2 ;;
    --staging)     USE_STAGING=true; shift ;;
    --no-redirect) USE_REDIRECT=false; shift ;;
    --dry-run)     DRY_RUN=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             log_e "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

[[ -n "$EMAIL" ]] || { log_e "--email is required"; usage; exit 1; }
[[ -d "$WWWBASE" ]] || { log_e "WWWBASE not a directory: $WWWBASE"; exit 1; }

# ---------- firewall ----------
ensure_ufw

# ---------- sanity ----------
ensure_tools

log_i "Validating Nginx configuration pre-flight..."
if ! nginx -t >/dev/null 2>&1; then
  log_e "nginx -t failed. Fix your vhosts before issuing certificates."
  nginx -t
  exit 1
fi
log_ok "Nginx config looks good."

# ---------- main loop ----------
shopt -s nullglob
DOM_DIRS=( "$WWWBASE"/*/ )
TOTAL=0; OK=0; FAIL=0; SKIP=0

if [[ ${#DOM_DIRS[@]} -eq 0 ]]; then
  log_w "No subfolders in $WWWBASE — nothing to do."
  exit 0
fi

for d in "${DOM_DIRS[@]}"; do
  [[ -d "$d" ]] || continue
  domain="$(basename "$d")"

  # Skip non-FQDNs (like html)
  if ! is_fqdn "$domain"; then
    log_w "Skip '$domain' (not a valid FQDN)."
    ((SKIP++)) || true
    continue
  fi

  if ! have_vhost_enabled "$domain"; then
    log_w "Skip '$domain' (/etc/nginx/sites-enabled/${domain}.conf not found)."
    ((SKIP++)) || true
    continue
  fi

  ((TOTAL++)) || true
  log_i "Processing $domain ..."

  CB_ARGS=(
    --nginx
    -d "$domain"
    --agree-tos
    --non-interactive
    -m "$EMAIL"
  )

  if $USE_REDIRECT; then
    CB_ARGS+=( --redirect )
  else
    CB_ARGS+=( --no-redirect )
  fi

  $USE_STAGING && CB_ARGS+=( --staging )

  if $DRY_RUN; then
    echo "certbot ${CB_ARGS[*]}"
    ((OK++)) || true
    continue
  fi

  if ! nginx -t >/dev/null 2>&1; then
    log_e "nginx -t failed just before issuing for $domain. Aborting."
    nginx -t
    exit 1
  fi

  if certbot "${CB_ARGS[@]}"; then
    log_ok "Issued/renewed for $domain"
    ((OK++)) || true
  else
    log_w "certbot failed for $domain"
    ((FAIL++)) || true
  fi
done

# ---------- post actions ----------
if ! $DRY_RUN && [[ $OK -gt 0 ]]; then
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx || log_w "nginx reload failed (but certs may still be installed)."
  else
    log_w "nginx -t failed after issuing some certs — check configs before reload."
    nginx -t
  fi
fi

echo
log_i "Summary: processed=$TOTAL, ok=$OK, failed=$FAIL, skipped=$SKIP"

if [[ $OK -gt 0 && $FAIL -eq 0 ]]; then
  exit 0
elif [[ $OK -gt 0 ]]; then
  exit 0
else
  exit 1
fi
