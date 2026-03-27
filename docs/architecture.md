# Infrastructure Architecture

High-level overview of the production infrastructure this toolkit supports.

## Server topology

```
                    ┌─────────────────┐
                    │   Cloudflare    │
                    │  (proxy + DNS)  │
                    └────────┬────────┘
                             │ CF-Connecting-IP header
                    ┌────────▼────────┐
                    │   nginx         │
                    │  real_ip module │  ← realip-cloudflare.conf
                    └────────┬────────┘
                ┌────────────┴────────────┐
                │                         │
       ┌────────▼────────┐      ┌─────────▼───────┐
       │   PHP-FPM       │      │  Static assets  │
       │  (per domain)   │      │  (nginx direct) │
       └────────┬────────┘      └─────────────────┘
                │
       ┌────────▼────────┐
       │   MySQL 8.0     │
       │  (per-site DB)  │
       └─────────────────┘
```

## Domain provisioning flow

```
lemp_pipeline.sh --auto-vhosts
        │
        ├── APT watchdog → install nginx + php-fpm + certbot
        ├── UFW: open 22/80/443
        ├── Cloudflare RRIP → /etc/nginx/conf.d/realip-cloudflare.conf
        │
        └── for each /var/www/<fqdn>/:
                ├── create /etc/nginx/sites-available/<domain>.conf
                ├── symlink → sites-enabled/
                └── [optional] certbot --no-redirect

issue_ssl.sh (separate run or scheduled)
        │
        └── for each /var/www/<fqdn>/:
                ├── nginx -t preflight
                ├── certbot --nginx -d <domain> --no-redirect
                └── nginx reload if OK
```

## Scale

- **Domains per server:** 50–200 depending on traffic
- **Provisioning time:** ~2 min per domain including SSL
- **SSL renewal:** certbot systemd timer (auto, every 12h)
- **Servers:** Ubuntu 22.04 / 24.04 VPS (Volter, Bitlaunch)

## What's NOT in this repo

The following components are proprietary and not published:

- **Domain management panel (MyPanel)** — Node.js app with BullMQ job queue,
  Prisma ORM, Redis, SSH automation for remote server operations
- **Cloaking gate** — PHP + Redis/SQLite per-IP visit counter
- **Lead integration layer** — PHP scripts, Cloudflare geo headers,
  MaxMind GeoLite2 IP resolution, CRM API integrations
- **WordPress migration tooling** — rsync + WP-CLI parallelized multi-site
  migration scripts
