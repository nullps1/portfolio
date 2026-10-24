# Deployment (Oracle Cloud)

The site is static HTML/CSS/JS served by an unprivileged nginx container on the Oracle VM, behind the
host's existing Caddy, which terminates TLS.

```
Internet -> Oracle IP :80/:443 -> host Caddy (systemd) -> 127.0.0.1:8081 -> portfolio container (nginx :8080)
```

**Releases go GitHub Actions -> GHCR -> Oracle, and only that way.** The first release through this path was
workflow run 40122021217 on 2026-10-24 (commit `40626f0`, image
`ghcr.io/nullps1/portfolio@sha256:898d0f85e3fd3a5c8f701505d6b23fa0e4cfe1218e4753dab23c9c7217d1a09e`).

## Releasing a change (the supported workflow)

1. Merge or push the change to `main`. Pushing does **not** deploy: the Deploy workflow has no push trigger.
2. Run `tests/check-site.mjs` locally (see `WEBSITE.md`), then start the workflow:
   `gh workflow run deploy.yml --ref main` (or Actions > Deploy > Run workflow, branch `main`).
3. The `build` job pushes `ghcr.io/nullps1/portfolio:sha-<commit>` for `linux/arm64` and records the immutable digest.
   Check the digest, architecture and `org.opencontainers.image.revision` label against the commit.
4. The `deploy` job waits for the **Production** environment. The reviewer approves it in the GitHub UI. Nothing on
   the server changes before that.
5. After approval the job calls `portfolio-deploy deploy <digest>` over the restricted SSH key, then verifies the
   public site. On any failure it rolls back automatically and the job fails.
6. Confirm afterwards: the job is green, `sudo /usr/local/sbin/portfolio-deploy status` shows `current=<digest>`,
   `last_result=deployed`, and `https://weeksitsolutions.com/healthz` returns 200 with `X-Origin: oci-portfolio`.

Do not run `docker compose` against the portfolio container by hand, do not build images on the server, and do not
copy site files onto the host. See "Legacy manual deployment (retired)".

## Server (verified 2026-10-22, updated 2026-10-24)

- Ubuntu 24.04 ARM64 (2 vCPU, 11 GiB RAM shared with Minecraft), Docker 29.x, Compose v5.
- Caddy 2.6.2 runs on the host (not in Docker) and owns ports 80/443. Its config is `/etc/caddy/Caddyfile`.
  Host Caddy cannot join Docker networks, so the container publishes to **loopback only**
  (`127.0.0.1:8081`), the same convention as homepage, uptime-kuma, and portainer.
- The portfolio container is a Compose project named `portfolio` whose compose file is the root-owned
  `/opt/portfolio-deploy/compose.yaml`. The other apps live in `/srv/apps`; `/srv/apps/portfolio` is a retired
  legacy directory and is not used by any release.
- The container sits alone on its own network, `portfolio_default`. It is not attached to any other stack.
- The GHCR package `ghcr.io/nullps1/portfolio` is **public**; the host pulls anonymously and stores no registry
  credentials.
- Containers cannot reach the OCI instance metadata service: see "Metadata firewall guard".

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | `nginx-unprivileged` pinned by digest; copies the page files, `robots.txt`, `favicon.svg` and `assets/`. Used by the CI build. New site files must be added to its `COPY` lines or they are not shipped. |
| `deploy/nginx.conf` | Serves on 8080, `/healthz`, `X-Origin: oci-portfolio` header; no gzip or access log (Caddy does both) |
| `compose.yaml` | Build-from-source file for **local experiments only**. Never use it on the Oracle host: it uses the same project and container name as production. |
| `deploy/Caddyfile.snippet` | Reference copy of the site blocks applied to `/etc/caddy/Caddyfile` |
| `deploy/host/portfolio-deploy` | The privileged deploy/rollback program installed on the host (see "Automated deployment") |
| `deploy/host/compose.yaml` | Root-owned production compose file used only by that program: loopback port, `user: 101:101`, read-only rootfs, all caps dropped, 64 MiB / 0.25 CPU / 64 pids, log rotation, healthcheck |
| `deploy/host/install.sh` | One-time, idempotent provisioning of the CI account, sudoers rule, program and state directories |
| `deploy/host/test/run-tests.sh` | Sandboxed tests of the program with mocked docker/curl (no root, no real containers) |
| `deploy/host/test/verify-boundaries.sh` | Post-provisioning proof that the CI account can do nothing but deploy |
| `deploy/host/imds/` | The metadata firewall guard: script, systemd units, installer, tests and runbook (see its `README.md`) |
| `.github/workflows/deploy.yml` | Build ARM64 image, push to GHCR, approved deploy by digest, verify, roll back (manual trigger only) |
| `.github/dependabot.yml` | Weekly update PRs for the SHA-pinned actions |

