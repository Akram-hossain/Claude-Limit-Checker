# Claude Meter

A tiny macOS menu bar app that shows your Claude subscription usage limits —
the same numbers as claude.ai's usage page and Claude Code's `/usage` —
without opening the site. Personal use; everything stays on this Mac.

## What it shows

- **Floating meter (bottom-right corner)**: a small always-on-top pill pinned
  above the Dock on every desktop/Space, showing the session % and the highest
  weekly %. Click it for the full menu. Toggle it via the menu item
  "Floating Meter (bottom right)".
- **Menu bar**: a progress ring + percentage for your current **session (5-hour)
  limit**. Turns orange at 70% and red at 90%. A `⚠` appears if any weekly
  limit is at 90%+.
- **Dropdown menu**: every limit (session, weekly all-models, weekly per-model)
  with a progress bar and time until reset, plus:
  - Refresh Now (also auto-refreshes every 60s and after wake from sleep)
  - Open claude.ai Usage Page
  - Launch at Login toggle

## How it works

It reads the OAuth token that **Claude Code** already stores in your login
Keychain (service `Claude Code-credentials`) and calls
`https://api.anthropic.com/api/oauth/usage` — the official endpoint the Claude
apps use. The token never leaves your machine and is never written anywhere.

Requirement: be signed in to the `claude` CLI (Claude Code). If the token
expires, the menu shows a hint; opening Claude Code once refreshes it.

## Build & run

```
./build.sh
open "Claude Meter.app"
```

On first launch macOS asks to allow access to the Keychain item — click
**Always Allow**. Because the app is ad-hoc signed, rebuilding it may make
that prompt appear once again.

To have it start automatically, click the menu bar icon → **Launch at Login**.

## Security & privacy

What the app does with your credentials:

- **Reads** the OAuth token Claude Code already stores in your login Keychain
  (service `Claude Code-credentials`). macOS asks your permission on first
  launch; the token is held in memory only for the duration of each request.
- **Sends** it to exactly one place: `https://api.anthropic.com/api/oauth/usage`,
  over HTTPS, in an `Authorization` header. No other network destination exists
  in the code.
- **Never writes** the token anywhere — not to disk, logs, or preferences. The
  network layer uses an *ephemeral* `NSURLSession` with caching disabled,
  because the default shared session persists request headers (including the
  bearer token) to a plaintext cache in `~/Library/Caches/`.
- **Stores** only one thing locally: a boolean preference for whether the
  floating meter is visible.

Build hardening: the binary is compiled with the **hardened runtime** enabled
(`codesign --options runtime`), which blocks other processes from attaching a
debugger and reading the token out of memory.

Trust model: the app is distributed as source, so anyone with write access to
this repository could change what it does. Read the code before you build it —
it is one file, and this section describes all of it.

## Sharing with colleagues

Each person needs their own Claude subscription and the Claude Code CLI signed
in — the app reads each user's own token from their own Keychain. Nothing of
yours is shared.

**Easiest: share the source (GitHub repo) and let them build it themselves.**

```
git clone <repo-url>
cd claude-status-tool
./build.sh
open "Claude Meter.app"
```

Building locally means macOS never quarantines the app — no Gatekeeper
warnings. They need the Xcode Command Line Tools (`xcode-select --install`).

**Alternative: send them the zip** (`./dist.sh` creates `ClaudeMeter-1.0.zip`).
Because the app isn't notarized, macOS will block it on first open. The
recipient must either:

- open it once, then go to **System Settings → Privacy & Security → "Open
  Anyway"**, or
- run `xattr -dr com.apple.quarantine "Claude Meter.app"` after unzipping.

On first launch, everyone gets a Keychain prompt asking to allow access to
"Claude Code-credentials" — click **Always Allow**.

Public distribution (beyond colleagues) would additionally need an Apple
Developer ID + notarization (see `dist.sh`), and a rename/re-icon since
"Claude" is Anthropic's trademark.

## Files

- `ClaudeMeter.m` — the whole app (Objective-C, AppKit, no dependencies)
- `Info.plist` — bundle metadata (`LSUIElement` keeps it out of the Dock)
- `build.sh` — compiles with `clang` and assembles `Claude Meter.app`
