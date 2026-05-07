# Feature implementation workflow — index

| Directory | Status | Description |
|-----------|--------|-------------|
| [20260506_repo_memory_storage](20260506_repo_memory_storage/) | COMPLETE | Move evolve `type=memory` artifact storage from `~/.claude/projects/{cwd}/memory/` into the repo at `data/global/memory/` and `data/projects/{project_id}/memory/`, mirroring instincts; inject ALL memories (no decay, no top-N) at SessionStart alongside instincts. |
| [20260507_memory_auto_creation](20260507_memory_auto_creation/) | COMPLETE | Auto-create memory artifacts from high-confidence individual instincts via a new `graduate.sh` (tiered propose + auto-approve), build out missing global memory infrastructure (approve/reject/write), restrict the clusterer to skill+rule, and add an `archive_proposal()` lib helper. |
