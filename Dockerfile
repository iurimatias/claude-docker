FROM node:20

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies and common build tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    python3 \
    python3-pip \
    gcc \
    g++ \
    make \
    curl \
    ca-certificates \
    sudo \
    xz-utils \
    zsh \
    tmux \
    neovim \
    jq \
    fzf \
    fd-find \
    ripgrep \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code globally
# Pass --build-arg CLAUDE_CODE_VERSION=<version> to pin, or a changing value
# (e.g. $(date +%s)) to force a cache bust and pull the latest.
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Create workspace and config directories
RUN mkdir -p /workspace /home/node/.claude && \
    chown -R node:node /workspace /home/node/.claude

# Give node user passwordless sudo (safe — we're in a container)
RUN echo "node ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/node

# Prepare /nix directory owned by node for single-user install
# /nix-cache is a shared binary cache volume mount point (used with --nix copy)
RUN mkdir -p /nix /nix-cache && chown -R node:node /nix /nix-cache

# Build parallelism: use all available cores for make/gcc/node
# MAKEFLAGS is set in .bashrc since ENV doesn't expand $(nproc)
ENV NODE_OPTIONS="--max-old-space-size=8192"

# Switch to node user
USER node

# Install Rust toolchain
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="/home/node/.cargo/bin:$PATH"

# Install Nix in single-user mode as the node user
RUN curl -L https://nixos.org/nix/install | sh -s -- --no-daemon
ENV PATH="/home/node/.local/bin:/home/node/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
# Source nix profile in bash so interactive shells pick it up
# MAKEFLAGS uses runtime nproc so it reflects actual container CPU allocation
RUN echo '. /home/node/.nix-profile/etc/profile.d/nix.sh' >> /home/node/.bashrc && \
    echo 'export MAKEFLAGS="-j$(nproc)"' >> /home/node/.bashrc

# Git wrapper — fix submodule object DB permissions before write operations.
# Two problems on Docker bind-mounts (VirtioFS/gRPC-FUSE from macOS):
#   1. Host-side git/nix creates objects owned by host UID
#   2. Git sets pack/idx/rev files to 444 (read-only); on VirtioFS the
#      container can't chmod them back, so subsequent writes fail
# The wrapper chowns + chmods before any git write operation.
RUN mkdir -p /home/node/.local/bin && \
    printf '%s\n' '#!/usr/bin/env bash' \
    'case "$1" in' \
    '  add|commit|stash|merge|rebase|cherry-pick|am|gc|hash-object|reset|checkout)' \
    '    top=$(/usr/bin/git rev-parse --git-common-dir 2>/dev/null)' \
    '    if [ -d "$top/modules" ]; then' \
    '      sudo chown -R node:node "$top/modules" 2>/dev/null' \
    '      sudo find "$top/modules" -type f \( -name "*.pack" -o -name "*.idx" -o -name "*.rev" \) -exec chmod u+w {} + 2>/dev/null' \
    '    fi' \
    '    ;;' \
    'esac' \
    'exec /usr/bin/git "$@"' \
    > /home/node/.local/bin/git && chmod +x /home/node/.local/bin/git

# Prevent git from creating read-only pack files (444) inside the container.
# On VirtioFS bind-mounts, 444 files can't be chmod'd back by the container.
RUN /usr/bin/git config --global core.sharedRepository 0664

# Quiet nix wrapper — injects --quiet unless -v/--verbose is passed
RUN printf '%s\n' '#!/usr/bin/env bash' \
    'for arg in "$@"; do' \
    '  case "$arg" in -v|--verbose) exec /home/node/.nix-profile/bin/nix "$@" ;; esac' \
    'done' \
    'exec /home/node/.nix-profile/bin/nix --quiet "$@"' \
    > /home/node/.local/bin/nix && chmod +x /home/node/.local/bin/nix

# Configure Nix: local binary cache + parallel builds
RUN mkdir -p /home/node/.config/nix && \
    printf '%s\n' \
    'extra-substituters = file:///nix-cache' \
    'require-sigs = false' \
    'max-jobs = auto' \
    'cores = 0' \
    'experimental-features = nix-command flakes' \
    > /home/node/.config/nix/nix.conf

# Keep bash as default shell (Claude Code uses it internally)
# zsh is available for interactive sessions via docker exec

# Configure zsh
COPY --chown=node:node zshrc /home/node/.zshrc

# Inline entrypoint: repair nix profile if stale volume, print VM stats, exec Claude
RUN printf '%s\n' '#!/usr/bin/env bash' \
    '# Repair nix profile: Docker volume may be stale after image rebuild' \
    'if ! /home/node/.nix-profile/bin/nix --version &>/dev/null; then' \
    '  nix_pkg=$(find /nix/store -maxdepth 1 -name "*-nix-*" -type d | grep -E "nix-[0-9]" | head -1)' \
    '  if [ -n "$nix_pkg" ] && [ -x "$nix_pkg/bin/nix" ]; then' \
    '    ln -sfn "$nix_pkg" ~/.local/state/nix/profiles/profile-1-link' \
    '  fi' \
    'fi' \
    'cpus=$(nproc)' \
    'mem=$(awk "/MemTotal/{printf \"%.0fGB\", \$2/1024/1024}" /proc/meminfo)' \
    'shm=$(df -h /dev/shm | awk "NR==2{print \$2}")' \
    'tmp=$(df -h /tmp | awk "NR==2{print \$2}")' \
    'disk=$(df -h /workspace | awk "NR==2{print \$4}")' \
    'nix=$(grep -oP "experimental-features\s*=\s*\K.*" ~/.config/nix/nix.conf 2>/dev/null || echo "none")' \
    'printf "\033[90m  VM: %s cpus | %s ram | %s shm | %s tmp | %s disk free | nix: %s\033[0m\n" "$cpus" "$mem" "$shm" "$tmp" "$disk" "$nix"' \
    'exec /usr/local/bin/claude --dangerously-skip-permissions "$@"' \
    > /home/node/entrypoint.sh && chmod +x /home/node/entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/home/node/entrypoint.sh"]
CMD []
