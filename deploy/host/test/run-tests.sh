#!/usr/bin/env bash
# Exercises deploy/host/portfolio-deploy in a throwaway sandbox with mocked docker/curl.
# Needs Linux (flock, GNU stat). Needs no root and never touches real containers or real host paths.
# The program under test is a copy whose fixed-configuration constants (paths, timings, root check)
# are rewritten by sed; its logic is unchanged.
#
#   bash deploy/host/test/run-tests.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../portfolio-deploy"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
W="$T/w"
PASS=0
FAIL=0
UID_NOW="$(id -u)"

A="ghcr.io/nullps1/portfolio@sha256:$(printf 'a%.0s' {1..64})"
B="ghcr.io/nullps1/portfolio@sha256:$(printf 'b%.0s' {1..64})" # container never becomes healthy
C="ghcr.io/nullps1/portfolio@sha256:$(printf 'c%.0s' {1..64})" # healthy, but wrong X-Origin
D="ghcr.io/nullps1/portfolio@sha256:$(printf 'd%.0s' {1..64})" # compose fails outright
E="ghcr.io/nullps1/portfolio@sha256:$(printf 'e%.0s' {1..64})" # wrong architecture
F="ghcr.io/nullps1/portfolio@sha256:$(printf 'f%.0s' {1..64})" # wrong source label
G="ghcr.io/nullps1/portfolio@sha256:$(printf '1%.0s' {1..64})" # second good release
H="ghcr.io/nullps1/portfolio@sha256:$(printf '2%.0s' {1..64})" # not pullable
J="ghcr.io/nullps1/portfolio@sha256:$(printf '%064x' 10)" # healthy container, origin 502 WITH the right header
K="ghcr.io/nullps1/portfolio@sha256:$(printf '%064x' 11)" # origin 200 without X-Origin
L="ghcr.io/nullps1/portfolio@sha256:$(printf '%064x' 12)" # origin header is a lookalike
M="ghcr.io/nullps1/portfolio@sha256:$(printf '%064x' 13)" # compose starts a DIFFERENT image
N="ghcr.io/nullps1/portfolio@sha256:$(printf '%064x' 14)" # reports "starting" once before healthy
O="ghcr.io/nullps1/portfolio@sha256:$(printf '%064x' 15)" # source label is a lookalike (portfolio-evil)
LOCAL_ID="sha256:$(printf '9%.0s' {1..64})"
ID_OF() { printf 'sha256:%s' "$(printf '%s' "${1##*sha256:}" | tr 'a-f' '3-8' | cut -c1-64)"; }

pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; }
check() { # name expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}
contains() { # name haystack needle
  if grep -qF -- "$3" <<<"$2"; then pass "$1"; else fail "$1" "missing [$3] in [$2]"; fi
}
lacks() { # name haystack needle
  if grep -qF -- "$3" <<<"$2"; then fail "$1" "unexpected [$3]"; else pass "$1"; fi
}
st() { sed -n "s/^$1=//p" "$T/state/state" 2>/dev/null | head -1; }
calls() { cat "$W/calls.log" 2>/dev/null; }
compose_calls() { grep -c '^docker compose' "$W/calls.log" 2>/dev/null || true; }

build_tools() {
  mkdir -p "$T/bin"
  sed -E \
    -e "s|^PATH=.*|PATH=$T/bin:/usr/bin:/bin|" \
    -e "s|^readonly DEPLOY_DIR=.*|readonly DEPLOY_DIR=\"$T/opt\"|" \
    -e "s|^readonly STATE_DIR=.*|readonly STATE_DIR=\"$T/state\"|" \
    -e "s|^readonly LOG_FILE=.*|readonly LOG_FILE=\"$T/log\"|" \
    -e "s|^readonly HEALTH_TRIES=.*|readonly HEALTH_TRIES=2|" \
    -e "s|^readonly HEALTH_SLEEP=.*|readonly HEALTH_SLEEP=0|" \
    -e "s|^readonly ORIGIN_TRIES=.*|readonly ORIGIN_TRIES=2|" \
    -e "s|^readonly REQUIRE_ROOT=.*|readonly REQUIRE_ROOT=0|" \
    -e "s|^readonly TRUSTED_UID=.*|readonly TRUSTED_UID=${UID_NOW}|" \
    "$SRC" >"$T/portfolio-deploy"
  chmod 755 "$T/portfolio-deploy"
  # variants: 1-second timeouts, and a different "root" uid so the owner check can actually fail
  sed -E -e "s|^readonly PULL_TIMEOUT=.*|readonly PULL_TIMEOUT=1|" -e "s|^readonly COMPOSE_TIMEOUT=.*|readonly COMPOSE_TIMEOUT=1|" \
    "$T/portfolio-deploy" >"$T/portfolio-deploy-t1"
  sed -E -e "s|^readonly TRUSTED_UID=.*|readonly TRUSTED_UID=$((UID_NOW + 1))|" "$T/portfolio-deploy" >"$T/portfolio-deploy-uid"
  sed -E -e "s|^readonly REQUIRE_ROOT=.*|readonly REQUIRE_ROOT=1|" "$T/portfolio-deploy" >"$T/portfolio-deploy-root"
  chmod 755 "$T/portfolio-deploy-t1" "$T/portfolio-deploy-uid" "$T/portfolio-deploy-root"
  cat >"$T/bin/docker" <<'MOCK'
#!/bin/bash
W="${MOCK_WORLD:?}"
echo "docker $* [PORTFOLIO_IMAGE=${PORTFOLIO_IMAGE:-}] [DOCKER_HOST=${DOCKER_HOST:-unset} DOCKER_CONFIG=${DOCKER_CONFIG:-unset} HOME=${HOME:-unset} COMPOSE_FILE=${COMPOSE_FILE:-unset}]" >>"$W/calls.log"
key() { printf '%s' "$1" | tr '/:@' '___'; }
imgfile() {
  local f="$W/images/$(key "$1")"
  if [ -f "$f" ]; then echo "$f"; return 0; fi
  grep -lx "id=$1" "$W/images/"* 2>/dev/null | head -1
}
getf() { sed -n "s/^$2=//p" "$1" | head -1; }
case "$1" in
  container)
    [ "$2" = inspect ] || exit 99
    case "$4" in
      *State.Health*)
        if [ ! -f "$W/running" ]; then echo missing; exit 1; fi
        h="$(cat "$W/health")"
        if [ "$h" = starting1 ]; then echo starting; echo healthy >"$W/health"; else echo "$h"; fi ;;
      *.Image*) [ -f "$W/running" ] || exit 1; cat "$W/running" ;;
    esac ;;
  image)
    f="$(imgfile "$5")"
    [ -n "$f" ] || exit 1
    case "$4" in
      *.Id*) getf "$f" id ;;
      *Architecture*) echo "$(getf "$f" os)/$(getf "$f" arch) $(getf "$f" source)" ;;
    esac ;;
  pull)
    ref="${*: -1}"
    [ -f "$W/hang_pull" ] && sleep 5
    if grep -qxF "$ref" "$W/pull_fail" 2>/dev/null; then echo "mock: manifest unknown" >&2; exit 1; fi
    src="$W/available/$(key "$ref")"
    [ -f "$src" ] || exit 1
    cp "$src" "$W/images/$(key "$ref")" ;;
  tag)
    f="$(imgfile "$2")"
    [ -n "$f" ] || exit 1
    cp "$f" "$W/images/$(key "$3")" ;;
  compose)
    f="$(imgfile "${PORTFOLIO_IMAGE:-}")"
    [ -n "$f" ] || { echo "mock: no such image: ${PORTFOLIO_IMAGE:-}" >&2; exit 1; }
    [ -f "$W/slow" ] && sleep 1
    [ -f "$W/hang_compose" ] && sleep 5
    [ -f "$W/lock_state_dir" ] && chmod 500 "${MOCK_STATE_DIR:?}"
    beh="$(getf "$f" behavior)"
    [ "$beh" = crash ] && { echo "mock: compose failed" >&2; exit 1; }
    if [ "$beh" = wrongimg ]; then
      cat "$W/running" 2>/dev/null >/dev/null
      printf '%s' "sha256:$(printf '8%.0s' {1..64})" >"$W/running"
      echo healthy >"$W/health"
    else
      getf "$f" id >"$W/running"
      if [ "$beh" = slow1 ]; then echo starting1 >"$W/health"; else echo "$beh" >"$W/health"; fi
    fi
    getf "$f" origin >"$W/origin" ;;
  *) echo "mock docker: unsupported: $*" >&2; exit 99 ;;
