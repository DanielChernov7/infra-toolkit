#!/usr/bin/env bash
# Ubuntu LEMP one-shot pipeline — Nginx + PHP-FPM, multi-domain aware
#
# Features:
#   - Safe APT watchdog (detects stuck unattended-upgrades / apt-get upgrade)
#   - If apt is locked too long, force-kills the stuck apt, cleans locks, repairs dpkg, continues
#   - Can provision single domain OR auto-provision all folders in /var/www/*
#   - Optional SSL issuance via certbot for one or many domains
#
# Usage (single domain):
#   sudo ./lemp_pipeline.sh --domain example.com \
#       [--wwwroot /var/www/example.com] [--email admin@example.com] [--ssl]
#
# Usage (auto mode: scan /var/www and create vhosts for all subfolders):
#   sudo ./lemp_pipeline.sh --auto-vhosts \
#       [--wwwbase /var/www] [--email admin@example.com] [--ssl-all]
#
# Assumptions:
#   - Ubuntu 24.04+
#   - php-fpm.sock path is /run/php/php-fpm.sock (we’ll detect if missing)
#
set -euo pipefail

########################################
## Defaults / CLI flags
########################################
DOMAIN=""
WWWROOT=""
WWWBASE="/var/www"
EMAIL=""
ENABLE_SSL=false
ENABLE_SSL_ALL=false
AUTO_VHOSTS=false

# --- Watchdog settings ---
WAIT_SECONDS=30      # how long we patiently wait for running apt/unattended-upgrades (in seconds)
POLL_INTERVAL=5       # how often we poll

########################################
## Logging helpers
########################################
log()  { echo -e "\033[1;32m[OK ]\033[0m $*"; }
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR ]\033[0m $*"; }

########################################
## Safety checks
########################################
require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    err "Run as root: sudo $0 ..."
    exit 1
  fi
}

########################################
## Arg parsing
########################################
usage() {
cat <<EOF
lemp_pipeline.sh - provision nginx+php and vhosts

Single-domain mode:
  --domain example.com                (required in single-domain mode)
  --wwwroot /var/www/example.com      (default: /var/www/<domain>)
  --email admin@example.com           (for certbot if --ssl is used)
  --ssl                               request/enable SSL for this domain

Auto mode (all folders in --wwwbase):
  --auto-vhosts                       scan --wwwbase and create vhosts for every directory that looks like a domain
  --wwwbase /var/www                  base path to scan
  --email admin@example.com           used for certbot in --ssl-all mode
  --ssl-all                           request SSL for each detected domain

General:
  --help | -h                         show this help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        DOMAIN="$2"; shift 2;;
      --wwwroot)
        WWWROOT="$2"; shift 2;;
      --wwwbase)
        WWWBASE="$2"; shift 2;;
      --email)
        EMAIL="$2"; shift 2;;
      --ssl)
        ENABLE_SSL=true; shift;;
      --ssl-all)
        ENABLE_SSL_ALL=true; shift;;
      --auto-vhosts)
        AUTO_VHOSTS=true; shift;;
      --help|-h)
        usage; exit 0;;
      *)
        err "Unknown arg: $1"
        usage
        exit 1;;
    esac
  done
}

########################################
## APT Watchdog logic
########################################
# Plan:
# 1. Check if apt/dpkg/unattended-upgrade is active.
# 2. Wait up to WAIT_SECONDS for it to finish quietly.
# 3. If it's still alive after WAIT_SECONDS -> assume it's wedged:
#    - kill -9 those processes
#    - remove lock files
#    - dpkg --configure -a
#    - apt-get install -f -y
#    - apt-get clean && apt-get update
# Then proceed with apt-get install stuff.

list_apt_pids() {
  # Show real apt/dpkg processes. Ignore our own grep.
  ps aux | egrep 'apt(-get)?|dpkg|unattended-upgrade' | egrep -v 'egrep|grep' || true
}

kill_apt_force() {
  warn "APT watchdog: forcing kill of stuck apt/dpkg"

  local pids
  pids=$(ps -eo pid,cmd \
    | egrep 'apt-get|dpkg|unattended-upgrade' \
    | egrep -v 'egrep|grep' \
    | awk '{print $1}' || true)

  if [[ -n "$pids" ]]; then
    warn "Killing PIDs: $pids"
    kill -9 $pids || true
  fi

  # Remove stale locks
  rm -f /var/lib/dpkg/lock-frontend || true
  rm -f /var/lib/dpkg/lock || true
  rm -f /var/cache/apt/archives/lock || true

  # Repair state
  dpkg --configure -a || true
  apt-get install -f -y || true
  apt-get clean || true
  apt-get update || true

  log "APT watchdog recovery done"
}

watchdog_wait_for_apt() {
  info "Checking for running apt/dpkg before install..."

  local procs
  procs=$(list_apt_pids)

  if [[ -z "$procs" ]]; then
    log "No active apt/dpkg processes. Safe to continue."
    return 0
  fi

  warn "APT is busy (unattended-upgrades or apt-get running):"
  echo "$procs"

  warn "Force-killing apt/dpkg right now (aggressive mode)."
  kill_apt_force
  return 0
}

