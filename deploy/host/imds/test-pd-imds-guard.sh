#!/bin/bash
# Exercises pd-imds-guard against the real iptables inside a PRIVATE network namespace, so the host firewall is
# never touched. Run as root:  sudo ./test-pd-imds-guard.sh ./pd-imds-guard
# It re-executes itself under `unshare -n` and refuses to run if it shares the init network namespace.
set -u
GUARD="${1:-}"
[ -x "$GUARD" ] || {
  echo "usage: $0 PATH_TO_pd-imds-guard" >&2
  exit 2
}
GUARD="$(readlink -f "$GUARD")"
if [ "${PD_TEST_INNER:-}" != 1 ]; then
  [ "$(id -u)" -eq 0 ] || {
    echo "run as root" >&2
    exit 2
  }
  PD_TEST_INNER=1 PD_IMDS_LOCK="$(mktemp -u /tmp/pd-guard-test-lock.XXXXXX)" exec unshare -n -- "$0" "$GUARD"
fi
# Safety: never run against the host's namespace.
[ "$(readlink /proc/self/ns/net)" != "$(readlink /proc/1/ns/net)" ] || {
  echo "REFUSING: shares the host network namespace" >&2
  exit 3
}

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  echo "PASS  $1"
}
bad() {
  FAIL=$((FAIL + 1))
  echo "FAIL  $1"
}
check() { # name expected-rc command...
  local n="$1" want="$2"
  shift 2
  "$@" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$n"; else bad "$n (rc=$rc, wanted $want)"; fi
}
reset() { # fresh namespace state shaped like Docker's: chain + jump + a foreign rule in each place
  iptables -F
  iptables -X 2>/dev/null
  iptables -N DOCKER-USER
  iptables -N DOCKER-FORWARD
  iptables -A FORWARD -j DOCKER-USER
  iptables -A FORWARD -j DOCKER-FORWARD
  iptables -A DOCKER-FORWARD -s 172.22.0.0/16 -j ACCEPT
}
foreign() { iptables-save | grep -v 'pd-imds-guard' | grep -vE '^(#|:)'; }
tagged() { iptables-save | grep -c 'pd-imds-guard'; }
g() { "$GUARD" "$@"; }

echo "== empty chain =="
reset
check "verify fails before apply" 1 g verify
check "apply succeeds" 0 g apply
check "verify passes" 0 g verify
check "verify --live passes (jump present)" 0 g verify --live
[ "$(tagged)" -eq 3 ] && ok "exactly 3 tagged rules" || bad "tagged rules: $(tagged)"
iptables -S DOCKER-USER | grep -- '--comment pd-imds-guard' | sed -n '1p;2p;3p' | tr '\n' '|' | grep -q 'RETURN.*RETURN.*REJECT' && ok "order RETURN, RETURN, REJECT" || bad "order"

echo "== idempotence =="
before="$(iptables-save | grep -v '^#')"
check "second apply succeeds" 0 g apply
[ "$(iptables-save | grep -v '^#')" = "$before" ] && ok "second apply changed nothing (byte-identical)" || bad "second apply changed rules"

echo "== chain created when missing (boot without rules.v4 snapshot) =="
iptables -F; iptables -X
iptables -N DOCKER-FORWARD 2>/dev/null; iptables -A FORWARD -j DOCKER-FORWARD
check "apply creates DOCKER-USER" 0 g apply
check "verify passes" 0 g verify
check "verify --live fails until Docker adds the jump" 1 g verify --live
iptables -I FORWARD -j DOCKER-USER
check "verify --live passes once jump exists" 0 g verify --live

echo "== other rules are preserved =="
reset
iptables -A DOCKER-USER -s 10.99.0.0/24 -j DROP
iptables -A DOCKER-USER -j RETURN
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
f0="$(foreign)"
g apply >/dev/null 2>&1
[ "$(foreign)" = "$f0" ] && ok "apply left every foreign rule untouched" || bad "foreign rules changed by apply"
check "verify passes with foreign rules around" 0 g verify
g remove >/dev/null 2>&1
[ "$(foreign)" = "$f0" ] && ok "remove left every foreign rule untouched" || bad "foreign rules changed by remove"
[ "$(tagged)" -eq 0 ] && ok "remove deleted all tagged rules" || bad "tagged rules remain"
check "remove is idempotent" 0 g remove

echo "== repair of damaged states (never leaves REJECT before DNS) =="
for state in only-reject dns-missing-udp reversed duplicated flushed; do
  reset
  case "$state" in
    only-reject) iptables -A DOCKER-USER -d 169.254.169.254/32 -m comment --comment pd-imds-guard -j REJECT --reject-with icmp-port-unreachable ;;
    dns-missing-udp)
      iptables -A DOCKER-USER -d 169.254.169.254/32 -p tcp --dport 53 -m comment --comment pd-imds-guard -j RETURN
      iptables -A DOCKER-USER -d 169.254.169.254/32 -m comment --comment pd-imds-guard -j REJECT --reject-with icmp-port-unreachable ;;
    reversed)
      iptables -A DOCKER-USER -d 169.254.169.254/32 -m comment --comment pd-imds-guard -j REJECT --reject-with icmp-port-unreachable
      iptables -A DOCKER-USER -d 169.254.169.254/32 -p udp --dport 53 -m comment --comment pd-imds-guard -j RETURN
      iptables -A DOCKER-USER -d 169.254.169.254/32 -p tcp --dport 53 -m comment --comment pd-imds-guard -j RETURN ;;
    duplicated) g apply >/dev/null 2>&1; iptables -A DOCKER-USER -d 169.254.169.254/32 -p udp --dport 53 -m comment --comment pd-imds-guard -j RETURN ;;
    flushed) g apply >/dev/null 2>&1; iptables -F DOCKER-USER ;;
  esac
  [ "$state" = flushed ] || check "verify detects ${state}" 1 g verify
  check "apply repairs ${state}" 0 g apply
  check "verify passes after ${state}" 0 g verify
  [ "$(tagged)" -eq 3 ] && ok "${state}: exactly 3 tagged rules" || bad "${state}: tagged=$(tagged)"
