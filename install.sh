#!/usr/bin/env bash
set -euo pipefail

# ── claude-evolve installer ────────────────────────────────────────────────
# Symlinks repo files into ~/.claude/evolve/, merges hooks into settings.json,
# and checks prerequisites.

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
EVOLVE_DIR="$HOME/.claude/evolve"
SETTINGS_FILE="$HOME/.claude/settings.json"
SKILLS_DIR="$HOME/.claude/skills"

echo "claude-evolve installer"
echo "======================="
echo ""

# ── OS detection ────────────────────────────────────────────────────────────
# Used to choose package-manager hints. Stays empty on unrecognized platforms;
# install hints fall back to a generic "see project page" message.
OS_KIND=""
case "$(uname -s 2>/dev/null)" in
  Darwin) OS_KIND="macos" ;;
  Linux)  OS_KIND="linux" ;;
esac

# install_hint <tool>
# Returns a single-line, OS-appropriate suggestion for installing <tool>.
install_hint() {
  local tool="$1"
  case "$OS_KIND" in
    macos)
      case "$tool" in
        jq)    echo "Install with: brew install jq" ;;
        yq)    echo "Install with: brew install yq  (mikefarah/yq v4)" ;;
        flock) echo "Install with: brew install flock" ;;
        *)     echo "Install $tool via your package manager" ;;
      esac
      ;;
    linux)
      case "$tool" in
        jq)    echo "Install with your package manager (e.g., apt-get install jq, dnf install jq, pacman -S jq)" ;;
        yq)    echo "Install mikefarah/yq v4 from https://github.com/mikefarah/yq#install (the Python yq is NOT compatible)" ;;
        flock) echo "flock is part of util-linux; install via your package manager (e.g., apt-get install util-linux)" ;;
        *)     echo "Install $tool via your package manager" ;;
      esac
      ;;
    *)
      echo "Install $tool — see the tool's project page for instructions"
      ;;
  esac
}

# ── Prerequisites ───────────────────────────────────────────────────────────

check_required() {
  local cmd="$1"
  local desc="$2"
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required but not found. $desc"
    exit 1
  fi
  echo "  [ok] $cmd"
}

echo "Checking prerequisites..."

check_required "jq" "$(install_hint jq)"
check_required "claude" "Install Claude Code: https://docs.anthropic.com/en/docs/claude-code"
check_required "flock" "$(install_hint flock)"

# yq: offer auto-install on macOS via brew; otherwise direct user to manual install.
if ! command -v yq &>/dev/null; then
  echo "  [!!] yq is not installed (required for config parsing)"
  if [[ "$OS_KIND" == "macos" ]] && command -v brew &>/dev/null; then
    read -rp "  Install yq via 'brew install yq'? [y/N] " yn
    case "$yn" in
      [Yy]*)
        echo "  Installing yq..."
        brew install yq
        if ! command -v yq &>/dev/null; then
          echo "ERROR: yq installation failed."
          exit 1
        fi
        echo "  [ok] yq installed"
        ;;
      *)
        echo "ERROR: yq is required. Aborting."
        exit 1
        ;;
    esac
  else
    echo "ERROR: yq is required. $(install_hint yq)"
    exit 1
  fi
else
  echo "  [ok] yq"
fi

# Anchor on literal `version v` to prevent the previous regex from over-matching
# `v3.4.x` (where `.*` greedily consumes through `v3.` and `4.` satisfies `v?4\.`)
# or `v14.x` (where `1` is consumed by `.*` and `4.` satisfies the rest).
if ! yq --version 2>&1 | grep -Eq 'mikefarah.*version v?4\.'; then
  echo "ERROR: claude-evolve requires mikefarah/yq v4."
  echo "       Found: $(yq --version 2>&1)"
  echo "       $(install_hint yq)"
  exit 1
fi
echo "  [ok] yq is mikefarah v4"

echo ""

# ── Create evolve directory ─────────────────────────────────────────────────

echo "Setting up ~/.claude/evolve/..."
mkdir -p "$EVOLVE_DIR"

# ── Symlink repo contents ──────────────────────────────────────────────────

