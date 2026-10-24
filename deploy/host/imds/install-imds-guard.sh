#!/bin/bash
# Copies the reviewed OCI-metadata guard onto the host as root-owned files. It does NOT run daemon-reload, enable
# or start anything and never touches the firewall, Docker or any container: activation is a separate step
# (see README.md). Run as root from the directory that holds the reviewed copies:
#
#   sudo ./install-imds-guard.sh
set -Eeuo pipefail
umask 022
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$(id -u)" -eq 0 ] || {
  echo "ERROR: run as root" >&2
  exit 1
}
for f in pd-imds-guard pd-imds-guard.service pd-imds-guard-check.service pd-imds-guard-check.timer; do
  [ -f "${HERE}/${f}" ] || {
    echo "ERROR: missing ${HERE}/${f}" >&2
    exit 1
  }
done
bash -n "${HERE}/pd-imds-guard"
install -o root -g root -m 0755 "${HERE}/pd-imds-guard" /usr/local/sbin/pd-imds-guard
for u in pd-imds-guard.service pd-imds-guard-check.service pd-imds-guard-check.timer; do
  install -o root -g root -m 0644 "${HERE}/${u}" "/etc/systemd/system/${u}"
done
sha256sum /usr/local/sbin/pd-imds-guard /etc/systemd/system/pd-imds-guard*.service /etc/systemd/system/pd-imds-guard-check.timer
echo "Installed (inactive). No daemon-reload, enable, start, or firewall change was made."
