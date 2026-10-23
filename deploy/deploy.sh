#!/usr/bin/env bash
# Deploys an image to the portfolio container and rolls back if it does not become healthy.
# Run on the Oracle host. Usable directly (deploy.sh <image>) or as an SSH forced command,
# in which case the image ref arrives in SSH_ORIGINAL_COMMAND.
#   image: ghcr.io/nullps1/portfolio@sha256:<digest> | ghcr.io/nullps1/portfolio:<tag> | portfolio:<local tag>
set -euo pipefail
cd /srv/apps/portfolio

IMAGE="${1:-${SSH_ORIGINAL_COMMAND:-}}"
if ! [[ "$IMAGE" =~ ^(ghcr\.io/nullps1/portfolio|portfolio)[:@][A-Za-z0-9_.:-]+$ ]]; then
  echo "refusing image ref: '$IMAGE'" >&2
  exit 2
fi

set_image() {
  touch .env
  grep -v '^PORTFOLIO_IMAGE=' .env > .env.tmp || true
  echo "PORTFOLIO_IMAGE=$1" >> .env.tmp
  mv .env.tmp .env
}

wait_healthy() {
  for _ in $(seq 1 30); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' portfolio 2>/dev/null)" = healthy ] && return 0
    sleep 2
  done
  return 1
}

# The image the running container uses is the rollback target (an image ID works even if untagged).
PREV="$(docker inspect -f '{{.Image}}' portfolio 2>/dev/null || true)"

[[ "$IMAGE" == ghcr.io/* ]] && docker pull -q "$IMAGE" >/dev/null

set_image "$IMAGE"
docker compose up -d --no-build --force-recreate portfolio

if wait_healthy; then
  echo "deployed $IMAGE (previous: ${PREV:-none})"
  echo "$PREV" > .previous
  exit 0
fi

echo "UNHEALTHY after deploy of $IMAGE" >&2
docker logs --tail 20 portfolio >&2 || true
if [ -n "$PREV" ]; then
  set_image "$PREV"
  docker compose up -d --no-build --force-recreate portfolio
  wait_healthy && echo "rolled back to $PREV" >&2 || echo "ROLLBACK ALSO UNHEALTHY" >&2
fi
exit 1
