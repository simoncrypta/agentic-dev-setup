# agentic-dev-setup shell integration (zsh)
# Managed by agentic-dev — do not edit; use ~/.config/agentic-dev/config.toml

source "${HOME}/.config/agentic-dev/shell/agentic-dev.inc.sh"

if command -v wt >/dev/null 2>&1; then
  eval "$(command wt config shell init zsh)"
fi
