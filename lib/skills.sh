#!/usr/bin/env bash
# shellcheck shell=bash

# Agent-specific skill dirs (scrubbed on reconfigure/uninstall).
skill_extra_global_dirs_all() {
  printf '%s\n' \
    "${HOME}/.codex/skills" \
    "${HOME}/.config/opencode/skills" \
    "${HOME}/.claude/skills" \
    "${HOME}/.pi/agent/skills" \
    "${HOME}/.grok/skills"
}

# Extra link only when the agent does not discover ~/.agents/skills.
# Grok scans ~/.grok/skills (and ~/.claude/skills), not ~/.agents/skills.
skill_agent_extra_global_dirs() {
  local cmd="${1:-}"
  case "$cmd" in
    agent|cursor|cursor-agent) return 1 ;;
    grok) printf '%s' "${HOME}/.grok/skills" ;;
    pi) printf '%s' "${HOME}/.pi/agent/skills" ;;
    codex) printf '%s' "${HOME}/.codex/skills" ;;
    opencode) printf '%s' "${HOME}/.config/opencode/skills" ;;
    claude|claude-code) printf '%s' "${HOME}/.claude/skills" ;;
    *) return 1 ;;
  esac
}

_skill_link_is_ours() {
  local link="$1"
  [[ -L "$link" ]] || return 1
  local resolved canonical
  resolved="$(realpath "$link" 2>/dev/null || true)"
  canonical="$(realpath "$AGENTIC_DEV_SKILL_DIR" 2>/dev/null || true)"
  [[ -n "$resolved" && -n "$canonical" && "$resolved" == "$canonical" ]]
}

ensure_skill_symlink() {
  local dest_parent="$1"
  local link="${dest_parent}/${AGENTIC_DEV_SKILL_ID}"

  [[ "$dest_parent" == "$AGENTS_SKILLS_DIR" ]] && return 0
  ensure_dir "$dest_parent"

  if [[ -L "$link" ]]; then
    if _skill_link_is_ours "$link"; then
      info "unchanged: skill link $link"
      return 0
    fi
    warn "preserving pre-existing skill link $link -> $(readlink "$link")"
    return 0
  fi
  if [[ -e "$link" ]]; then
    warn "preserving pre-existing skill path $link (not a symlink to $AGENTIC_DEV_SKILL_DIR)"
    return 0
  fi

  info "link skill: $link -> $AGENTIC_DEV_SKILL_DIR"
  run ln -s "$AGENTIC_DEV_SKILL_DIR" "$link"
}

remove_managed_skill_symlink() {
  local dest_parent="$1"
  local link="${dest_parent}/${AGENTIC_DEV_SKILL_ID}"
  [[ -L "$link" ]] || return 0
  _skill_link_is_ours "$link" || return 0
  info "remove: $link"
  run rm -f "$link"
}

scrub_managed_skill_extra_links() {
  local dir
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    remove_managed_skill_symlink "$dir"
  done < <(skill_extra_global_dirs_all)
}

deploy_skill_tree() {
  local src dest_root src_root manifest line
  dest_root="$AGENTIC_DEV_SKILL_DIR"
  ensure_dir "$dest_root"

  src="$(install_src_dir)"
  if [[ -d "$src" ]]; then
    src_root="$src/skills/${AGENTIC_DEV_SKILL_ID}"
    [[ -d "$src_root" ]] || {
      warn "skill source missing: $src_root"
      return 1
    }
    deploy_tree "$src_root" "$dest_root"
    return 0
  fi

  deploy_install_file "skills/${AGENTIC_DEV_SKILL_ID}/MANIFEST" "${dest_root}/MANIFEST"
  [[ -f "${dest_root}/MANIFEST" ]] || {
    warn "skill MANIFEST missing after fetch"
    return 1
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" && "$line" != \#* ]] || continue
    deploy_install_file "skills/${AGENTIC_DEV_SKILL_ID}/$line" "${dest_root}/$line"
  done <"${dest_root}/MANIFEST"
}

deploy_skills() {
  local agent_cmd agent_skills_dir
  ensure_dir "$AGENTS_SKILLS_DIR"
  deploy_skill_tree
  scrub_managed_skill_extra_links

  agent_cmd="$(read_agent_command 2>/dev/null || printf '%s' "agent")"
  if agent_skills_dir="$(skill_agent_extra_global_dirs "$agent_cmd")"; then
    ensure_skill_symlink "$agent_skills_dir"
  else
    info "skill at $AGENTIC_DEV_SKILL_DIR (no extra link for '$agent_cmd')"
  fi
}

remove_managed_handoff_skill() {
  scrub_managed_skill_extra_links
  if [[ -d "$AGENTIC_DEV_SKILL_DIR" ]]; then
    info "remove: $AGENTIC_DEV_SKILL_DIR"
    run rm -rf "$AGENTIC_DEV_SKILL_DIR"
  fi
}
