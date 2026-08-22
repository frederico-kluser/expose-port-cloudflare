#!/usr/bin/env bash
# =============================================================================
# install.sh — make the expose-port-cloudflare-agent-skill skill global on this machine
# -----------------------------------------------------------------------------
# Two things, both idempotent and safe to re-run after every `git pull`:
#
#   1. SKILL → every Claude Code config dir on the machine
#      The repo root (it holds SKILL.md) is symlinked into:
#        • $CLAUDE_CONFIG_DIR/skills            (the active config dir, if set)
#        • ~/.claude/skills                     (the default)
#        • ~/.claude-*/skills                   (multi-account setups)
#      A symlink never ages: the skill is always the version on disk, and a
#      copy is only made when the filesystem cannot symlink (fallback).
#
#   2. SHORTCUT → `expose-port-cloudflare-agent-skill` from any folder
#      A tiny wrapper is installed at ~/.local/bin/expose-port-cloudflare-agent-skill that
#      execs this repo's scripts/cli.sh, which dispatches:
#        expose-port-cloudflare-agent-skill <target>   expose (8080 | host:port | http(s)://…)
#        expose-port-cloudflare-agent-skill list       what is running (read-only)
#        expose-port-cloudflare-agent-skill stop       stop the tracked tunnel + proxy
#        expose-port-cloudflare-agent-skill stop-all   stop every quick tunnel + gate proxy
#      ~/.local/bin is added to PATH in the shell rc only if missing.
#
# Works on macOS and Linux. Nothing outside ~ is touched, no sudo, and nothing
# the user owns is deleted: only entries that ARE this skill are removed.
#
# Usage:
#   ./install.sh            install/refresh skill + shortcut
#   ./install.sh --dry-run  show what would be done, change nothing
#   ./install.sh --uninstall  remove the skill symlinks + shortcut + rc line
#   ./install.sh --quiet    less output
#   ./install.sh --help     this message
#
# Exit codes: 0 = ok, 1 = something failed, 2 = usage / not run from the repo.
# =============================================================================

set -euo pipefail

VERSION="1.3.1"
SKILL_NAME="expose-port-cloudflare-agent-skill"
MARKER="# added by expose-port-cloudflare-agent-skill install.sh"   # guard for rc edits

QUIET=0
DRY_RUN=0
UNINSTALL=0

for a in "$@"; do
  case "$a" in
    --dry-run)   DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --quiet)     QUIET=1 ;;
    --help|-h)   sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option: $a (try --help)" >&2; exit 2 ;;
  esac
done

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# --- repo root: resolved from this script's location, never guessed -----------
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P 2>/dev/null || true)"
if [ -z "$DIR" ] || [ ! -f "$DIR/SKILL.md" ] || [ ! -d "$DIR/scripts" ]; then
  warn "install.sh: SKILL.md/scripts not found next to this script — run me from the repo root."
  exit 2
fi

# --- discover Claude Code skills dirs -----------------------------------------
# Order matters: the active config dir first, then the default, then any other
# ~/.claude-* accounts that have a skills folder. Duplicates are dropped.
skill_dirs() {
  local dirs=() d real seen=" "
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then dirs+=("${CLAUDE_CONFIG_DIR%/}/skills"); fi
  dirs+=("$HOME/.claude/skills")
  for d in "$HOME"/.claude-*/; do
    d="${d%/}"
    [ -d "$d/skills" ] && dirs+=("$d/skills")
  done
  for d in "${dirs[@]}"; do
    # dedupe by RESOLVED path: ~/.claude may be a symlink to ~/.claude-k2.* (or
    # vice versa) — two strings, one physical directory, one install.
    real=$(cd "$d" 2>/dev/null && pwd -P || true)
    [ -n "$real" ] || real="$d"
    case "$seen" in
      *" $real "*) ;;              # same physical dir already listed
      *) printf '%s\n' "$d"; seen="$seen$real " ;;
    esac
  done
}

# --- is_this_skill <path>: only touch entries that really are this skill --------
is_this_skill() {
  local p="$1"
  # symlink pointing at this repo, or a directory whose SKILL.md names us
  if [ -L "$p" ]; then
    local target resolved
    target=$(readlink "$p" 2>/dev/null || true)
    resolved=$(cd "$p" 2>/dev/null && pwd -P || true)
    [ "$resolved" = "$DIR" ] && return 0
    return 1
  fi
  [ -f "$p/SKILL.md" ] && grep -qx "name: $SKILL_NAME" "$p/SKILL.md" 2>/dev/null
}

# --- link_into <skills-dir> ------------------------------------------------------
link_into() {
  local dest="$1/$SKILL_NAME"
  if [ ! -d "$1" ]; then
    say "  • $1 — missing, skipped"
    return 0
  fi
  if is_this_skill "$dest"; then
    if [ -L "$dest" ]; then
      say "  • $1 — OK (already linked)"
    else
      say "  • $1 — OK (already installed)"
    fi
    return 0
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    warn "  • $1 — $dest exists and is NOT this skill — PRESERVED (re-run with --uninstall if it is a leftover)"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    say "  • $1 — [dry-run] would link $dest → $DIR"
    return 0
  fi
  if ln -sfn "$DIR" "$dest" 2>/dev/null && [ -f "$dest/SKILL.md" ]; then
    say "  • $1 — linked"
  elif cp -R "$DIR" "$dest" 2>/dev/null && [ -f "$dest/SKILL.md" ]; then
    say "  • $1 — copied (symlinks unsupported here)"
  else
    warn "  • $1 — FAILED to install"
    return 1
  fi
}

