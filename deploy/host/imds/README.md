# OCI metadata guard

Containers on this host must not reach the OCI instance metadata service (`169.254.169.254`): the instance's
instance-principal credentials are served there. `pd-imds-guard` keeps three rules at the top of Docker's
`DOCKER-USER` chain (the rules that passed the supervised test; only the comment was renamed from `pd-imds-test` to `pd-imds-guard`, and no rule with the old comment exists on the host):

1. `-d 169.254.169.254/32 -p udp --dport 53 -j RETURN`
2. `-d 169.254.169.254/32 -p tcp --dport 53 -j RETURN`
3. `-d 169.254.169.254/32 -j REJECT --reject-with icmp-port-unreachable`

The host's own metadata and DNS access (the `OUTPUT` path) is not affected. The resolver of this VM is
`169.254.169.254`, which is why the two DNS exceptions precede the rejection.

## Design

| Concern | Decision |
|---|---|
| Source of rules | The script only. `/etc/iptables/rules.v4` is a stale Docker snapshot; `netfilter-persistent save` must never be run. |
| Boot order | `pd-imds-guard.service` runs after `netfilter-persistent` (its restore replaces the whole table) and before `docker.socket`, `docker.service` and `containerd`. `DefaultDependencies=no` is required: the implicit `After=basic.target` forms an ordering cycle with `Before=docker.socket`. |
| `DOCKER-USER` before Docker | `rules.v4` already declares `:DOCKER-USER` and `-A FORWARD -j DOCKER-USER`, so both exist before dockerd starts. If they did not, the script creates the chain and Docker adds the jump later; Docker creates the chain only when missing and does not flush it (documented behaviour; **proven only by the separately approved restart test**). |
| Docker restart | `PartOf=docker.service` re-runs the guard on `systemctl restart docker`; `WantedBy=docker.service` re-runs it on `stop` then `start`. No `ExecStop`: rules stay while Docker is down. |
| Drift | `pd-imds-guard-check.timer` (60 s) runs `verify --live \|\| apply`, which covers a direct `netfilter-persistent reload` that systemd cannot see. |
| Idempotence | `apply` is a no-op when correct; otherwise it deletes only the three exact rules and inserts them at positions 1-3. No flush, no restore, no other rule is read or modified. |
| Failure mode | **Fail-open for availability** (`Wants`): if the guard fails, Docker still starts and `systemctl --failed` / the 60 s timer show it. Fail-closed (`RequiredBy=docker.service`) was rejected: it couples a guard restart to a Docker restart (all containers, `live-restore=false`) and lets a guard fault block the whole host. |

## Known limits (not a hard boundary)

* Containers with `network_mode: host` and privileged containers bypass `DOCKER-USER`. None exist now.
* Anything holding `/var/run/docker.sock` (portainer rw, homepage) can start such a container. Treat those two as the larger risk.
* IPv4 only. If IPv6 is ever enabled on the VNIC/Docker networks, mirror the rules with `ip6tables` (OCI IMDS IPv6 endpoint `fd00:c1::a9fe:a9fe`).
* Repair (not the no-op path) removes and re-inserts the rules: metadata is reachable for a few milliseconds.
* `systemctl restart netfilter-persistent` flushes Docker's own chains (pre-existing hazard); the guard is re-applied, but restart Docker too.
* IAM least privilege in the OCI console remains the real fix; this only removes the network path.

## Runbook (everything below the install step needs explicit approval)

### 1. Install (files only; no reload, enable, start or firewall change)

```bash
cd <directory with the reviewed copies>
sudo ./install-imds-guard.sh
sudo /usr/local/sbin/pd-imds-guard status          # read-only: prints the (still empty) chain
```

### 2. Pre-activation checks (read-only)

```bash
sudo ./test-pd-imds-guard.sh /usr/local/sbin/pd-imds-guard    # private network namespace; host untouched
sudo systemctl daemon-reload                                    # approval-gated: reloads unit files, restarts nothing
sudo systemd-analyze verify multi-user.target docker.socket docker.service containerd.service \
  netfilter-persistent.service pd-imds-guard.service pd-imds-guard-check.timer 2>&1 | grep -iE 'cycle|deleted' || echo "no cycle"
sudo iptables-save > /root/pd-guard-pre-$(date -u +%Y%m%dT%H%M%SZ).rules      # record only, never restored
docker ps --format '{{.Names}} {{.Status}} {{.HostConfig.NetworkMode}}' 2>/dev/null || docker ps --format '{{.Names}} {{.Status}}'
update-alternatives --query iptables | grep -E '^Value'          # must be the nft variant
```

### 3. Activation, with an automatic timed rollback (does not restart Docker)

```bash
sudo systemd-run --unit=pd-imds-guard-rollback --on-active=15min --collect \
  /bin/sh -c 'systemctl disable --now pd-imds-guard-check.timer; systemctl stop pd-imds-guard-check.service; /usr/local/sbin/pd-imds-guard remove; systemctl disable pd-imds-guard.service pd-imds-guard-check.timer'
sudo systemctl enable pd-imds-guard.service pd-imds-guard-check.timer     # creates symlinks; starts nothing
sudo systemctl start pd-imds-guard.service                               # applies the three rules now
sudo /usr/local/sbin/pd-imds-guard verify --live
sudo iptables -S DOCKER-USER
sudo systemctl start pd-imds-guard-check.timer                           # only AFTER the probes below pass, so a timer repair cannot mask a guard fault
systemctl --failed --no-pager; systemctl list-timers pd-imds-guard-check.timer --no-pager
```

Fail-open window: only if the guard fails at boot or its repair fails; it is bounded by `systemctl --failed`
and the timer (first check 30 s after boot, then every 60 s).

Renaming the tag later (the script, unit and rules share the literal `pd-imds-guard`) requires running
`pd-imds-guard remove` with the OLD script first, otherwise the old rules are orphaned.

Then the non-disruptive checks used in the supervised test (disposable `--pull never` probes, no credential
endpoints): TCP connect to `169.254.169.254:80` refused, container DNS still resolves, host DNS and a
non-credential host metadata path still work, all seven containers unchanged, `/healthz` 200 with
`X-Origin: oci-portfolio`. When satisfied: `sudo systemctl stop pd-imds-guard-rollback.timer`.

### 4. Rollback (order matters: stop the timer first, or it re-applies the rules within 60 s)

```bash
sudo systemctl disable --now pd-imds-guard-check.timer
sudo systemctl stop pd-imds-guard-check.service      # waits for a run in progress
systemctl is-active pd-imds-guard-check.timer        # must print: inactive
sudo /usr/local/sbin/pd-imds-guard remove            # deletes only the three tagged rules, REJECT first
sudo systemctl disable --now pd-imds-guard.service   # no ExecStop, so this removes only the symlinks
sudo iptables -S DOCKER-USER                         # back to: -N DOCKER-USER
# optional full removal: rm /etc/systemd/system/pd-imds-guard* /usr/local/sbin/pd-imds-guard && systemctl daemon-reload
```

### 5. Later, separately approved tests (these interrupt services)

* `systemctl restart docker`, then `systemctl stop docker; systemctl start docker`: expect the guard's start time before Docker's, one `FORWARD` jump, exactly three tagged rules, `verify --live` passing.
* Reboot: `journalctl -b -g 'ordering cycle'` empty; `systemctl show -p ActiveEnterTimestamp pd-imds-guard docker.socket docker containerd` shows the guard first; `verify --live` passing; repeat the container probes.
