# Claude Code Usage Menu Bar

Small macOS menu-bar utility that shows live Claude Code usage limits and reset
timing next to the clock. It is a port of the Codex usage menu bar, rebuilt for
Claude Code.

<p align="left">
  <img src="docs/widget-percentage.png" alt="Percentage display" height="43">
  &nbsp;&nbsp;
  <img src="docs/widget-battery.png" alt="Battery display with countdown" height="43">
</p>

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
signs it with your code-signing identity if you have one (ad-hoc otherwise).
This local build is not notarized.

### Keychain access (no password prompts)

The app never touches the keychain directly. It reads and writes
`Claude Code-credentials` through `/usr/bin/security` — the same tool, and the
same commands, Claude Code itself uses. That item already trusts
`/usr/bin/security`, so there is no prompt to approve, rebuilding doesn't
matter, and the item's access list is never modified.

Earlier versions wrote the item with `SecItemUpdate`, which replaced its
partition list with this app's identity and locked Claude Code out: the Claude
desktop app / CLI then asked for your login password on every launch. If that
happened to you, click **Always Allow** once on the next prompt that names
`security`, or restore it directly (asks for your login password):

```sh
security set-generic-password-partition-list -s "Claude Code-credentials" -S apple-tool:
```

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
   (`security find-generic-password -w`), cached in memory for the token's
   lifetime.
2. If the OAuth access token is expired (or about to expire), refresh it against
   `https://platform.claude.com/v1/oauth/token` using the stored refresh token,
   then write the rotated tokens back to the same keychain item
   (`security -i` ← `add-generic-password -U … -X <hex>`, so the token never
   appears in `ps`) so the CLI and this widget stay in sync. Refresh tokens are
   single-use, so the write is read back and verified.
3. `GET https://api.anthropic.com/api/oauth/usage` with the bearer token and the
   `anthropic-beta: oauth-2025-04-20` header.
4. Map `five_hour` → the session window and `seven_day` → the weekly window.
   `utilization` is a 0–100 percentage; `resets_at` is an ISO-8601 timestamp.

If a refresh fails after the app has already fetched usage, it keeps the
last-good percentages but marks them stale, shows the refresh error in the menu,
and replaces an expired reset time/countdown with `--` / `--:--`. On a cold
start with no cached usage, the menu shows an explanatory `Error:` line and the
bar shows `--`.

## Notes

- This is a local-only project; it is not wired to any GitHub repo.
- It started as a port of the Codex usage menu bar, which was used only as
  reference and is not part of this repo.