symlink_item() {
  local src="$1"
  local dst="$2"
  if [[ -L "$dst" ]]; then
    # Already a symlink -- update it
    rm "$dst"
  elif [[ -e "$dst" ]]; then
    echo "  WARNING: $dst exists and is not a symlink. Skipping."
    return
  fi
  ln -s "$src" "$dst"
  echo "  $dst -> $src"
}

echo "Creating symlinks..."
symlink_item "$REPO_DIR/agents"      "$EVOLVE_DIR/agents"
symlink_item "$REPO_DIR/scripts"     "$EVOLVE_DIR/scripts"
symlink_item "$REPO_DIR/config.yaml" "$EVOLVE_DIR/config.yaml"
symlink_item "$REPO_DIR/install.sh"  "$EVOLVE_DIR/install.sh"
symlink_item "$REPO_DIR/uninstall.sh" "$EVOLVE_DIR/uninstall.sh"

# Ensure scripts are executable (matters for tarball/zip distributions where
# the executable bit may have been lost). `|| true` defends against unmatched glob.
chmod +x "$REPO_DIR"/scripts/*.sh "$REPO_DIR/install.sh" "$REPO_DIR/uninstall.sh" 2>/dev/null || true

# Symlink evolve skills into global skills directory
mkdir -p "$SKILLS_DIR"
for skill_dir in "$REPO_DIR/skills"/*/; do
  skill_name="$(basename "$skill_dir")"
  if [[ -d "$skill_dir" ]]; then
    symlink_item "$skill_dir" "$SKILLS_DIR/$skill_name"
  fi
done

# Symlink projects directory (data lives in the git repo for cross-machine sync)
DATA_PROJECTS="$REPO_DIR/data/projects"
mkdir -p "$DATA_PROJECTS"
if [[ -d "$EVOLVE_DIR/projects" ]] && [[ ! -L "$EVOLVE_DIR/projects" ]]; then
  echo "  WARNING: $EVOLVE_DIR/projects exists and is not a symlink."
  echo "  To migrate: cp -a $EVOLVE_DIR/projects/* $DATA_PROJECTS/ && rm -rf $EVOLVE_DIR/projects"
  echo "  Then re-run install.sh"
else
  symlink_item "$DATA_PROJECTS" "$EVOLVE_DIR/projects"
fi

# Symlink global directory (global instincts/proposals, cross-machine sync)
DATA_GLOBAL="$REPO_DIR/data/global"
mkdir -p "$DATA_GLOBAL"
if [[ -d "$EVOLVE_DIR/global" ]] && [[ ! -L "$EVOLVE_DIR/global" ]]; then
  echo "  WARNING: $EVOLVE_DIR/global exists and is not a symlink."
  echo "  To migrate: cp -a $EVOLVE_DIR/global/* $DATA_GLOBAL/ && rm -rf $EVOLVE_DIR/global"
  echo "  Then re-run install.sh"
else
  symlink_item "$DATA_GLOBAL" "$EVOLVE_DIR/global"
fi

echo ""

# ── Merge hooks into settings.json ─────────────────────────────────────────

echo "Configuring hooks in $SETTINGS_FILE..."

# Ensure settings.json exists
if [[ ! -f "$SETTINGS_FILE" ]]; then
  echo '{}' > "$SETTINGS_FILE"
fi

# The evolve hook configuration
EVOLVE_HOOKS='
{
  "hooks": {
    "UserPromptSubmit": [{"hooks": [
      {"type": "command", "command": "~/.claude/evolve/scripts/record-observation.sh"}
    ]}],
    "PostToolUse": [{"hooks": [
      {"type": "command", "command": "~/.claude/evolve/scripts/record-observation.sh"}
    ]}],
    "Stop": [{"hooks": [
      {"type": "command", "command": "~/.claude/evolve/scripts/reinforce.sh"}
    ]}],
    "SessionStart": [
      {"matcher": "startup", "hooks": [
        {"type": "command", "command": "~/.claude/evolve/scripts/on-session-start.sh"}
      ]},
      {"hooks": [
        {"type": "command", "command": "~/.claude/evolve/scripts/inject-instincts.sh"}
      ]}
    ]
  }
}
'

