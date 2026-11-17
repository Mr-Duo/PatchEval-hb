#!/usr/bin/env bash
set -euo pipefail

NAME="ndduong"
IMAGE="${NAME}-workspace:latest"
PREFIX="${NAME}-workspace"

# ---- Resource settings (edit as needed) ----
GPUS='"device=0"'      # your assigned GPU, e.g. '"device=0"'
MEMORY="32g"
CPUS="8"
SHM_SIZE="8g"
MODE="rootless"        # "rootless" (default, safe) or "privileged" (local testing only)
# --------------------------------------------

usage() {
  echo "Usage: $0 [-s suffix] [-d project_dir] [-D docker_data_dir] [-m rootless|privileged]"
  echo "  -s  container suffix -> ${PREFIX}-<suffix> (default: first free number 1, 2, 3, ...)"
  echo "  -d  host directory mounted at /workspace (default: current directory)"
  echo "  -D  host directory for the inner Docker data (default: <parent of project_dir>/docker-data/<container>)"
  echo "  -m  run mode (default: ${MODE})"
  exit 1
}

SUFFIX=""
WORKDIR_HOST="$(pwd)"
DOCKER_DATA_HOST=""
while getopts "s:d:D:m:h" opt; do
  case "$opt" in
    s) SUFFIX="$OPTARG" ;;
    d) WORKDIR_HOST="$OPTARG" ;;
    D) DOCKER_DATA_HOST="$OPTARG" ;;
    m) MODE="$OPTARG" ;;
    *) usage ;;
  esac
done

# docker -v needs an absolute path (a relative one is treated as a volume name)
WORKDIR_HOST="$(cd "$WORKDIR_HOST" && pwd)"

container_exists() {
  docker ps -a --format '{{.Names}}' | grep -qx "$1"
}

if [ -n "$SUFFIX" ]; then
  CONTAINER="${PREFIX}-${SUFFIX}"
  if container_exists "$CONTAINER"; then
    echo "Error: container '${CONTAINER}' already exists." >&2
    echo "Pick another suffix, re-attach with ./attach.sh ${SUFFIX}, or delete it with ./destroy.sh ${SUFFIX}" >&2
    exit 1
  fi
else
  i=1
  while container_exists "${PREFIX}-${i}"; do
    i=$((i + 1))
  done
  CONTAINER="${PREFIX}-${i}"
fi

# GPU: only pass --gpus if the host Docker has an NVIDIA runtime
HAS_NVIDIA=0
GPU_ARGS=()
if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then
  HAS_NVIDIA=1
  GPU_ARGS=(--gpus "${GPUS}")
else
  echo "No NVIDIA runtime on this host: starting without GPU."
fi

# Guardrail: privileged on a GPU server defeats the one-GPU policy
if [ "$MODE" = "privileged" ] && [ "$HAS_NVIDIA" = "1" ]; then
  echo "WARNING: privileged mode on a GPU host exposes ALL host devices and disks."
  echo "         It bypasses the one-GPU limit and can affect other users."
  read -r -p "Continue anyway? (y/N): " ans
  case "$ans" in [yY]|[yY][eE][sS]) ;; *) echo "Aborted."; exit 0 ;; esac
fi

# Inner Docker data dir: use -D if given, else a sibling of the workspace dir
if [ -z "$DOCKER_DATA_HOST" ]; then
  DOCKER_DATA_HOST="$(dirname "${WORKDIR_HOST}")/docker-data/${CONTAINER}"
fi
mkdir -p "$DOCKER_DATA_HOST"
DOCKER_DATA_HOST="$(cd "$DOCKER_DATA_HOST" && pwd)"   # absolute path, required for -v
echo "Inner Docker data: ${DOCKER_DATA_HOST}"

echo "Starting container: ${CONTAINER} (mode: ${MODE})"

COMMON_ARGS=(
  -d --init
  --name "${CONTAINER}"
  --memory "${MEMORY}" --memory-swap "${MEMORY}"
  --cpus "${CPUS}"
  --shm-size "${SHM_SIZE}"
  --pids-limit 4096
  -v "${WORKDIR_HOST}":/workspace
  -v "${DOCKER_DATA_HOST}":/home/${NAME}/.local/share/docker
)

case "$MODE" in
  rootless)
    docker run "${COMMON_ARGS[@]}" \
      ${GPU_ARGS[@]+"${GPU_ARGS[@]}"} \
      --security-opt seccomp=unconfined \
      --security-opt apparmor=unconfined \
      --security-opt systempaths=unconfined \
      --device /dev/net/tun --device /dev/fuse \
      "${IMAGE}" >/dev/null
    ;;
  privileged)
    docker run "${COMMON_ARGS[@]}" \
      ${GPU_ARGS[@]+"${GPU_ARGS[@]}"} \
      --privileged \
      "${IMAGE}" >/dev/null
    ;;
  *) echo "Error: unknown MODE '${MODE}' (use rootless or privileged)" >&2; exit 1 ;;
esac

# Wait for the inner dockerd to come up
echo -n "Waiting for inner Docker daemon"
for _ in $(seq 1 60); do
  if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
    echo; echo "Container exited. Logs:" >&2
    docker logs "${CONTAINER}" >&2 || true
    echo "Clean up with: ./destroy.sh ${CONTAINER#${PREFIX}-}" >&2
    exit 1
  fi
  docker exec "${CONTAINER}" docker info >/dev/null 2>&1 && break
  echo -n "."; sleep 1
done
echo " ready."

echo "Attaching (detach with Ctrl-a d; re-attach with ./attach.sh ${CONTAINER#${PREFIX}-})"
exec docker exec -it -w /workspace "${CONTAINER}" \
  tmux new-session -A -s main