#!/bin/bash
# Provisions the restricted CI deployment path on the Oracle host. Run as root, from a directory
# holding the reviewed copies of portfolio-deploy and compose.yaml:
#
#   sudo ./install.sh --pubkey-file /path/to/ci_key.pub
#
# Idempotent. It never touches sshd_config, Caddy, other containers, or the docker group.
# The public key file must contain exactly one `ssh-ed25519 AAAA... comment` line.
set -Eeuo pipefail
umask 022
export LC_ALL=C

readonly CI_USER="portfolio-deploy"
readonly CI_HOME="/home/${CI_USER}"
readonly PROGRAM="/usr/local/sbin/portfolio-deploy"
readonly DEPLOY_DIR="/opt/portfolio-deploy"
readonly STATE_DIR="/var/lib/portfolio-deploy"
readonly LOG_FILE="/var/log/portfolio-deploy.log"
readonly SUDOERS_FILE="/etc/sudoers.d/portfolio-deploy"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HERE

die() {
  echo "ERROR: $*" >&2
  exit 1
}
[ "$(id -u)" -eq 0 ] || die "run as root"
[ "${1:-}" = "--pubkey-file" ] && [ -n "${2:-}" ] && [ "$#" -eq 2 ] || die "usage: install.sh --pubkey-file PATH"
[ -f "$2" ] || die "public key file not found"
[ "$(wc -l <"$2")" -le 1 ] || die "public key file must contain exactly one line"
KEY_LINE="$(tr -d '\r' <"$2" | head -n1)"
# An ed25519 blob is 68 base64 characters (the 20-character type prefix + the 4-byte length + 32 key bytes).
[[ $KEY_LINE =~ ^ssh-ed25519\ AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+/]{43}(\ [A-Za-z0-9._@:-]{1,64})?$ ]] ||
  die "not a plain ssh-ed25519 public key (no options, one line)"
ssh-keygen -lf "$2" 2>/dev/null | grep -q '(ED25519)$' || die "ssh-keygen does not accept this as an ED25519 public key"
# Keep only the key type and blob; the authorized_keys comment is ours.
KEY_LINE="$(awk '{print $1 " " $2 " ci-portfolio-deploy"}' <<<"$KEY_LINE")"
for f in portfolio-deploy compose.yaml; do [ -f "${HERE}/${f}" ] || die "missing ${HERE}/${f}"; done
command -v visudo >/dev/null || die "visudo not found"

echo "==> Program and compose file (root-owned, not writable by anyone else)"
install -d -o root -g root -m 0755 "$DEPLOY_DIR"
install -o root -g root -m 0644 "${HERE}/compose.yaml" "${DEPLOY_DIR}/compose.yaml"
install -o root -g root -m 0755 "${HERE}/portfolio-deploy" "$PROGRAM"

echo "==> State, lock, log (root only)"
install -d -o root -g root -m 0700 "$STATE_DIR" "${STATE_DIR}/docker-config"
if [ ! -e "$LOG_FILE" ]; then install -o root -g adm -m 0640 /dev/null "$LOG_FILE"; fi
cat >/etc/logrotate.d/portfolio-deploy <<'EOF'
/var/log/portfolio-deploy.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    create 0640 root adm
}
EOF

echo "==> Account ${CI_USER} (no password, no groups, root-owned home so it cannot alter its own SSH config)"
if id "$CI_USER" >/dev/null 2>&1; then
  # Never adopt an account we did not create: files it owns (cli-plugins, ~/.curlrc, authorized_keys2, ...)
  # could be turned into code that runs with the program's privileges.
  if [ -d "$CI_HOME" ] && [ -n "$(find "$CI_HOME" -mindepth 1 -not -user root -print -quit)" ]; then
    die "account ${CI_USER} already exists and owns files under ${CI_HOME}; inspect and clean it manually"
  fi
else
  useradd --system --user-group --home-dir "$CI_HOME" --create-home --shell /bin/sh "$CI_USER"
  chown -R root:root "$CI_HOME" # the skeleton files copied in belong to the new user until now
fi
passwd -l "$CI_USER" >/dev/null
chown root:root "$CI_HOME"
chmod 0755 "$CI_HOME"
install -d -o root -g root -m 0755 "${CI_HOME}/.ssh"
rm -f "${CI_HOME}/.bashrc" "${CI_HOME}/.profile" "${CI_HOME}/.bash_profile" "${CI_HOME}/.bash_logout" \
  "${CI_HOME}/.ssh/authorized_keys2"
printf 'restrict,command="/usr/bin/sudo -n %s" %s\n' "$PROGRAM" "$KEY_LINE" >"${CI_HOME}/.ssh/authorized_keys"
chown root:root "${CI_HOME}/.ssh/authorized_keys"
chmod 0644 "${CI_HOME}/.ssh/authorized_keys"

echo "==> sudoers: exactly one program, exactly zero arguments"
TMP="$(mktemp)"
cat >"$TMP" <<EOF
# Managed by deploy/host/install.sh
Defaults:${CI_USER} env_keep += "SSH_ORIGINAL_COMMAND"
Defaults:${CI_USER} !requiretty
${CI_USER} ALL=(root) NOPASSWD: ${PROGRAM} ""
EOF
visudo -cf "$TMP" >/dev/null || {
  rm -f "$TMP"
  die "sudoers validation failed; nothing installed"
}
install -o root -g root -m 0440 "$TMP" "$SUDOERS_FILE"
rm -f "$TMP"
visudo -c >/dev/null

echo "==> Read-only checks"
id "$CI_USER"
command -v logrotate >/dev/null || echo "WARNING: logrotate is not installed; ${LOG_FILE} will not be rotated (apt install logrotate)"
if [ -n "$(find "$CI_HOME" -mindepth 1 -not -user root -print -quit)" ]; then die "files under ${CI_HOME} are not root-owned"; fi
echo "docker group members: $(getent group docker | cut -d: -f4)"
sshd -T -C "user=${CI_USER},host=localhost,addr=127.0.0.1" 2>/dev/null |
  grep -E '^(passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitrootlogin) ' || true
echo "Done. Host key to pin:"
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
