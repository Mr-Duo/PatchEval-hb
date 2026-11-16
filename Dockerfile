# syntax=docker/dockerfile:1
# ---------------------------------------------------------------
# GPU-ready dev environment with true Docker-in-Docker + tmux
#
# Build:
#   docker build \
#     --build-arg UID=$(id -u) --build-arg GID=$(id -g) --build-arg USERNAME=$(whoami) \
#     -t $(whoami)/work:latest .
#
# Run, option A (recommended on a shared server): Sysbox runtime, no --privileged
#   docker run -d --init --runtime=sysbox-runc \
#     --name $(whoami)-work \
#     --memory 32g --memory-swap 32g --cpus 8 --shm-size 8g \
#     -v /path/to/your/project:/workspace \
#     $(whoami)/work:latest
#
# Run, option B (no Sysbox): --privileged
#   docker run -d --init --privileged \
#     --name $(whoami)-work \
#     --gpus '"device=0"' \
#     --memory 32g --memory-swap 32g --cpus 8 --shm-size 8g \
#     -v docker-data-$(whoami):/var/lib/docker \
#     -v /path/to/your/project:/workspace \
#     $(whoami)/work:latest
#
# Attach as yourself, in a persistent tmux session:
#   docker exec -it -u $(whoami) $(whoami)-work tmux new-session -A -s main
#
# Inner daemon logs: docker exec $(whoami)-work tail -f /var/log/dockerd.log
# Inner GPU test:    docker exec -u $(whoami) $(whoami)-work \
#                      docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
# ---------------------------------------------------------------

FROM nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TERM=xterm-256color \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

# System packages (iptables/iproute2/kmod etc. are needed by dockerd)
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv python-is-python3 \
        git curl wget vim nano tmux htop build-essential ca-certificates \
        gnupg lsb-release tzdata less jq unzip openssh-client \
        iptables iproute2 kmod pigz xz-utils e2fsprogs \
    && update-alternatives --set iptables  /usr/sbin/iptables-legacy \
    && update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy \
    && rm -rf /var/lib/apt/lists/*

# Full Docker Engine (daemon + CLI + compose + buildx)
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# NVIDIA Container Toolkit so INNER containers can use the GPU too
RUN curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
    && curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list \
    && apt-get update && apt-get install -y --no-install-recommends nvidia-container-toolkit \
    && nvidia-ctk runtime configure --runtime=docker \
    # nested containers usually can't manage device cgroups themselves
    && nvidia-ctk config --set nvidia-container-cli.no-cgroups --in-place \
    && rm -rf /var/lib/apt/lists/*

# Non-root user matching host UID/GID, in the (inner) docker group
ARG USERNAME=dev
ARG UID=1000
ARG GID=1000
RUN (getent group ${GID} >/dev/null || groupadd -g ${GID} ${USERNAME}) \
    && useradd -m -u ${UID} -g ${GID} -s /bin/bash ${USERNAME} \
    && usermod -aG docker ${USERNAME}

# tmux config (system-wide)
RUN cat > /etc/tmux.conf <<'EOF'
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",*256col*:Tc"
set -g mouse on
set -g history-limit 50000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -sg escape-time 10
set -g status-interval 5
unbind C-b
set -g prefix C-a
bind C-a send-prefix
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind c new-window -c "#{pane_current_path}"
bind r source-file /etc/tmux.conf \; display "reloaded"
EOF

# Entrypoint: start the inner Docker daemon, wait until ready, then run CMD
RUN cat > /usr/local/bin/entrypoint.sh <<'EOF'
#!/usr/bin/env bash
set -e
rm -f /var/run/docker.pid /var/run/docker.sock
dockerd --host=unix:///var/run/docker.sock --group docker \
    > /var/log/dockerd.log 2>&1 &
DOCKERD_PID=$!
for _ in $(seq 1 60); do
    docker info >/dev/null 2>&1 && break
    sleep 1
done
docker info >/dev/null 2>&1 || { echo "dockerd failed to start:" >&2; tail -n 50 /var/log/dockerd.log >&2; exit 1; }

trap 'kill -TERM "$DOCKERD_PID" 2>/dev/null; wait "$DOCKERD_PID" 2>/dev/null; exit 0' TERM INT
"$@" &
wait $!
EOF
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && git config --system --add safe.directory '*'

WORKDIR /workspace
RUN chown ${UID}:${GID} /workspace

# Python deps installed as the normal user
USER ${USERNAME}
ENV PATH="/home/${USERNAME}/.local/bin:${PATH}"
COPY --chown=${UID}:${GID} requirements.txt* /tmp/
RUN python -m pip install --upgrade pip \
    && if [ -f /tmp/requirements.txt ]; then pip install -r /tmp/requirements.txt; fi
# RUN pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124

# Back to root: dockerd must start as root. Use `docker exec -u <you>` to log in.
USER root
VOLUME /var/lib/docker
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]