# --- shortcut: ~/.local/bin/expose-port-cloudflare-agent-skill ------------------------------
install_shortcut() {
  local bindir="$HOME/.local/bin" wrapper="$HOME/.local/bin/$SKILL_NAME"
  if [ "$DRY_RUN" = 1 ]; then
    say "  • shortcut — [dry-run] would write $wrapper → scripts/cli.sh"
  else
    mkdir -p "$bindir"
    printf '#!/usr/bin/env bash\n# %s — CLI shortcut, generated by install.sh (re-run it to refresh)\nexec "%s/scripts/cli.sh" "$@"\n' \
      "$SKILL_NAME" "$DIR" > "$wrapper"
    chmod +x "$wrapper"
    say "  • shortcut — $wrapper"
  fi
  # PATH: only touch the rc when the bin dir is not already there
  if case ":$PATH:" in *":$bindir:"*) false ;; *) true ;; esac; then
    local rc="" line
    case "${SHELL:-}" in
      *fish) rc="$HOME/.config/fish/config.fish" ;;
      *bash) [ -f "$HOME/.bashrc" ] && rc="$HOME/.bashrc" || rc="$HOME/.bash_profile" ;;
      *)     rc="$HOME/.zshrc" ;;
    esac
    [ -n "$rc" ] || rc="$HOME/.zshrc"
    if [ -f "$rc" ] && grep -Fq "$MARKER" "$rc" 2>/dev/null; then
      say "  • PATH — already in $rc"
    elif [ "$DRY_RUN" = 1 ]; then
      say "  • PATH — [dry-run] would add $bindir to $rc"
    else
      {
        echo "$MARKER"
        echo "export PATH=\"\$HOME/.local/bin:\$PATH\""
      } >> "$rc"
      say "  • PATH — added $bindir to $rc (open a new terminal, or 'source $rc')"
    fi
  else
    say "  • PATH — $bindir already on PATH"
  fi
}

# --- uninstall -------------------------------------------------------------------
uninstall_all() {
  local d dest
  local found=0
  for d in $(skill_dirs); do
    dest="$d/$SKILL_NAME"
    if is_this_skill "$dest"; then
      found=1
      if [ "$DRY_RUN" = 1 ]; then
        say "  • $dest — [dry-run] would remove"
      else
        rm -rf -- "$dest" && say "  • removed $dest"
      fi
    fi
  done
  local wrapper="$HOME/.local/bin/$SKILL_NAME"
  if [ -f "$wrapper" ] && grep -qE "scripts/(cli|expose-port)\.sh" "$wrapper" 2>/dev/null; then
    found=1
    if [ "$DRY_RUN" = 1 ]; then
      say "  • $wrapper — [dry-run] would remove"
    else
      rm -f -- "$wrapper" && say "  • removed $wrapper"
    fi
  fi
  # strip the rc block we added (portable: no sed -i on macOS)
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.config/fish/config.fish"; do
    if [ -f "$rc" ] && grep -Fq "$MARKER" "$rc"; then
      found=1
      if [ "$DRY_RUN" = 1 ]; then
        say "  • $rc — [dry-run] would remove the PATH block"
      else
        grep -vF "$MARKER" "$rc" | grep -vF 'export PATH="$HOME/.local/bin:$PATH"' > "$rc.tmp" && mv "$rc.tmp" "$rc"
        say "  • $rc — removed the PATH block"
      fi
    fi
  done
  if [ "$found" = 0 ]; then
    say "nothing to uninstall — $SKILL_NAME is not installed anywhere."
  fi
}

# =============================================================================
say "expose-port-cloudflare-agent-skill installer v$VERSION (skill home: $DIR)"
if [ "$UNINSTALL" = 1 ]; then
  uninstall_all
  exit 0
fi

say "Installing the skill into every Claude Code config dir:"
FAILED=0
while IFS= read -r d; do
  link_into "$d" || FAILED=1
done < <(skill_dirs)

say "Installing the CLI shortcut:"
install_shortcut

say ""
say "Done. The skill is global — restart any running Claude Code session, then from any folder:"
say "    expose-port-cloudflare-agent-skill 8080                     expose a local server"
say "    expose-port-cloudflare-agent-skill list                     what is running now"
say "    expose-port-cloudflare-agent-skill stop                     stop the tracked tunnel + proxy"
say "    expose-port-cloudflare-agent-skill stop-all                 stop every quick tunnel + gate proxy"
if [ "$FAILED" = 1 ]; then
  warn "One or more steps failed — see messages above (nothing was destroyed)."
  exit 1
fi
exit 0
