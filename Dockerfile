# syntax=docker/dockerfile:1
# ---------------------------------------------------------------
# GPU-ready dev workspace with rootless Docker-in-Docker + tmux
#
# The inner dockerd runs as an unprivileged user INSIDE the container.
# The host's docker.sock is never mounted, so this container cannot see
# or touch other users' containers. The GPU (--gpus) goes to the
# workspace only; inner containers are CPU-only.
#
# Use build.sh / run.sh / attach.sh / stop.sh rather than raw docker commands.
# ---------------------------------------------------------------

FROM nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TERM=xterm-256color \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

# System packages (iptables/iproute2 are needed by the rootless daemon's network namespace)
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv python-is-python3 \
        git curl wget vim nano tmux htop build-essential ca-certificates \
        gnupg lsb-release tzdata less jq unzip openssh-client \
        iptables iproute2 kmod pigz xz-utils \
    && update-alternatives --set iptables  /usr/sbin/iptables-legacy \
    && update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy \
    && rm -rf /var/lib/apt/lists/*

# Docker Engine + rootless extras
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
        docker-ce-rootless-extras uidmap slirp4netns fuse-overlayfs \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y --no-install-recommends libcap2-bin \
    && chmod u-s /usr/bin/newuidmap /usr/bin/newgidmap \
    && setcap cap_setuid=ep /usr/bin/newuidmap \
    && setcap cap_setgid=ep /usr/bin/newgidmap \
    && rm -rf /var/lib/apt/lists/*

# Non-root user matching host UID/GID.
# If the GID already exists in the image (e.g. 20 = dialout), reuse it.
ARG USERNAME=dev
ARG UID=1000
ARG GID=1000
RUN (getent group ${GID} >/dev/null || groupadd -g ${GID} ${USERNAME}) \
    && useradd -m -u ${UID} -g ${GID} -s /bin/bash ${USERNAME} \
    && (grep -q "^${USERNAME}:" /etc/subuid || echo "${USERNAME}:100000:65536" >> /etc/subuid) \
    && (grep -q "^${USERNAME}:" /etc/subgid || echo "${USERNAME}:100000:65536" >> /etc/subgid)

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

# Entrypoint: start the rootless inner dockerd, wait until ready, run CMD, stop cleanly
RUN cat > /usr/local/bin/entrypoint.sh <<'EOF'
#!/usr/bin/env bash
set -e
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
rm -rf "$XDG_RUNTIME_DIR"/* 2>/dev/null || true

dockerd-rootless.sh > "$HOME/dockerd.log" 2>&1 &
DPID=$!

for _ in $(seq 1 60); do
    docker info >/dev/null 2>&1 && break
    kill -0 "$DPID" 2>/dev/null || break
    sleep 1
done
if ! docker info >/dev/null 2>&1; then
    echo "Inner dockerd failed to start. Last log lines:" >&2
    tail -n 50 "$HOME/dockerd.log" >&2
    exit 1
fi

trap 'kill -TERM "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; exit 0' TERM INT
"$@" &
wait $!
EOF
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && git config --system --add safe.directory '*'

# Workspace + inner Docker data dir (created and owned by the user BEFORE the
# VOLUME line, so the named volume inherits the right ownership)
WORKDIR /workspace
RUN chown ${UID}:${GID} /workspace \
    && mkdir -p /home/${USERNAME}/.local/share/docker /home/${USERNAME}/.run \
    && chown -R ${UID}:${GID} /home/${USERNAME}/.local /home/${USERNAME}/.run
VOLUME /home/${USERNAME}/.local/share/docker

ENV XDG_RUNTIME_DIR=/home/${USERNAME}/.run \
    DOCKER_HOST=unix:///home/${USERNAME}/.run/docker.sock \
    PATH="/home/${USERNAME}/.local/bin:${PATH}"

USER ${USERNAME}

# Python dependencies (edit requirements.txt for your project)
COPY --chown=${UID}:${GID} requirements.txt* /tmp/
RUN python -m pip install --upgrade pip \
    && if [ -f /tmp/requirements.txt ]; then pip install -r /tmp/requirements.txt; fi
# RUN pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]