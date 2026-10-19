# pnow

pnow ("post now") is a tiny macOS menu bar app. A global hotkey opens a glass composer that posts to [dev-null.sh](https://dev-null.sh). X and LinkedIn come later. It ships as a signed, notarized Homebrew cask (`brew install --cask tarasyarema/tap/pnow`) and updates itself with Sparkle.

## Stack and layout

- Swift 6 + SwiftUI with a thin AppKit layer. macOS 26+ only. SwiftPM only: there is no Xcode project.
- `Package.swift` sets `defaultIsolation(MainActor.self)`. Code that blocks (the `ssh` tools) lives in `nonisolated` types and runs in `Task.detached`.
- One dependency: Sparkle (SwiftPM binary). `scripts/build-app.sh` copies `Sparkle.framework` into the bundle and signs it from the inside out.

| Path | What |
| --- | --- |
| `Sources/pnow/PnowApp.swift` | App entry, `AppDelegate` (one-instance hand-off, hotkey, Sparkle, `pnow://` URLs, settings window), menu bar menu |
| `Sources/pnow/ComposerPanel.swift` | The floating `NSPanel`: show/hide, centering, list keys (↓ ↑ ↩ R esc), ⌘V image paste |
| `Sources/pnow/ComposerView.swift` | The SwiftUI composer: editor, attachments, Recent/search, action bar |
| `Sources/pnow/AppModel.swift` | State: draft, reply target, search, selection, attachments, posting |
| `Sources/pnow/DevNull.swift` | The dev-null.sh client, a port of `curl -fsSL https://dev-null.sh/commit` |
| `Sources/pnow/SSH.swift` | Key discovery (agents incl. `IdentityAgent` from `ssh -G`, `~/.ssh/*.pub`) and `ssh-keygen -Y sign` |
| `Sources/pnow/Attachments.swift` | Clipboard and file images, converted to PNG/JPEG up to 10 MB |
| `Sources/pnow/History.swift` | Local history in `~/Library/Application Support/pnow/history.json`. Nothing is fetched |
| `Sources/pnow/Settings.swift` | Preferences (hotkey, launch at login, composer at launch) and the settings view |
| `Sources/pnow/HotKey.swift` | Carbon `RegisterEventHotKey`: no Accessibility permission needed |
| `packaging/Info.plist` | Bundle template (`__VERSION__` is replaced). Bundle id `com.tarasyarema.pnow` |
| `packaging/pnow.rb` | Cask template (`__VERSION__`, `__SHA256__`) |
| `scripts/dev.sh`, `scripts/build-app.sh`, `scripts/release.sh` | Run locally, build, release |

## dev-null.sh protocol

There is no login. pnow signs each post with a local SSH key that is on the user's GitHub account:

1. POST the candidate public keys (`<type> <base64>` per line) to `/api/cli/key-lookups`. The first line of the answer is the key to use. Only ever sign with a key from the candidates.
2. Sign `<unix time>\n<nonce>\n<reply to>\n<message>` with `ssh-keygen -Y sign -n devnull-commit`. With images, a line of comma-separated SHA-256 hashes goes before the message, and the namespace is `devnull-commit-images`.
3. POST to `/api/cli/commits` with the header `X-SSH-Signature`: the raw payload as `text/plain`, or a multipart form with `payload` and `images[]` (up to 3, 10 MB each). Redirects are refused.

The answer is plain text with the post link, for example `Committed: https://dev-null.sh/@user/commits/<id> (pending review, ...)`. `<reply to>` is that link.

## Development

```sh
scripts/dev.sh        # build, quit any running pnow, run build/pnow.app
swift build           # fast compile check
```

- The local build is the pnow Taras runs while developing. It shows as "pnow dev", has no Sparkle feed (it never updates itself), and shares the history file.
- Only one pnow runs at a time. A second launch (Raycast opens `/Applications/pnow.app`) hands its request to the running one and quits. The running one also force-quits older copies without the hand-off. Go back to the brew copy: quit pnow, then `open /Applications/pnow.app`.
- The `x86_64 architecture is deprecated` warning from the universal build is expected.

<important if="you are testing or verifying a change to pnow">

- NEVER post to dev-null.sh to test. Posts are public and signed as Taras. Taras makes every real post, including the first test of a new posting path.
- To test signing without posting: compile `Sources/pnow/SSH.swift` with a small `main.swift` (define `PnowError` there), sign a dummy payload, and check it with `ssh-keygen -Y check-novalidate -n devnull-commit -s <sig>`.
- NEVER send synthetic keystrokes or clicks (`osascript ... System Events`, CGEvent) to Taras's Mac. Ask Taras to press keys.
- To look at the UI, capture only the panel region, not the full screen: find the pnow window at layer 3 with `CGWindowListCopyWindowInfo`, then `screencapture -x -R x,y,w,h`. Taras has 3 displays, and the panel opens on the one with the mouse.
- `open build/pnow.app` while pnow runs shows the composer (reopen). So does `open "pnow://new"`.
</important>

## Release

```sh
scripts/release.sh patch --dry-run   # build, sign, notarize, staple, appcast: publish nothing
scripts/release.sh patch             # or minor, major, or 1.2.3
```

A real release:
1. Picks the version from the last `v*` tag.
2. Builds with the Developer ID, notarizes, staples, and checks Gatekeeper.
3. Zips the app and writes `build/appcast.xml`, signed with the Sparkle EdDSA key.
4. Pushes `main`, tags `v<version>`, and creates the GitHub release with the zip and `appcast.xml`.
5. Writes `Casks/pnow.rb` in `../taras-homebrew-tap`, then commits and pushes it.

Installed copies find the update through `https://github.com/tarasyarema/pnow/releases/latest/download/appcast.xml`.

<important if="you are about to release pnow">

- Releasing is public: ask Taras before you run it without `--dry-run`. Commit first: the script refuses a dirty tree, a branch other than `main`, an existing tag, or a dirty tap checkout.
- Run it in the background. Notarization takes a few minutes.
- Requirements, all on Taras's Mac:
  - `Developer ID Application: Taras Yarema (2HUBD5T348)` in the login keychain.
  - The `pnow-notary` notarytool profile.
  - The Sparkle EdDSA private key in the login keychain. Its backup is in Bitwarden as "pnow Sparkle EdDSA private key". Restore it with `.build/artifacts/sparkle/Sparkle/bin/generate_keys -f <file>`. The public key is `SUPublicEDKey` in `packaging/Info.plist`. Never change it, or installed copies stop updating.
  - The tap checkout at `../taras-homebrew-tap` (`tarasyarema/homebrew-tap`), and `gh` logged in.
- Verify after a release:
  - `brew info --cask tarasyarema/tap/pnow` shows the new version.
  - `brew audit --cask --online tarasyarema/tap/pnow` passes.
  - The appcast at the `latest/download` URL shows the new `sparkle:version`.
- Releases happen from this Mac, not CI. CI would need the Developer ID `.p12`, a notary key, a tap token, and the Sparkle key as secrets.
</important>
