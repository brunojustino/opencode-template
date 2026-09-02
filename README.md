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
install.ps1                non-destructive installer (creates .env, installs Serena if uv present)
.env.example               API key template (copied to .env; .env is gitignored)
docs/
  rules/task-execution.md  the gated task loop (load-on-demand)
  rules/git-workflow.md    commit + docs-update conventions
  adr/                     decision records (0001 records this template's design)
  plans/                   plan template with per-task mini-plans
  templates/               ADR template
.opencode/
  agent/planner.md         read-only planning agent
  agent/arch-analyzer.md   read-only architecture-analysis subagent
  command/                 /analyze-architecture entry point
  skills/                  10 skills, committed and auditable
```

## Apply to a project

```powershell
# from the template root
.\install.ps1 -Target C:\path\to\project
```

The installer **backs up first, then merges** - nothing can be lost:

- **Backup**: every existing file it touches is copied to `.template-backup\<timestamp>\<path>` before anything is written (re-runs create a new timestamped folder, never clobbering previous backups). Restore = copy files back.
- **Merges**: `AGENTS.md` (your content preserved, template router appended inside `<!-- owt:start/end -->` markers - idempotent on re-runs), `CONTEXT.md` (ensures a `## Language` section; your terms untouched), `.gitignore` (appends missing entries), `opencode.json` (JSON merge, missing keys only, plus a `opencode.json.pre-install.bak`)
- **Updates**: `.opencode/skills/**` and `.opencode/agent/` to the template version (old copies in the backup)
- **Never writes**: your existing `docs/` files (created only if missing) and `.env` (backed up every run, never written - keys stay verbatim)
- A write-guard aborts rather than overwriting any file that was not backed up in that run
- Sanity-checks the skill dependency chain; auto-installs Serena when `uv` is present

For a brand-new empty project you can also just copy the whole template folder.

## Workflow

```
/grill-with-docs  ->  /to-spec  ->  /to-tickets  ->  execute-task (per task):
  interview that          synthesize      split into        mini-plan -> approval ->
  builds CONTEXT.md       into a spec     ordered tasks     implement -> verify ->
  and ADRs                                                  docs update -> commit -> stop
```

- `execute-task` is the enforcement point: one task, one approval, one commit.
- `/analyze-architecture` is the onboarding point for existing codebases: it explores the project (via parallel read-only `arch-analyzer` subagents) and writes `docs/architecture/` - re-runnable, it refreshes only what changed since the last analysis.
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
| `analyze-architecture` | **Custom**: analyze the codebase and create/refresh `docs/architecture/` (overview, components, data flow, constraints - with Mermaid). Run `/analyze-architecture` after installing into a new project |

### Updating skills

```powershell
npx skills add mattpocock/skills --skill <name>   # fetch upstream into a scratch dir
# diff against .opencode/skills/<name>/ and copy what you want
```

Skills are vendored on purpose: versioned, auditable, offline. Update deliberately, not automatically.

## MCP servers

Enabled (both low context cost):

- **context7** (remote): up-to-date library docs. Key is wired by default to `{env:CONTEXT7_API_KEY}` from `.env` (the installer creates `.env` from `.env.example`). Empty = keyless, just rate-limited. Free key: https://context7.com
- **Serena** (local): symbol-level code retrieval/editing - the agent reads symbols, not whole files. Needs no key. The installer auto-installs it via uv when missing (`uv tool install -p 3.13 serena-agent`); if uv itself is missing it prints the install link. Skip it on small projects by setting `"enabled": false`.

Opt-in (not installed - each adds tool-list context cost):

| Server | Best for | Cost |
| ------ | -------- | ---- |
| GitHub (official, remote) | PRs, issues, Actions | High (dozens of tools) |
| Playwright (Microsoft) | Browser automation / E2E | Medium |
| Sentry (remote) | Error triage with stack traces | Medium |
| Chrome DevTools | Live console/network debugging | Medium |

Rule of thumb: 3-6 servers max, and only when a real need shows up.

## Stack suggestions

Recipes per project type. All snippets are `opencode.json`-ready and assume context7 + Serena (the template defaults) are already present. Skills install via the [skills registry](https://skills.sh) and land in `.agents/skills/` — cheap, since skills load on demand. MCP servers add permanent tool context, so add only what the project actually needs.

### Fullstack (Next.js/TypeScript + API + database)

| MCP | Why | Cost |
| --- | --- | --- |
| Playwright | Agent verifies its own UI changes in a real browser | Medium |
| Postgres MCP Pro | Schema + safe SQL; pair with a read-only DB role | Low-Med |
| GitHub (official) | PRs/issues/Actions without leaving the session | High - `ask`-gate it |
| Sentry | Errors with full stack-trace context | Medium |

```json
{
  "mcp": {
    "playwright": { "type": "local", "command": ["npx", "@playwright/mcp@latest"] },
    "postgres": {
      "type": "local",
      "command": ["postgres-mcp", "--access-mode=restricted", "{env:DATABASE_URI}"],
      "timeout": 15000
    },
    "github": { "type": "remote", "url": "https://api.githubcopilot.com/mcp", "oauth": {} },
    "sentry": { "type": "remote", "url": "https://mcp.sentry.dev/mcp", "oauth": {} }
  }
}
```

Install `postgres-mcp` once: `uv tool install postgres-mcp` (or `pipx install postgres-mcp`). Put the connection string in `.env` as `DATABASE_URI` and use a DB role with only `CONNECT`/`USAGE`/`SELECT`. **Never use the archived `@modelcontextprotocol/server-postgres`** - deprecated in 2025 after a SQL injection finding.

```powershell
npx skills add vercel-labs/agent-skills --skill react-best-practices
npx skills add vercel-labs/agent-skills --skill composition-patterns
npx skills add better-auth/skills        # only if using Better Auth
```

### Frontend

| MCP | Why | Cost |
| --- | --- | --- |
| Playwright | E2E verification driven via the accessibility tree | Medium |
| Chrome DevTools | Live console/network/perf traces on a running app | Medium |

```json
{
  "mcp": {
    "playwright": { "type": "local", "command": ["npx", "@playwright/mcp@latest"] },
    "chrome-devtools": { "type": "local", "command": ["npx", "chrome-devtools-mcp@latest"] }
  }
}
```

```powershell
npx skills add vercel-labs/agent-skills --skill react-best-practices
npx skills add vercel-labs/agent-skills --skill web-design-guidelines
npx skills add anthropics/skills --skill frontend-design   # avoids generic AI-looking UI
```

### Backend / API

| MCP | Why | Cost |
| --- | --- | --- |
| Postgres MCP Pro | Query plans, health checks, safe read-only SQL | Low-Med |
| Sentry | Production error triage | Medium |
| Firecrawl (hosted, keyless) | `firecrawl_developer_search` - semantic search over PRs/issues/docs; see firecrawl.dev for the endpoint | Low |

Docker: enable via Docker Desktop's built-in MCP toolkit instead of adding a server here.

```json
{
  "mcp": {
    "postgres": {
      "type": "local",
      "command": ["postgres-mcp", "--access-mode=restricted", "{env:DATABASE_URI}"]
    },
    "sentry": { "type": "remote", "url": "https://mcp.sentry.dev/mcp", "oauth": {} }
  }
}
```

The vendored `tdd` skill already covers test-first backend work. For framework-specific skills there is no dominant first-party set - search: `npx skills find fastapi` / `django` / `nestjs`.

### Android (native)

| MCP | Why | Cost |
| --- | --- | --- |
| replicant-mcp | Token-optimized (progressive disclosure) - fits the template's context budget | Medium |
| androidbuild-mcp | Alternative: compact `file:line` build errors, emulator control | Medium |

Prereqs: Android SDK (`ANDROID_HOME`), JDK 17+, Node 18+. Run the server's `doctor` tool first - it reports exactly what is missing. On smaller toolchains, `adb` via Bash is often enough.

```json
{
  "mcp": {
    "replicant": { "type": "local", "command": ["npx", "-y", "replicant-mcp"], "timeout": 30000 }
  }
}
```

No first-party Kotlin/Compose skills yet: `npx skills find kotlin` and `npx skills find jetpack compose`, install only what has real install counts.

### React Native / Expo

| MCP | Why | Cost |
| --- | --- | --- |
| Expo MCP | Dev server, logs, update workflows | Medium |

```powershell
npx skills add vercel-labs/agent-skills --skill react-native-guidelines
npx skills find expo        # Expo publishes a suite of first-party skills - pick what you use
```

### Python / data

| MCP | Why | Cost |
| --- | --- | --- |
| Jupyter MCP (Datalayer) | Real-time notebook cell editing/execution from the agent; hosted keyless alternative at `mcp.datalayer.run/mcp` | Low-Med |
| Postgres MCP Pro | If data lives in Postgres | Low-Med |
| mcp-data-science | 102 pipeline tools (EDA -> modeling). **102 tools = heavy context cost - opt-in only, when you truly work tabular-data-first** | High |

```json
{
  "mcp": {
    "jupyter": {
      "type": "local",
      "command": ["uvx", "jupyter-mcp-server"],
      "environment": {
        "JUPYTER_URL": "http://localhost:8888",
        "JUPYTER_TOKEN": "{env:JUPYTER_TOKEN}"
      }
    },
    "postgres": {
      "type": "local",
      "command": ["postgres-mcp", "--access-mode=restricted", "{env:DATABASE_URI}"]
    }
  }
}
```

Notebooks: keep heavy modeling in scripts/modules and use notebooks for exploration - the gated `execute-task` workflow works far better on diffable Python files. Skill coverage is sparse: `npx skills find pandas` / `pytorch` / `<framework>`.

### Agents

Keep `planner` (read-only thinker) everywhere. Optional additions - each agent's tool list costs context, so add sparingly:

- **reviewer** (subagent, read-only, loads `code-review`): any stack, run after `implement`
- **ui-verifier** (subagent, Playwright access): frontend/fullstack - drives the browser to verify the change actually works

### Safety notes

- Databases: dedicated read-only role + `--access-mode=restricted`. The role is the boundary that holds; the flag is the second layer.
- Read-only agents (planner, arch-analyzer, built-in plan) deny Serena's mutating tools **by name** (`serena_replace_content`, ...): `write/edit: false` only covers built-in tools, MCP tools are permissioned separately. `"doom_loop": "ask"` is the global safety net against any repeat-call loop.
- Credentials never in `opencode.json` (it is meant to be committed) - put them in `.env`, reference via `{env:...}`.
- Device/emulator MCPs (Android): these control real software state - keep their destructive tools behind `ask` permissions if you enable them.

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
