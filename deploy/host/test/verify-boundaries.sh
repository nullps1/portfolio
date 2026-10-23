#!/usr/bin/env bash
# Proves the authorization boundaries of the CI deployment account AFTER install.sh has run.
# Read-only against production: it only calls `status`, and every other probe is expected to be refused.
#
#   bash verify-boundaries.sh HOST CI_PRIVATE_KEY_FILE [ADMIN_SSH_TARGET]
#
# HOST             Oracle address (e.g. 129.146.74.225)
# CI_PRIVATE_KEY   the CI private key (never printed)
# ADMIN_SSH_TARGET an admin login used for the host-side checks (default: ubuntu@HOST)
set -u
[ "$#" -ge 2 ] || {
  echo "usage: $0 HOST CI_PRIVATE_KEY_FILE [ADMIN_SSH_TARGET]" >&2
  exit 2
}
HOST="$1"
KEY="$2"
ADMIN="${3:-ubuntu@${HOST}}"
CI_USER="portfolio-deploy"
PASS=0
FAIL=0

ci() { ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes "${CI_USER}@${HOST}" "$@"; }
adm() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$ADMIN" "$@"; }
ok() {
  PASS=$((PASS + 1))
  printf 'PASS  %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"
}
expect_rc() { # name expected actual [detail]
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected rc $2, got $3 ${4:-}"; fi
}
refused() { # name command...: the command must fail
  local n="$1"
  shift
  if "$@" >/dev/null 2>&1; then bad "$n" "command succeeded"; else ok "$n"; fi
}
never_ran() { # name output: the output must not show a command ran
  if grep -q 'uid=' <<<"$2"; then bad "$1" "$2"; else ok "$1"; fi
}

echo "== through the CI key =="
out="$(ci status 2>&1)"
expect_rc "status is allowed" 0 "$?" "$out"

out="$(ci id 2>&1)"
expect_rc "arbitrary command 'id' is rejected by the program" 2 "$?"
never_ran "'id' did not execute" "$out"

out="$(ci 'deploy ghcr.io/nullps1/portfolio:latest' 2>&1)"
expect_rc "tag reference is rejected" 2 "$?"

out="$(ci 'status; id' 2>&1)"
expect_rc "shell metacharacters are rejected" 2 "$?"
never_ran "injection did not execute" "$out"

ssh -tt -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes "${CI_USER}@${HOST}" </dev/null >/dev/null 2>&1
expect_rc "no interactive shell (empty request is rejected)" 2 "$?"

refused "TCP forwarding is refused" ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 \
  -W 127.0.0.1:22 "${CI_USER}@${HOST}" </dev/null
refused "sftp/scp is refused" sftp -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 \
  "${CI_USER}@${HOST}" </dev/null
refused "password login is impossible" ssh -o PubkeyAuthentication=no \
  -o PreferredAuthentications=password,keyboard-interactive -o BatchMode=yes -o ConnectTimeout=15 \
  "${CI_USER}@${HOST}" true

echo "== host-side privilege boundaries (as admin) =="
groups_out="$(adm "id -nG ${CI_USER}" 2>&1)"
if grep -qE '(^| )(docker|sudo|adm|root)( |$)' <<<"$groups_out"; then
  bad "CI account has no privileged groups" "$groups_out"
else
  ok "CI account has no privileged groups (${groups_out})"
fi

sudo_out="$(adm "sudo -l -U ${CI_USER} 2>&1" | tr -s ' ')"
echo "      sudo -l:"
while IFS= read -r line; do echo "        ${line}"; done <<<"$sudo_out"
if grep -q 'portfolio-deploy ""' <<<"$sudo_out" && ! grep -q 'NOPASSWD: ALL' <<<"$sudo_out"; then
  ok "sudo allows only the program with zero arguments"
else
  bad "sudo allows only the program with zero arguments"
fi

refused "sudo refuses the program when arguments are supplied" adm "sudo -u ${CI_USER} sudo -n /usr/local/sbin/portfolio-deploy status"
refused "sudo refuses any other command" adm "sudo -u ${CI_USER} sudo -n /bin/true"
refused "no direct docker access" adm "sudo -u ${CI_USER} docker ps"
for target in /opt/portfolio-deploy/compose.yaml /usr/local/sbin/portfolio-deploy \
  /home/portfolio-deploy/.ssh/authorized_keys /etc/sudoers.d/portfolio-deploy; do
  refused "cannot write ${target}" adm "sudo -u ${CI_USER} sh -c 'echo x >> ${target}'"
done
for target in /var/lib/portfolio-deploy/state /var/log/portfolio-deploy.log; do
  refused "cannot read ${target}" adm "sudo -u ${CI_USER} cat ${target}"
done

echo "      ownership and modes:"
adm "stat -c '%U:%G %a %n' /usr/local/sbin/portfolio-deploy /opt/portfolio-deploy /opt/portfolio-deploy/compose.yaml /var/lib/portfolio-deploy /home/portfolio-deploy /home/portfolio-deploy/.ssh /home/portfolio-deploy/.ssh/authorized_keys /etc/sudoers.d/portfolio-deploy" 2>&1 |
  sed 's/^/        /'
if adm "sudo -n visudo -c" >/dev/null 2>&1; then ok "sudoers configuration is valid"; else bad "sudoers configuration is valid"; fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
