# Deployment (Oracle Cloud)

The site is static HTML/CSS/JS served by an unprivileged nginx container on the Oracle VM, behind the
host's existing Caddy, which terminates TLS.

```
Internet -> Oracle IP :80/:443 -> host Caddy (systemd) -> 127.0.0.1:8081 -> portfolio container (nginx :8080)
```

## Server (verified 2026-10-22)

- Ubuntu 24.04 ARM64 (2 vCPU, 11 GiB RAM shared with Minecraft), Docker 29.x, Compose v5.
- Caddy 2.6.2 runs on the host (not in Docker) and owns ports 80/443. Its config is `/etc/caddy/Caddyfile`.
  Host Caddy cannot join Docker networks, so the container publishes to **loopback only**
  (`127.0.0.1:8081`), the same convention as homepage, uptime-kuma, and portainer.
- App directory: `/srv/apps/portfolio`, alongside the other apps in `/srv/apps`.
- The container sits alone on its own network, `portfolio_default`. It is not attached to any other stack.

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | `nginx-unprivileged` pinned by digest, copies the three site files |
| `deploy/nginx.conf` | Serves on 8080, `/healthz`, `X-Origin: oci-portfolio` header; no gzip or access log (Caddy does both) |
| `compose.yaml` | Loopback port, read-only rootfs, all caps dropped, 64 MiB / 0.25 CPU / 64 pids, log rotation, healthcheck |
| `deploy/Caddyfile.snippet` | Site blocks to append to `/etc/caddy/Caddyfile` |
| `deploy/deploy.sh` | Pull, recreate, wait for healthy, automatic rollback |
| `.github/workflows/deploy.yml` | Build ARM64 image, push to GHCR, deploy by digest (manual trigger) |

## Manual deploy / update (build on the server)

From the repo root:

```bash
tar -c Dockerfile .dockerignore compose.yaml index.html script.js styles.css deploy/nginx.conf \
  | ssh ubuntu@129.146.74.225 'cd /srv/apps/portfolio && tar -x && docker compose up -d --build'
```

## Caddy

`deploy/Caddyfile.snippet` makes `weeksitsolutions.com` canonical and 301-redirects `www`. It adds gzip/zstd,
basic security headers and HSTS (`max-age=63072000`, no preload, no includeSubDomains). There is **no CSP**
because the page loads Google Fonts; add one only after testing.

Apply it only once DNS points at this server, to avoid failed ACME attempts:

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak
sudo tee -a /etc/caddy/Caddyfile < deploy/Caddyfile.snippet >/dev/null
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo systemctl reload caddy
```

Certificates are issued automatically on first request and stored under `/var/lib/caddy`.

## DNS (IONOS)

| Record | Host | Current (public DNS) | Required |
|--------|------|----------------------|----------|
| A | `@` | `216.198.79.1` (Vercel) | `129.146.74.225` |
| CNAME | `www` | `5fb0a757aedd5afa.vercel-dns-017.com` | `weeksitsolutions.com` (applied 2026-10-23) |

Leave untouched: NS, MX (Zoho), TXT (Zoho verification, SPF), and the `status`, `home`, `panel`, and `pack`
subdomains. Lower the TTL on the changed records beforehand to speed up a rollback. Check the IONOS dashboard
for records that public DNS can't show; there are no public AAAA records today.

**Rollback:** restore the two original records. Vercel keeps serving until then.

## Health, logs, status

```bash
docker ps --filter name=portfolio          # STATUS shows (healthy)
docker logs --tail 50 portfolio            # nginx errors (rotated: 3 x 5 MB)
curl -s http://127.0.0.1:8081/healthz      # on the server
sudo journalctl -u caddy -n 50 --no-pager  # access log and certificate events
```

## Automated deployment (prepared, not active)

`deploy.yml` builds `linux/arm64` in CI, pushes to `ghcr.io/nullps1/portfolio`, then SSHes in and passes the
image **digest** to `deploy/deploy.sh`. That script recreates the container and rolls back to the previous image
if it is not healthy within 60 s. A final step confirms `X-Origin: oci-portfolio` on the public site.

Required before enabling:

1. A dedicated SSH key for CI, installed in the server's `authorized_keys` with a forced command so it can
   do nothing but deploy:
   `command="/srv/apps/portfolio/deploy/deploy.sh",restrict ssh-ed25519 AAAA... ci-portfolio`
   Docker group membership is root-equivalent, so use a separate non-sudo user, not `ubuntu`.
2. Repo secrets `DEPLOY_SSH_KEY` and `DEPLOY_KNOWN_HOSTS` (output of `ssh-keyscan -t ed25519 <host>`),
   and repo variables `DEPLOY_HOST` and `DEPLOY_USER`.
3. A `production` environment with required reviewers.
4. The GHCR package set to public (the site is public), so the server needs no registry credentials.

## Rollback (container)

Automatic when a deploy is unhealthy. Manual: tag the previous image and redeploy it:

```bash
cd /srv/apps/portfolio
docker tag "$(cat .previous)" portfolio:rollback
./deploy/deploy.sh portfolio:rollback
```

## Open items

- UDP 443 is not allowed in iptables, so Caddy's HTTP/3 won't work; browsers fall back to HTTP/2.
- Whether the Oracle public IP is reserved can only be confirmed in the OCI console (Networking > Reserved public IPs).
- Uptime Kuma monitor "Portfolio (weeksitsolutions.com)" checks `https://weeksitsolutions.com/healthz` every 60 s and
  uses the same email notification as the other monitors. It was added directly to Kuma's database (backup in
  `/srv/backups/uptime-kuma/`); edit or pause it in the Kuma UI like any other.
- The final CI step only checks the public site after the deploy; it does not trigger a rollback. `deploy.sh`'s
  own health check is what rolls back.
- `deploy.sh` writes `.env` and runs `docker compose` in `/srv/apps/portfolio`, so the CI user needs write access to
  that directory and docker group membership. Neither is set up yet.
