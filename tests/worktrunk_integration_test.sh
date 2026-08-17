#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"
FAKE_BIN="$TMP_DIR/bin"
HERDR_CALL_LOG="$TMP_DIR/herdr-calls.log"

cleanup() {
  rm -rf "$TMP_DIR"
  printf 'CLEANUP PASS: removed isolated HOME/XDG fixture: %s\n' "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  [[ "$actual" == "$expected" ]] || fail "$message (expected=$expected actual=$actual)"
}

assert_log_count() {
  local pattern="$1" expected="$2"
  local actual
  actual="$(grep -cE "$pattern" "$HERDR_CALL_LOG" 2>/dev/null || true)"
  assert_eq "$expected" "$actual" "unexpected fake Herdr call count for $pattern"
}

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

registry_path() {
  printf '%s/herdr/plugins.json' "$XDG_CONFIG_HOME"
}

write_registry() {
  mkdir -p "$(dirname "$(registry_path)")"
  printf '%s\n' "$1" >"$(registry_path)"
}

seed_github() {
  local id="$1" repo="$2" ref="$3"
  local owner="${repo%%/*}" name="${repo#*/}" root
  root="$XDG_CONFIG_HOME/herdr/plugins/github/${id}-${ref}"
  mkdir -p "$root"
  printf 'source-%s\n' "$ref" >"$root/sentinel"
  write_registry "$(jq -n \
    --arg id "$id" --arg owner "$owner" --arg repo "$name" --arg ref "$ref" --arg root "$root" \
    '[{plugin_id:$id,plugin_root:$root,source:{kind:"github",owner:$owner,repo:$repo,resolved_commit:$ref,managed_path:$root}}]')"
}

registry_source() {
  local id="$1"
  jq -r --arg id "$id" \
    '.[] | select(.plugin_id == $id) | if .source.kind == "local" then "local:" + .plugin_root else "github:" + .source.owner + "/" + .source.repo + "@" + .source.resolved_commit end' \
    "$(registry_path)"
}

reset_fixture() {
  rm -rf "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME/herdr" "$XDG_STATE_HOME"
  write_registry '[]'
  : >"$HERDR_CALL_LOG"
  unset FAKE_HERDR_LIST_OUTPUT FAKE_HERDR_VERSION_OUTPUT
}

mkdir -p "$FAKE_BIN"

# Resolve the real Python interpreter before HOME/PATH are overridden: python3 may
# be a version-manager shim (mise/asdf) that fails once $HOME points at the fixture.
PYTHON_BIN="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null || true)"
[[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]] || PYTHON_BIN="$(command -v python3)"

cat >"$FAKE_BIN/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail

registry="${XDG_CONFIG_HOME}/herdr/plugins.json"
printf '%s\n' "$*" >>"$HERDR_CALL_LOG"

if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' "${FAKE_HERDR_VERSION_OUTPUT:-herdr 0.7.5}"
  exit 0
fi

write_entry() {
  local entry="$1" tmp="${registry}.tmp"
  jq --argjson entry "$entry" \
    '[.[] | select(.plugin_id != $entry.plugin_id)] + [$entry]' "$registry" >"$tmp"
  mv "$tmp" "$registry"
}

case "${1:-} ${2:-}" in
  'plugin list')
    if [[ -n "${FAKE_HERDR_LIST_OUTPUT:-}" ]]; then
      printf '%s\n' "$FAKE_HERDR_LIST_OUTPUT"
      exit 0
    fi
    jq -r '.[] | if .source.kind == "local" then
      "- \(.plugin_id) (fixture) enabled [local:\(.plugin_root)]"
    else
      "- \(.plugin_id) (fixture) enabled [github:\(.source.owner)/\(.source.repo)@\(.source.resolved_commit)]"
    end' "$registry"
    ;;
  'integration install'|'integration status'|'integration uninstall')
    exit 0
    ;;
  'plugin install')
    source_name="${3:?missing plugin source}"
    shift 3
    ref=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --ref) ref="${2:?missing ref}"; shift 2 ;;
        --yes) shift ;;
        *) shift ;;
      esac
    done
    case "$source_name" in
      simoncrypta/herdr-dev-layout) id='agentic-dev.dev-layout' ;;
      tomasvarga/herdr-pickr) id='pickr' ;;
      devashish2203/herdr-worktrunk) id='worktrunk' ;;
      *) exit 64 ;;
    esac
    owner="${source_name%%/*}"
    repo="${source_name#*/}"
    root="${XDG_CONFIG_HOME}/herdr/plugins/github/${id}-${ref}"
    mkdir -p "$root"
    entry="$(jq -n --arg id "$id" --arg owner "$owner" --arg repo "$repo" \
      --arg ref "$ref" --arg root "$root" \
      '{plugin_id:$id,plugin_root:$root,source:{kind:"github",owner:$owner,repo:$repo,resolved_commit:$ref,managed_path:$root}}')"
    write_entry "$entry"
    ;;
  'plugin link')
    root="${3:?missing plugin root}"
    id="$(grep -m 1 -E '^id[[:space:]]*=' "$root/herdr-plugin.toml" | cut -d '"' -f 2)"
    entry="$(jq -n --arg id "$id" --arg root "$root" \
      '{plugin_id:$id,plugin_root:$root,manifest_path:($root + "/herdr-plugin.toml"),source:{kind:"local"}}')"
    write_entry "$entry"
    ;;
  *)
    exit 64
    ;;
