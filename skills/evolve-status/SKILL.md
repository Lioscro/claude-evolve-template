---
name: evolve-status
description: Show evolve system status (counts plus full list of active instincts with triggers and actions, and active proposals with titles and descriptions) for the current project, a specific project, or "all".
user_invocable: true
---

# /evolve-status -- Evolve System Status

Show the state of the claude-evolve system for the current project, a specific
project, or every managed project. Output includes one-line counts for
observations, instincts, and proposals (active + archived), followed by the
full list of active instincts (with trigger and action) and active proposals
(with title and description) for both the project and the global scope.

## Steps

1. Read the single argument into `ARG` (may be empty).

2. Determine `MODE` from `ARG`:
   - `ARG` empty -> `MODE=cwd`
   - `ARG` is the literal string `all` (case-sensitive) -> `MODE=all`
   - anything else -> `MODE=single`

3. Resolve project ids via the shared helper. The helper prints resolved ids to
   stdout, one per line, and writes errors directly to stderr (the user sees
   them immediately). On non-zero exit, stop without further output.
   ```bash
   PROJECT_IDS="$(~/.claude/evolve/scripts/select-projects.sh "$ARG")" || exit 1
   ```

4. If `MODE=cwd` or `MODE=single` (exactly one id expected), run and print
   verbatim:
   ```bash
   ~/.claude/evolve/scripts/show-summary.sh "$PROJECT_IDS"
   ```

5. If `MODE=all`, iterate the ids (bash 3.2-safe; skip empty lines because
   `<<< ""` yields one empty iteration) and prefix each emitted line with
   `[<pid>] `. Projects with zero data produce no lines (Phase 2a's
   `--no-global` behavior) and are silently skipped.
   ```bash
   if [[ -z "$PROJECT_IDS" ]]; then
     echo "[claude-evolve] no projects yet"
   else
     while IFS= read -r pid; do
       [[ -z "$pid" ]] && continue
       ~/.claude/evolve/scripts/show-summary.sh --no-global "$pid" \
         | sed "/^[[:space:]]*$/!s|^|[$pid] |"
     done <<< "$PROJECT_IDS"
   fi
   ```

6. If `MODE=all`, after the per-project loop, print the global section exactly
   once (empty output if no global data):
   ```bash
   ~/.claude/evolve/scripts/show-summary.sh --global-only
   ```

7. Display the combined output to the user.
