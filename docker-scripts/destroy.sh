#!/usr/bin/env bash
set -euo pipefail

NAME="ndduong"
PREFIX="${NAME}-workspace"
IMAGE="${PREFIX}"

usage() {
  echo "Usage: $0 <suffix|full-name> [more ...]"
  echo "  e.g. $0 1            -> stops and REMOVES ${PREFIX}-1 and its inner Docker data"
  echo "       $0 ${PREFIX}-exp-a"
  echo "Only containers named ${PREFIX}-<suffix> (created from image ${IMAGE}) are allowed."
  echo "To stop without deleting anything, use ./stop.sh."
  exit 1
}

[ $# -ge 1 ] || usage

TARGETS=()
for arg in "$@"; do
  case "$arg" in
    "${PREFIX}-"*) cname="$arg" ;;
    *)             cname="${PREFIX}-${arg}" ;;
  esac

  if ! [[ "$cname" =~ ^${PREFIX}-[A-Za-z0-9_.-]+$ ]]; then
    echo "Error: '${arg}' is not a valid ${PREFIX}-<suffix> name." >&2
    exit 1
  fi

  if ! docker ps -a --format '{{.Names}}' | grep -qx "$cname"; then
    echo "Error: container '${cname}' does not exist." >&2
    exit 1
  fi

  img="$(docker inspect -f '{{.Config.Image}}' "$cname")"
  img="${img%%:*}"
  if [ "$img" != "$IMAGE" ]; then
    echo "Error: '${cname}' is not created from image '${IMAGE}' (found '${img}'). Refusing." >&2
    exit 1
  fi

  TARGETS+=("$cname")
done

echo "The following containers will be STOPPED and REMOVED:"
for c in "${TARGETS[@]}"; do
  state="$(docker inspect -f '{{.State.Status}}' "$c")"
  echo "  - ${c} (${state})"
done
echo "WARNING: this permanently deletes the container, ALL inner Docker images,"
echo "         containers and volumes, and tmux sessions. /workspace is NOT touched."

read -r -p "Proceed? (y/N): " answer
case "$answer" in
  [yY]|[yY][eE][sS]) ;;
  *) echo "Aborted."; exit 0 ;;
esac

for c in "${TARGETS[@]}"; do
  echo "Stopping ${c}..."
  docker stop -t 60 "$c" >/dev/null
  echo "Removing ${c}..."
  docker rm -v "$c" >/dev/null
  docker volume rm -f "${c}-docker" >/dev/null   # inner Docker data
  echo "Done: ${c}"
done