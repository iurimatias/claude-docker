# History
HISTSIZE=10000
SAVEHIST=10000
HISTFILE=~/.zsh_history
setopt SHARE_HISTORY HIST_IGNORE_DUPS

# Nix
[ -f ~/.nix-profile/etc/profile.d/nix.sh ] && . ~/.nix-profile/etc/profile.d/nix.sh

# Build parallelism — use all available CPUs
export MAKEFLAGS="-j$(nproc)"

# Prompt
PROMPT='%F{blue}%~%f %F{green}❯%f '

# Aliases (Debian package names differ)
alias fd='fdfind'
alias ll='ls -la --color=auto'
alias vim='nvim'

# fzf keybindings
[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ] && source /usr/share/doc/fzf/examples/key-bindings.zsh
[ -f /usr/share/doc/fzf/examples/completion.zsh ] && source /usr/share/doc/fzf/examples/completion.zsh