esac
FAKE_HERDR
chmod +x "$FAKE_BIN/herdr"

export HOME="$TMP_DIR/home"
export XDG_CONFIG_HOME="$TMP_DIR/xdg-config"
export XDG_STATE_HOME="$TMP_DIR/xdg-state"
export HERDR_CALL_LOG
export PATH="$FAKE_BIN:$PATH"
export INSTALL_SRC="$ROOT"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/deps.sh
source "$ROOT/lib/deps.sh"
# shellcheck source=lib/config.sh
source "$ROOT/lib/config.sh"
# shellcheck source=lib/skills.sh
source "$ROOT/lib/skills.sh"

HERDR_CONFIG_DIR="$XDG_CONFIG_HOME/herdr"
HERDR_DEV_LAYOUT_LEGACY_DIR="$HERDR_CONFIG_DIR/plugins/dev-layout"
export AGENTIC_DEV_CONFIG_DIR="$XDG_CONFIG_HOME/agentic-dev"
export AGENTIC_DEV_SHELL_DIR="$AGENTIC_DEV_CONFIG_DIR/shell"
export AGENTIC_DEV_USER_CONFIG="$AGENTIC_DEV_CONFIG_DIR/config.toml"
export WORKTRUNK_CONFIG_DIR="$XDG_CONFIG_HOME/worktrunk"
export FCITX5_CONFIG_DIR="$XDG_CONFIG_HOME/fcitx5"
export LOCAL_BIN="$HOME/.local/bin"
export YES=1
export DRY_RUN=0
export FORCE=0

WORKTRUNK_INSTALL_LOG="^plugin install $WORKTRUNK_PLUGIN_REPO --ref $WORKTRUNK_PLUGIN_REF --yes$"

assert_worktrunk_keybindings() {
  local config_path="$1"
  "$PYTHON_BIN" - "$config_path" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as fh:
    data = tomllib.load(fh)
commands = data.get("keys", {}).get("command", [])
expected = {
    "prefix+shift+g": "worktrunk.open",
    "prefix+shift+c": "worktrunk.open-current",
    "prefix+shift+r": "worktrunk.remove",
}
for key, action in expected.items():
    matches = [entry for entry in commands if entry.get("key") == key]
    if len(matches) != 1:
        sys.exit(f"FAIL: {key} appears {len(matches)} times in {sys.argv[1]} (expected exactly 1)")
    entry = matches[0]
    if entry.get("type") != "plugin_action" or entry.get("command") != action:
        sys.exit(
            f"FAIL: {key} maps to {entry.get('command')!r} type={entry.get('type')!r}"
            f" (expected plugin_action {action})"
        )
PY
}

test_herdr_config_keybindings() {
  assert_worktrunk_keybindings "$ROOT/config/herdr/config.toml" \
    || fail "repo Herdr config keybinding assertion failed"
  printf 'PASS: repo Herdr config binds prefix+shift+g/c/r to worktrunk.open/open-current/remove exactly once\n'
}