esac
MOCK
  cat >"$T/bin/curl" <<'MOCK'
#!/bin/bash
case "$(cat "${MOCK_WORLD}/origin" 2>/dev/null || echo ok)" in
  ok) printf 'HTTP/1.1 200 OK\r\nX-Origin: oci-portfolio\r\n\r\n' ;;
  wrong) printf 'HTTP/1.1 200 OK\r\nX-Origin: someone-else\r\n\r\n' ;;
  lookalike) printf 'HTTP/1.1 200 OK\r\nX-Origin: not-oci-portfolio\r\n\r\n' ;;
  nohdr) printf 'HTTP/1.1 200 OK\r\n\r\n' ;;
  err-hdr) printf 'HTTP/1.1 502 Bad Gateway\r\nX-Origin: oci-portfolio\r\n\r\n' ;;
  *) printf 'HTTP/1.1 502 Bad Gateway\r\n\r\n' ;;
esac
MOCK
  printf '#!/bin/bash\nexit 0\n' >"$T/bin/logger"
  chmod 755 "$T/bin/docker" "$T/bin/curl" "$T/bin/logger"
}

mkimg() { # dir ref id os arch source behavior origin
  mkdir -p "$1"
  printf 'id=%s\nos=%s\narch=%s\nsource=%s\nbehavior=%s\norigin=%s\n' "$3" "$4" "$5" "$6" "$7" "$8" \
    >"$1/$(printf '%s' "$2" | tr '/:@' '___')"
}

