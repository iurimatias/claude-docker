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
RUN npm install -g @anthropic-ai/claude-code

# Create workspace and config directories
RUN mkdir -p /workspace /home/node/.claude && \
    chown -R node:node /workspace /home/node/.claude

# Give node user passwordless sudo (safe — we're in a container)
RUN echo "node ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/node

# Prepare /nix directory owned by node for single-user install
RUN mkdir -p /nix && chown -R node:node /nix

# Switch to node user
ENV PATH="/home/node/.local/bin:$PATH"
USER node

# Install Nix in single-user mode as the node user
RUN curl -L https://nixos.org/nix/install | sh -s -- --no-daemon
ENV PATH="/home/node/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
# Source nix profile in bash so interactive shells pick it up
RUN echo '. /home/node/.nix-profile/etc/profile.d/nix.sh' >> /home/node/.bashrc

# Keep bash as default shell (Claude Code uses it internally)
# zsh is available for interactive sessions via docker exec

# Configure zsh
COPY --chown=node:node zshrc /home/node/.zshrc

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/claude", "--dangerously-skip-permissions"]
CMD []
