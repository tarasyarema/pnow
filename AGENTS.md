# pnow

pnow ("post now") is a tiny macOS menu bar app. A global hotkey opens a glass composer that posts to [dev-null.sh](https://dev-null.sh), X, or both. LinkedIn comes later. It ships as a signed, notarized Homebrew cask (`brew install --cask tarasyarema/tap/pnow`) and updates itself with Sparkle.

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
| `Sources/pnow/X.swift` | The X client: PKCE login, tokens in the keychain, image upload, posts, link parsing, the 280 counter |
| `Sources/pnow/SSH.swift` | Key discovery (agents incl. `IdentityAgent` from `ssh -G`, `~/.ssh/*.pub`) and `ssh-keygen -Y sign` |
| `Sources/pnow/Attachments.swift` | Clipboard and file images, converted to PNG/JPEG up to 10 MB |
| `Sources/pnow/History.swift` | Local history in `~/Library/Application Support/pnow/history.json`. Nothing is fetched |
| `Sources/pnow/Settings.swift` | Preferences (hotkey, launch at login, composer at launch) and the settings view |
| `Sources/pnow/HotKey.swift` | Carbon `RegisterEventHotKey`: no Accessibility permission needed |
| `packaging/Info.plist` | Bundle template (`__VERSION__` is replaced). Bundle id `com.tarasyarema.pnow` |
| `packaging/pnow.rb` | Cask template (`__VERSION__`, `__SHA256__`) |
| `packaging/AppIcon.svg` | App icon source (pixel-art paper plane). `scripts/make-icon.sh` regenerates `AppIcon.icns` and the README `AppIcon.png` |
| `scripts/dev.sh`, `scripts/build-app.sh`, `scripts/release.sh` | Run locally, build, release |

## dev-null.sh protocol

There is no login. pnow signs each post with a local SSH key that is on the user's GitHub account:

1. POST the candidate public keys (`<type> <base64>` per line) to `/api/cli/key-lookups`. The first line of the answer is the key to use. Only ever sign with a key from the candidates.
2. Sign `<unix time>\n<nonce>\n<reply to>\n<message>` with `ssh-keygen -Y sign -n devnull-commit`. With images, a line of comma-separated SHA-256 hashes goes before the message, and the namespace is `devnull-commit-images`.
3. POST to `/api/cli/commits` with the header `X-SSH-Signature`: the raw payload as `text/plain`, or a multipart form with `payload` and `images[]` (up to 3, 10 MB each). Redirects are refused.

The answer is plain text with the post link, for example `Committed: https://dev-null.sh/@user/commits/<id> (pending review, ...)`. `<reply to>` is that link.

## X

pnow posts through the official X API v2. Each user brings their own X developer app ([docs/x-setup.md](docs/x-setup.md)), and the repo ships no client ID. The client ID is in `~/.config/pnow/config.json` (`{"x": {"clientID": "..."}}`), set from Settings or by hand. Taras's app, "pnow", is in his personal X developer account (not desplegalabs, which runs Agent Swarm).

- Pay per use: X bills the app owner, $0.015 a post and $0.20 a post with a link. With your own app, you pay only for your own posts, and a fork cannot spend anyone else's credits.
- X's restricted-use policy says that requiring end users to register their own apps "could result in enforcement". Taras chose this anyway (2026-10-20). Do not ship a shared client ID without asking him.
- Login: OAuth 2.0 with PKCE as a public "Native App" client (no secret), in `ASWebAuthenticationSession`, with the callback `pnow://oauth/x`. Taras's app also has `http://127.0.0.1:52817/oauth/x`, unused for now. Scopes: `tweet.read tweet.write users.read media.write offline.access`. A new client ID logs you out.
- Tokens: in the login keychain (service `com.tarasyarema.pnow`, account `x-tokens`). Access tokens last 2 hours. Each refresh also replaces the refresh token. The handle is in UserDefaults (`xUsername`).
- Images: `POST /2/media/upload` (multipart, `media_category=tweet_image`), up to 5 MB, so bigger ones become a smaller JPEG. Then `POST /2/tweets` with `media.media_ids` and `reply.in_reply_to_tweet_id`.
- Replies: the API takes a reply only in your own thread, or when the author mentions you. Replies to other people's X posts open `https://x.com/intent/tweet?text=...&in_reply_to=<id>` in the browser instead, and images go on the clipboard.
- ⇥ and ⌘T cycle the destination: dev-null.sh, X, both. A reply goes only where its post is. When one of two places fails, the text stays, set to go only to the failed one.

## Development

```sh
scripts/dev.sh        # build, quit any running pnow, run build/pnow.app
swift build           # fast compile check
```

- The local build is the pnow Taras runs while developing. It shows as "pnow dev", has no Sparkle feed (it never updates itself), and shares the history file.
- Only one pnow runs at a time. A second launch (Raycast opens `/Applications/pnow.app`) hands its request to the running one and quits. The running one also force-quits older copies without the hand-off. Go back to the brew copy: quit pnow, then `open /Applications/pnow.app`.
- The `x86_64 architecture is deprecated` warning from the universal build is expected.
- Local builds are signed with the Developer ID when it is in the keychain (no notarization). The keychain then treats them and the brew copy as the same app, so the X login works in both without a password prompt.

<important if="you are testing or verifying a change to pnow">

- NEVER post to dev-null.sh or X to test. Posts are public and signed as Taras, and each X post costs money. Taras makes every real post, including the first test of a new posting path. Do not call the X API with his tokens either.
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
- Your X client ID must never reach git. The release refuses to run when it finds the ID from `~/.config/pnow/config.json` in a tracked file or in the history. A local pre-commit hook (`.git/hooks/pre-commit`, not in git) also blocks a commit that adds it.
- Releases happen from this Mac, not CI. CI would need the Developer ID `.p12`, a notary key, a tap token, and the Sparkle key as secrets.
</important>