new_world() {
  rm -rf "$W" "$T/state" "$T/opt" "$T/log"
  mkdir -p "$W/images" "$W/available" "$T/opt"
  chmod 755 "$T/opt"
  printf 'services: {}\n' >"$T/opt/compose.yaml"
  chmod 644 "$T/opt/compose.yaml"
  local src="https://github.com/nullps1/portfolio"
  mkimg "$W/images" "$LOCAL_ID" "$LOCAL_ID" linux arm64 "" healthy ok
  printf '%s' "$LOCAL_ID" >"$W/running"
  echo healthy >"$W/health"
  echo ok >"$W/origin"
  mkimg "$W/available" "$A" "$(ID_OF "$A")" linux arm64 "$src" healthy ok
  mkimg "$W/available" "$B" "$(ID_OF "$B")" linux arm64 "$src" unhealthy ok
  mkimg "$W/available" "$C" "$(ID_OF "$C")" linux arm64 "$src" healthy wrong
  mkimg "$W/available" "$D" "$(ID_OF "$D")" linux arm64 "$src" crash ok
  mkimg "$W/available" "$E" "$(ID_OF "$E")" linux amd64 "$src" healthy ok
  mkimg "$W/available" "$F" "$(ID_OF "$F")" linux arm64 "https://github.com/evil/portfolio" healthy ok
  mkimg "$W/available" "$G" "$(ID_OF "$G")" linux arm64 "$src" healthy ok
  mkimg "$W/available" "$J" "$(ID_OF "$J")" linux arm64 "$src" healthy err-hdr
  mkimg "$W/available" "$K" "$(ID_OF "$K")" linux arm64 "$src" healthy nohdr
  mkimg "$W/available" "$L" "$(ID_OF "$L")" linux arm64 "$src" healthy lookalike
  mkimg "$W/available" "$M" "$(ID_OF "$M")" linux arm64 "$src" wrongimg ok
  mkimg "$W/available" "$N" "$(ID_OF "$N")" linux arm64 "$src" slow1 ok
  mkimg "$W/available" "$O" "$(ID_OF "$O")" linux arm64 "${src}-evil" healthy ok
  : >"$W/calls.log"
}

