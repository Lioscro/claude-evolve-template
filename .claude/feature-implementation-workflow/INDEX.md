# Feature implementation workflow — index

| Directory | Status | Description |
|-----------|--------|-------------|
| [20260506_repo_memory_storage](20260506_repo_memory_storage/) | COMPLETE | Move evolve `type=memory` artifact storage from `~/.claude/projects/{cwd}/memory/` into the repo at `data/global/memory/` and `data/projects/{project_id}/memory/`, mirroring instincts; inject ALL memories (no decay, no top-N) at SessionStart alongside instincts. |
