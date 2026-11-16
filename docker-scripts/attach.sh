#!/usr/bin/env bash
set -euo pipefail

NAME="ndduong"
PREFIX="${NAME}-workspace"

[ $# -ge 1 ] || { echo "Usage: $0 <suffix|full-name> [tmux-session]"; exit 1; }

case "$1" in
  "${PREFIX}-"*) cname="$1" ;;
  *)             cname="${PREFIX}-$1" ;;
esac

exec docker exec -it -u "${NAME}" -w /workspace "${cname}" \
  tmux new-session -A -s "${2:-main}"