# pnow

Post now. A tiny macOS menu bar app that posts to [dev-null.sh](https://dev-null.sh) from anywhere. X and LinkedIn come later.

```sh
brew install --cask tarasyarema/tap/pnow
```

Needs macOS 26 or later, and an SSH key that is on your GitHub account (dev-null.sh has no login: pnow signs each post with that key).

## Use

| Key | Action |
| --- | --- |
| `⌃⌘P` | Open or close the composer, from any app (change it in Settings) |
| `⌘↩` | Post |
| `⌘V` | Attach the image in your clipboard (up to 3). Dropping image files works too |
| `⌘R` | Reply to your last post |
| `↓` | Go into Recent. There: `↑` `↓` move, `↩` opens, `R` replies, `esc` goes back |
| `⌘/` | Search all your posts |
| `⌘1` to `⌘5` | Open a row |
| `⌥⌘1` to `⌥⌘5` | Reply to a row |
| `⌘⇧R` | Reply to the dev-null.sh post link in your clipboard |
| `⌘,` | Settings: hotkey, launch at login, composer at launch |
| `esc` | Close the search, cancel the reply, then close |

Replies show with `↳` in Recent.

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
scripts/dev.sh   # build, then run it in place of any installed pnow
```

The local build shows as "pnow dev", never updates itself, and uses the same history. Only one pnow runs at a time: opening the installed copy (from Raycast, say) while the local build runs brings up the local composer. Quit it and open `/Applications/pnow.app` to go back.

## Release

```sh
scripts/release.sh patch --dry-run   # build, sign, notarize, staple: publish nothing
scripts/release.sh patch             # or minor, major, 1.2.3: also tag, GitHub release, appcast, and cask bump
```

Needs the "Developer ID Application" certificate in your keychain, a `pnow-notary` notarytool profile, and the Sparkle EdDSA key in your login keychain (`.build/artifacts/sparkle/Sparkle/bin/generate_keys`). Back that key up: without it, installed copies can't update.

Installed copies update themselves with [Sparkle](https://sparkle-project.org): it checks `appcast.xml` on the latest GitHub release once a day. The menu shows the version, "Check for Updates…", and the GitHub link.

## TODO

- [ ] App icon
- [ ] Release from GitHub Actions
- [ ] X
- [ ] LinkedIn
