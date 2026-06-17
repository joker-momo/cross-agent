# Cerebrum — Cross-Session Learnings

OpenWolf's value comes from learning across sessions. Update this file whenever
you learn something useful (low bar — when in doubt, add it).

## User Preferences

- Prime directive: correctness + real output quality win over speed/cost.
- Reasoning-tier handshake: begin every reply with `Reasoning tier: <low|medium|high|max> — reason`.
- Roles are flexible per task: any of {claude, codex, agy} can be planner /
  implementer / reviewer.

## Key Learnings

- This is a standalone, project-agnostic tool. It operates on a target project by
  path; it is NOT embedded in any target project.
- Headless agent CLIs: `claude -p` (`--output-format json`), `codex exec`
  (`--output-schema`, `--sandbox workspace-write`), `agy -p --yes`
  (`--output-format json`, known non-TTY stdout drop — google-antigravity/antigravity-cli#76).
- Quota IS precisely readable via live endpoints (earlier "no CLI exposes a
  precise quota" assumption was WRONG). Reference impl: hoangpm96/ai-switcher
  (Rust/Tauri, `src-tauri/src/quota.rs`).
  - Claude: `GET https://api.anthropic.com/api/oauth/usage`, Bearer = OAuth
    accessToken. In Claude 2.x the token lives in the macOS **Keychain** service
    `Claude Code-credentials-<sha256(CLAUDE_CONFIG_DIR)[:8]>` (NOT
    `~/.claude/.credentials.json` anymore). Headers REQUIRED:
    `anthropic-beta: oauth-2025-04-20` and `User-Agent: claude-code/<ver>`
    (missing UA → repeated 429s). Response: `five_hour.utilization` /
    `seven_day.utilization` (0-100) + `resets_at`. Cache 60s/dir. We implemented
    this read-only (no token refresh) with fallback to ~/.claude.json hints.
  - Codex live fallback (not yet implemented here): `GET
    https://chatgpt.com/backend-api/wham/usage`, Bearer = `tokens.access_token`,
    refresh via `https://auth.openai.com/oauth/token` (writes auth.json). Profile
    accounts symlink sessions/ so rollout files are SHARED — rollout reflects the
    last active account, not necessarily the one asked for.
- This dev machine canNOT live-verify Claude usage: `claude auth status` =
  `loggedIn:false` (Claude Code harness injects creds at runtime; nothing in the
  Keychain), and `ANTHROPIC_BASE_URL` is set. Realtime only works on a machine
  logged in via `claude setup-token` (token lands in Keychain). Parse + fallback
  + cooldown are unit-tested; the live HTTP path only runs on such a machine.
- Claude usage hardening (ref decolua/9router `open-sse/services/usage/claude.js`
  + `providers/registry/claude.js`):
  - Token can EXPIRE. Keychain blob `claudeAiOauth` has `accessToken`,
    `refreshToken`, `expiresAt` (ms). Refresh via `POST
    https://api.anthropic.com/v1/oauth/token` JSON body
    {grant_type:refresh_token, refresh_token, client_id} with Claude Code's
    public client_id `9d1c250a-e61b-44d9-88ed-5944d1962f5e`. Use the fresh token
    in-memory (CLI owns the stored copy).
  - The usage endpoint 429s easily — back off ~180s per token after a 429
    (chat with the same token still works; only the quota poll is limited).
    Send `anthropic-version: 2023-06-01` + `User-Agent: claude-code/<ver>`.
  - Response may carry model-specific weekly windows `seven_day_<model>`
    (sonnet/opus) + `extra_usage` beyond five_hour/seven_day.
  - Legacy/admin path (deferred, not implemented): `GET /v1/settings` →
    `organization_id` → `GET /v1/organizations/{org}/usage` for API-key/org users.
  - 9router itself does NOT read the CLI keychain — it runs its own OAuth PKCE
    login and stores its own tokens. We chose the keychain-read approach instead
    (lighter; no second login). Own-OAuth is the fallback option if needed later.
  - Do NOT show `oauthAccount.billingType` from `~/.claude.json` as the account
    plan. Values like `stripe_subscription` are payment mechanisms, not
    user-facing account types.
- Antigravity (agy): CLI = `agy`, auth = Google OAuth stored ENCRYPTED in Keychain
  "Antigravity IDE Safe Storage" (master key encrypting the IDE's state DB, Chrome
  Safe-Storage style) — NOT directly readable. So quota has two real sources, both
  refs (skainguyen1412/antigravity-usage, wusimpl/AntigravityQuotaWatcher,
  ai-switcher quota.rs):
  - LOCAL (chosen, needs IDE open, no second login): each `language_server_*`
    process (find via `ps -ax -o pid=,command=`) carries `--csrf_token <uuid>` and
    `--extension_server_port <port>`; it listens on loopback. Transport is
    **HTTPS with a self-signed cert** (`https://127.0.0.1:<listening-port>`, accept
    untrusted for 127.0.0.1) — NOT plain http; fall back to **HTTP on
    `--extension_server_port`** if the TLS handshake fails. POST
    `/exa.language_server_pb.LanguageServerService/GetUserStatus`, headers
    `X-Codeium-Csrf-Token` + `Connect-Protocol-Version: 1`. (A no-arg
    `GetUnleashData {"wrapper_data":{}}` probe can pick the right port.)
  - CLOUD (deferred, no IDE but needs own OAuth login): `POST
    cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` then `:fetchAvailableModels`
    with a Bearer Google token (User-Agent `antigravity`). antigravity-usage logs
    in itself for this; it does NOT read agy's keychain token.
  - RICH quota (the IDE "Model Quota" panel): RPC
    `RetrieveUserQuotaSummary` (body `{}`) → `response.groups[].buckets[]`, each
    bucket = `window` ("weekly"/"5h") + `remainingFraction` (1.0=full) +
    `resetTime`. Groups are "Gemini Models" / "Claude and GPT models". This is
    far richer than GetUserStatus (which only gives per-model 5h fraction). Use
    GetUserStatus for email/plan/credits, RetrieveUserQuotaSummary for quota.
    Find more hidden RPCs via `strings .../Resources/bin/language_server | grep
    LanguageServerService/`.
  Parse: `userStatus.cascadeModelConfigData.clientModelConfigs[].quotaInfo.remainingFraction`
  (1.0 = full; label from `label` or `modelOrAlias.model`). PROTO3 GOTCHA: a
  default value is OMITTED, so a missing `remainingFraction` = 0.0 = exhausted —
  do NOT skip. Plan + monthly prompt credits at
  `userStatus.planStatus.{planInfo.planName, availablePromptCredits, planInfo.monthlyPromptCredits}`.
  IDE closed => no server => UI shows "open Antigravity IDE for quota".
- Build/packaging:
- Universal .app without full Xcode: `swift build -c release --arch <a>` PER ARCH
  (single-arch uses llbuild; the `--arch a --arch b` multi path needs xcbuild),
  then `lipo -create` the per-arch binaries. Sign ad-hoc (`codesign -s -`) by
  default; `SIGN_IDENTITY=<Developer ID>` adds hardened runtime for notarization.
- Codex local status, REAL on-disk schema (verified 2026-06-17, do not guess):
  - `CODEX_HOME/auth.json` has NO plain email. Account email + ChatGPT plan live
    in the signed JWT at `tokens.id_token` — base64url-decode the payload segment.
    Claims: `email`, and `https://api.openai.com/auth.chatgpt_plan_type`.
    `tokens.account_id` is only a GUID fallback.
  - Quota lives in `.codex/sessions/**/*.jsonl`, nested under `payload.rate_limits`
    (NOT top-level). Windows are `primary` / `secondary` (not `*_window`); each has
    `used_percent`, `window_minutes` (300=5h, 10080=weekly; NOT seconds), `resets_at`
    (epoch, NOT `reset_at`). Plan name also at `rate_limits.plan_type`.
  - rate_limits appears in recent sessions too, so scanning newest ~20 jsonl works.
- Current machine has SwiftPM/Command Line Tools but not full Xcode; `xcodebuild`
  is unavailable and XCTest/Swift Testing modules are absent, so native Swift
  verification uses `Trinity --self-test`.
- Native Swift UI should feel like a Mac utility: use `NavigationSplitView` with
  a persistent sidebar for workspace/agent context, toolbar items for Run/Stop
  actions, and detail content built from native `GroupBox`, `List`, `Picker`,
  `Stepper`, and `TextEditor` controls instead of web-dashboard panels.
- Sidebar quota should not be rendered as one long label. Use compact structured
  rows per quota window, separate reset timestamp sublines, and small percent
  meter bars for quick scanning.
- For status/quota refresh in the Swift app, prefer silent background refreshes
  for periodic polling; reserve visible "Checking accounts..." spinners for
  user-triggered Recheck and login/account-switch polling.
- Design guidance from taste-skill should be applied contextually here: Trinity
  is a native macOS utility/product UI, not a marketing landing page, so use the
  anti-default/visual-hierarchy/a11y parts but avoid hero/portfolio/web flourish
  rules that do not fit.
- Shell visual capture can be unavailable in this desktop harness:
  `screencapture` may fail to create a display image and `osascript` may lack
  Assistive Access, so app UI verification may need Computer Use or manual
  inspection beyond build/self-test evidence.
- After macOS screen/accessibility permissions are granted, Swift app visual
  verification works by activating `Trinity`, reading the `Workbench` window
  bounds through System Events, and capturing that region with `screencapture -R`.
- Antigravity has two separate readiness concepts: app/language-server
  availability can provide account/quota, but task execution still needs a
  runnable `agy` CLI. On this machine `~/.antigravity/antigravity/bin/agy`
  exists as a broken symlink, so UI must not present app availability as
  runnable CLI readiness.

- Swift `Process`: ALWAYS drain stdout/stderr pipes concurrently with execution
  (background queue + DispatchGroup), never `readDataToEndOfFile()` after
  `waitUntilExit()` — agent CLI output exceeds the ~64KB pipe buffer and
  deadlocks. `DispatchGroup.wait()` is illegal in an async context, so do the
  draining in a synchronous helper called from `Task.detached`.
- SelfTests use a `FakeShell`, so the real `Shell`/`Process` path is NOT covered
  by the role/builder tests. Bugs in real subprocess handling need their own
  self-test that exercises `Shell()` directly.
- Codex reviewer needs `--output-schema <path>`; the schema ships as a Swift
  resource (`Sources/Trinity/Resources/review.schema.json`) resolved via
  `Bundle.module` — note the resource base name is `review.schema` (ext `json`).

## Do-Not-Repeat

- 2026-06-17: Don't call `readDataToEndOfFile()` on a `Process` pipe only after
  `waitUntilExit()` — deadlocks on >64KB output. Drain concurrently.
- 2026-06-17: Watch Swift operator precedence — `a && b || c` is `(a && b) || c`.
  `char.isASCII && char.isLetter || char.isNumber` leaked non-ASCII digits into
  branch names. Parenthesize the OR.
- 2026-06-17: A builder param that nothing passes is a dead contract — verify the
  caller actually wires optional args (codex `schemaPath` was unused in prod).

## Decision Log

- 2026-06-17: Loop strategy = hybrid (implement↔review, escalate to planner after
  2 consecutive fails). max_iter=5, full-auto, every stop states an explicit reason.
- 2026-06-17: UI = local web control center (FastAPI + React/Vite/Tailwind/shadcn,
  SSE for live). [SUPERSEDED below.]
- 2026-06-17: PIVOT — app is now **pure Swift only**. Deleted the Python backend,
  the React/Tauri frontend, and all non-Swift code. Single target = native SwiftUI
  macOS app (`Sources/Trinity/`, SwiftPM). No localhost, no `uv`/`node`, no other
  runtime. Verification = `Trinity --self-test` (no XCTest in this Command Line
  Tools env). Do NOT reintroduce Python/Rust/web layers.
