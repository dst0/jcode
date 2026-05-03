#!/usr/bin/env bash
# scripts/docker_dev.sh
#
# Build jcode inside a Docker container and optionally run it there.
# The container gets full access to the host's network stack via
# --network=host (Linux) so that local LLM servers, OAuth callbacks, and
# any other localhost services are reachable at 127.0.0.1 exactly as they
# are on the host.
#
# On macOS / Windows, --network=host works differently (Docker runs inside a
# VM), so this script automatically falls back to mapping the host via the
# special DNS name "host.docker.internal" instead of sharing the network
# namespace.
#
# Quick-start:
#   scripts/docker_dev.sh               # build image + start interactive shell
#   scripts/docker_dev.sh --build-only  # build the Docker image and exit
#   scripts/docker_dev.sh --install     # build jcode inside container, install, then attach
#   scripts/docker_dev.sh --ssh         # also start the in-container SSH daemon (port 2222)
#   scripts/docker_dev.sh --exec        # exec a shell into the already-running container
#   scripts/docker_dev.sh --stop        # stop and remove the container
#
# Provider configuration:
#   The script mounts ~/.jcode and ~/.config/jcode (read-write) into the
#   container so every credential, config.toml, and env file you have on the
#   host is transparently available inside the container.
#   You can also pass arbitrary env vars with --env NAME=VALUE (repeatable).
#
# SSH access (--ssh flag):
#   The container's SSH daemon listens on host port 2222.
#   Authorized key:  ~/.ssh/id_rsa.pub (or override with SSH_PUBKEY_FILE env).
#   Connect with:   ssh -p 2222 root@localhost
#   VS Code:        Remote-SSH → root@localhost:2222
#
# Environment variables that influence this script:
#   JCODE_DEV_IMAGE      Docker image tag to use (default: jcode-dev)
#   JCODE_DEV_CONTAINER  Container name (default: jcode-dev)
#   SSH_PUBKEY_FILE      Path to the SSH public key to inject (default: ~/.ssh/id_rsa.pub)
#   JCODE_DEV_EXTRA_MOUNTS  Space-separated list of extra -v mount specs
#   JCODE_DEV_CACHE_DIR  sccache / cargo cache directory on the host
#                        (default: ~/.cache/jcode-docker-dev)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE="${JCODE_DEV_IMAGE:-jcode-dev}"
CONTAINER="${JCODE_DEV_CONTAINER:-jcode-dev}"
CACHE_DIR="${JCODE_DEV_CACHE_DIR:-$HOME/.cache/jcode-docker-dev}"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-$HOME/.ssh/id_rsa.pub}"

# ── helpers ────────────────────────────────────────────────────────────────────
info()  { printf '\033[1;34m[docker-dev] %s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m[docker-dev] warning: %s\033[0m\n' "$*" >&2; }
err()   { printf '\033[1;31m[docker-dev] error: %s\033[0m\n' "$*" >&2; exit 1; }

require_docker() {
  command -v docker >/dev/null 2>&1 || err "docker not found – install Docker Desktop or Docker Engine first"
  docker info >/dev/null 2>&1       || err "Docker daemon is not running"
}

# Detect whether --network=host gives true host-network sharing (Linux only).
use_host_network() {
  [[ "$(uname -s)" == "Linux" ]]
}

# ── option parsing ──────────────────────────────────────────────────────────────
MODE="shell"
DO_INSTALL=false
ENABLE_SSH=false
EXTRA_ENVS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only)   MODE="build-only" ;;
    --install)      DO_INSTALL=true ;;
    --ssh)          ENABLE_SSH=true ;;
    --exec)         MODE="exec" ;;
    --stop)         MODE="stop" ;;
    --env)
      shift
      [[ $# -gt 0 ]] || err "--env requires an argument"
      EXTRA_ENVS+=("$1")
      ;;
    --env=*)
      EXTRA_ENVS+=("${1#--env=}")
      ;;
    -h|--help)
      sed -n '2,50p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      err "Unknown option: $1  (run with --help for usage)"
      ;;
  esac
  shift
done

require_docker

# ── build Docker image ─────────────────────────────────────────────────────────
build_image() {
  info "Building Docker image '$IMAGE' from scripts/Dockerfile.dev …"
  # Use scripts/ as the build context — the Dockerfile does not COPY anything
  # from the repo root, so there is no need to send the (potentially large)
  # target/ directory and other repo files to the Docker daemon.
  docker build \
    -f "$SCRIPT_DIR/Dockerfile.dev" \
    -t "$IMAGE" \
    "$SCRIPT_DIR"
  info "Image '$IMAGE' built successfully."
}

