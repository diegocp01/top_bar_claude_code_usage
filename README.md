# Claude Code Usage Menu Bar

Small macOS menu-bar utility that shows live Claude Code usage limits and reset
timing next to the clock. It is a port of the Codex usage menu bar, rebuilt for
Claude Code.

The app reads your Claude Code login from the macOS keychain item
`Claude Code-credentials` (the same one the Claude Code CLI uses), refreshes the
OAuth access token when needed, and calls Anthropic's `/api/oauth/usage`
endpoint — the same source that powers the `/usage` command inside Claude Code.

It surfaces:

- The **5-hour session** window (used / left, reset time).
- The **7-day weekly** window (used / left, reset date).
- The **weekly Opus** window when your plan exposes one (Max plans).
- Your plan (Pro / Max) and last-updated time.

No Python runtime and no network credentials of your own are required — it
reuses the existing Claude Code login.

Click the menu-bar item to choose:

- Percentage or battery display.
- Percentage left or percentage used (default: percentage left).
- Which window the menu-bar number tracks: **Session (5h)** or **Weekly (7d)**.
- Reset clock time or a live countdown to reset.
- Refresh interval: 30 seconds, 1 minute, 3 minutes, or 5 minutes.
- Launch at Login, backed by `SMAppService`.

## Requirements

- macOS 13 (Ventura) or newer.
- Claude Code CLI installed and signed in (`claude` — so the keychain item
  exists).

## Build & Run

```sh
./scripts/build.sh
open ".build/release/Claude Code Usage Menu Bar.app"
```

The build script produces a universal Apple Silicon/Intel `.app` bundle and
ad-hoc signs it for local use. This local build is not notarized.

### First-run keychain prompt

The first time the app reads your Claude Code credentials, macOS shows a
keychain prompt:

> "Claude Code Usage Menu Bar" wants to use information stored in
> "Claude Code-credentials" in your keychain.

Click **Always Allow**. Because local builds are ad-hoc signed, the prompt
re-appears after every rebuild (each build has a different signature). Once you
settle on a build and stop rebuilding, the approval sticks.

## Launch at Login

Use the app menu item **Launch at Login** (macOS `SMAppService`). It does not
use `KeepAlive`, so choosing **Quit** stays quit.

For local development builds, you can also install a per-user LaunchAgent that
opens the built app at login:

```sh
./scripts/install_launch_agent.sh
```

To remove it:

```sh
./scripts/uninstall_launch_agent.sh
```

## How it works

1. Read the `Claude Code-credentials` generic-password item from the keychain
   (`SecItemCopyMatching`).
2. If the OAuth access token is expired (or about to expire), refresh it against
   `https://platform.claude.com/v1/oauth/token` using the stored refresh token,
   then write the rotated tokens back to the same keychain item so the CLI and
   this widget stay in sync.
3. `GET https://api.anthropic.com/api/oauth/usage` with the bearer token and the
   `anthropic-beta: oauth-2025-04-20` header.
4. Map `five_hour` → the session window and `seven_day` → the weekly window.
   `utilization` is a 0–100 percentage; `resets_at` is an ISO-8601 timestamp.

If anything fails (not signed in, keychain denied, offline, rate-limited), the
menu shows an explanatory `Error:` line and the bar shows `--`.

## Notes

- This is a local-only project; it is not wired to any GitHub repo.
- It started as a port of the Codex usage menu bar, which was used only as
  reference and is not part of this repo.