## Caddy

`deploy/Caddyfile.snippet` makes `weeksitsolutions.com` canonical and 301-redirects `www`. It adds gzip/zstd,
basic security headers and HSTS (`max-age=63072000`, no preload, no includeSubDomains). There is **no CSP header**;
the page carries a restrictive CSP `<meta>` tag instead (fonts are self-hosted). A header is preferable because it also
allows `frame-ancestors`; add one after testing.

The snippet is already applied on the host. To re-apply it on a fresh server, do it only once DNS points at that
server, to avoid failed ACME attempts:

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak
sudo tee -a /etc/caddy/Caddyfile < deploy/Caddyfile.snippet >/dev/null
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo systemctl reload caddy
```

Certificates are issued automatically on first request and stored under `/var/lib/caddy`.

## DNS (IONOS)

| Record | Host | Value |
|--------|------|-------|
| A | `@` | `129.146.74.225` |
| CNAME | `www` | `weeksitsolutions.com` |

The site moved from Vercel to this server on 2026-10-23 and Vercel has since been retired. Leave untouched:
NS, MX (Zoho), TXT (Zoho verification, SPF), and the `status`, `home`, `panel`, and `pack` subdomains.
There are no AAAA records; add one only if the server gets IPv6 and Caddy is verified on it.

**Rollback:** there is no DNS fallback any more. Roll back the site by redeploying a previous image
(see "Rollback" below), or restore `/etc/caddy/Caddyfile.pre-portfolio` if a Caddy change is at fault.

## Health, logs, status

```bash
sudo /usr/local/sbin/portfolio-deploy status    # current / previous release, last result, running image and health
sudo tail -n 40 /var/log/portfolio-deploy.log   # one line per deploy decision (root:adm)
docker ps --filter name=portfolio               # STATUS shows (healthy)
docker logs --tail 50 portfolio                 # nginx errors (rotated: 3 x 5 MB)
curl -s http://127.0.0.1:8081/healthz           # on the server
sudo journalctl -u caddy -n 50 --no-pager       # access log and certificate events
```

## Automated deployment (in production use since 2026-10-24)

```
workflow_dispatch (main only)
  build job  : ARM64 image -> ghcr.io/nullps1/portfolio@sha256:<digest>      (packages: write, no deploy secrets)
  deploy job : environment "Production" (reviewer approval) -> ssh -> sudo -> portfolio-deploy
               -> verify public + origin -> on failure: rollback via the same entry point
