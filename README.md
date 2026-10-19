# pnow

Post now. A tiny macOS menu bar app that posts to [dev-null.sh](https://dev-null.sh) from anywhere. X and LinkedIn come later.

```sh
brew install --cask tarasyarema/tap/pnow
```

Needs macOS 26 or later, and an SSH key that is on your GitHub account (dev-null.sh has no login: pnow signs each post with that key).

## Use

| Key | Action |
| --- | --- |
| `⌘⌃P` | Open or close the composer, from any app |
| `⌘↩` | Post |
| `⌘R` | Reply to your last post |
| `↓` | Go into Recent. There: `↑` `↓` move, `↩` opens, `R` replies, `esc` goes back |
| `⌘1` to `⌘5` | Open a recent post |
| `⌥⌘1` to `⌥⌘5` | Reply to a recent post |
| `⌘⇧R` | Reply to the dev-null.sh post link in your clipboard |
| `esc` | Cancel the reply, then close |

To reply to anyone's post, copy its link and press `⌘⇧R`, or paste the link into the empty composer.

Opening the app again (Raycast, Spotlight, Finder) also brings up the composer. So does the URL scheme, for Raycast quicklinks and bookmarklets:

```sh
open "pnow://new"
open "pnow://new?text=Shipped%20it"
open "pnow://reply?to=https://dev-null.sh/@user/commits/<id>"
```

History stays local, in `~/Library/Application Support/pnow/history.json`.

## Develop

```sh
scripts/build-app.sh && open build/pnow.app   # ad-hoc signed dev build
```

## Release

```sh
scripts/release.sh 0.1.0 --dry-run   # build, sign, notarize, staple: publish nothing
scripts/release.sh 0.1.0             # also tag, GitHub release, and bump the cask in tarasyarema/homebrew-tap
```

Needs the "Developer ID Application" certificate in your keychain and a `pnow-notary` notarytool profile.

## TODO

- [ ] Paste and drag-drop images (up to 3, 10 MB each)
- [ ] Hotkey setting (fixed to `⌘⌃P` for now)
- [ ] Launch at login
- [ ] App icon
- [ ] Release from GitHub Actions
- [ ] X
- [ ] LinkedIn
