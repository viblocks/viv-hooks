## Context Navigation (Graphify)

This repo is treated as **markdown-only** for memory-system purposes: graphify's default AST extraction does not cover bash/shell scripts (the primary code in this repo), so the 3-layer rule collapses to 2 layers.

### 2-Layer Query Rule
1. **First:** query the Obsidian vault (`logs/`, `architecture/decisions.md`) for project-level decisions and recent context.
2. **Second:** read raw `.md` and `.sh` files when answering domain questions or editing.

### When to use Graphify
- Not applicable today — `graphify update .` reports "No code files found" because bash/shell is not in the default extractor.
- If TypeScript/Python/JS tooling is added later, run `graphify update . --obsidian --obsidian-dir ~/AI/vault/graphify/<this-repo>` and switch to the 3-layer rule.
- For semantic extraction of shell + markdown, consider `--mode deep` with `MOONSHOT_API_KEY` — costs tokens.

### Do NOT
- Don't manually modify files inside `graphify-out/` (none today).
- Don't re-read every file in a session — use READMEs and SKILL.md indexes first.