```

### Why this shape

The CI account must not be able to do anything except ask for a deployment. Docker group membership is
root-equivalent, so the account has **no** groups. A forced SSH command alone is not an authorization boundary,
so the boundary is a root-owned program that re-validates every request itself:

| Component | Owner / mode | Role |
|-----------|--------------|------|
| `/usr/local/sbin/portfolio-deploy` | root:root 0755 | The only code that touches Docker. Fixed container, project, compose file, image repo. |
| `/opt/portfolio-deploy/compose.yaml` | root:root 0644 (dir 0755) | Production compose file; no `build:`, the image comes from a validated digest. |
| `/var/lib/portfolio-deploy/` | root:root 0700 | State (`state`), lock, and an empty Docker config directory. The program exports `DOCKER_CONFIG` to it and sets `HOME=/root`, so registry pulls are always anonymous and no caller or root login credentials are picked up. |
| `/var/log/portfolio-deploy.log` | root:adm 0640 | One line per decision; contains no credentials. Rotated weekly. |
| `/etc/sudoers.d/portfolio-deploy` | root:root 0440 | `portfolio-deploy ALL=(root) NOPASSWD: /usr/local/sbin/portfolio-deploy ""` (zero arguments) plus `env_keep` of `SSH_ORIGINAL_COMMAND` only. |
| `/home/portfolio-deploy/.ssh/authorized_keys` | root:root 0644 (home and `.ssh` root-owned) | `restrict,command="/usr/bin/sudo -n /usr/local/sbin/portfolio-deploy" ssh-ed25519 ...` |
| user `portfolio-deploy` | no groups, locked password, shell `/bin/sh` | Cannot edit its own SSH config, its home, or any file the program trusts. |

`restrict` disables PTY, port/agent/X11 forwarding and `~/.ssh/rc`. `sshd_config` is not modified
(`PasswordAuthentication no` is already global).

The program accepts exactly three requests (via `SSH_ORIGINAL_COMMAND`, or as arguments when run by root):

```
status
deploy   ghcr.io/nullps1/portfolio@sha256:<64 lowercase hex>
rollback ghcr.io/nullps1/portfolio@sha256:<64 lowercase hex>    # the release expected to be live
```

Anything else is rejected before any side effect (exit 2): tags, other repositories or registries, uppercase,
whitespace tricks, shell metacharacters, newlines, extra arguments, requests over 160 characters.

Exit codes: `0` ok, `2` bad request, `10` deploy failed and the previous release was restored, `11` the restore or
rollback ALSO failed (the site may be down), `12` image refused or not pullable (nothing changed), `20` rollback not
applicable (that release is not live), `21` no authorized rollback target, `75` another deployment is running,
`77` not root or a trust check failed, `78` state file invalid, `79` state could not be written (the old state is kept
and the next run reconciles).

On every run it first checks that the program, `/opt/portfolio-deploy`, the compose file, and the state
directory are owned by root, not group/world-writable, and not symlinks; otherwise it refuses (exit 77). It never
executes anything from `/srv/apps` or a repository checkout.

**Deploy:** take the lock (`flock`; a second caller gets exit 75), reconcile any interrupted run, pull the digest
anonymously, require `linux/arm64` and the label `org.opencontainers.image.source=https://github.com/nullps1/portfolio`,
record `pending`, then `docker compose up --no-build --pull never --force-recreate --no-deps portfolio`. It then
requires the container to be `healthy`, the local origin to return 200 with `X-Origin: oci-portfolio`, and the running
image to match the request. Any failure restores the previous release and exits 10 (or 11 if the restore also
failed). Only the `portfolio` service is ever recreated. The program ignores SIGHUP/SIGPIPE so a dropped SSH
session cannot leave a half-done switch. A previous release that is a bare image ID (the bootstrap image) is handed
to Compose through a local tag, `portfolio-rollback:id-<12 hex>`, created just before use, so Compose never has to
interpret `sha256:<id>` as a repository name. Pull and Compose errors are written to the root-only log.

**Rollback:** `rollback <digest>` only acts if `<digest>` is still the live release, so it can never replace a
newer successful release (otherwise exit 20). The target is the `previous` release recorded in root-only state and
it must appear in the recorded history (exit 21 otherwise). After a rollback `previous` is cleared, so repeating
it cannot flip back to the rejected release. State is rewritten atomically; a `pending` marker lets the next run
detect an interrupted transition and either adopt a release that came up healthy or restore the last good one.

### Workflow behavior

1. `build` pushes `ghcr.io/nullps1/portfolio:sha-<commit>` and outputs the immutable digest. No SSH secrets exist here.
2. `deploy` waits for Production-environment approval, loads the environment secrets, and calls `deploy <digest>`.
3. `verify` checks `https://weeksitsolutions.com/healthz` for HTTP 200, valid TLS (1.2 or newer), and
   `X-Origin: oci-portfolio`, both through public DNS and pinned to the Oracle IP with `--resolve`. It needs 3
   consecutive passes within 12 attempts.
