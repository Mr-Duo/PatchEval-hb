#!/usr/bin/env bash
set -euo pipefail

NAME="ndduong"
IMAGE="${NAME}-workspace"
CONTEXT="$(pwd)"

cd "$(dirname "$0")"

docker build \
  --build-arg UID="$(id -u)" \
  --build-arg GID="$(id -g)" \
  --build-arg USERNAME="${NAME}" \
  -t "${IMAGE}:latest" "${CONTEXT}"

echo "Built image: ${IMAGE}:latest"
