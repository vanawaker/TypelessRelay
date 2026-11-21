# TypelessRelay

**English** | [简体中文](README_CN.md)

> Instant, zero-config LAN voice-paste relay for using **Typeless** inside macOS **Screen Sharing** — no stray `v`, no manual copy-paste popup.

**TypelessRelay** is a tiny, single-file native Swift menu-bar utility (Universal Binary for Apple Silicon & Intel, auto-localized in English & Simplified Chinese) for dual-Mac workflows where your microphone and **Typeless** run on your main Mac while you control a second Mac through macOS **Screen Sharing** (or Luna Display / Apple Remote Desktop / UURemote).

---

## The Problem

When you dictate with **Typeless** (`Fn`) on your main Mac while focused inside a **Screen Sharing** window controlling a second Mac, two things break simultaneously:

1. **Only a lone lowercase `v` gets typed into the remote input box**
   - Under the hood, Typeless inserts dictated text by placing it on the host Mac's pasteboard (tagged with `org.nspasteboard.TransientType`), posting a synthetic `v` key event with the `kCGEventFlagMaskCommand` flag set (without sending separate hardware `Command` keyDown/keyUp events), and restoring the pasteboard 500 ms later.
   - macOS Screen Sharing (`RFBEventHelperd`) tracks modifier state from actual modifier key events, strips the synthetic Command flag, and forwards a bare `v` to the remote Mac — while the remote Mac never receives the clipboard text in time.
2. **Typeless pops up its bottom copy card on every sentence**
   - To the host Mac's Accessibility API, a Screen Sharing window is an opaque video canvas (`is_editable == false`). Typeless's built-in `app_whitelist` already whitelists Windows remote desktop viewers (`RDCMan.exe`, `mRemoteNG.exe`), but omits macOS's `com.apple.ScreenSharing`.

---

## How TypelessRelay Solves It

Install the same lightweight `TypelessRelay.app` on both Macs on the same LAN:

- **Zero-config LAN peer discovery**: Physical-interface-bound UDP subnet broadcast (`IP_BOUND_IF`, port `52972`, immune to proxy/VPN TUN default routes and multi-NIC Ethernet + Wi-Fi setups) plus unicast keepalive automatically pairs both Macs within milliseconds.
- **One-click role switching in the menu bar**: Pick **Act as Receiver** or **Send to → `<Mac Name>`** from either Mac's menu bar — choosing a target automatically switches the peer into Receiver mode.
- **Sender side (Main Mac with Typeless + Mic)**:
  - Activates **only** when a remote viewer (`com.apple.ScreenSharing`, etc.) is frontmost — 100% transparent in local apps.
  - Installs an active `CGEventTap` at the tail of `kCGHIDEventTap` (upstream of Screen Sharing's `RFBEventHelperd` on `kCGSessionEventTap`).
  - Identifies Typeless's synthetic paste event by kernel `eventSourceUnixProcessID`, swallows the stray `v` before it ever reaches Screen Sharing, and streams both plain text and rich HTML over LAN TCP (port `52971`, `<40 ms`).
  - Automatically adds remote-viewer bundle IDs (`com.apple.ScreenSharing`, etc.) to Typeless's `app_whitelist` in `~/Library/Application Support/Typeless/app-storage.json` (backing up `.bak` first) so the bottom copy card never triggers inside Screen Sharing while still working normally on your local desktop.
- **Receiver side (Remote Mac)**:
  - Archives the remote Mac's current clipboard, writes the relayed text, fires a clean 4-step native `Cmd-down → V-down → V-up → Cmd-up` sequence (leaving zero stuck modifier states), and restores the original clipboard 380 ms later.

---

## Build & Install

Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/vanawaker/TypelessRelay.git
cd TypelessRelay

# 1. Build Universal Binary (arm64 + x86_64) into build/TypelessRelay.app
./scripts/build.sh

# 2. Install & launch on this Mac
./scripts/install_local.sh

# 3. Optional: Deploy & launch on your other Mac over SSH
./scripts/deploy_remote.sh user@other-mac.local
```

> **Tip for personal workflows**: Create a gitignored `.env.local` in the project root with `TYPELESSRELAY_REMOTE="user@your-other-mac"` so you can run `./scripts/deploy_remote.sh` with no arguments.

### Stable Code Signing (Optional)

By default, builds are ad-hoc signed (`-`). Re-compiling an ad-hoc binary changes its `cdhash`, which resets macOS Accessibility permission (the install scripts automatically run `tccutil reset Accessibility` so the re-grant prompt stays clean). To keep your Accessibility grant across rebuilds, create a self-signed Code Signing certificate in Keychain Access and set:

```bash
export TYPELESSRELAY_SIGN_IDENTITY="Your Code Signing Cert"
./scripts/build.sh
./scripts/install_local.sh
```

---

## Permissions & First-Time Setup

1. Launch **TypelessRelay** on both Macs.
2. Grant **Accessibility** permission on both Macs (**System Settings → Privacy & Security → Accessibility → enable `TypelessRelay`**). The menu-bar icon updates automatically without restarting:
   - `Waveform !` — Accessibility permission needed
   - `Waveform ↗` — Sender ready & paired
   - `Waveform ↙` — Receiver ready
3. Click the menu-bar icon on your main Mac and verify **Send to → `<Your Remote Mac>`** is selected (and optionally enable **Start at Login** on both Macs).

> **Standalone whitelist helper**: `TypelessRelay` automatically maintains the Typeless remote-viewer whitelist while running in Sender mode. If you ever log out/re-install Typeless and want to patch it manually, run `./scripts/patch_typeless_whitelist.py` on the main Mac.

---

## Companion Project

If you also run into macOS Sequoia's endless *"Allow ScreensharingAgent to enable third-party input method"* dialog when switching IMEs over Screen Sharing, check out **[CapsRelay](https://github.com/vanawaker/CapsRelay)** — the sibling zero-config menu-bar tool for local Caps Lock IME switching.

---

## Note

Built for my own dual-Mac Screen Sharing setup and shared as-is in case it saves someone else from the same rabbit hole. Note that it relies on Typeless's current pasteboard/whitelist internals, which may change if Typeless natively fixes Screen Sharing dictation in a future release.

## License

[MIT](LICENSE)
