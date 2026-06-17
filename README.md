# Trinity — Multi-Agent Orchestrator

Project-agnostic tool that runs a **plan → implement → review** loop across three
coding-agent CLIs — **Claude** (`claude`), **Codex** (`codex`), and
**Antigravity** (`agy`). You assign any agent to any role per task; the loop runs
full-auto until the reviewer approves or it stops with an explicit reason.

Design spec: [`docs/specs/2026-06-17-trinity-orchestrator-design.md`](docs/specs/2026-06-17-trinity-orchestrator-design.md).

Pure Swift. SwiftUI + Swift Package Manager, no other language or runtime: no
Python backend, no web frontend, no localhost binding, no `uv`/`node`.

## Layout

```
Sources/Trinity/  SwiftUI macOS-native app, service layer, agent runner, UI
Scripts/          Native app packaging helpers
```

## Build & run

```bash
swift build
.build/debug/Trinity --self-test    # built-in regression checks
Scripts/build_app.sh                # package Trinity.app
open .build/release/Trinity.app
```

The app expects users to install whichever agent CLIs they want to use:
`claude`, `codex`, and/or `agy`.

## Distribution

`Scripts/build_app.sh` builds a **universal** (arm64 + x86_64) `.app` and signs it.

```bash
Scripts/build_app.sh                       # universal, ad-hoc signed
ARCHS="arm64" Scripts/build_app.sh         # single-arch (faster, this Mac only)
SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" Scripts/build_app.sh  # notarizable
```

- **Ad-hoc signed** (default): runs locally; on another Mac the recipient must
  clear quarantine once — `xattr -dr com.apple.quarantine Trinity.app` (or
  right-click → Open).
- **Developer ID** (needs an Apple Developer account): builds with hardened
  runtime + timestamp, ready to notarize (`xcrun notarytool submit … --wait`
  then `xcrun stapler staple Trinity.app`) so it opens with no warning anywhere.
- Universal binary requires the per-arch build path used by the script; the
  `swift build --arch a --arch b` multi-arch flag needs full Xcode, which the
  script avoids by building each arch separately and `lipo`-merging.

Recipients still install + log in to the agent CLIs (`claude`, `codex`, `agy`)
themselves; the app spawns them and reads their local credentials.

## How it works

- **Roles**: planner / implementer / reviewer — any agent in any role, per task.
- **Loop**: plan → (implement → checkpoint commit → review)×N. Reviewer alone
  decides approval via a schema-validated JSON verdict.
- **Guardrails**: never runs on `main`, creates `trinity/<slug>` branch, stashes a
  dirty worktree, per-call timeout, checkpoint commit each iteration.
- **Escalation**: ≥2 consecutive rejections → planner revises the plan.
- **Stop reasons** (always explicit): `approved`, `max_iterations`,
  `plan_rejected`, `agent_error`, `verdict_unparseable`, `no_changes`,
  `cancelled`.

Per-run artifacts land in `<target-project>/.trinity/runs/<id>/`
(`task.md`, `plan.md`, `review-N.json`, `transcript.log`, `status.json`).
Tool-global state lives in `~/.trinity/`.
