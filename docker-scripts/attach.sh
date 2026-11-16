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

exec docker exec -it -w /workspace "${cname}" \
  tmux new-session -A -s "${2:-main}"