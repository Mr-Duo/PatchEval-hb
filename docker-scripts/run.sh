#!/usr/bin/env bash
set -euo pipefail

NAME="ndduong"
IMAGE="${NAME}-workspace:latest"
PREFIX="${NAME}-workspace"

# ---- Resource settings (edit as needed) ----
GPUS='"device=0"'      # e.g. '"device=0,1"' or 'all'
MEMORY="32g"
CPUS="8"
SHM_SIZE="8g"
MODE="privileged"      # "privileged" or "sysbox" (sysbox must be installed on the host)
# --------------------------------------------

usage() {
  echo "Usage: $0 [-s suffix] [-d project_dir]"
  echo "  -s  container suffix -> ${PREFIX}-<suffix> (default: first free number 1, 2, 3, ...)"
  echo "  -d  host directory mounted at /workspace (default: current directory)"
  exit 1
}

SUFFIX=""
WORKDIR_HOST="$(pwd)"
while getopts "s:d:h" opt; do
  case "$opt" in
    s) SUFFIX="$OPTARG" ;;
    d) WORKDIR_HOST="$OPTARG" ;;
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
    echo "Pick another suffix, or remove it with: ./stop.sh ${SUFFIX}" >&2
    exit 1
  fi
else
  i=1
  while container_exists "${PREFIX}-${i}"; do
    i=$((i + 1))
  done
  CONTAINER="${PREFIX}-${i}"
fi

echo "Starting container: ${CONTAINER} (mode: ${MODE})"

COMMON_ARGS=(
  -d --init
  --name "${CONTAINER}"
  --memory "${MEMORY}" --memory-swap "${MEMORY}"
  --cpus "${CPUS}"
  --shm-size "${SHM_SIZE}"
  --pids-limit 4096
  -v "${WORKDIR_HOST}":/workspace
)

GPU_ARGS=()
if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then
  GPU_ARGS=(--gpus "${GPUS}")
else
  echo "No NVIDIA runtime on this host: starting without GPU."
fi

case "$MODE" in
  privileged)
    docker run "${COMMON_ARGS[@]}" \
      --privileged \
      ${GPU_ARGS[@]+"${GPU_ARGS[@]}"} \
      -v "${CONTAINER}-docker":/var/lib/docker \
      "${IMAGE}" >/dev/null
    ;;
  sysbox)
    docker run "${COMMON_ARGS[@]}" \
      --runtime=sysbox-runc \
      "${IMAGE}" >/dev/null
    ;;
  *) echo "Error: unknown MODE '${MODE}'" >&2; exit 1 ;;
esac

# Wait for the inner dockerd to come up
echo -n "Waiting for inner Docker daemon"
for _ in $(seq 1 60); do
  if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
    echo; echo "Container exited. Logs:" >&2
    docker logs "${CONTAINER}" >&2 || true
    exit 1
  fi
  docker exec "${CONTAINER}" docker info >/dev/null 2>&1 && break
  echo -n "."; sleep 1
done
echo " ready."

echo "Attaching (detach with Ctrl-a d; re-attach with ./attach.sh ${CONTAINER#${PREFIX}-})"
exec docker exec -it -u "${NAME}" -w /workspace "${CONTAINER}" \
  tmux new-session -A -s main