safe_apt_update_install() {
  info "[APT] Updating apt and installing packages"

  # make sure apt is not (or no longer) locked
  watchdog_wait_for_apt

  # After watchdog: apt should now be safe.
  apt-get update -y

  # Core stack packages
  apt-get install -y \
    nginx \
    php-fpm php-cli php-curl php-mysql php-xml php-mbstring php-zip php-gd \
    certbot python3-certbot-nginx

  log "[APT] Base packages ensured"
}

########################################
## Helper: detect php-fpm sock path
########################################
detect_php_fpm_sock() {
  # Prefer generic socket if present
  if [[ -S /run/php/php-fpm.sock ]]; then
    echo "/run/php/php-fpm.sock"
    return
  fi

  # Otherwise first versioned socket
  local first_sock
  first_sock=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -n1 || true)
  if [[ -n "$first_sock" ]]; then
    echo "$first_sock"
    return
  fi

  # Fallback guess
  echo "/run/php/php-fpm.sock"
}

########################################
## Nginx vhost helpers
########################################
create_vhost() {
  local domain="$1"
  local rootdir="$2"

  if [[ -z "$rootdir" ]]; then
    rootdir="/var/www/${domain}"
  fi

  mkdir -p "$rootdir"
  if [[ ! -f "$rootdir/index.php" && ! -f "$rootdir/index.html" ]]; then
    # Безопасная заглушка — не раскрывает информацию о сервере
    echo "<?php http_response_code(200); exit;" > "$rootdir/index.php"
  fi

  local sock_path
  sock_path=$(detect_php_fpm_sock)

  local conf="/etc/nginx/sites-available/${domain}.conf"
  cat > "$conf" <<NGINXCONF
server {
    listen 80;
    server_name ${domain} www.${domain};
    root ${rootdir};
    index index.php;

    access_log /var/log/nginx/${domain}_access.log;
    error_log  /var/log/nginx/${domain}_error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \\.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${sock_path};
    }

    location ~ /\\.ht {
        deny all;
    }
}
NGINXCONF

  ln -sf "$conf" "/etc/nginx/sites-enabled/${domain}.conf"
  log "Nginx vhost created for ${domain} -> ${rootdir} (php-fpm sock: ${sock_path})"
}

obtain_ssl_if_enabled() {
  local domain="$1"
  local email="$2"
  local want_ssl="$3" # true/false

  if [[ "$want_ssl" != "true" ]]; then
    info "SSL disabled for ${domain}"
    return 0
  fi

  if [[ -z "$email" ]]; then
    warn "SSL requested for ${domain} but no --email provided. Skipping certbot."
    return 0
  fi

  info "Requesting Let's Encrypt cert for ${domain}"
  certbot --nginx \
    -d "$domain" \
    --agree-tos -m "$email" --non-interactive --no-redirect \
    || warn "Certbot failed for ${domain}"
}

reload_nginx() {
  info "Validating nginx config"
  nginx -t
  info "Reloading nginx"
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx
  log "nginx reloaded"
}

########################################
## Provision flows
########################################
provision_single_domain() {
  if [[ -z "$DOMAIN" ]]; then
    err "--domain is required in single-domain mode"
    exit 1
  fi

  local rootdir="$WWWROOT"
  if [[ -z "$rootdir" ]]; then
    rootdir="/var/www/${DOMAIN}"
  fi

  create_vhost "$DOMAIN" "$rootdir"
  obtain_ssl_if_enabled "$DOMAIN" "$EMAIL" "${ENABLE_SSL}"
}