if [[ "$MODE" == "build-only" ]]; then
  build_image
  exit 0
fi

# If the image doesn't exist yet, build it automatically.
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  build_image
fi

# ── stop / remove ──────────────────────────────────────────────────────────────
if [[ "$MODE" == "stop" ]]; then
  if docker ps -q --filter "name=^${CONTAINER}$" | grep -q .; then
    info "Stopping container '$CONTAINER' …"
    docker stop "$CONTAINER"
  fi
  if docker ps -aq --filter "name=^${CONTAINER}$" | grep -q .; then
    info "Removing container '$CONTAINER' …"
    docker rm "$CONTAINER"
  fi
  info "Done."
  exit 0
fi

# ── exec into existing container ───────────────────────────────────────────────
if [[ "$MODE" == "exec" ]]; then
  if ! docker ps -q --filter "name=^${CONTAINER}$" | grep -q .; then
    err "Container '$CONTAINER' is not running. Start it first without --exec."
  fi
  exec docker exec -it "$CONTAINER" /bin/bash -l
fi

# ── check for an already-running container ─────────────────────────────────────
if docker ps -q --filter "name=^${CONTAINER}$" | grep -q .; then
  info "Container '$CONTAINER' is already running."
  info "Attaching a new shell (use --exec to open another shell in the same container)."
  exec docker exec -it "$CONTAINER" /bin/bash -l
fi

# Remove a stopped container of the same name so we can recreate it.
if docker ps -aq --filter "name=^${CONTAINER}$" | grep -q .; then
  info "Removing stopped container '$CONTAINER' …"
  docker rm "$CONTAINER"
fi

# ── prepare mounts and caches ─────────────────────────────────────────────────
mkdir -p \
  "$CACHE_DIR/cargo-registry" \
  "$CACHE_DIR/cargo-git" \
  "$CACHE_DIR/sccache" \
  "$CACHE_DIR/target"

# jcode config / credentials (host paths that may not exist yet)
JCODE_CONFIG_HOST="$HOME/.config/jcode"
JCODE_DATA_HOST="$HOME/.jcode"
mkdir -p "$JCODE_CONFIG_HOST" "$JCODE_DATA_HOST"

# ── network flags ─────────────────────────────────────────────────────────────
NET_ARGS=()
if use_host_network; then
  NET_ARGS=(--network host)
  info "Using --network=host (Linux): all host ports reachable at 127.0.0.1"
else
  # macOS / Windows: host is reachable via the special DNS name
  NET_ARGS=(--add-host "host.docker.internal:host-gateway")
  warn "Non-Linux host detected: host ports are reachable inside the container"
  warn "  as 'host.docker.internal' rather than '127.0.0.1'."
  warn "  Update your provider base URLs accordingly (e.g. http://host.docker.internal:8000/v1)."
fi

# ── SSH publish ────────────────────────────────────────────────────────────────
# With --network=host the container shares the host's network namespace, so
# Docker's -p publish flags are ignored.  We start sshd inside the container
# on port 2222 (instead of 22) to avoid colliding with the host's SSH server.
# Without host networking we publish container port 22 → host port 2222.
SSH_PUBLISH_ARGS=()
SSH_SETUP_CMDS=()
SSHD_PORT=22        # port sshd binds inside the container
SSH_HOST_PORT=2222  # port the user connects to on the host
if [[ "$ENABLE_SSH" == true ]]; then
  if use_host_network; then
    # Host networking: -p flags are silently ignored by Docker; run sshd on
    # an unprivileged port that won't clash with the host's sshd on port 22.
    SSHD_PORT=2222
    SSH_SETUP_CMDS+=("sed -i 's/^#\?Port .*/Port 2222/' /etc/ssh/sshd_config")
  else
    # Bridge/default networking: sshd listens on 22 inside the container;
    # Docker maps host:2222 → container:22.
    SSH_PUBLISH_ARGS=(-p "2222:22")
    SSHD_PORT=22
  fi

  # Inject authorized key
  if [[ -f "$SSH_PUBKEY_FILE" ]]; then
    PUBKEY="$(cat "$SSH_PUBKEY_FILE")"
    SSH_SETUP_CMDS+=(
      "mkdir -p /root/.ssh"
      "echo '$PUBKEY' >> /root/.ssh/authorized_keys"
      "chmod 600 /root/.ssh/authorized_keys"
    )
    info "SSH enabled on host port $SSH_HOST_PORT (authorized key: $SSH_PUBKEY_FILE)"
    info "Connect with: ssh -p $SSH_HOST_PORT root@localhost"
  else
    warn "SSH requested but no public key found at $SSH_PUBKEY_FILE"
    warn "Set SSH_PUBKEY_FILE to point to your public key, or add keys manually:"
    warn "  docker exec $CONTAINER bash -c \"echo '<pubkey>' >> /root/.ssh/authorized_keys\""
  fi
