# infra-toolkit

Production bash toolkit for automated server provisioning, multi-domain 
WordPress deployment, and SSL/nginx management.

Used in production across 100+ domains. Extracted and sanitized from 
internal infrastructure (core business logic under NDA).

## What's inside

### `lemp/`
Full LEMP stack deployment pipeline for Ubuntu / AlmaLinux VPS

- `lemp_pipeline.sh` — automated nginx + MySQL 8.0 + PHP install and 
  hardening
- `issue_ssl.sh` — per-domain SSL issuance with Cloudflare Flexible 
  redirect loop prevention
- `ufw_setup.sh` — UFW port management for multi-tenant servers

### `wordpress/`
Multi-site WordPress provisioning and migration

- `wp_provision.sh` — full WP install: DB creation, wp-config, 
  admin user, permalink setup via WP-CLI
- `migrate_wp.sh` — rsync + WP-CLI based migration, parallelized 
  for multi-site setups (~70% faster than manual)
- `db_name_sanitize.sh` — MySQL 8.0 compatible DB naming (fixes 
  collision bugs in bulk provisioning)

### `nginx/`
Reusable nginx vhost configs

- `vhost_standard.conf` — production vhost with Cloudflare IP 
  passthrough, gzip, and cache headers
- `vhost_wp.conf` — WordPress-optimized: PHP-FPM, `try_files`, 
  `.bak` file blocking, static asset caching

### `mysql/`
Low-memory MySQL tuning

- `my_low_mem.cnf` — swap-friendly MySQL 8.0 config for 1–2GB VPS 
  (InnoDB buffer pool, tmp table sizing)

## Stack

`bash` · `nginx` · `MySQL 8.0` · `PHP-FPM` · `WP-CLI` · 
`Certbot` · `Cloudflare` · `UFW` · `rsync` · `Ubuntu 22.04` · 
`AlmaLinux 8`

## Production context

These scripts manage infrastructure for a high-load ad-tech platform 
serving hundreds of domains. Key constraints they solve:

- Zero-downtime multi-domain SSL provisioning behind Cloudflare proxy
- MySQL 8.0 auth compatibility (caching_sha2 vs native password)
- Parallel WP migration across sites with shared DB host
- UFW rules that survive server reboots without locking out SSH

## Notes

Scripts are provided as-is for reference. Some environment-specific 
variables (internal hostnames, credentials) are replaced with 
`$PLACEHOLDER` syntax.

---

> Main infrastructure and application code is proprietary (NDA).  
> See my [CV](https://linkedin.com) for full scope of work.
