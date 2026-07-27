#!/usr/bin/env bash
# shellcheck shell=bash

default_user_config() {
  cat <<'EOF'
[agent]
command = "agent"

[layout]
editor = "nvim"
EOF
}

_config_reader_path() {
  local src
  src="$(install_src_dir)"
  if [[ -d "$src" && -f "$src/config/agentic-dev/config-reader.sh" ]]; then
    printf '%s' "$src/config/agentic-dev/config-reader.sh"
    return 0
  fi
  if [[ -f "$AGENTIC_DEV_CONFIG_DIR/config-reader.sh" ]]; then
    printf '%s' "$AGENTIC_DEV_CONFIG_DIR/config-reader.sh"
    return 0
  fi
  return 1
}

ensure_config_reader() {
  declare -F agentic_dev_agent_command >/dev/null 2>&1 && return 0
  local reader
  reader="$(_config_reader_path)" || return 1
  # shellcheck source=/dev/null
  source "$reader"
}

read_agent_command() {
  ensure_config_reader || true
  if declare -F agentic_dev_agent_command >/dev/null 2>&1; then
    agentic_dev_agent_command
  else
    printf '%s' "agent"
  fi
}

read_layout_editor() {
  ensure_config_reader || true
  if declare -F agentic_dev_layout_editor >/dev/null 2>&1; then
    agentic_dev_layout_editor
  else
    printf '%s' "${EDITOR:-nvim}"
  fi
}

RECONFIGURE=0

export DEV_LAYOUT_PLUGIN_REPO="simoncrypta/herdr-dev-layout"
export DEV_LAYOUT_PLUGIN_REF="v0.2.0"
PICKR_PLUGIN_REPO="tomasvarga/herdr-pickr"
PICKR_PLUGIN_REF="e393ef593e44d2497f43d20aa7b0e4a26ea3d445"
WORKTRUNK_PLUGIN_REPO="devashish2203/herdr-worktrunk"
WORKTRUNK_PLUGIN_REF="a3107ca566bafcd463bc138007a0c01051970784"

PLUGIN_STATUS=""
PLUGIN_SOURCE_KIND=""
PLUGIN_SOURCE_REPO=""
PLUGIN_SOURCE_REF=""
PLUGIN_SOURCE_PATH=""
PLUGIN_SOURCE_RAW=""