# Merge hooks: for each event type, append evolve matchers if not already present.
# Detection: check if any command contains "evolve/scripts/" for that event type.
MERGED=$(jq --argjson evolve "$EVOLVE_HOOKS" '
  # Ensure .hooks exists
  .hooks //= {} |

  # For each event type in the evolve config, walk each evolve matcher block
  # and merge it into the corresponding event-key on the user side.
  # Semantics: matcher equality (including both-null) collapses rows. Within a
  # matched row, append only NEW evolve commands (dedup by .command exact match
  # against pre-mutation $existing). Idempotent on re-run.
  reduce ($evolve.hooks | to_entries[]) as $entry (
    .;
    reduce ($entry.value[]) as $emat (
      .;
      .hooks[$entry.key] |= (
        (. // []) as $cur |
        if ($cur | any(.matcher == $emat.matcher)) then
          $cur | map(
            if .matcher == $emat.matcher then
              (.hooks // []) as $existing |
              .hooks = $existing + ([$emat.hooks[]]
                | map(. as $eh
                      | select(($existing | map(.command) | index($eh.command)) | not)))
            else . end)
        else $cur + [$emat]
        end
      )
    )
  )
' "$SETTINGS_FILE") || { echo "ERROR: jq merge failed. settings.json untouched."; exit 1; }

# `jq .` (not `jq -e .`) -- legal-but-unusual values like null are acceptable JSON.
if [[ -z "$MERGED" ]] || ! printf '%s' "$MERGED" | jq . >/dev/null 2>&1; then
  echo "ERROR: merged settings.json is empty or invalid JSON. settings.json untouched."
  exit 1
fi

# Backup-then-write-then-mv. Backup is defensive: $SETTINGS_FILE is not mutated
# until the final mv, so the cp-restore branches below are dead code in normal
# operation -- they protect against filesystem-level corruption between operations.
BACKUP_FILE="${SETTINGS_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
cp "$SETTINGS_FILE" "$BACKUP_FILE"
echo "  Backup written to $BACKUP_FILE"

TMP_FILE="${SETTINGS_FILE}.tmp.$$"
printf '%s\n' "$MERGED" > "$TMP_FILE" || {
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
echo "  Hooks merged into settings.json"

# Partial-install warning detector (R17 best-effort, see IMPROVEMENTS.md Tier 3 backlog).
# The merge logic above skips an event-key entirely if any evolve hook is already
# present. So a user with partial state (e.g., inject-instincts.sh but not
# record-observation.sh under UserPromptSubmit) ends up under-installed. Detect that
# and tell the user which commands they need to add manually.
PARTIAL_WARN=$(jq -r '
  def expected_for($event):
    if $event == "UserPromptSubmit" then ["record-observation.sh"]
    elif $event == "PostToolUse" then ["record-observation.sh"]
    elif $event == "Stop" then ["reinforce.sh"]
    elif $event == "SessionStart" then ["on-session-start.sh", "inject-instincts.sh"]
    else [] end;

  (.hooks // {}) as $h |
  ["UserPromptSubmit","PostToolUse","Stop","SessionStart"] | map(
    . as $event |
    expected_for($event) as $exp |
    ($h[$event] // [] | map(.hooks // []) | flatten | map(.command // "") | map(select(contains("evolve/scripts/")))) as $present |
    ($exp | map(. as $script | select(($present | map(contains($script)) | any) | not))) as $missing |
    if ($present | length) > 0 and ($missing | length) > 0
    then "  [!!] Partial-install detected for \($event): missing \($missing | join(", "))"
    else empty
    end
  ) | .[]
' "$SETTINGS_FILE" 2>/dev/null || true)

if [[ -n "$PARTIAL_WARN" ]]; then
  echo ""
  echo "WARNING: partial-install state detected. The merge filter does not auto-add"
  echo "         missing evolve commands when other evolve commands are already present"
  echo "         in the same event matcher (this is a known limitation tracked as a"
  echo "         Tier 3 follow-up to IMPROVEMENTS.md #31). Please add the missing"
  echo "         commands manually to your settings.json:"
  echo "$PARTIAL_WARN"
  echo ""
fi

echo ""

# ── Verify agent invocation ────────────────────────────────────────────────

echo "Verifying agent invocation..."
# Use plain mktemp (no -t flag) to match lib.sh:280 convention -- mktemp -t has
# divergent BSD/GNU semantics.
VERIFY_TMP="$(mktemp)"
trap 'rm -f "$VERIFY_TMP"' EXIT
printf 'Reply with OK and nothing else.\n' > "$VERIFY_TMP"

VERIFY_RESULT=""
VERIFY_RESULT=$(echo "test" | EVOLVE_SUBPROCESS=1 claude -p \
  --model claude-haiku-4-5 \
  --no-session-persistence \
  --system-prompt-file "$VERIFY_TMP" 2>/dev/null || true)

rm -f "$VERIFY_TMP"
trap - EXIT

if [[ -n "$VERIFY_RESULT" ]]; then
  echo "  [ok] Agent invocation works"
else
  echo "  [!!] Agent invocation returned empty response."
  echo "       claude-evolve requires 'claude -p --system-prompt-file' to work."
  echo "       Continuing anyway -- this may be a transient issue."
fi

echo ""

# ── Configure upstream remote (for repos created from the template) ────────

TEMPLATE_REPO_PATH="Lioscro/claude-evolve-template"
TEMPLATE_FETCH_URL="https://github.com/${TEMPLATE_REPO_PATH}.git"

setup_upstream() {
  if ! command -v git &>/dev/null; then
    echo "  [--] git not found; skipping upstream remote setup"
    return
  fi

  if ! git -C "$REPO_DIR" rev-parse --git-dir &>/dev/null; then
    echo "  [--] $REPO_DIR is not a git repository; skipping upstream remote setup"
    return
  fi

  # If origin already points at the template, this IS the template repo.
  local origin_url
  origin_url=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || echo "")
  if [[ "$origin_url" == *"$TEMPLATE_REPO_PATH"* ]]; then
    echo "  [--] origin matches the template ($TEMPLATE_REPO_PATH); skipping"
    return
  fi

  local existing_upstream_url
  existing_upstream_url=$(git -C "$REPO_DIR" remote get-url upstream 2>/dev/null || echo "")

  if [[ -z "$existing_upstream_url" ]]; then
    git -C "$REPO_DIR" remote add upstream "$TEMPLATE_FETCH_URL"
    echo "  [ok] added upstream: $TEMPLATE_FETCH_URL"
    git -C "$REPO_DIR" remote set-url --push upstream no_push
    echo "  [ok] locked upstream push URL to 'no_push'"
  elif [[ "$existing_upstream_url" == *"$TEMPLATE_REPO_PATH"* ]]; then
    echo "  [ok] upstream already points at template"
    local current_push_url
    current_push_url=$(git -C "$REPO_DIR" remote get-url --push upstream 2>/dev/null || echo "")
    if [[ "$current_push_url" != "no_push" ]]; then
      git -C "$REPO_DIR" remote set-url --push upstream no_push
      echo "  [ok] locked upstream push URL to 'no_push'"
    fi
  else
    echo "  [--] upstream is set to $existing_upstream_url (not the template); leaving alone"
  fi
}

echo "Configuring git upstream remote..."
setup_upstream || true

echo ""

# ── Summary ─────────────────────────────────────────────────────────────────

echo "Installation complete!"
echo ""
echo "Installed to:  $EVOLVE_DIR"
echo "Hooks config:  $SETTINGS_FILE"
echo "Projects dir:  $EVOLVE_DIR/projects/"
echo ""
echo "To uninstall:  $REPO_DIR/uninstall.sh"

if git -C "$REPO_DIR" remote get-url upstream &>/dev/null; then
  echo ""
  echo "Pull template updates:"
  echo "  git -C $REPO_DIR fetch upstream && git -C $REPO_DIR merge upstream/main"
fi
