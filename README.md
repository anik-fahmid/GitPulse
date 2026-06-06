<div align="center">

<img src="icon.png" width="120" alt="GitPulse icon" />

# GitPulse

**A native macOS menu-bar app to triage your GitHub notifications — filtered to just the things that matter.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Release](https://img.shields.io/github/v/release/anik-fahmid/GitPulse)](https://github.com/anik-fahmid/GitPulse/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/anik-fahmid/GitPulse/total)](https://github.com/anik-fahmid/GitPulse/releases)

</div>

GitHub's notification inbox is noisy. GitPulse lives in your menu bar, shows an unread count for **only the notification types and repositories you care about** (mentions, review requests, assignments…), and fires native desktop alerts on a schedule you choose. No Dock clutter, no Electron — a small native SwiftUI app.

> Built to answer one question at a glance: *"Did anyone mention or assign me something I haven't seen?"*

## ✨ Features

**Menu bar, not the Dock**
- Lives entirely in the menu bar with a live unread **badge count**.
- Click the bell → a compact panel of your filtered notifications.
- Never appears in the Dock or app switcher.

**Smart filtering**
- **Notification types** — mention, team mention, review requested, assigned, comments, CI activity, state change, and more. The selected types drive both the badge and the alerts.
- **Repository picker** — load every repo you can access, search, and check exactly the ones to watch (private org repos included).

**Desktop notifications**
- Native banners for new unread items of your selected types.
- Click a banner to open the issue/PR straight on GitHub.
- **Reminder intervals**: Realtime (30 min), 1h, 2h, 4h, 8h, or Daily.
- A **Test notification** button to confirm everything's wired.

**Fast triage**
- **Mark all read** and **per-notification mark as read** — instant, no reappearing.
- **⌘-click** or **double-click** a row to open it on GitHub.

**Private & lightweight**
- Built-in **Sign in with GitHub** (OAuth Device Flow) or a **Personal Access Token**.
- Token is stored in the **encrypted macOS Keychain** (device-only) — never in the app bundle or a plaintext file.

## 📦 Requirements

- macOS **13 (Ventura)** or later — built and tested on macOS 26, Apple Silicon.
- A GitHub account. No external dependencies (no `gh` CLI required).

## 🚀 Install

### Download (recommended)
1. Grab `GitPulse.dmg` from the [latest release](https://github.com/anik-fahmid/GitPulse/releases/latest).
2. Open the DMG, drag **GitPulse** into **Applications**.
3. First launch: the app is ad-hoc signed, so **right-click → Open** once to bypass Gatekeeper.

### Build from source
```bash
git clone https://github.com/anik-fahmid/GitPulse.git
cd GitPulse
./build.sh        # produces GitPulse.app and GitPulse.dmg
```
Requires Xcode command-line tools (`swiftc`).

## 🔐 Authentication

GitPulse talks to the GitHub REST API directly — pick either:

- **Sign in with GitHub** (OAuth Device Flow): click the button, approve the code in your browser.
- **Personal Access Token**: paste a classic token with `notifications` + `repo` scope. **Required for private org repos** when the OAuth app isn't org-approved (e.g. free-plan orgs with third-party app restrictions). [Create one here](https://github.com/settings/tokens/new?scopes=notifications,repo&description=GitPulse).

Your token is stored in the macOS Keychain (encrypted, device-only). For org-private access, prefer a token scoped to only what you need.

## ⌨️ Usage

| Action | How |
| --- | --- |
| Open the panel | Click the menu-bar bell |
| Open Settings | Gear icon → Settings window |
| Open a notification | Double-click or ⌘-click a row, or the ↗ button |
| Mark one read | The ✓ button on a row (or right-click → Mark as read) |
| Mark all read | **Mark all read** button |
| Refresh now | **Fetch** button |
| Quit | **Quit** button or ⌘Q |

## 🧠 How it works

- Polls `GET /notifications` on your chosen interval, filtered locally by type + repo.
- Native notifications via Apple's `UserNotifications` framework.
- Marked-read items are cleared optimistically and suppressed so they never flicker back.
- 100% Swift / SwiftUI. No telemetry, no servers, no third-party SDKs.

## 🛠️ Tech stack

SwiftUI · AppKit · UserNotifications · LocalAuthentication · Security (Keychain) · GitHub REST API.

## 🔒 Privacy

GitPulse makes requests only to `api.github.com` and `github.com` (for sign-in). It stores your token in the macOS Keychain and your filter preferences in `~/.gh-notif-reviewer/config.json`. Nothing else leaves your machine.

## 🤝 Contributing

Issues and PRs welcome. Ideas on the [roadmap](#-roadmap) are a good place to start.

## 🗺️ Roadmap

- [x] In-app update check (notifies when a newer release is available)
- [x] Touch ID lock (optional)
- [ ] Launch at login toggle
- [ ] Notarized & signed builds (no Gatekeeper prompt)
- [ ] Universal binary (Intel + Apple Silicon)
- [ ] Per-repo / per-type sounds
- [ ] Snooze and "remind me later"
- [ ] Homebrew cask

## 📄 License

[MIT](LICENSE) — free to use, modify, and distribute. In plain English: do what you like with it, just keep the copyright notice. No warranty.

## 🙏 Credits

Built by [@anik-fahmid](https://github.com/anik-fahmid). 