4. If `deploy` or `verify` fails (or is cancelled) the `rollback` step calls `rollback <digest>`, then re-runs
   verification. It waits and retries while the host reports it is still busy (exit 75), and it is skipped when
   the deploy was a no-op ("already deployed"), because a failed public check then is not caused by this release.
   The job **fails** whenever deploy or verify failed, even if the rollback succeeded, and it fails
   loudly if the rollback itself does not complete or the site is still unhealthy afterwards.
5. `DEPLOY_HOST` must be an IPv4 literal (curl `--resolve` pins to it) and `DEPLOY_USER` a plain account name; both
   are validated before they are written into the SSH config.

### Provisioning record (completed 2026-10-23/24)

This was done once and is kept as the procedure for rebuilding the host or the GitHub side from scratch.

1. On the host, as an admin: copy `deploy/host/{install.sh,portfolio-deploy,compose.yaml}` and run
   `sudo ./install.sh --pubkey-file ci_key.pub`. It creates the account, files, and sudoers rule, validating the
   sudoers file with `visudo` before installing it. It accepts only a plain one-line `ssh-ed25519` key (verified
   with `ssh-keygen`; only the key type and blob are kept) and refuses to adopt a pre-existing
   `portfolio-deploy` account that owns any files.
2. Run `deploy/host/test/verify-boundaries.sh <host> <ci_key>` and require 0 failures (24 checks passed on this host).
3. GitHub, on the `Production` environment: required reviewer, deployment branch policy `main`, admin bypass
   off. Self-review: with a single maintainer, leave "prevent self-review" **off**, otherwise no run can ever be
   approved.
4. Environment **secrets** `DEPLOY_SSH_KEY` (CI private key) and `DEPLOY_KNOWN_HOSTS` (the host's ed25519 key line,
   read from `/etc/ssh/ssh_host_ed25519_key.pub`, not from `ssh-keyscan`); environment **variables**
   `DEPLOY_HOST=129.146.74.225` and `DEPLOY_USER=portfolio-deploy`. Delete the private key from the workstation
   after upload.
5. The GHCR package must be **public** because the host pulls anonymously; a private package would need a registry
   token stored on the host, which is avoided. On a brand-new package: start the workflow, let `build` finish and
   push, set the package to public in the package settings, then approve the waiting `deploy` job. The inspection
   that preceded the first release checked the image anonymously: architecture, user `101`, healthcheck, labels, and
   that the three added layers contain only the expected files.
6. Install `logrotate` (`sudo apt install logrotate`); the rotation file `install.sh` writes is inert without it.
7. Run the first deploy supervised, with the Uptime Kuma monitor open. Expect a few seconds of downtime while
   Compose recreates the container (it adopts the existing `portfolio` container: same project, service and
   container name, same `portfolio_default` network).

The program bootstraps its state from the container that is running when it is first invoked. On this host the
pre-pipeline image (`sha256:a8f0660e…`, kept locally as `portfolio-rollback:id-a8f0660e012b`) became the first
rollback target.

## Rollback

Automatic as described above. Manual, from an admin shell on the host (the same validated path):

```bash
sudo /usr/local/sbin/portfolio-deploy status
sudo /usr/local/sbin/portfolio-deploy rollback ghcr.io/nullps1/portfolio@sha256:<currently-live-digest>
```

Caddy-level problem: restore `/etc/caddy/Caddyfile.pre-portfolio` and `sudo systemctl reload caddy`.

## Metadata firewall guard

Containers must not reach the OCI instance metadata service (`169.254.169.254`). The guard keeps three rules at the
top of `DOCKER-USER` (UDP/TCP 53 to that address are allowed, everything else is rejected) through a systemd unit
ordered after `netfilter-persistent` and before Docker, plus a 60-second repair timer. Design, tests, runbook and
rollback are in [`deploy/host/imds/README.md`](../deploy/host/imds/README.md). Check it with
`sudo /usr/local/sbin/pd-imds-guard verify --live` and `systemctl --failed`. Never run `netfilter-persistent save`
on this host: its snapshot is stale and would persist outdated Docker rules.

