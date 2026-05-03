#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--yes] [--dry-run]

Remove jcode binaries, launchers, stored credentials, logs, and local state that
come from the standard install script.

Options:
  --yes      Skip the confirmation prompt.
  --dry-run  Print what would be removed without changing anything.
  --help     Show this help.
EOF
}

info() { printf '\033[1;34m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarning: %s\033[0m\n' "$*" >&2; }
err()  { printf '\033[1;31merror: %s\033[0m\n' "$*" >&2; exit 1; }

DRY_RUN=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --yes|-y)
      ASSUME_YES=true
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      ;;
  esac
  shift
done

OS="$(uname -s)"
INSTALL_DIR="${JCODE_INSTALL_DIR:-$HOME/.local/bin}"
JCODE_DIR="${JCODE_HOME:-$HOME/.jcode}"

if [[ -n "${JCODE_HOME:-}" ]]; then
  APP_CONFIG_DIR="$JCODE_HOME/config/jcode"
elif [[ "$OS" = "Darwin" ]]; then
  APP_CONFIG_DIR="$HOME/Library/Application Support/jcode"
else
  APP_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/jcode"
fi

launcher_path="$INSTALL_DIR/jcode"
path_line="export PATH=\"$INSTALL_DIR:\$PATH\""
installer_marker="# Added by jcode installer"

runtime_dir=""
if [[ -n "${JCODE_RUNTIME_DIR:-}" ]]; then
  runtime_dir="$JCODE_RUNTIME_DIR"
elif [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
  runtime_dir="$XDG_RUNTIME_DIR"
elif [[ "$OS" = "Darwin" && -n "${TMPDIR:-}" ]]; then
  runtime_dir="$TMPDIR"
else
  runtime_dir="${TMPDIR:-/tmp}/jcode-$(id -u)"
fi

mac_targets=()
if [[ "$OS" = "Darwin" ]]; then
  mac_targets=(
    "$HOME/Applications/Jcode.app"
    "$HOME/Applications/jcode.app"
    "$HOME/Library/LaunchAgents/com.jcode.hotkey.plist"
  )
fi

runtime_targets=(
  "$runtime_dir/jcode"
  "$runtime_dir/jcode.sock"
  "$runtime_dir/jcode-debug.sock"
  "$runtime_dir/jcode-daemon.lock"
  "$runtime_dir/jcode.reload"
  "$runtime_dir/jcode-screenshots"
)

remove_path() {
  local path="$1"
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" = true ]]; then
    info "would remove $path"
    return 0
  fi

  rm -rf -- "$path"
  info "removed $path"
}

remove_glob() {
  local pattern="$1"
  shopt -s nullglob
  local matches=( $pattern )
  shopt -u nullglob

  if [[ ${#matches[@]} -eq 0 ]]; then
    return 0
  fi

  local path
  for path in "${matches[@]}"; do
    remove_path "$path"
  done
}

prune_dir_if_empty() {
  local path="$1"
  if [[ ! -d "$path" ]]; then
    return 0
  fi
  if find "$path" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
    return 0
  fi
  if [[ "$DRY_RUN" = true ]]; then
    info "would remove empty directory $path"
    return 0
  fi
  rmdir "$path" 2>/dev/null || true
}

clean_rc_file() {
  local rc="$1"
  [[ -f "$rc" ]] || return 0

  local tmp
  tmp="$(mktemp)"
  awk -v path_line="$path_line" -v marker="$installer_marker" '
    $0 == marker {
      if (getline next_line > 0) {
        if (next_line == path_line) {
          next
        }
        print $0
        print next_line
        next
      }
      next
    }
    $0 == path_line { next }
    { print }
  ' "$rc" > "$tmp"

  if cmp -s "$rc" "$tmp"; then
    rm -f "$tmp"
    return 0
  fi

  if [[ "$DRY_RUN" = true ]]; then
    info "would clean PATH entry from $rc"
    rm -f "$tmp"
    return 0
  fi

  cat "$tmp" > "$rc"
  rm -f "$tmp"
  info "cleaned PATH entry from $rc"
}

confirm() {
  [[ "$ASSUME_YES" = true ]] && return 0

  echo "This will remove jcode binaries, state, credentials, and installer-added PATH entries."
  echo ""
  echo "Paths targeted:"
  echo "  - $launcher_path"
  echo "  - $JCODE_DIR"
  echo "  - $APP_CONFIG_DIR"
  if [[ "$OS" = "Darwin" ]]; then
    local target
    for target in "${mac_targets[@]}"; do
      echo "  - $target"
    done
  fi
  echo ""
  printf 'Continue? [y/N] '
  read -r reply
  case "$reply" in
    y|Y|yes|YES)
      ;;
    *)
      info "Aborted."
      exit 0
      ;;
  esac
}

unload_macos_hotkey_agent() {
  [[ "$OS" = "Darwin" ]] || return 0
  local plist="$HOME/Library/LaunchAgents/com.jcode.hotkey.plist"
  [[ -e "$plist" ]] || return 0

  if [[ "$DRY_RUN" = true ]]; then
    info "would unload LaunchAgent $plist"
    return 0
  fi

  launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
  launchctl unload "$plist" >/dev/null 2>&1 || true
}

confirm
unload_macos_hotkey_agent

remove_path "$launcher_path"
remove_path "$JCODE_DIR"
remove_path "$APP_CONFIG_DIR"

if [[ "$OS" = "Darwin" ]]; then
  for target in "${mac_targets[@]}"; do
    remove_path "$target"
  done
fi

for target in "${runtime_targets[@]}"; do
  remove_path "$target"
done
remove_glob "$runtime_dir/browser-session-"'*.sock'
remove_glob "$runtime_dir/browser-session-"'*.pid'

for rc in \
  "$HOME/.zshenv" \
  "$HOME/.zshrc" \
  "$HOME/.zprofile" \
  "$HOME/.bashrc" \
  "$HOME/.bash_profile" \
  "$HOME/.profile"
do
  clean_rc_file "$rc"
done

prune_dir_if_empty "$INSTALL_DIR"
if [[ "$INSTALL_DIR" = "$HOME/.local/bin" ]]; then
  prune_dir_if_empty "$HOME/.local"
fi

echo ""
if [[ "$DRY_RUN" = true ]]; then
  info "Dry run complete."
else
  info "✅ jcode uninstall complete."
fi
