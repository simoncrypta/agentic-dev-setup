#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

unset BASH_ENV
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  [[ "$expected" == "$actual" ]] || fail "${msg}: expected '$expected' got '$actual'"
}
assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  [[ "$haystack" == *"$needle"* ]] || fail "${msg}: missing '$needle' in '$haystack'"
}

export HOME="$TMP_DIR/home"
export XDG_CONFIG_HOME="$HOME/.config"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$ROOT/lib/detect.sh"
# shellcheck source=lib/deps.sh
source "$ROOT/lib/deps.sh"
# shellcheck source=lib/config.sh
source "$ROOT/lib/config.sh"

export INSTALL_SRC="$ROOT"
export AGENTIC_DEV_CONFIG_DIR="$XDG_CONFIG_HOME/agentic-dev"
export AGENTIC_DEV_USER_CONFIG="$AGENTIC_DEV_CONFIG_DIR/config.toml"
unset EDITOR
YES=1
DRY_RUN=0

info() { :; }
warn() { printf '%s\n' "$*" >&2; }

if grep -Eq '^[[:space:]]*default_shell[[:space:]]*=' "$ROOT/config/herdr/config.toml"; then
  fail "shipped herdr config must not set default_shell (macOS /bin/bash nags to switch to zsh)"
fi
grep -Eq '^[[:space:]]*shell_mode[[:space:]]*=[[:space:]]*"auto"' "$ROOT/config/herdr/config.toml" \
  || fail "shipped herdr config must set shell_mode = auto (login on macOS, non-login on Linux)"

saved_shell="${SHELL:-}"
SHELL=/bin/zsh
assert_eq "zsh" "$(detect_shell_name)" "detect_shell_name follows zsh \$SHELL"
assert_eq "${HOME}/.zshrc" "$(shell_rc_for zsh)" "zsh rc is ~/.zshrc"
SHELL=/bin/bash
assert_eq "bash" "$(detect_shell_name)" "detect_shell_name follows bash \$SHELL"
assert_eq "${HOME}/.bashrc" "$(shell_rc_for bash)" "bash rc is ~/.bashrc"
SHELL="$saved_shell"

assert_contains "$(default_user_config)" 'command = "cursor-agent"' \
  "default config uses cursor-agent"
assert_contains "$(default_user_config)" 'review = "tuicr"' \
  "default config includes review"
assert_contains "$(default_user_config)" 'editor = "nvim"' \
  "default config includes editor"

mkdir -p "$AGENTIC_DEV_CONFIG_DIR"
cp "$ROOT/config/agentic-dev/config-reader.sh" "$AGENTIC_DEV_CONFIG_DIR/config-reader.sh"

assert_eq "cursor-agent" "$(read_agent_command)" "agent defaults to cursor-agent"
assert_eq "tuicr" "$(read_layout_review)" "review defaults to tuicr"
assert_eq "nvim" "$(read_layout_editor)" "editor defaults to nvim"

write_user_config grok hunk fresh
assert_eq "grok" "$(read_agent_command)" "write_user_config stores agent"
assert_eq "hunk" "$(read_layout_review)" "write_user_config stores review"
assert_eq "fresh" "$(read_layout_editor)" "write_user_config stores explorer"

write_user_config agent tuicr tode
assert_eq "tode" "$(read_layout_editor)" "write_user_config stores tode"
migrate_cursor_cli_command
assert_eq "cursor-agent" "$(read_agent_command)" "migrates agent command to cursor-agent"

# Doctor reports configured tools, not hardcoded tuicr/nvim.
case_dir="$TMP_DIR/doctor-hunk-fresh"
mkdir -p "$case_dir/bin" "$case_dir/home/.config/agentic-dev"
cat >"$case_dir/home/.config/agentic-dev/config.toml" <<'EOF'
[agent]
command = "agent"

[layout]
review = "hunk"
editor = "fresh"
EOF
cp "$ROOT/config/agentic-dev/config-reader.sh" \
  "$case_dir/home/.config/agentic-dev/config-reader.sh"
cat >"$case_dir/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf 'herdr 0.7.5\n'
EOF
chmod +x "$case_dir/bin/herdr"
for cmd in git wt fzf jq lazygit hunk fresh; do
  ln -s /bin/true "$case_dir/bin/$cmd"
done

output="$(
  HOME="$case_dir/home" \
    XDG_CONFIG_HOME="$case_dir/home/.config" \
    AGENTIC_DEV_CONFIG_DIR="$case_dir/home/.config/agentic-dev" \
    AGENTIC_DEV_USER_CONFIG="$case_dir/home/.config/agentic-dev/config.toml" \
    PATH="$case_dir/bin:/usr/bin:/bin" \
    doctor_dependencies 2>&1
)" || rc=$?
rc="${rc:-0}"
assert_eq "0" "$rc" "doctor exits 0 for hunk+fresh layout"
assert_contains "$output" "ok  hunk" "doctor accepts configured hunk"
assert_contains "$output" "ok  fresh" "doctor accepts configured fresh"
[[ "$output" != *"missing  tuicr"* ]] || fail "doctor should not require tuicr when review is hunk"
[[ "$output" != *"missing  nvim"* ]] || fail "doctor should not require nvim when explorer is fresh"

printf 'PASS: layout config, write, and doctor follow selected review/explorer tools\n'