test_missing_installs_selected_sha() {
  reset_fixture
  ensure_adopted_github_plugin worktrunk "$WORKTRUNK_PLUGIN_REPO" "$WORKTRUNK_PLUGIN_REF"
  assert_eq "$WORKTRUNK_PLUGIN_REF" \
    "a3107ca566bafcd463bc138007a0c01051970784" "worktrunk pin constant drifted"
  assert_eq "github:$WORKTRUNK_PLUGIN_REPO@$WORKTRUNK_PLUGIN_REF" \
    "$(registry_source worktrunk)" "missing worktrunk plugin was not installed at the selected SHA"
  assert_log_count "$WORKTRUNK_INSTALL_LOG" 1
  printf 'PASS: missing worktrunk installs devashish2203/herdr-worktrunk at the selected SHA\n'
}

test_exact_sha_is_noop() {
  local before after
  reset_fixture
  ensure_adopted_github_plugin worktrunk "$WORKTRUNK_PLUGIN_REPO" "$WORKTRUNK_PLUGIN_REF"
  before="$(checksum "$(registry_path)")"
  ensure_adopted_github_plugin worktrunk "$WORKTRUNK_PLUGIN_REPO" "$WORKTRUNK_PLUGIN_REF"
  after="$(checksum "$(registry_path)")"
  assert_eq "$before" "$after" "exact selected SHA changed the plugin registry"
  assert_log_count "$WORKTRUNK_INSTALL_LOG" 1
  printf 'PASS: exact selected SHA is a registry no-op\n'
}

test_mismatched_ref_preserved_with_warning() {
  local before after warning_log="$TMP_DIR/mismatch-ref.warning"
  reset_fixture
  seed_github worktrunk "$WORKTRUNK_PLUGIN_REPO" 0000000000000000000000000000000000000000
  before="$(checksum "$(registry_path)")"
  ensure_adopted_github_plugin worktrunk "$WORKTRUNK_PLUGIN_REPO" "$WORKTRUNK_PLUGIN_REF" 2>"$warning_log"
  after="$(checksum "$(registry_path)")"
  assert_eq "$before" "$after" "pre-existing mismatched ref was replaced"
  assert_eq "github:$WORKTRUNK_PLUGIN_REPO@0000000000000000000000000000000000000000" \
    "$(registry_source worktrunk)" "pre-existing mismatched ref registration changed"
  grep -q 'preserving pre-existing Herdr plugin worktrunk' "$warning_log" \
    || fail "mismatched ref did not produce a visible preservation warning"
  assert_log_count '^plugin (install|uninstall|unlink) ' 0
  printf 'PASS: pre-existing mismatched ref is preserved untouched with a warning\n'
}

test_mismatched_source_preserved_with_warning() {
  local before after warning_log="$TMP_DIR/mismatch-source.warning"
  reset_fixture
  seed_github worktrunk someone/herdr-worktrunk-fork custom-ref
  before="$(checksum "$(registry_path)")"
  ensure_adopted_github_plugin worktrunk "$WORKTRUNK_PLUGIN_REPO" "$WORKTRUNK_PLUGIN_REF" 2>"$warning_log"
  after="$(checksum "$(registry_path)")"
  assert_eq "$before" "$after" "pre-existing mismatched source was replaced"
  grep -q 'preserving pre-existing Herdr plugin worktrunk' "$warning_log" \
    || fail "mismatched source did not produce a visible preservation warning"
  assert_log_count '^plugin (install|uninstall|unlink) ' 0
  printf 'PASS: pre-existing mismatched source is preserved untouched with a warning\n'
}

seed_existing_worktrunk_config() {
  mkdir -p "$WORKTRUNK_CONFIG_DIR"
  cat >"$WORKTRUNK_CONFIG_DIR/config.toml" <<'EOF'
# user-customized worktrunk config - must survive install/update
[pre-start]
custom = "echo custom-user-hook"
EOF
}

