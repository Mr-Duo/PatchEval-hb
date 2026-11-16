# PatchEval-hb

A [Harbor](https://github.com/laude-institute/harbor)-format version of the PatchEval dataset, with separate sandbox and verifier environments.

## Requirements

- Docker
- Harbor
- uv

## Install

```bash
bash install.sh
```

## Run

Copy the example config and env files, then fill in your API keys. Check the `run_*.sh` scripts and adjust the config if needed before running.

```bash
# Load environment variables
source ./config/load_env.sh

# Run experiments with the cost-check wrapper
python hb_cost.py run_codex.sh

# Run experiments without the cost check
bash run_codex.sh
```

## Docker workspace (rootless Docker-in-Docker)

`Dockerfile` builds a GPU-ready dev workspace with:

- **Rootless Docker-in-Docker:** the container runs its own unprivileged `dockerd`, so inner images, containers and networks are private. The host's `docker.sock` is never mounted, so the workspace cannot see or touch other users' containers.
- **One GPU for the workspace**, enforced by `--gpus` (no `--privileged`, so other GPUs are not exposed).
- **tmux**, so sessions survive SSH disconnects.
- Your host UID/GID, so files in the mounted folder are owned by you.

Edit `NAME` (username) and the resource settings (`GPUS`, `MEMORY`, `CPUS`, `SHM_SIZE`, `MODE`) in the scripts under `docker-scripts/` before first use.

```bash
# Build (first time, or after Dockerfile changes)
bash docker-scripts/build.sh

# Run: create a new container, mount the current folder at /workspace, attach to tmux
bash docker-scripts/run.sh                 # auto-named: <name>-workspace-1, -2, ...
bash docker-scripts/run.sh -s exp1         # named:      <name>-workspace-exp1
bash docker-scripts/run.sh -d /path/to/dir # mount a different folder

# Attach: re-attach to a running container, or start a stopped one and attach
bash docker-scripts/attach.sh <suffix>

# Stop: stop the container but KEEP it and its inner Docker data
bash docker-scripts/stop.sh <suffix>

# Destroy: stop and REMOVE the container and all its inner Docker data
bash docker-scripts/destroy.sh <suffix>
```

### Data persistence

| Data | `stop.sh` | `destroy.sh` |
|------|-----------|--------------|
| `/workspace` (your host folder) | Kept | Kept |
| Inner Docker images, containers, volumes, build cache | Kept | **Deleted** |
| Container filesystem outside `/workspace` (e.g. `pip install` done by hand) | Kept | **Deleted** |
| tmux sessions and running processes | Lost | Lost |

- Inner images are stored in the Docker volume `<container>-docker` on the host, mounted at `~/.local/share/docker` in the workspace.
- After `stop.sh` and `attach.sh`, inner images are still there, but inner containers that were running are stopped. Start them again with `docker start` or `docker compose up`.
- A stopped container still holds its memory and CPU settings, but uses no GPU, memory or CPU until restarted. Its volume and disk space are kept, so `destroy.sh` containers you no longer need.
- To keep images even after `destroy.sh`, use one shared volume: set the volume line in `run.sh` to `-v "${NAME}-docker-data":/home/${NAME}/.local/share/docker` and remove the `docker volume rm` line from `destroy.sh`. Only one running container may use it at a time.

### Run modes

Set `MODE` in `run.sh`, or pass `-m`.

| Mode | Use for | Isolation |
|------|---------|-----------|
| `rootless` (default) | Shared servers | Inner daemon runs as an unprivileged user. No host devices or disks, no host Docker socket. The GPU limit is enforced. |
| `privileged` | Local testing only | Removes container restrictions: all host devices and disks are exposed, and the one-GPU limit is not enforced. `run.sh` asks for confirmation if it detects a GPU host. |

`rootless` relaxes three security filters (`seccomp`, `apparmor`, `systempaths`) so the inner daemon can create user namespaces. This applies only to your own container and gives no access to the host or other users.

GPUs are detected automatically: if the host Docker has no NVIDIA runtime (e.g. Docker Desktop on a Mac), the container starts without a GPU.

### Limitations

- **Inner containers have no GPU.** The GPU is available in the workspace itself. Containers started by the inner Docker (e.g. Harbor sandboxes and verifiers) run CPU-only. Run GPU work directly in the workspace.
- **May not start on every host.** It needs the host kernel to allow nested user namespaces. If the inner daemon fails, run `docker logs <container>` on the host, which shows the last lines of `~/dockerd.log`.
- Rootless networking and storage are a bit slower than a root daemon.
- Inner containers count against the outer `--memory` and `--cpus` limits.

### tmux

- The prefix is `Ctrl-a`; detach with `Ctrl-a d`. The container keeps running.
- Mouse support is on, and new panes and windows open in the current directory.
- Sessions are lost when the container is stopped or removed.

### Verify the setup

Inside the container:

```bash
docker info | grep -i rootless    # shows rootless; this is the inner daemon, not the host's
docker ps -a                      # only your own inner containers
docker run --rm hello-world       # inner pull and run works
nvidia-smi                        # shows only your assigned GPU (server only)
```

### Notes

- Never mount the host's `/var/run/docker.sock` into the workspace, and never use `--privileged` on a shared server.
- Inner images live in the Docker volume `<container>-docker` and are deleted only by `destroy.sh`.
- `newuidmap`/`newgidmap` use file capabilities instead of the setuid bit, which fixes rootless Docker on hosts where Docker is installed as a snap.
- Always rebuild on the machine you will run on, since architectures may differ.
- Inner daemon log: `~/dockerd.log` inside the container.