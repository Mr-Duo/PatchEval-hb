#!/usr/bin/env bash
set -euo pipefail

NAME="ndduong"
PREFIX="${NAME}-workspace"
IMAGE="${PREFIX}"

usage() {
  echo "Usage: $0 <suffix|full-name> [more ...]"
  echo "  e.g. $0 1   -> stops ${PREFIX}-1 (container and inner Docker data are kept)"
  echo "Restart with ./attach.sh <suffix>. To delete everything, use ./destroy.sh."
  exit 1
}

[ $# -ge 1 ] || usage

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

  state="$(docker inspect -f '{{.State.Status}}' "$cname")"
  if [ "$state" != "running" ]; then
    echo "${cname} is already stopped (${state})."
    continue
  fi

  echo "Stopping ${cname}..."
  docker stop -t 60 "$cname" >/dev/null     # time for the inner dockerd to shut down
  echo "Stopped: ${cname} (data kept; restart with ./attach.sh ${cname#${PREFIX}-})"
done