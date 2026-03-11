#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="claude-sandbox"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_DIR="$HOME/.claude/docker-sessions"
DOCKERFILE_HASH_FILE="$HOME/.claude/docker-image-hash"

# --- Usage ---
usage() {
    cat <<'EOF'
Usage: claude.sh [OPTIONS] [FOLDERS...] [-- CLAUDE_ARGS...]

Options:
  --memory SIZE    Set container memory limit (e.g. 8g, 4096m)
  --gpu            Enable GPU passthrough (--gpus all)
  --no-network     Disable network access inside the container
  --worktree NAME  Run in a git worktree (isolated branch + working dir)
  --sessions       List and manage saved sessions
  --rebuild        Force rebuild the Docker image
  -h, --help       Show this help message

Examples:
  ./claude.sh                              # Current dir, default settings
  ./claude.sh --memory 8g /path/to/project
  ./claude.sh --gpu --memory 16g .
  ./claude.sh --no-network .               # Fully offline/sandboxed
  ./claude.sh --worktree feature-auth      # Isolated worktree session
  ./claude.sh --sessions                   # Manage saved sessions
  ./claude.sh /path/to/project -- -p "fix the tests"
EOF
    exit 0
}

# --- Session management subcommand ---
manage_sessions() {
    mkdir -p "$SESSION_DIR"
    files=("$SESSION_DIR"/*)
    if [ ! -e "${files[0]}" ]; then
        echo "No saved sessions."
        exit 0
    fi

    echo "Saved sessions:"
    echo ""
    i=1
    session_files=()
    for f in "$SESSION_DIR"/*; do
        [ -f "$f" ] || continue
        session_id=$(cat "$f")
        # Try to find the directory from the hash by checking the session metadata
        # We store hash -> session_id, but not the reverse. Show the hash + session_id + age.
        age=$(( ( $(date +%s) - $(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null) ) ))
        if [ "$age" -lt 3600 ]; then
            age_str="$(( age / 60 ))m ago"
        elif [ "$age" -lt 86400 ]; then
            age_str="$(( age / 3600 ))h ago"
        else
            age_str="$(( age / 86400 ))d ago"
        fi
        echo "  $i) $session_id  ($age_str)"
        session_files+=("$f")
        i=$((i + 1))
    done

    echo ""
    echo -n "Delete sessions? [enter numbers, 'all', or empty to cancel] "
    read -r choice </dev/tty || choice=""

    if [ -z "$choice" ]; then
        echo "Cancelled."
        exit 0
    fi

    if [ "$choice" = "all" ]; then
        rm -f "$SESSION_DIR"/*
        echo "All sessions deleted."
        exit 0
    fi

    for num in $choice; do
        idx=$((num - 1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#session_files[@]}" ]; then
            rm -f "${session_files[$idx]}"
            echo "Deleted session $num."
        fi
    done
    exit 0
}

# --- Parse script-level flags (before folders and --) ---
memory_limit=""
gpu_flag=false
no_network=false
force_rebuild=false
worktree_name=""
positional=()

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            ;;
        --sessions)
            manage_sessions
            ;;
        --memory)
            memory_limit="$2"
            shift 2
            ;;
        --gpu)
            gpu_flag=true
            shift
            ;;
        --no-network)
            no_network=true
            shift
            ;;
        --worktree)
            worktree_name="${2:-}"
            if [ -n "$worktree_name" ] && [[ "$worktree_name" != --* ]]; then
                shift 2
            else
                # --worktree without a name: Claude will auto-generate one
                worktree_name="__auto__"
                shift
            fi
            ;;
        --rebuild)
            force_rebuild=true
            shift
            ;;
        *)
            positional+=("$1")
            shift
            ;;
    esac
done
set -- "${positional[@]+"${positional[@]}"}"

# --- Separate folder arguments from claude arguments (split on --) ---
folders=()
claude_args=()
past_separator=false

for arg in "$@"; do
    if [ "$arg" = "--" ]; then
        past_separator=true
        continue
    fi
    if $past_separator; then
        claude_args+=("$arg")
    else
        folders+=("$arg")
    fi
done

# Default to current directory if no folders specified
if [ ${#folders[@]} -eq 0 ]; then
    folders=("$(pwd)")
fi

# --- Auto-rebuild stale image ---
current_hash=$(shasum "$SCRIPT_DIR/Dockerfile" | cut -d' ' -f1)
needs_build=false

if $force_rebuild; then
    needs_build=true
elif ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    needs_build=true
elif [ -f "$DOCKERFILE_HASH_FILE" ]; then
    saved_hash=$(cat "$DOCKERFILE_HASH_FILE")
    if [ "$current_hash" != "$saved_hash" ]; then
        echo "Dockerfile changed since last build. Rebuilding..."
        needs_build=true
    fi
else
    # Image exists but no hash saved — save current hash, skip rebuild
    echo "$current_hash" > "$DOCKERFILE_HASH_FILE"
fi

if $needs_build; then
    echo "Building image '$IMAGE_NAME'..."
    docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
    echo "$current_hash" > "$DOCKERFILE_HASH_FILE"
fi

# --- Build mount arguments ---
mount_args=()
workdir="/workspace"
if [ ${#folders[@]} -eq 1 ]; then
    folder="$(cd "${folders[0]}" && pwd)"
    mount_args+=(-v "$folder:/workspace")
else
    for folder in "${folders[@]}"; do
        abs="$(cd "$folder" && pwd)"
        base="$(basename "$abs")"
        mount_args+=(-v "$abs:/workspace/$base")
    done
    first_abs="$(cd "${folders[0]}" && pwd)"
    workdir="/workspace/$(basename "$first_abs")"
fi

# --- Environment ---
env_args=()
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    env_args+=(-e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY")
fi

mkdir -p "$HOME/.claude"
touch "$HOME/.claude.json"
mkdir -p "$SESSION_DIR"

# --- Auto-resume: check for a saved session for this directory ---
abs_workdir="$(cd "${folders[0]}" && pwd)"
session_hash=$(echo -n "$abs_workdir" | shasum | cut -d' ' -f1)
session_file="$SESSION_DIR/$session_hash"

# --- Worktree: prepend --worktree to claude args ---
if [ -n "$worktree_name" ]; then
    if [ "$worktree_name" = "__auto__" ]; then
        claude_args=("--worktree" ${claude_args[@]+"${claude_args[@]}"})
    else
        claude_args=("--worktree" "$worktree_name" ${claude_args[@]+"${claude_args[@]}"})
    fi
fi

if [ ${#claude_args[@]} -eq 0 ] && [ -f "$session_file" ]; then
    saved_session=$(cat "$session_file")
    echo "Found previous session for $abs_workdir"
    echo "Session: $saved_session"
    echo -n "Resume? [Y/n] "
    read -r answer </dev/tty || answer=""
    if [ "$answer" != "n" ] && [ "$answer" != "N" ]; then
        claude_args=("--resume" "$saved_session")
    fi
fi

# --- Build docker run flags ---
run_args=(-it)

# Memory limit
if [ -n "$memory_limit" ]; then
    run_args+=(--memory "$memory_limit")
fi

# GPU passthrough
if $gpu_flag; then
    run_args+=(--gpus all)
fi

# Network isolation
if $no_network; then
    run_args+=(--network none)
fi

# Container name based on directory
dir_basename=$(basename "$abs_workdir" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')
CONTAINER_NAME="claude-${dir_basename}-$$"

# --- Run ---
docker run \
    "${run_args[@]}" \
    --name "$CONTAINER_NAME" \
    -w "$workdir" \
    --tmpfs /tmp:size=2G \
    -e TERM="$TERM" \
    ${env_args[@]+"${env_args[@]}"} \
    -v "$HOME/.claude:/home/node/.claude" \
    -v "$HOME/.claude.json:/home/node/.claude.json" \
    "${mount_args[@]}" \
    "$IMAGE_NAME" \
    ${claude_args[@]+"${claude_args[@]}"}

EXIT_CODE=$?

# --- Post-mortem: check why the container exited ---
if docker inspect "$CONTAINER_NAME" &>/dev/null; then
    OOM=$(docker inspect --format='{{.State.OOMKilled}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
    REAL_EXIT=$(docker inspect --format='{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")

    if [ "$OOM" = "true" ]; then
        echo ""
        echo "========================================="
        echo " CONTAINER WAS OOM-KILLED"
        echo " Docker ran out of memory."
        if [ -n "$memory_limit" ]; then
            echo " Current limit: $memory_limit"
            echo " Try a higher --memory value."
        else
            echo " Try: ./claude.sh --memory 8g"
            echo " Or increase in Docker Desktop settings"
            echo " (Settings > Resources > Memory)"
        fi
        echo "========================================="
    elif [ "$REAL_EXIT" != "0" ] && [ "$REAL_EXIT" != "unknown" ]; then
        echo ""
        echo "Container exited with code: $REAL_EXIT"
    fi

    # --- Extract session ID from container logs ---
    SESSION_ID=$(docker logs "$CONTAINER_NAME" 2>&1 | grep -oE 'claude --resume [a-f0-9-]+' | tail -1 | awk '{print $3}' || true)
    if [ -n "$SESSION_ID" ]; then
        echo "$SESSION_ID" > "$session_file"
        echo "Session saved for $abs_workdir — will auto-resume next time."
    fi

    # Clean up container
    docker rm "$CONTAINER_NAME" &>/dev/null || true
fi

exit "$EXIT_CODE"