plugin_inspect() {
  local id="$1" output line descriptor payload matches=0 mentions=0

  PLUGIN_STATUS="unknown"
  PLUGIN_SOURCE_KIND=""
  PLUGIN_SOURCE_REPO=""
  PLUGIN_SOURCE_REF=""
  PLUGIN_SOURCE_PATH=""
  PLUGIN_SOURCE_RAW=""

  if ! output="$(herdr plugin list 2>/dev/null)"; then
    return 1
  fi

  while IFS= read -r line; do
    [[ "$line" != *"$id"* ]] || mentions=$((mentions + 1))
    [[ "$line" == "- $id "* ]] || continue
    matches=$((matches + 1))
    PLUGIN_SOURCE_RAW="$line"
  done <<<"$output"

  if [[ "$matches" -eq 0 ]]; then
    [[ "$mentions" -eq 0 ]] || return 1
    PLUGIN_STATUS="missing"
    return 0
  fi
  [[ "$matches" -eq 1 ]] || return 1

  descriptor="${PLUGIN_SOURCE_RAW##*[}"
  [[ "$descriptor" != "$PLUGIN_SOURCE_RAW" && "$descriptor" == *']'* ]] || return 1
  descriptor="${descriptor%%]*}"
  case "$descriptor" in
    local:*)
      PLUGIN_STATUS="present"
      PLUGIN_SOURCE_KIND="local"
      PLUGIN_SOURCE_PATH="${descriptor#local:}"
      [[ -n "$PLUGIN_SOURCE_PATH" ]] || {
        PLUGIN_STATUS="unknown"
        return 1
      }
      ;;
    github:*@*)
      payload="${descriptor#github:}"
      PLUGIN_SOURCE_REPO="${payload%@*}"
      PLUGIN_SOURCE_REF="${payload##*@}"
      [[ "$PLUGIN_SOURCE_REPO" == */* && -n "$PLUGIN_SOURCE_REF" ]] || return 1
      PLUGIN_STATUS="present"
      PLUGIN_SOURCE_KIND="github"
      ;;
    *)
      return 1
      ;;
  esac
}

plugin_is_exact_github() {
  local repo="$1" ref="$2"
  [[ "$PLUGIN_STATUS" == "present" \
    && "$PLUGIN_SOURCE_KIND" == "github" \
    && "$PLUGIN_SOURCE_REPO" == "$repo" \
    && "$PLUGIN_SOURCE_REF" == "$ref" ]]
}

plugin_is_exact_local() {
  local path="$1"
  [[ "$PLUGIN_STATUS" == "present" \
    && "$PLUGIN_SOURCE_KIND" == "local" \
    && "$PLUGIN_SOURCE_PATH" == "$path" ]]
}

_plugin_install_github() {
  local repo="$1" ref="$2"
  info "installing Herdr plugin: $repo@$ref"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] herdr plugin install $repo --ref $ref --yes"
    return 0
  fi
  herdr plugin install "$repo" --ref "$ref" --yes
}

_plugin_remove_registration() {
  local id="$1" kind="$2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] herdr plugin $([[ "$kind" == "local" ]] && printf unlink || printf uninstall) $id"
    return 0
  fi
  if [[ "$kind" == "local" ]]; then
    herdr plugin unlink "$id"
  else
    herdr plugin uninstall "$id"
  fi
}

_herdr_plugin_registry_path() {
  printf '%s/herdr/plugins.json' "${XDG_CONFIG_HOME:-${HOME}/.config}"
}

_plugin_registry_source_path() {
  local registry="$1" id="$2"
  jq -er --arg id "$id" '
    [.[] | select(.plugin_id == $id)] |
    if length == 1 then (.[0].plugin_root // .[0].source.managed_path // "")
    else error("expected one plugin entry") end
  ' "$registry"
}

ensure_adopted_github_plugin() {
  local id="$1" repo="$2" ref="$3"

  if ! plugin_inspect "$id"; then
    warn "cannot safely inspect Herdr plugin $id; preserving it unchanged"
    return 0
  fi
  if plugin_is_exact_github "$repo" "$ref"; then
    info "unchanged: Herdr plugin $id ($repo@$ref)"
    return 0
  fi
  if [[ "$PLUGIN_STATUS" == "present" ]]; then
    warn "preserving pre-existing Herdr plugin $id: ${PLUGIN_SOURCE_RAW#- }"
    return 0
  fi

  _plugin_install_github "$repo" "$ref" || {
    warn "failed to install Herdr plugin $id from $repo@$ref"
    return 1
  }
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  if plugin_inspect "$id" && plugin_is_exact_github "$repo" "$ref"; then
    return 0
  fi

  warn "Herdr reported success but $id is not registered at $repo@$ref"
  if [[ "$PLUGIN_STATUS" == "present" ]]; then
    _plugin_remove_registration "$id" "$PLUGIN_SOURCE_KIND" || true
  fi
  return 1
}

_managed_plugin_transaction() (
  local id="$1" repo="$2" ref="$3" previous_kind="$4"
  local previous_repo="$5" previous_ref="$6" previous_path="$7"
  local registry snapshot restore_tmp source_path source_backup current_path
  local rollback_started=0 rollback_ok=0

  registry="$(_herdr_plugin_registry_path)"
  snapshot="${registry}.agentic-dev-backup.$$"
  restore_tmp="${registry}.agentic-dev-restore.$$"
  source_path=""
  source_backup=""

  rollback() {
    [[ "$rollback_started" -eq 1 ]] || return 0
    trap '' HUP INT TERM
    rollback_ok=0
    : >"$restore_tmp" || rollback_ok=1

    current_path=""
    if [[ -f "$registry" ]]; then
      current_path="$(_plugin_registry_source_path "$registry" "$id" 2>/dev/null || true)"
    fi
    if [[ -n "$current_path" && "$current_path" != "$source_path" ]]; then
      warn "preserving failed-install artifact for $id: $current_path"
    fi

    if [[ "$previous_kind" == "local" ]]; then
      if [[ -d "$source_backup" ]]; then
        rm -rf "$previous_path" || rollback_ok=1
        mv "$source_backup" "$previous_path" || rollback_ok=1
      elif [[ ! -d "$previous_path" ]]; then
        rollback_ok=1
      fi
    else
      if [[ -d "$source_backup" ]]; then
        rm -rf "$source_path" || rollback_ok=1
        mv "$source_backup" "$source_path" || rollback_ok=1
      elif [[ ! -d "$source_path" ]]; then
        rollback_ok=1
      fi
    fi

    if [[ -f "$snapshot" ]]; then
      cp -p "$snapshot" "$restore_tmp" && mv "$restore_tmp" "$registry" || rollback_ok=1
    else
      rollback_ok=1
    fi

    if [[ "$rollback_ok" -eq 0 ]]; then
      warn "rolled back Herdr plugin $id to its previous $previous_kind source"
    else
      warn "rollback for Herdr plugin $id was incomplete; previous source: ${previous_path:-$previous_repo@$previous_ref}"
    fi
    rm -f "$restore_tmp" "$snapshot"
    rollback_started=0
    return "$rollback_ok"
  }

  # shellcheck disable=SC2329
  interrupted() {
    local status="$1"
    if [[ "$rollback_started" -eq 1 ]]; then
      rollback || true
    else
      trap '' HUP INT TERM
      rm -rf "$source_backup"
      rm -f "$restore_tmp" "$snapshot"
    fi
    exit "$status"
  }
  trap 'interrupted 129' HUP
  trap 'interrupted 130' INT
  trap 'interrupted 143' TERM

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] snapshot complete Herdr registry and previous plugin source"
    info "[dry-run] transaction for $id: remove $previous_kind registration"
    if [[ "$previous_kind" == "local" ]]; then
      info "[dry-run] back up $previous_path before migration"
    fi
    _plugin_remove_registration "$id" "$previous_kind"
    _plugin_install_github "$repo" "$ref"
    info "[dry-run] verify $id is exactly $repo@$ref; restore registry/source snapshot on failure or interruption"
    return 0
  fi

  if [[ ! -f "$registry" ]] || ! jq -e 'type == "array"' "$registry" >/dev/null 2>&1; then
    warn "cannot transactionally update $id because the Herdr registry is missing or malformed: $registry"
    return 1
  fi
  source_path="$(_plugin_registry_source_path "$registry" "$id" 2>/dev/null)" || {
    warn "cannot transactionally update $id because its registry entry is ambiguous"
    return 1
  }
  [[ -n "$source_path" ]] || source_path="$previous_path"
  [[ -d "$source_path" ]] || {
    warn "legacy Herdr plugin source is stale or missing: $source_path"
    return 1
  }
  source_backup="${source_path}.agentic-dev-backup.$$"
  [[ ! -e "$snapshot" && ! -e "$restore_tmp" && ! -e "$source_backup" ]] || {
    warn "refusing migration because a transaction backup path already exists"
    return 1
  }
  cp -p "$registry" "$snapshot" || return 1
  if [[ "$previous_kind" == "github" ]]; then
    cp -a "$source_path" "$source_backup" || {
      rm -f "$snapshot"
      return 1
    }
  fi

  rollback_started=1
  if ! _plugin_remove_registration "$id" "$previous_kind"; then
    rollback || true
    return 1
  fi
  if [[ "$previous_kind" == "local" ]] && ! mv "$source_path" "$source_backup"; then
    rollback || true
    return 1
  fi

  if ! _plugin_install_github "$repo" "$ref" \
    || ! plugin_inspect "$id" \
    || ! plugin_is_exact_github "$repo" "$ref"; then
    warn "transactional install failed for Herdr plugin $id; restoring previous registration"
    rollback || true
    return 1
  fi

  trap - HUP INT TERM
  rollback_started=0
  rm -rf "$source_backup"
  rm -f "$snapshot" "$restore_tmp"
)

ensure_managed_github_plugin() {
  local id="$1" repo="$2" ref="$3" legacy_path="$4"
  local previous_kind previous_repo previous_ref previous_path

  if ! plugin_inspect "$id"; then
    warn "cannot safely inspect managed Herdr plugin $id; preserving it unchanged"
    return 1
  fi
  if plugin_is_exact_github "$repo" "$ref"; then
    info "unchanged: managed Herdr plugin $id ($repo@$ref)"
    return 0
  fi
  if [[ "$PLUGIN_STATUS" == "missing" ]]; then
    ensure_adopted_github_plugin "$id" "$repo" "$ref"
    return
  fi

  previous_kind="$PLUGIN_SOURCE_KIND"
  previous_repo="$PLUGIN_SOURCE_REPO"
  previous_ref="$PLUGIN_SOURCE_REF"
  previous_path="$PLUGIN_SOURCE_PATH"
  if [[ "$previous_kind" == "local" && "$previous_path" != "$legacy_path" ]]; then
    warn "preserving Herdr plugin $id from unowned local source: $previous_path"
    return 0
  fi
  if [[ "$previous_kind" == "github" && "$previous_repo" != "$repo" ]]; then
    warn "preserving Herdr plugin $id from unowned GitHub source: $previous_repo@$previous_ref"
    return 0
  fi

  _managed_plugin_transaction "$id" "$repo" "$ref" \
    "$previous_kind" "$previous_repo" "$previous_ref" "$previous_path"
}

ensure_managed_local_plugin() {
  local id="$1" path="$2"
  if ! plugin_inspect "$id"; then
    warn "cannot safely inspect Herdr plugin $id; preserving its registration"
    return 0
  fi
  if plugin_is_exact_local "$path"; then
    info "unchanged: Herdr plugin $id linked at $path"
    return 0
  fi
  if [[ "$PLUGIN_STATUS" == "present" ]]; then
    warn "preserving pre-existing Herdr plugin $id: ${PLUGIN_SOURCE_RAW#- }"
    return 0
  fi
  info "linking Herdr plugin: $id"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] herdr plugin link $path"
  else
    # plugin link needs a running server (ENOENT otherwise).
    if ! herdr status server 2>/dev/null | grep -q '^status: running'; then
      herdr server >/dev/null 2>&1 &
      local _i
      for _i in 1 2 3 4 5 6 7 8 9 10; do
        herdr status server 2>/dev/null | grep -q '^status: running' && break
        sleep 0.2
      done
    fi
    herdr plugin link "$path" 2>/dev/null || herdr plugin link "$path" \
      || warn "herdr plugin link failed — run manually: herdr plugin link $path"
  fi
}

deploy_third_party_plugins() {
  ensure_adopted_github_plugin pickr "$PICKR_PLUGIN_REPO" "$PICKR_PLUGIN_REF"
  ensure_adopted_github_plugin worktrunk "$WORKTRUNK_PLUGIN_REPO" "$WORKTRUNK_PLUGIN_REF"
}

pickr_template_for_platform() {
  case "$(detect_os)" in
    linux) printf '%s' "config/pickr/config.linux.toml" ;;
    macos) printf '%s' "config/pickr/config.macos.toml" ;;
    *) return 1 ;;
  esac
}

deploy_pickr_config() {
  local config_dir dest template_rel
  if ! config_dir="$(herdr plugin config-dir pickr 2>/dev/null)" || [[ "$config_dir" != /* ]]; then
    warn "cannot resolve the pickr plugin config dir; keeping any existing pickr config"
    return 0
  fi
  dest="$config_dir/config.toml"
  if [[ -e "$dest" || -L "$dest" ]]; then
    info "keeping existing pickr config: $dest"
    return 0
  fi
  if ! template_rel="$(pickr_template_for_platform)"; then
    warn "no portable pickr defaults for platform $(detect_os); skipping"
    return 0
  fi
  deploy_install_file "$template_rel" "$dest"
}

prompt_agent_command() {
  if [[ -f "$AGENTIC_DEV_USER_CONFIG" ]] && [[ "$RECONFIGURE" -ne 1 ]]; then
    info "using existing agent command: $(read_agent_command)"
    return 0
  fi

  if [[ "$YES" -eq 1 ]]; then
    ensure_dir "$AGENTIC_DEV_CONFIG_DIR"
    if [[ ! -f "$AGENTIC_DEV_USER_CONFIG" ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] would write default $AGENTIC_DEV_USER_CONFIG"
      else
        default_user_config >"$AGENTIC_DEV_USER_CONFIG"
      fi
    fi
    return 0
  fi

  log ""
  log "Which command should the agent pane auto-start?"
  log "  1) agent"
  log "  2) codex"
  log "  3) opencode"
  log "  4) claude"
  log "  5) custom"
  log ""
  printf 'Choice [1-5]: '
  local choice custom_cmd cmd="agent"
  read_tty choice
  case "$choice" in
    1|agent) cmd="agent" ;;
    2|codex) cmd="codex" ;;
    3|opencode) cmd="opencode" ;;
    4|claude) cmd="claude" ;;
    5|custom)
      printf 'Enter custom command: '
      read_tty custom_cmd
      cmd="${custom_cmd:-agent}"
      ;;
    ""|*) cmd="agent" ;;
  esac

  local editor
  editor="$(read_layout_editor)"
  ensure_dir "$AGENTIC_DEV_CONFIG_DIR"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would write $AGENTIC_DEV_USER_CONFIG (agent=$cmd)"
    return 0
  fi
  cat >"$AGENTIC_DEV_USER_CONFIG" <<EOF
[agent]
command = "$cmd"

[layout]
editor = "$editor"
EOF
  info "saved agent command to $AGENTIC_DEV_USER_CONFIG"
}

deploy_tree() {
  local src="$1"
  local dest="$2"
  [[ -d "$src" ]] || return 0
  ensure_dir "$dest"
  while IFS= read -r -d '' file; do
    local sub="${file#"$src"/}"
    copy_file "$file" "$dest/$sub"
  done < <(find "$src" -type f -print0)
}

deploy_install_file() {
  local rel="$1" dest="$2"
  local src
  src="$(install_src_dir)"
  if [[ -d "$src" ]]; then
    copy_file "$src/$rel" "$dest"
  else
    fetch_file "$rel" "$dest"
  fi
}

deploy_agentic_dev_config() {
  local src file sub
  src="$(install_src_dir)"
  if [[ -d "$src" ]]; then
    while IFS= read -r -d '' file; do
      sub="${file#"$src/config/agentic-dev"/}"
      [[ "$sub" == "config.toml" ]] && continue
      copy_file "$file" "$AGENTIC_DEV_CONFIG_DIR/$sub"
    done < <(find "$src/config/agentic-dev" -type f -print0 2>/dev/null)
  else
    deploy_install_file "config/agentic-dev/config-reader.sh" "$AGENTIC_DEV_CONFIG_DIR/config-reader.sh"
    deploy_install_file "config/agentic-dev/config.toml.example" "$AGENTIC_DEV_CONFIG_DIR/config.toml.example"
  fi
}

deploy_lib() {
  local src
  src="$(install_src_dir)"
  if [[ -d "$src" ]]; then
    deploy_tree "$src/lib" "${HOME}/.local/share/agentic-dev/lib"
  else
    local libfile
    for libfile in common.sh detect.sh deps.sh config.sh shell-rc.sh uninstall.sh help.sh omarchy.sh; do
      deploy_install_file "lib/$libfile" "${HOME}/.local/share/agentic-dev/lib/$libfile"
    done
  fi
}

deploy_plugin() {
  if command -v herdr >/dev/null 2>&1; then
    require_herdr_min_version || return 1
    ensure_managed_github_plugin \
      "$PLUGIN_ID" \
      "$DEV_LAYOUT_PLUGIN_REPO" \
      "$DEV_LAYOUT_PLUGIN_REF" \
      "$HERDR_DEV_LAYOUT_LEGACY_DIR"
    deploy_third_party_plugins
    deploy_pickr_config
  else
    warn "herdr not on PATH — skipping managed plugin install ($DEV_LAYOUT_PLUGIN_REPO@$DEV_LAYOUT_PLUGIN_REF)"
  fi
}

deploy_finalize_permissions() {
  run chmod +x "$LOCAL_BIN/agentic-dev" \
    "$WORKTRUNK_CONFIG_DIR/herdr-layout.sh" \
    "$AGENTIC_DEV_SHELL_DIR/agentic-dev.sh" \
    "$AGENTIC_DEV_SHELL_DIR/agentic-dev.zsh" \
    "$AGENTIC_DEV_SHELL_DIR/agentic-dev.inc.sh" \
    "$AGENTIC_DEV_CONFIG_DIR/config-reader.sh" 2>/dev/null || true
  find "${HOME}/.local/share/agentic-dev/lib" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
}

deploy_configs() {
  local -a files=(
    "config/shell/agentic-dev.inc.sh|${AGENTIC_DEV_SHELL_DIR}/agentic-dev.inc.sh"
    "config/bash/agentic-dev.sh|${AGENTIC_DEV_SHELL_DIR}/agentic-dev.sh"
    "config/zsh/agentic-dev.zsh|${AGENTIC_DEV_SHELL_DIR}/agentic-dev.zsh"
    "config/herdr/config.toml|${HERDR_CONFIG_DIR}/config.toml"
    "config/worktrunk/herdr-layout.sh|${WORKTRUNK_CONFIG_DIR}/herdr-layout.sh"
    "bin/agentic-dev|${LOCAL_BIN}/agentic-dev"
  )
  local entry rel dest

  prompt_agent_command

  ensure_dir "$AGENTIC_DEV_CONFIG_DIR"
  ensure_dir "$AGENTIC_DEV_SHELL_DIR"
  ensure_dir "$HERDR_CONFIG_DIR"
  ensure_dir "$WORKTRUNK_CONFIG_DIR"
  ensure_dir "${HOME}/.local/share/agentic-dev"

  for entry in "${files[@]}"; do
    rel="${entry%%|*}"
    dest="${entry#*|}"
    deploy_install_file "$rel" "$dest"
  done

  deploy_agentic_dev_config
  deploy_lib
  deploy_plugin

  if [[ ! -f "$WORKTRUNK_CONFIG_DIR/config.toml" ]] || [[ "$FORCE" -eq 1 ]]; then
    deploy_install_file "config/worktrunk/config.toml" "$WORKTRUNK_CONFIG_DIR/config.toml"
  else
    info "keeping existing worktrunk config: $WORKTRUNK_CONFIG_DIR/config.toml"
  fi

  deploy_finalize_permissions
}