done

echo "== a foreign rule with our comment text but different action is not adopted =="
reset
iptables -A DOCKER-USER -d 169.254.169.254/32 -m comment --comment pd-imds-guard -j ACCEPT
check "verify fails" 1 g verify
check "apply still ends with a valid state" 1 g apply

echo "== shadowing: a foreign rule ahead of ours must not defeat the block =="
for fr in ACCEPT RETURN; do
  reset
  iptables -A DOCKER-USER -j "$fr"
  check "foreign ${fr} first: verify fails" 1 g verify
  check "foreign ${fr} first: apply puts ours first" 0 g apply
  check "foreign ${fr} first: verify passes" 0 g verify
  iptables -S DOCKER-USER | sed -n '2,4p' | grep -c 'pd-imds-guard' | grep -qx 3 && ok "${fr}: our rules are lines 1-3" || bad "${fr}: position"
  iptables -S DOCKER-USER | sed -n '5p' | grep -qx -- "-A DOCKER-USER -j ${fr}" && ok "${fr}: foreign rule kept, after ours" || bad "${fr}: foreign rule lost"
done
reset
g apply >/dev/null 2>&1
iptables -I DOCKER-USER 2 -s 10.0.0.1/32 -j ACCEPT
check "foreign rule between ours: verify fails" 1 g verify
check "foreign rule between ours: apply repairs" 0 g apply
check "foreign rule between ours: verify passes" 0 g verify

echo "== netfilter-persistent style table replacement =="
reset
g apply >/dev/null 2>&1
printf '*filter\n:INPUT ACCEPT [0:0]\n:FORWARD DROP [0:0]\n:OUTPUT ACCEPT [0:0]\n:DOCKER-USER - [0:0]\n-A FORWARD -j DOCKER-USER\nCOMMIT\n' | iptables-restore
check "after snapshot restore the block is gone" 1 g verify
check "apply re-installs after the restore" 0 g apply
check "verify --live after restore + apply" 0 g verify --live

echo "== FORWARD jump checks =="
reset
g apply >/dev/null 2>&1
iptables -A FORWARD -j DOCKER-USER
check "duplicated jump fails verify --live" 1 g verify --live
reset
g apply >/dev/null 2>&1
iptables -I FORWARD -s 1.2.3.4 -j DROP
check "jump not first fails verify --live" 1 g verify --live

echo "== concurrency and locking =="
reset
( g apply >/dev/null 2>&1 & g apply >/dev/null 2>&1 & wait )
check "two parallel applies leave a valid state" 0 g verify
[ "$(tagged)" -eq 3 ] && ok "no duplicates after parallel applies" || bad "tagged=$(tagged)"
reset
exec 8>"${PD_IMDS_LOCK}"
flock -x 8
# a held exclusive lock must make a writer wait and then fail rather than interleave (shortened by timeout)
timeout 3 "$GUARD" apply >/dev/null 2>&1
[ "$?" -eq 124 ] && ok "apply waits on a held lock" || bad "apply did not wait on the lock"
[ "$(tagged)" -eq 0 ] && ok "nothing applied while locked" || bad "applied while locked"
flock -u 8
exec 8>&-
check "apply works once the lock is released" 0 g apply

echo "== more than 10 duplicate copies are refused rather than looping =="
reset
for _ in $(seq 12); do iptables -A DOCKER-USER -d 169.254.169.254/32 -p udp --dport 53 -m comment --comment pd-imds-guard -j RETURN; done
check "apply fails closed-loud on 12 duplicates" 1 g apply

echo "== check-service command semantics =="
chk() { sh -c "$GUARD verify --live || { $GUARD apply; $GUARD verify --live; }"; }
reset
g apply >/dev/null 2>&1
check "check command passes on a healthy state" 0 chk
g remove >/dev/null 2>&1
check "check command re-applies after a remove (why the timer is stopped before rollback)" 0 chk
check "rules are back" 0 g verify
iptables -A FORWARD -j DOCKER-USER
check "check command FAILS when the FORWARD jump is wrong" 1 chk
reset
g apply >/dev/null 2>&1
iptables -I DOCKER-USER 1 -s 10.0.0.9/32 -j RETURN
check "external rule inserted at top: verify fails" 1 g verify
check "check command re-fronts our rules" 0 chk
iptables -S DOCKER-USER | grep -qx -- '-A DOCKER-USER -s 10.0.0.9/32 -j RETURN' && ok "external rule preserved" || bad "external rule lost"

echo "== argument handling =="
check "no argument is rejected" 2 g
check "unknown argument is rejected" 2 g bogus
check "status prints the chain" 0 g status

echo
echo "passed: ${PASS}  failed: ${FAIL}"
[ "$FAIL" -eq 0 ]
