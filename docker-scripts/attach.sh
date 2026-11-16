#!/usr/bin/env bash
set -euo pipefail

NAME="ndduong"
PREFIX="${NAME}-workspace"

[ $# -ge 1 ] || { echo "Usage: $0 <suffix|full-name> [tmux-session]"; exit 1; }

case "$1" in
  "${PREFIX}-"*) cname="$1" ;;
  *)             cname="${PREFIX}-$1" ;;
esac

# Only attach to your own workspace containers
[[ "$cname" =~ ^${PREFIX}-[A-Za-z0-9_.-]+$ ]] || { echo "Invalid name: $cname" >&2; exit 1; }

state="$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null)" || {
  echo "Error: container '${cname}' does not exist." >&2
  exit 1
}

# Start it if it was stopped, then wait for the inner dockerd
if [ "$state" != "running" ]; then
  echo "Starting ${cname}..."
  docker start "$cname" >/dev/null
  echo -n "Waiting for inner Docker daemon"
  for _ in $(seq 1 60); do
    if [ "$(docker inspect -f '{{.State.Status}}' "$cname")" != "running" ]; then
      echo; echo "Container exited. Logs:" >&2
      docker logs "$cname" >&2 || true
      exit 1
    fi
    docker exec "$cname" docker info >/dev/null 2>&1 && break
    echo -n "."; sleep 1
  done
  echo " ready."
fi

exec docker exec -it -w /workspace "${cname}" \
  tmux new-session -A -s "${2:-main}"