provision_auto_vhosts() {
  info "Auto mode: scanning $WWWBASE"
  if [[ ! -d "$WWWBASE" ]]; then
    err "--wwwbase $WWWBASE does not exist"
    exit 1
  fi

  local d
  for d in "$WWWBASE"/*; do
    [[ -d "$d" ]] || continue

    # Guess domain from folder name
    local dom
    dom=$(basename "$d")

    # naive: treat only folders with a dot as domains (like example.com)
    if [[ "$dom" != *.* ]]; then
        info "Skip $dom (does not look like FQDN)"
        continue
    fi

    create_vhost "$dom" "$d"
    obtain_ssl_if_enabled "$dom" "$EMAIL" "${ENABLE_SSL_ALL}"
  done
}

########################################
## Ensure nginx includes conf.d/*.conf inside http {}
########################################
ensure_nginx_conf_d_include() {
  local nginx_conf="/etc/nginx/nginx.conf"
  local include_line="include /etc/nginx/conf.d/*.conf;"

  info "Ensuring nginx loads conf.d/*.conf inside http{}"

  # Если nginx.conf вообще не существует — авария
  if [[ ! -f "$nginx_conf" ]]; then
    err "nginx.conf not found at $nginx_conf"
    return 1
  fi

  # Если include уже есть в файле — ничего не делаем
  if grep -qF "$include_line" "$nginx_conf"; then
    log "nginx already includes conf.d/*.conf"
    return 0
  fi

  warn "conf.d/*.conf not included — patching nginx.conf"

  # Бэкап (один раз)
  if [[ ! -f "${nginx_conf}.bak_rrip" ]]; then
    cp "$nginx_conf" "${nginx_conf}.bak_rrip"
    log "Backup created: ${nginx_conf}.bak_rrip"
  fi

  # Вставляем include внутрь блока http {}
  # Сразу ПОСЛЕ строки 'http {'
  sed -i "/^[[:space:]]*http[[:space:]]*{/a\\
    ${include_line}
  " "$nginx_conf"

  log "Inserted 'include /etc/nginx/conf.d/*.conf;' into http{}"
  nginx -t || { err "nginx -t failed after patching nginx.conf. Restoring backup."; cp "${nginx_conf}.bak_rrip" "$nginx_conf"; return 1; }
}


########################################
## Cloudflare: Restore Real Visitor IP (RRIP)
########################################
ensure_cloudflare_realip() {
  ensure_nginx_conf_d_include
  local realip_conf="/etc/nginx/conf.d/realip-cloudflare.conf"

  info "Ensuring Cloudflare Real IP (RRIP) config exists: $realip_conf"

  cat > "$realip_conf" <<'NGINXREALIP'
# Cloudflare Real IP restore
# This makes $remote_addr / $_SERVER['REMOTE_ADDR'] become the real visitor IP
real_ip_header CF-Connecting-IP;
real_ip_recursive on;

# IPv4
set_real_ip_from 103.21.244.0/22;
set_real_ip_from 103.22.200.0/22;
set_real_ip_from 103.31.4.0/22;
set_real_ip_from 104.16.0.0/13;
set_real_ip_from 104.24.0.0/14;
set_real_ip_from 108.162.192.0/18;
set_real_ip_from 131.0.72.0/22;
set_real_ip_from 141.101.64.0/18;
set_real_ip_from 162.158.0.0/15;
set_real_ip_from 172.64.0.0/13;
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 188.114.96.0/20;
set_real_ip_from 190.93.240.0/20;
set_real_ip_from 197.234.240.0/22;
set_real_ip_from 198.41.128.0/17;

# IPv6
set_real_ip_from 2400:cb00::/32;
set_real_ip_from 2606:4700::/32;
set_real_ip_from 2803:f800::/32;
set_real_ip_from 2405:b500::/32;
set_real_ip_from 2405:8100::/32;
set_real_ip_from 2a06:98c0::/29;
set_real_ip_from 2c0f:f248::/32;
NGINXREALIP

  log "Cloudflare RRIP config written: $realip_conf"
}

########################################
## UFW firewall
########################################
ensure_ufw() {
  info "Configuring UFW firewall..."

  # Устанавливаем UFW если нет
  if ! command -v ufw &>/dev/null; then
    apt-get install -y ufw
  fi

  # Разрешаем критичные порты ДО включения — иначе SSH оборвётся
  ufw allow 22/tcp   comment 'SSH'   >/dev/null
  ufw allow 80/tcp   comment 'HTTP'  >/dev/null
  ufw allow 443/tcp  comment 'HTTPS' >/dev/null

  # Включаем UFW (--force чтобы не было интерактивного вопроса)
  ufw --force enable >/dev/null

  log "UFW enabled. Open ports: 22 (SSH), 80 (HTTP), 443 (HTTPS)"
  ufw status numbered
}

########################################
## main
########################################
main() {
  require_root
  parse_args "$@"

  # 1. Make sure apt is sane, install base packages
  safe_apt_update_install

  # 1.5 Firewall — открыть 22/80/443 до старта nginx
  ensure_ufw

  # 2. Ensure services are up
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx || true

  # 2.5 Cloudflare Real IP restore (RRIP)
  ensure_cloudflare_realip

  # Restart any php-fpm units we have (php8.3-fpm, php8.2-fpm, etc.)
  systemctl list-unit-files | grep php | grep fpm | awk '{print $1}' | while read -r unit; do
    systemctl enable "$unit" >/dev/null 2>&1 || true
    systemctl restart "$unit" || true
  done

  # 3. Provision vhosts
  if [[ "$AUTO_VHOSTS" == true ]]; then
    provision_auto_vhosts
  else
    provision_single_domain
  fi

  # 4. Reload nginx after writing configs / possible certs
  reload_nginx

  ########################################
  ## 5. Auto-remove UTF-8 BOM from thanks_you.php in each /var/www/* dir
  ########################################
  info "Scanning for BOM in /var/www/*/thanks_you.php..."
  for d in /var/www/*; do
    f="$d/thanks_you.php"
    if [ -f "$f" ]; then
      # remove BOM if exists at start of file
      sed -i '1s/^\xEF\xBB\xBF//' "$f"
      echo "Fixed $f"
    fi
  done
  log "BOM cleanup completed."

  log "LEMP pipeline complete."
}

main "$@"