run() { # request  (sets OUT and RC)
  OUT="$(env -i PATH=/usr/bin:/bin MOCK_WORLD="$W" MOCK_STATE_DIR="$T/state" SSH_ORIGINAL_COMMAND="$1" "$T/portfolio-deploy" 2>&1)"
  RC=$?
}
run_with() { # program request [VAR=value ...]  (sets OUT and RC)
  local prog="$1" req="$2"
  shift 2
  OUT="$(env -i PATH=/usr/bin:/bin MOCK_WORLD="$W" MOCK_STATE_DIR="$T/state" "$@" SSH_ORIGINAL_COMMAND="$req" "$prog" 2>&1)"
  RC=$?
}
set_beh() { # ref-or-id behavior: edit every mock image file (and local tag copy) with that ref or ID
  local f
  for f in "$W/images/$(printf '%s' "$1" | tr '/:@' '___')" "$W/available/$(printf '%s' "$1" | tr '/:@' '___')"; do
    [ -f "$f" ] && sed -i "s/^behavior=.*/behavior=$2/" "$f"
  done
  grep -lx "id=$1" "$W/images/"* "$W/available/"* 2>/dev/null | while read -r f; do
    sed -i "s/^behavior=.*/behavior=$2/" "$f"
  done
  return 0
}
seed() { # current previous pending history last_result
  printf 'current=%s\nprevious=%s\npending=%s\nhistory=%s\nlast_result=%s\n' "$1" "$2" "$3" "$4" "$5" >"$T/state/state"
  chmod 600 "$T/state/state"
}
mode_of() { stat -c '%a' -- "$1"; }

build_tools
echo "== request validation (nothing may reach docker) =="
long="$(printf 'x%.0s' {1..300})"
bad=(
  "" "deploy" "rollback" "status extra" "STATUS" "bash -c id" "id"
  "deploy ghcr.io/nullps1/portfolio:latest" "deploy ghcr.io/nullps1/portfolio:sha-abc"
  "deploy ghcr.io/nullps1/portfolio@sha256:abc" "deploy portfolio:local"
  "deploy ghcr.io/nullps1/portfolio@sha256:$(printf 'A%.0s' {1..64})"
  "deploy ghcr.io/other/portfolio@sha256:$(printf 'a%.0s' {1..64})"
  "deploy docker.io/nullps1/portfolio@sha256:$(printf 'a%.0s' {1..64})"
  "deploy ${A}; id" "deploy ${A} && id" "deploy ${A} extra" "deploy  ${A}" " deploy ${A}"
  "deploy ${A}\$(id)" "deploy \`id\`" "deploy ../../etc/passwd" "rollback portfolio:local"
  "deploy ${A}"$'\n'"status" "deploy ${A}"$'\n' "$long" "deploy ${A}${long}"
  "deploy ${A}|cat" "deploy ${A}>/tmp/x" "deploy --help" "-x"
)
for r in "${bad[@]}"; do
  new_world
  run "$r"
  label="rejects: $(printf '%s' "$r" | tr -c '[:print:]' '?' | cut -c1-60)"
  if [ "$RC" -eq 2 ] && ! grep -q . "$W/calls.log"; then pass "$label"; else fail "$label" "rc=$RC calls=$(calls | head -2)"; fi
done

echo "== accepted requests =="
new_world
run "status"
check "status accepted" 0 "$RC"
check "status touches nothing" 0 "$(compose_calls)"

echo "== not root =="
if [ "$UID_NOW" -ne 0 ]; then
  OUT="$(env -i PATH=/usr/bin:/bin SSH_ORIGINAL_COMMAND="deploy ${A}" "$SRC" 2>&1)"
  RC=$?
  check "unpatched program refuses non-root" 77 "$RC"
else
  echo "SKIP  running as root"
fi

echo "== deploy =="
new_world
run "deploy ${A}"
check "deploy A rc" 0 "$RC"
check "state current=A" "$A" "$(st current)"
check "state previous=bootstrap image" "$LOCAL_ID" "$(st previous)"
check "state pending cleared" "" "$(st pending)"
check "running image is A" "$(ID_OF "$A")" "$(cat "$W/running")"
contains "history has both" "$(st history)" "$LOCAL_ID"
cl="$(calls | grep '^docker compose' | tail -1)"
for frag in "--project-name portfolio" "--file $T/opt/compose.yaml" "--env-file /dev/null" "--no-build" "--pull never" "--force-recreate" "--no-deps portfolio" "[PORTFOLIO_IMAGE=${A}]"; do
  contains "compose call has: $(printf '%s' "$frag" | cut -c1-40)" "$cl" "$frag"
done
lacks "never runs/execs/removes/stops containers" "$(calls | grep -E '^docker (run|exec|rm|stop|kill|restart|volume|system|network)' || true)" "docker"
run "deploy ${A}"
check "redeploy same ref is idempotent rc" 0 "$RC"
check "redeploy makes no extra compose call" 1 "$(compose_calls)"

