# opencode Workflow Template

A drop-in kit for [opencode](https://opencode.ai) projects - new or ongoing - that makes work controlled and documented by construction:

- **One task per approval cycle** - the agent never implements multiple tasks without your sign-off
- **Docs as first-class artifacts** - glossary (`CONTEXT.md`), decision records (`docs/adr/`), plans (`docs/plans/`) updated per task, committed per task
- **Minimal context usage** - thin `AGENTS.md` router, lazy-loaded rule files, on-demand skills, two low-cost MCP servers

## Structure

```
AGENTS.md                  ~30-line router: points to rules, loads them lazily
CONTEXT.md                 domain glossary (pure vocabulary)
opencode.template.json     MCP servers + permissions (merged into opencode.json)
install.ps1                non-destructive installer
docs/
  rules/task-execution.md  the gated task loop (load-on-demand)
  rules/git-workflow.md    commit + docs-update conventions
  adr/                     decision records (0001 records this template's design)
  plans/                   plan template with per-task mini-plans
  templates/               ADR template
.opencode/
  agent/planner.md         read-only planning agent
  skills/                  10 skills, committed and auditable
```

## Apply to a project

```powershell
# from the template root
.\install.ps1 -Target C:\path\to\project
```

The installer:

- Copies `AGENTS.md`, `CONTEXT.md`, `docs/`, `.opencode/` - **skips any file that already exists** (safe for ongoing projects)
- Merges `mcp` + `permission` into an existing `opencode.json` (preserves your keys); creates it if absent; prints a manual snippet if you use `opencode.jsonc`
- Sanity-checks the skill dependency chain, git repo, and Serena CLI

For a brand-new empty project you can also just copy the whole template folder.

## Workflow

```
/grill-with-docs  ->  /to-spec  ->  /to-tickets  ->  execute-task (per task):
  interview that          synthesize      split into        mini-plan -> approval ->
  builds CONTEXT.md       into a spec     ordered tasks     implement -> verify ->
  and ADRs                                                  docs update -> commit -> stop
```

- `execute-task` is the enforcement point: one task, one approval, one commit.
- ADRs are only written for decisions that are hard to reverse, surprising without context, and a real trade-off. Most sessions produce zero - that is by design.
- Push always requires explicit approval (`git push*` permission is `ask`).

## Skills

All committed under `.opencode/skills/` (source: [mattpocock/skills](https://github.com/mattpocock/skills), MIT):

| Skill | Purpose |
| ----- | ------- |
| `grill-with-docs` | Interview that sharpens a plan and writes CONTEXT.md + ADRs inline (needs `grilling` + `domain-modeling`) |
| `grilling` | The interview loop |
| `domain-modeling` | Glossary + ADR discipline |
| `to-spec` | Conversation -> spec |
| `to-tickets` | Spec/plan -> ordered tickets with blocking edges |
| `implement` | Implement spec/tickets (uses `tdd`, `code-review`) |
| `tdd` | Red-green-refactor reference |
| `code-review` | Two-axis review of a diff |
| `execute-task` | **Custom**: the gated per-task execution loop |

### Updating skills

```powershell
npx skills add mattpocock/skills --skill <name>   # fetch upstream into a scratch dir
# diff against .opencode/skills/<name>/ and copy what you want
```

Skills are vendored on purpose: versioned, auditable, offline. Update deliberately, not automatically.

## MCP servers

Enabled (both low context cost):

- **context7** (remote, keyless): up-to-date library docs. Optional: set `CONTEXT7_API_KEY` env var and add `"headers": { "CONTEXT7_API_KEY": "{env:CONTEXT7_API_KEY}" }` for higher rate limits.
- **Serena** (local): symbol-level code retrieval/editing - the agent reads symbols, not whole files. Requires [uv](https://docs.astral.sh/uv/getting-started/installation/): `uv tool install -p 3.13 serena-agent`. Skip it on small projects by setting `"enabled": false`.

Opt-in (not installed - each adds tool-list context cost):

| Server | Best for | Cost |
| ------ | -------- | ---- |
| GitHub (official, remote) | PRs, issues, Actions | High (dozens of tools) |
| Playwright (Microsoft) | Browser automation / E2E | Medium |
| Sentry (remote) | Error triage with stack traces | Medium |
| Chrome DevTools | Live console/network debugging | Medium |

Rule of thumb: 3-6 servers max, and only when a real need shows up.

## Context-efficiency principles

1. `AGENTS.md` is a router, never a manual. Details live in `docs/rules/` behind `@`-references the agent loads only when relevant.
2. Procedures live in skills (loaded on demand), not in always-on context.
3. Don't use `instructions` globs in `opencode.json` - those load *every* matching file into every session.
4. Keep the MCP tool list short; prefer servers with 2-3 tools.
5. On large codebases, prefer Serena symbol tools over whole-file reads.

## Customizing

- **Permissions**: `permission.skill` in `opencode.json` gates skills with glob patterns (`"experimental-*": "ask"`).
- **Second agent**: `planner.md` is the read-only thinker. Add more under `.opencode/agent/` if needed.
- **Serena per project**: flip `"enabled"` in `opencode.json`; it indexes on first use, then caches.
