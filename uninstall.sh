#!/usr/bin/env bash
set -euo pipefail

# ── claude-evolve uninstaller ──────────────────────────────────────────────
# Removes evolve hooks from settings.json, removes symlinks, and optionally
# cleans up project data.

EVOLVE_DIR="$HOME/.claude/evolve"
SETTINGS_FILE="$HOME/.claude/settings.json"
SKILLS_DIR="$HOME/.claude/skills"

# Resolve $0 through symlinks so symlink-invoked uninstall (~/.claude/evolve/uninstall.sh)
# correctly maps back to the real repo checkout.
SCRIPT="$0"
while [[ -L "$SCRIPT" ]]; do
  link="$(readlink "$SCRIPT")"
  case "$link" in
    /*) SCRIPT="$link" ;;
    *)  SCRIPT="$(dirname "$SCRIPT")/$link" ;;
  esac
done
REPO_DIR="$(cd "$(dirname "$SCRIPT")" && pwd -P)"

echo "claude-evolve uninstaller"
echo "========================="
echo ""

# ── Remove hooks from settings.json ────────────────────────────────────────

if [[ -f "$SETTINGS_FILE" ]]; then
  echo "Removing evolve hooks from $SETTINGS_FILE..."

  CLEANED=$(jq '
    if .hooks then
      .hooks |= with_entries(
        .value |= (
          map(.hooks |= map(select((.command // "") | contains("evolve/scripts/") | not)))
          | map(select((.hooks // []) | length > 0))
        )
      )
      | .hooks |= with_entries(select(.value | length > 0))
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else .
    end
  ' "$SETTINGS_FILE") || { echo "ERROR: jq filter failed. settings.json untouched."; exit 1; }

  # Use jq . (NOT jq -e .) so legal-but-unusual JSON values like null are accepted.
  if [[ -z "$CLEANED" ]] || ! printf '%s' "$CLEANED" | jq . >/dev/null 2>&1; then
    echo "ERROR: cleaned settings.json is empty or invalid JSON. settings.json untouched."
    exit 1
  fi

  BACKUP_FILE="${SETTINGS_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$SETTINGS_FILE" "$BACKUP_FILE"
  echo "  Backup written to $BACKUP_FILE"

  TMP_FILE="${SETTINGS_FILE}.tmp.$$"
  printf '%s\n' "$CLEANED" > "$TMP_FILE" || {
    echo "ERROR: failed to write temp file."
    rm -f "$TMP_FILE"
    exit 1
  }

  if ! jq . "$TMP_FILE" >/dev/null 2>&1; then
    echo "ERROR: temp file is not valid JSON."
    rm -f "$TMP_FILE"
    exit 1
  fi

  mv "$TMP_FILE" "$SETTINGS_FILE"
  echo "  Hooks removed from settings.json"
else
  echo "  No settings.json found -- nothing to clean."
fi

echo ""

# ── Remove skills symlink ──────────────────────────────────────────────────

echo "Removing evolve skill symlinks..."
found_skills=false
if [[ -d "$SKILLS_DIR" ]]; then
  for link in "$SKILLS_DIR"/*; do
    [[ -L "$link" ]] || continue
    target="$(readlink "$link")"
    case "$target" in
      "$REPO_DIR/skills/"*)
        rm "$link"
        echo "  Removed $(basename "$link") (-> $target)"
        found_skills=true
        ;;
    esac
  done
fi
[[ "$found_skills" == "false" ]] && echo "  No evolve skill symlinks found."

echo ""

# ── Remove evolve directory ────────────────────────────────────────────────

if [[ -d "$EVOLVE_DIR" ]]; then
  # Check if there's actual project data (not just symlinks)
  HAS_DATA=false
  if [[ -d "$EVOLVE_DIR/projects" ]] && [[ "$(ls -A "$EVOLVE_DIR/projects" 2>/dev/null)" ]]; then
    HAS_DATA=true
  fi

  if [[ "$HAS_DATA" == "true" ]]; then
    echo "Project data exists in $EVOLVE_DIR/projects/."
    read -rp "Remove ALL evolve data (projects, logs, etc.)? [y/N] " yn
    case "$yn" in
      [Yy]*)
        # Detach projects/global symlinks before rm -rf to avoid deleting repo data
        [[ -L "$EVOLVE_DIR/projects" ]] && rm "$EVOLVE_DIR/projects"
        [[ -L "$EVOLVE_DIR/global" ]] && rm "$EVOLVE_DIR/global"
        rm -rf "$EVOLVE_DIR"
        echo "Removed $EVOLVE_DIR and all data."
        ;;
      *)
        echo "Keeping project data. Removing only symlinks..."
        # Remove symlinks but not real directories/files
        for item in "$EVOLVE_DIR/agents" "$EVOLVE_DIR/scripts" \
                    "$EVOLVE_DIR/config.yaml" "$EVOLVE_DIR/install.sh" \
                    "$EVOLVE_DIR/uninstall.sh" "$EVOLVE_DIR/projects" \
                    "$EVOLVE_DIR/global"; do
          if [[ -L "$item" ]]; then
            rm "$item"
            echo "  Removed symlink: $item"
          fi
        done
        echo "  Project data preserved in $EVOLVE_DIR/projects/"
        ;;
    esac
  else
    [[ -L "$EVOLVE_DIR/projects" ]] && rm "$EVOLVE_DIR/projects"
    [[ -L "$EVOLVE_DIR/global" ]] && rm "$EVOLVE_DIR/global"
    rm -rf "$EVOLVE_DIR"
    echo "Removed $EVOLVE_DIR (no project data found)."
  fi
else
  echo "No evolve directory found at $EVOLVE_DIR."
fi

echo ""
echo "Uninstallation complete."