echo "== failed deployments restore the previous release =="
for case_ in "B:unhealthy container" "C:wrong X-Origin" "D:compose failure"; do
  v="${case_%%:*}"
  ref="${!v}"
  new_world
  run "deploy ${ref}"
  check "${case_#*:}: rc 10" 10 "$RC"
  check "${case_#*:}: current restored" "$LOCAL_ID" "$(st current)"
  check "${case_#*:}: previous release running" "$LOCAL_ID" "$(cat "$W/running")"
  check "${case_#*:}: pending cleared" "" "$(st pending)"
done
new_world
run "deploy ${A}"
run "deploy ${B}"
check "bad release after good one restores A" 10 "$RC"
check "A is live again" "$A" "$(st current)"

echo "== refused images change nothing =="
for case_ in "E:wrong architecture" "F:wrong source label" "H:unpullable"; do
  v="${case_%%:*}"
  ref="${!v}"
  new_world
  printf '%s\n' "$H" >"$W/pull_fail"
  run "deploy ${ref}"
  check "${case_#*:}: rc 12" 12 "$RC"
  check "${case_#*:}: no compose call" 0 "$(compose_calls)"
  check "${case_#*:}: running unchanged" "$LOCAL_ID" "$(cat "$W/running")"
done

echo "== rollback =="
new_world
run "deploy ${A}"
run "rollback ${G}"
check "rollback of a non-live release is refused" 20 "$RC"
check "  and makes no compose call" 1 "$(compose_calls)"
run "rollback ${A}"
check "rollback of the live release" 0 "$RC"
check "  restores previous" "$LOCAL_ID" "$(cat "$W/running")"
check "  state current" "$LOCAL_ID" "$(st current)"
check "  previous cleared (no flip-back)" "" "$(st previous)"
run "rollback ${A}"
check "second rollback of the same release refused" 20 "$RC"
new_world
run "deploy ${A}"
run "deploy ${G}"
run "rollback ${G}"
check "roll back G -> A" "$A" "$(st current)"
run "rollback ${A}"
check "no further rollback without a new deploy" 21 "$RC"
new_world
run "deploy ${A}"
sed -i "s|^previous=.*|previous=${H}|" "$T/state/state"
run "rollback ${A}"
check "unauthorized target (not in history) refused" 21 "$RC"
sed -i "s|^previous=.*|previous=evil|" "$T/state/state"
run "rollback ${A}"
check "corrupt state refused" 78 "$RC"
new_world
run "deploy ${A}"
printf 'surprise=1\n' >>"$T/state/state"
run "status"
check "unknown state key refused" 78 "$RC"

echo "== trust boundaries =="
new_world
chmod 666 "$T/opt/compose.yaml"
run "deploy ${A}"
check "group/world-writable compose file refused" 77 "$RC"
check "  nothing executed" 0 "$(compose_calls)"
new_world
mv "$T/opt/compose.yaml" "$T/real.yaml"
ln -s "$T/real.yaml" "$T/opt/compose.yaml"
run "deploy ${A}"
check "symlinked compose file refused" 77 "$RC"
new_world
chmod 777 "$T/opt"
run "deploy ${A}"
check "writable deploy dir refused" 77 "$RC"
new_world
mkdir -p "$T/state/docker-config"
chmod 755 "$T/state"
run "deploy ${A}"
check "world-readable state dir refused" 77 "$RC"

echo "== concurrency =="
new_world
run "status" # creates the state directory
mkdir -p "$T/state"
chmod 700 "$T/state"
touch "$T/state/lock"
flock "$T/state/lock" sleep 4 &
holder=$!
sleep 0.5
run "deploy ${A}"
check "second deployment rejected while one runs" 75 "$RC"
check "  and changes nothing" 0 "$(compose_calls)"
pkill -P "$holder" 2>/dev/null # the sleep child inherits and holds the lock
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
run "deploy ${A}"
check "deployment proceeds once the lock is free" 0 "$RC"