test_existing_worktrunk_config_preserved_across_install_and_update() {
  local before deploy_log="$TMP_DIR/deploy.output"
  reset_fixture
  seed_existing_worktrunk_config
  before="$(checksum "$WORKTRUNK_CONFIG_DIR/config.toml")"

  deploy_configs >"$deploy_log"
  assert_eq "$before" "$(checksum "$WORKTRUNK_CONFIG_DIR/config.toml")" \
    "install changed the existing worktrunk config"
  grep -q "keeping existing worktrunk config: $WORKTRUNK_CONFIG_DIR/config.toml" "$deploy_log" \
    || fail "install did not report keeping the existing worktrunk config"
  assert_eq "github:$WORKTRUNK_PLUGIN_REPO@$WORKTRUNK_PLUGIN_REF" \
    "$(registry_source worktrunk)" "install did not register worktrunk at the selected SHA"
  assert_worktrunk_keybindings "$HERDR_CONFIG_DIR/config.toml" \
    || fail "deployed Herdr config is missing the worktrunk keybindings"
  [[ -x "$WORKTRUNK_CONFIG_DIR/herdr-layout.sh" ]] \
    || fail "worktrunk herdr-layout.sh hook helper was not deployed executable"

  : >"$deploy_log"
  deploy_configs >"$deploy_log"
  assert_eq "$before" "$(checksum "$WORKTRUNK_CONFIG_DIR/config.toml")" \
    "update changed the existing worktrunk config"
  grep -q "keeping existing worktrunk config: $WORKTRUNK_CONFIG_DIR/config.toml" "$deploy_log" \
    || fail "update did not report keeping the existing worktrunk config"
  printf 'PASS: existing worktrunk config checksum is unchanged across install and update\n'
}

test_worktrunk_session_label_migrated_on_update() {
  local deploy_log="$TMP_DIR/deploy-migrate.output"
  reset_fixture
  mkdir -p "$WORKTRUNK_CONFIG_DIR"
  cat >"$WORKTRUNK_CONFIG_DIR/config.toml" <<'EOF'
# user-customized worktrunk config - must survive install/update
[post-start]
herdr = """
S="{{ repo | capitalize }}_{{ branch | capitalize }}"
W="{{ worktree_path }}"
custom = "echo keep-me"
"""

[post-remove]
herdr = """
S="{{ repo | capitalize }}_{{ branch | capitalize }}"
"""
EOF

  deploy_configs >"$deploy_log"
  grep -Fq 'S="{{ branch | capitalize }}_{{ repo | capitalize }}"' "$WORKTRUNK_CONFIG_DIR/config.toml" \
    || fail "did not migrate session labels to Branch_Repo"
  grep -Fq 'S="{{ repo | capitalize }}_{{ branch | capitalize }}"' "$WORKTRUNK_CONFIG_DIR/config.toml" \
    && fail "old Repo_Branch session labels still present"
  grep -q 'custom = "echo keep-me"' "$WORKTRUNK_CONFIG_DIR/config.toml" \
    || fail "migrated config lost user customizations"
  grep -q "migrated worktrunk session labels to Branch_Repo" "$deploy_log" \
    || fail "did not report session label migration"
  grep -q "keeping existing worktrunk config: $WORKTRUNK_CONFIG_DIR/config.toml" "$deploy_log" \
    || fail "update did not report keeping the existing worktrunk config"
  printf 'PASS: existing worktrunk S= templates migrate Repo_Branch to Branch_Repo\n'
}

test_worktrunk_post_start_unsets_handoff_prompt() {
  local deploy_log="$TMP_DIR/deploy-unset-prompt.output"
  reset_fixture
  mkdir -p "$WORKTRUNK_CONFIG_DIR"
  cat >"$WORKTRUNK_CONFIG_DIR/config.toml" <<'EOF'
[post-start]
herdr = """
S="{{ branch | capitalize }}_{{ repo | capitalize }}"
W="{{ worktree_path }}"
source "$HOME/.config/worktrunk/herdr-layout.sh"
wt_herdr_layout_create "$S" "$W"
"""
EOF

  deploy_configs >"$deploy_log"
  grep -q 'unset WT_HERDR_AGENT_PROMPT' "$WORKTRUNK_CONFIG_DIR/config.toml" \
    || fail "did not migrate unset WT_HERDR_AGENT_PROMPT into post-start"
  grep -q "migrated worktrunk post-start to unset WT_HERDR_AGENT_PROMPT" "$deploy_log" \
    || fail "did not report handoff prompt isolation migration"
  printf 'PASS: existing worktrunk post-start unsets WT_HERDR_AGENT_PROMPT\n'
}

test_herdr_config_keybindings
test_missing_installs_selected_sha
test_exact_sha_is_noop
test_mismatched_ref_preserved_with_warning
test_mismatched_source_preserved_with_warning
test_existing_worktrunk_config_preserved_across_install_and_update
test_worktrunk_session_label_migrated_on_update
test_worktrunk_post_start_unsets_handoff_prompt
printf 'ALL PASS: worktrunk integration fixture matrix\n'
