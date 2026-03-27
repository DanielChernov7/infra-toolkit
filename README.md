# infra-toolkit

Production bash toolkit for automated LEMP stack provisioning, multi-domain
WordPress deployment, and SSL/nginx management at scale.

Built for and battle-tested across **100+ advertising domains** in production.
Core application code is proprietary (NDA) — this repo contains the
infrastructure layer extracted and sanitized for reference.

---

## What's inside

```
infra-toolkit/
├── lemp/
│   └── lemp_pipeline.sh      # Full LEMP provisioning pipeline
├── ssl/
│   └── issue_ssl.sh          # Mass SSL issuance for multi-domain setups
├── nginx/
│   ├── vhost_standard.conf   # Production nginx vhost template
│   └── realip-cloudflare.conf # Cloudflare real IP restoration
└── docs/
    └── architecture.md       # Infrastructure overview
```

---

## lemp/lemp_pipeline.sh

One-shot LEMP provisioning for Ubuntu 22.04/24.04.

**What it does:**
- APT watchdog — detects and force-kills stuck `unattended-upgrades` / `dpkg`
  before install, cleans locks, repairs dpkg state
- Installs nginx, PHP-FPM (auto-detects version), certbot
- Auto-detects PHP-FPM socket path across PHP versions (8.1, 8.2, 8.3+)
- Creates nginx vhosts with correct FastCGI config
- Configures UFW: opens 22/80/443, blocks everything else
- Injects Cloudflare Real IP restoration into `nginx.conf` http block
- Two modes: single domain or auto-scan `/var/www/*`
- Optional certbot SSL per domain or for all domains

```bash
# Single domain
sudo ./lemp/lemp_pipeline.sh --domain example.com --email admin@example.com --ssl

# Auto-provision all folders in /var/www that look like FQDNs
sudo ./lemp/lemp_pipeline.sh --auto-vhosts --email admin@example.com --ssl-all

# Without SSL
sudo ./lemp/lemp_pipeline.sh --domain example.com
```

**Notable implementation details:**
- `set -euo pipefail` + `IFS=$'\n\t'` throughout — no silent failures
- APT watchdog with configurable timeout before force-kill
- FQDN detection via regex — skips `html`, `default`, and non-domain folders
- PHP-FPM socket auto-detection: checks `/run/php/php-fpm.sock` first,
  falls back to versioned sockets
- nginx config patched via `sed` to include `conf.d/*.conf` inside `http {}`
  without clobbering the original config (backup created)

---

## ssl/issue_ssl.sh

Mass Let's Encrypt issuance for all domains in `/var/www/*`.

**What it does:**
- Iterates all subdirectories, skips non-FQDNs (`html`, `default`, etc.)
- Pre-flight `nginx -t` before and after each cert issuance
- Cloudflare-safe: `--no-redirect` by default (avoids Flexible SSL redirect loops)
- Swap setup before certbot to prevent OOM on 1GB VPS
- APT watchdog — same as lemp_pipeline
- Dry-run mode to preview commands
- Summary: processed / ok / failed / skipped

```bash
# Dry run — preview what would happen
sudo ./ssl/issue_ssl.sh --email admin@example.com --dry-run

# Issue certs for all domains (Cloudflare-safe, no forced redirect)
sudo ./ssl/issue_ssl.sh --email admin@example.com

# Staging (safe for testing, won't hit rate limits)
sudo ./ssl/issue_ssl.sh --email admin@example.com --staging
```

**Cloudflare + Let's Encrypt note:**

When running behind Cloudflare with SSL set to "Flexible", adding
`--redirect` causes redirect loops. This script defaults to `--no-redirect`
for that reason. If you're terminating SSL at the server (Full/Full Strict
mode), pass `--redirect` explicitly.

---

## nginx/

### vhost_standard.conf

Production nginx vhost template with:
- PHP-FPM via Unix socket
- `.bak`, `.sql`, `.env`, `.git` blocking (returns 404)
- Static asset cache headers (30d)
- Gzip compression
- `try_files` for SPA/WordPress routing

### realip-cloudflare.conf

Restores real visitor IP when proxied through Cloudflare.
Place in `/etc/nginx/conf.d/` — auto-loaded by lemp_pipeline.sh.

Uses `CF-Connecting-IP` header + `real_ip_recursive on`.
Covers all current Cloudflare IPv4 and IPv6 ranges.

---

## Stack

`bash` · `nginx` · `MySQL 8.0` · `PHP-FPM 8.x` · `Certbot` ·
`Let's Encrypt` · `Cloudflare` · `UFW` · `Ubuntu 22.04/24.04` · `AlmaLinux 8`

---

## Production context

This tooling manages infrastructure for a high-load ad-tech platform.
Key problems it solves:

| Problem | Solution |
|---|---|
| `unattended-upgrades` blocking deploys at 3am | APT watchdog with force-kill + lock cleanup |
| Cloudflare Flexible SSL redirect loops | `--no-redirect` default in certbot args |
| PHP-FPM socket path varies by version | Auto-detection with fallback chain |
| 100+ domains need SSL in one run | Batch loop with per-domain error isolation |
| Real visitor IP lost behind Cloudflare | `CF-Connecting-IP` + `set_real_ip_from` ranges |
| OOM during certbot on 1GB VPS | Swap provisioning before issuance |
| MySQL 8.0 auth compatibility | Handled in provisioning (separate internal tooling) |

---

## Notes

Scripts use `$PLACEHOLDER` syntax where environment-specific values
(internal hostnames, paths) were present. All credentials and
business-specific config have been removed.

> Main application infrastructure (domain management panel, lead
> integration layer, cloaking gate) is proprietary and not published.