echo "== interrupted deployments =="
new_world
run "deploy ${A}" # live and healthy
printf 'current=%s\nprevious=%s\npending=%s\nhistory=%s %s\nlast_result=deployed\n' "$LOCAL_ID" "$LOCAL_ID" "$A" "$A" "$LOCAL_ID" >"$T/state/state"
run "deploy ${A}"
check "pending release that is live+healthy is adopted" "$A" "$(st current)"
check "  pending cleared" "" "$(st pending)"
new_world
run "deploy ${G}"
printf 'current=%s\nprevious=%s\npending=%s\nhistory=%s %s\nlast_result=deployed\n' "$G" "$LOCAL_ID" "$B" "$B" "$G" >"$T/state/state"
cp "$W/available/$(printf '%s' "$B" | tr '/:@' '___')" "$W/images/$(printf '%s' "$B" | tr '/:@' '___')"
ID_OF "$B" >"$W/running"
echo unhealthy >"$W/health"
run "deploy ${A}"
check "interrupted bad transition restored then new deploy succeeded" "$A" "$(st current)"
check "  previous is the restored release" "$G" "$(st previous)"

echo "== SSH drop mid-deploy =="
new_world
touch "$W/slow"
env -i PATH=/usr/bin:/bin MOCK_WORLD="$W" SSH_ORIGINAL_COMMAND="deploy ${A}" "$T/portfolio-deploy" >"$T/hup.out" 2>&1 &
pid=$!
sleep 0.3
kill -HUP "$pid" 2>/dev/null
wait "$pid"
check "SIGHUP during deploy does not abort it (rc)" 0 "$?"
check "  deploy completed" "$A" "$(st current)"

echo "== secret hygiene =="
new_world
OUT="$(env -i PATH=/usr/bin:/bin MOCK_WORLD="$W" DEPLOY_SSH_KEY=SUPERSECRET123 GITHUB_TOKEN=SUPERSECRET123 SSH_ORIGINAL_COMMAND="deploy ${A}" "$T/portfolio-deploy" 2>&1)"
all="$OUT $(cat "$T/log" "$T/state/state" "$W/calls.log")"
lacks "no secret values in output, log, state or docker calls" "$all" "SUPERSECRET123"

echo "== reconcile of interrupted runs (asserts outcome, result, pending, compose calls) =="
new_world
run "deploy ${A}"
seed "$LOCAL_ID" "$LOCAL_ID" "$A" "$A $LOCAL_ID" deployed
run "rollback ${H}" # reconciles first, then refuses (H is not live)
check "adopt: rc is the rollback refusal" 20 "$RC"
check "adopt: current is the live+healthy pending release" "$A" "$(st current)"
check "adopt: last_result" recovered-new "$(st last_result)"
check "adopt: pending cleared" "" "$(st pending)"
check "adopt: no extra compose call" 1 "$(compose_calls)"

new_world
run "deploy ${G}"
seed "$G" "$LOCAL_ID" "$B" "$B $G $LOCAL_ID" deployed
cp "$W/available/$(printf '%s' "$B" | tr '/:@' '___')" "$W/images/$(printf '%s' "$B" | tr '/:@' '___')"
printf '%s' "$(ID_OF "$B")" >"$W/running"
echo unhealthy >"$W/health"
before="$(compose_calls)"
run "rollback ${H}"
check "restore: current stays the last good release" "$G" "$(st current)"
check "restore: last_result" recovered-old "$(st last_result)"
check "restore: pending cleared" "" "$(st pending)"
check "restore: good release running again" "$(ID_OF "$G")" "$(cat "$W/running")"
check "restore: exactly one compose call" $((before + 1)) "$(compose_calls)"

new_world
run "deploy ${G}"
seed "$G" "$LOCAL_ID" "$B" "$B $G $LOCAL_ID" deployed
cp "$W/available/$(printf '%s' "$B" | tr '/:@' '___')" "$W/images/$(printf '%s' "$B" | tr '/:@' '___')"
printf '%s' "$(ID_OF "$B")" >"$W/running"
echo unhealthy >"$W/health"
set_beh "$G" crash
run "rollback ${H}"
check "restore that fails is recorded" recovery-failed "$(st last_result)"
check "  and pending is still cleared" "" "$(st pending)"