## Legacy manual deployment (retired)

Before the pipeline, the site was built on the server from `/srv/apps/portfolio` with `docker compose up -d --build`
(files copied with `tar | ssh`), and `deploy.sh` swapped images using the admin account's Docker-group rights, with its
own rollback bookkeeping in `.previous`. **None of this is supported any more.**

- `/srv/apps/portfolio` still exists on the host as an obsolete copy (old site files, its own `compose.yaml`,
  `deploy/deploy.sh`, `.env`, `.previous`). Nothing reads it and no container mounts it.
- Danger: that directory's `compose.yaml` has the **same Compose project name and container name** (`portfolio`) as
  the production project. Running `docker compose up` there would recreate the production container from an old
  image, without updating the deploy program's recorded state or its rollback target.
- The same applies to building images on the server and to `docker run` / `docker rm` on the `portfolio` container.
- The directory is scheduled for removal after review; see the cleanup inventory kept with the maintainer. Until it
  is removed, treat it as read-only history.

## Removing the pipeline

`sudo rm /etc/sudoers.d/portfolio-deploy`, `sudo userdel -r portfolio-deploy`, then remove
`/usr/local/sbin/portfolio-deploy`, `/opt/portfolio-deploy`, `/var/lib/portfolio-deploy`, and the environment
secrets. The running container is left as is. Doing this without a replacement leaves the site with no supported
way to release.

## Open items

- UDP 443 is not allowed in iptables, so Caddy's HTTP/3 won't work; browsers fall back to HTTP/2.
- Whether the Oracle public IP is reserved can only be confirmed in the OCI console (Networking > Reserved public IPs).
- OCI IAM: the instance-principal credentials are no longer reachable from containers, but whether the instance's
  dynamic group has any policy attached can only be checked in the OCI console (Identity > Domains > Dynamic groups,
  Policies). Least privilege there is the real fix.
- Uptime Kuma monitor "Portfolio (weeksitsolutions.com)" checks `https://weeksitsolutions.com/healthz` every 60 s and
  uses the same email notification as the other monitors. It was added directly to Kuma's database (backup in
  `/srv/backups/uptime-kuma/`); edit or pause it in the Kuma UI like any other.
- GitHub-hosted runner IP ranges are too broad to restrict the CI key with `from=`; the key's only power is
  to run the validating program.
- Nothing alerts on a failed guard timer or a failed deploy outside GitHub and `systemctl --failed`.

### Accepted residual risks (from the independent review)

- **Image provenance is label-deep.** The program verifies the digest, `linux/arm64`, and the `source` label, which
  anyone able to push to the GHCR package can set. A CI-key holder can also redeploy any older digest. The blast
  radius is bounded (user 101, all capabilities dropped, read-only rootfs, no-new-privileges, loopback port, memory
  and pid limits), but a malicious image could serve arbitrary content on the site. Stronger fixes: verify a
  cosign/GitHub attestation bound to this repo's `main` workflow, or keep an allowlist of CI-registered digests.
- **Container egress is otherwise unrestricted** on the default bridge (internet, host services bound to 0.0.0.0).
  Only the metadata service is blocked, by the guard above. Containers that use `network_mode: host`, and anything
  holding `docker.sock` (portainer, homepage), bypass it.
- **Rollback images accumulate.** One `portfolio-rollback:id-*` tag is kept per previous bootstrap image; prune old
  ones by hand with `docker image rm`, and never the current or the recorded previous release.
- **Tested with mocks, then in production.** `run-tests.sh` mocks `docker` and `curl` and patches the program's path
  and timing constants. The real sudo/SSH path, the Compose adoption of the existing container, and real healthcheck
  timing were first exercised by `verify-boundaries.sh` and the supervised first deployment (2026-10-24).