fi

# ── extra user mounts ──────────────────────────────────────────────────────────
EXTRA_MOUNT_ARGS=()
for spec in ${JCODE_DEV_EXTRA_MOUNTS:-}; do
  EXTRA_MOUNT_ARGS+=(-v "$spec")
done

# ── env flags ─────────────────────────────────────────────────────────────────
ENV_ARGS=()
for e in "${EXTRA_ENVS[@]+"${EXTRA_ENVS[@]}"}"; do
  ENV_ARGS+=(-e "$e")
done

# ── run container ─────────────────────────────────────────────────────────────
info "Starting container '$CONTAINER' …"

docker run -d \
  --name "$CONTAINER" \
  "${NET_ARGS[@]}" \
  "${SSH_PUBLISH_ARGS[@]+"${SSH_PUBLISH_ARGS[@]}"}" \
  -e CARGO_TERM_COLOR=always \
  -e RUSTUP_HOME=/root/.rustup \
  -e CARGO_HOME=/root/.cargo \
  -e CARGO_TARGET_DIR=/work/target/docker \
  "${ENV_ARGS[@]+"${ENV_ARGS[@]}"}" \
  -v "$REPO_ROOT:/work" \
  -v "$JCODE_DATA_HOST:/root/.jcode" \
  -v "$JCODE_CONFIG_HOST:/root/.config/jcode" \
  -v "$CACHE_DIR/cargo-registry:/root/.cargo/registry" \
  -v "$CACHE_DIR/cargo-git:/root/.cargo/git" \
  -v "$CACHE_DIR/sccache:/root/.cache/sccache" \
  -v "$CACHE_DIR/target:/work/target/docker" \
  "${EXTRA_MOUNT_ARGS[@]+"${EXTRA_MOUNT_ARGS[@]}"}" \
  -w /work \
  --init \
  "$IMAGE" \
  sleep infinity

# SSH daemon setup (deferred so the container is running first)
for cmd in "${SSH_SETUP_CMDS[@]+"${SSH_SETUP_CMDS[@]}"}"; do
  docker exec "$CONTAINER" bash -c "$cmd"
done
if [[ "$ENABLE_SSH" == true ]]; then
  docker exec -d "$CONTAINER" /usr/sbin/sshd -D -p "$SSHD_PORT"
fi

# ── optional in-container build & install ─────────────────────────────────────
if [[ "$DO_INSTALL" == true ]]; then
  info "Building jcode inside the container (release profile) …"
  docker exec -it "$CONTAINER" bash -lc "
    set -euo pipefail
    sccache --start-server 2>/dev/null || true
    scripts/dev_cargo.sh build --release -p jcode --bin jcode
    install -Dm755 \"\$CARGO_TARGET_DIR/release/jcode\" /root/.local/bin/jcode
    echo ''
    echo 'jcode installed.'
    /root/.local/bin/jcode --version
  "
fi

# ── attach interactive shell ───────────────────────────────────────────────────
info "Container '$CONTAINER' is running."
info "Source tree is mounted at /work inside the container."
info ""
info "Useful commands inside the container:"
info "  scripts/dev_cargo.sh build --release -p jcode --bin jcode   # fast build"
info "  scripts/install_release.sh                                    # install to ~/.local/bin"
info "  jcode --version                                               # verify install"
info ""
info "To open another shell later:  scripts/docker_dev.sh --exec"
info "To stop the container:        scripts/docker_dev.sh --stop"
if [[ "$ENABLE_SSH" == true ]]; then
  info "SSH:  ssh -p $SSH_HOST_PORT root@localhost"
fi
info ""

exec docker exec -it "$CONTAINER" /bin/bash -l