echo "== exit 11: the restore/rollback ALSO fails =="
new_world
set_beh "$LOCAL_ID" crash
run "deploy ${B}"
check "deploy fails and restore fails -> rc 11" 11 "$RC"
check "  result" restore-failed "$(st last_result)"
check "  pending cleared" "" "$(st pending)"
contains "  failure reason is logged, not discarded" "$(cat "$T/log")" "compose up failed"
new_world
run "deploy ${A}"
set_beh "$LOCAL_ID" crash
run "rollback ${A}"
check "rollback whose switch fails -> rc 11" 11 "$RC"
check "  result" rollback-failed "$(st last_result)"
check "  pending cleared" "" "$(st pending)"
check "  previous stays cleared" "" "$(st previous)"
new_world
rm -f "$W/running" "$W/health"
run "deploy ${B}"
check "first-ever deploy that fails has nothing to restore -> rc 11" 11 "$RC"
new_world
rm -f "$W/running" "$W/health"
run "deploy ${A}"
check "fresh host: first deploy works" 0 "$RC"
check "  no previous release recorded" "" "$(st previous)"

echo "== rollback target authorization =="
new_world
run "deploy ${A}"
n="$(compose_calls)"
sed -i "s|^previous=.*|previous=${G}|; s|^history=.*|history=${A} ${LOCAL_ID}|" "$T/state/state"
run "rollback ${A}"
check "pullable target that is NOT in history is refused" 21 "$RC"
check "  and no compose call was made" "$n" "$(compose_calls)"
sed -i "s|^previous=.*|previous=${H}|; s|^history=.*|history=${A} ${H}|" "$T/state/state"
run "rollback ${A}"
check "target missing locally and unpullable is refused" 21 "$RC"
sed -i "s|^previous=.*|previous=${E}|; s|^history=.*|history=${A} ${E}|" "$T/state/state"
run "rollback ${A}"
check "target that fails image verification (wrong arch) is refused" 21 "$RC"
check "  and no compose call was made" "$n" "$(compose_calls)"

echo "== verification gaps found by mutation testing =="
for case_ in "J:HTTP 502 even with the right header" "K:200 without X-Origin" "L:lookalike X-Origin header" "M:compose started a different image"; do
  v="${case_%%:*}"
  new_world
  run "deploy ${!v}"
  check "${case_#*:}: rc 10" 10 "$RC"
  check "${case_#*:}: previous release restored" "$LOCAL_ID" "$(st current)"
done
new_world
run "deploy ${O}"
check "lookalike source label is refused" 12 "$RC"
new_world
run "deploy ${N}"
check "container that reports 'starting' once still deploys" 0 "$RC"
new_world
run "deploy ${A}"
run "deploy ${G}"
echo unhealthy >"$W/health"
n="$(compose_calls)"
run "deploy ${G}"
check "redeploy of an UNHEALTHY live release re-runs compose" $((n + 1)) "$(compose_calls)"
check "  and keeps the recorded rollback target" "$A" "$(st previous)"

echo "== timeouts =="
new_world
touch "$W/hang_pull"
run_with "$T/portfolio-deploy-t1" "deploy ${A}"
check "hung pull is cut off -> rc 12" 12 "$RC"
check "  nothing switched" 0 "$(compose_calls)"
new_world
touch "$W/hang_compose"
run_with "$T/portfolio-deploy-t1" "deploy ${A}"
check "hung compose is cut off (and so is the restore) -> rc 11" 11 "$RC"

echo "== hostile environment and file modes =="
new_world
run_with "$T/portfolio-deploy" "deploy ${A}" DOCKER_HOST=tcp://127.0.0.1:1 COMPOSE_FILE=/evil.yaml \
  DOCKER_CONFIG=/evil HOME=/home/attacker PORTFOLIO_IMAGE=evil BASH_ENV=/evil.sh
check "deploy still succeeds with a hostile environment" 0 "$RC"
cl="$(calls | grep '^docker compose' | tail -1)"
contains "DOCKER_HOST is not inherited" "$cl" "DOCKER_HOST=unset"
contains "COMPOSE_FILE is not inherited" "$cl" "COMPOSE_FILE=unset"
contains "DOCKER_CONFIG is the root-only empty dir" "$cl" "DOCKER_CONFIG=$T/state/docker-config"
contains "HOME is root's, not the caller's" "$cl" "HOME=/root"
contains "image comes from the validated request" "$cl" "PORTFOLIO_IMAGE=${A}"
check "state file mode" 600 "$(mode_of "$T/state/state")"
check "state dir mode" 700 "$(mode_of "$T/state")"
check "log file mode" 640 "$(mode_of "$T/log")"

