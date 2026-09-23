#!/usr/bin/env bash
# Shared helpers for Wiz CLI git hooks.

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
CONF_PATH="${WIZ_GIT_HOOK_CONF:-$HOOKS_DIR/wiz-git-hook.conf}"

load_wiz_conf() {
  if [[ ! -f "$CONF_PATH" ]]; then
    echo "Wiz git hook: missing config at $CONF_PATH" >&2
    echo "Copy $HOOKS_DIR/wiz-git-hook.conf.example to wiz-git-hook.conf, chmod 600, and set cli_path / credentials." >&2
    exit 1
  fi

  local owner mode
  if stat -f '%u %OLp' "$CONF_PATH" >/dev/null 2>&1; then
    owner="$(stat -f '%u' "$CONF_PATH")"
    mode="$(stat -f '%OLp' "$CONF_PATH")"
  else
    owner="$(stat -c '%u' "$CONF_PATH")"
    mode="$(stat -c '%a' "$CONF_PATH")"
  fi

  if [[ "$owner" != "$(id -u)" ]]; then
    echo "Wiz git hook: $CONF_PATH must be owned by the current user." >&2
    exit 1
  fi

  if [[ "$mode" != "600" && "$mode" != "400" ]]; then
    echo "Wiz git hook: $CONF_PATH must be chmod 600 (or 400)." >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$CONF_PATH"

  cli_path="${cli_path:-wiz}"
  if ! command -v "$cli_path" >/dev/null 2>&1 && [[ ! -x "$cli_path" ]]; then
    echo "Wiz git hook: CLI not found at '$cli_path'. Install Wiz CLI or update cli_path in $CONF_PATH." >&2
    exit 1
  fi
}

collect_policies() {
  local line
  local -a policies=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] && policies+=("$line")
  done <<< "${wiz_policies:-}"

  if [[ ${#policies[@]} -eq 0 ]]; then
    echo "Wiz git hook: wiz_policies is empty in $CONF_PATH." >&2
    exit 1
  fi

  local IFS=','
  printf '%s' "${policies[*]}"
}

run_wiz_dir_scan() {
  local scan_path="$1"
  local policies
  policies="$(collect_policies)"

  echo "Wiz git hook: scanning $scan_path" >&2
  "$cli_path" scan dir "$scan_path" --no-publish --policies "$policies"
}

device_id() {
  if stat -f '%d' "$1" >/dev/null 2>&1; then
    stat -f '%d' "$1"
  else
    stat -c '%d' "$1"
  fi
}

is_same_filesystem() {
  local left="$1"
  local right="$2"
  [[ "$(device_id "$left")" == "$(device_id "$right")" ]]
}

secure_remove_path() {
  local path="$1"
  [[ -e "$path" ]] || return 0

  if [[ -d "$path" ]]; then
    if command -v shred >/dev/null 2>&1; then
      find "$path" -type f -exec shred -u {} + 2>/dev/null || true
    elif [[ "$(uname -s)" == "Darwin" ]]; then
      find "$path" -type f -exec rm -P {} + 2>/dev/null || true
    fi
    rm -rf "$path"
  else
    if command -v shred >/dev/null 2>&1; then
      shred -u "$path" 2>/dev/null || rm -f "$path"
    elif [[ "$(uname -s)" == "Darwin" ]]; then
      rm -P "$path" 2>/dev/null || rm -f "$path"
    else
      rm -f "$path"
    fi
  fi
}

link_or_copy_staged_file() {
  local src="$1"
  local dest="$2"
  local action="cp"

  mkdir -p "$(dirname "$dest")"
  if is_same_filesystem "$src" "$(dirname "$dest")"; then
    action="ln"
  fi
  "$action" "$src" "$dest"
}