echo "== trust checks, each in isolation =="
new_world
run "status"
run_with "$T/portfolio-deploy-uid" "status"
check "files not owned by the trusted uid are refused" 77 "$RC"
contains "  names the failing check" "$OUT" "not owned by root"
run_with "$T/portfolio-deploy-root" "status"
contains "non-root caller is told why" "$OUT" "must run as root"
for spec in "$T/portfolio-deploy:775:the program itself (group-writable)" "$T/opt/compose.yaml:664:compose file (group-writable)" \
  "$T/opt:775:deploy dir (group-writable)" "$T/state/docker-config:755:docker config dir (readable by others)"; do
  path="${spec%%:*}"
  rest="${spec#*:}"
  mode="${rest%%:*}"
  desc="${rest#*:}"
  new_world
  run "status"
  orig="$(mode_of "$path")"
  chmod "$mode" "$path"
  run "status"
  check "$desc is refused" 77 "$RC"
  chmod "$orig" "$path"
done
new_world
run "deploy ${A}"
chmod 644 "$T/state/state"
run "status"
check "world-readable state file is refused" 77 "$RC"
new_world
run "deploy ${A}"
chmod 666 "$T/log"
run "status"
check "world-writable log is refused" 77 "$RC"

echo "== a failed state write never destroys the good state =="
if [ "$UID_NOW" -ne 0 ]; then
  new_world
  run "deploy ${A}"
  n="$(compose_calls)"
  chmod 500 "$T/state"
  run "deploy ${G}"
  chmod 700 "$T/state"
  check "unwritable state dir -> rc 79" 79 "$RC"
  check "  no release was switched" "$n" "$(compose_calls)"
  check "  previous state intact" "$A" "$(st current)"
  new_world
  touch "$W/lock_state_dir"
  run "deploy ${A}" # the mock locks the state dir right after the switch, so the FINAL save fails
  chmod 700 "$T/state"
  rm -f "$W/lock_state_dir"
  check "state lost its write access after the switch -> rc 79" 79 "$RC"
  check "  state file still parses and still names the pending release" "$A" "$(st pending)"
  check "  the old release is still the recorded current" "$LOCAL_ID" "$(st current)"
  run "deploy ${A}"
  check "next run adopts the live release" 0 "$RC"
  check "  current is now the new release" "$A" "$(st current)"
  check "  pending cleared" "" "$(st pending)"
else
  echo "SKIP  running as root (permission-based fault injection needs a non-root user)"
fi

echo "== history is bounded and de-duplicated =="
new_world
last=""
prev_last=""
for i in $(seq 20 33); do
  r="ghcr.io/nullps1/portfolio@sha256:$(printf '%064x' "$i")"
  mkimg "$W/available" "$r" "$(ID_OF "$r")" linux arm64 "https://github.com/nullps1/portfolio" healthy ok
  run "deploy ${r}"
  prev_last="$last"
  last="$r"
done
hist="$(st history)"
check "history keeps at most 10 entries" 10 "$(wc -w <<<"$hist")"
check "history has no duplicates" "$(wc -w <<<"$hist")" "$(tr ' ' '\n' <<<"$hist" | sort -u | wc -l)"
check "newest first" "$last" "$(cut -d' ' -f1 <<<"$hist")"
check "current is the last deploy" "$last" "$(st current)"
check "previous is the one before" "$prev_last" "$(st previous)"
printf 'current=%s\nprevious=\npending=\nhistory=%s evil\nlast_result=x\n' "$last" "$last" >"$T/state/state"
run "status"
check "history entry that is not a valid ref -> rc 78" 78 "$RC"

echo "== sudoers syntax (as generated by install.sh) =="
if command -v visudo >/dev/null; then
  printf 'Defaults:portfolio-deploy env_keep += "SSH_ORIGINAL_COMMAND"\nDefaults:portfolio-deploy !requiretty\nportfolio-deploy ALL=(root) NOPASSWD: /usr/local/sbin/portfolio-deploy ""\n' >"$T/sudoers"
  if visudo -cf "$T/sudoers" >/dev/null 2>&1; then pass "sudoers file parses"; else echo "SKIP  visudo needs root here"; fi
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
