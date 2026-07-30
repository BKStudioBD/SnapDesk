# SnapDesk

One lightweight, fully native macOS menu-bar app that puts your whole capture workflow in the menu bar — **screenshots + annotation, on-device OCR, a color picker, clipboard history, and screen recording with a trim timeline** — with nothing else to install. Pure Swift on Apple frameworks, no external dependencies, tiny binary, low memory, and **100% on-device:** every capture, OCR and caption is computed locally. The only network call in the whole app is an **opt-in** update check against GitHub Releases — off unless you turn it on, and it sends nothing.

Everything runs from a crisp menu-bar icon. No Dock icon, no main window.

## Features at a glance

| Shortcut | Feature | What it does |
|---|---|---|
| ⌃1 | 📸 **Capture & Annotate** | Select a region (or click a window to snap), annotate in place, copy/save/pin |
| ⌃2 | 🔤 **Grab Text (OCR)** | Drag over any text on screen → recognized on-device and copied instantly |
| ⌃3 | 🎨 **Pick a Color** | Magnified eyedropper → copies the hex, and keeps the last 16 picks |
| ⌃4 | 📋 **Clipboard History** | Searchable history of copied text & images — pin, filter, paste back |
| ⌃5 | 🎥 **Record Screen** | Region or full-screen video with audio, captions, effects and privacy blur |
| ⌃6 | 📜 **Scrolling Capture** | Scroll through a long page → stitched into one tall image |
| ⌃7 | 🔁 **Grab Text Again** | Re-reads the last OCR area with no drag — perfect for a value that keeps changing |
| ⌃8 | 🗂 **Text Stack** | Collect several grabs into one clipboard payload; press again to stop |

Every shortcut is rebindable live in **Settings → Shortcuts** (click, press a new combo — conflicts are flagged, changes apply instantly, no relaunch).

## Feature details

### 📸 Capture & Annotate (⌃1)
- Press ⌃1 → the whole screen dims instantly. Drag a region — a **magnifier loupe** follows the cursor for pixel-perfect edges and a live **W × H label** shows the size — **or just click any window** to snap to it exactly (hovering shows an outline hint). **F** selects the entire screen. **Esc** cancels.
- The shot opens in an **in-place editor** right where you captured, with 10 tools on a floating bar:

  | Key | Tool | Key | Tool |
  |---|---|---|---|
  | **A** | Arrow | **H** | Highlighter (marker) |
  | **L** | Line | **B** | Blur — pixelates the area (hide secrets) |
  | **R** | Rectangle | **N** | Numbered steps (1, 2, 3… auto-increment) |
  | **O** | Ellipse | **T** | Text (click, type, styled) |
  | **P** | Freehand pen | **S** | Spotlight — dims everything except the area |

- Color swatches + stroke-width slider on the bar; the selection itself stays **resizable by its handles** while editing.
- **⌘C / ↵** copy · **⌘S** save (PNG or JPEG with quality slider) · **⌘Z** undo · **⌘⇧T** grab the text out of the shot · **⌘⇧R** repeat the last annotation's tool/colour/width · **Esc** close.
- **📌 Pin** — floats the capture as an always-on-top reference window (multiple pins allowed, drag anywhere, close individually).
- **Auto-save** every capture to a folder of your choice, or copy-only — your call in Settings → Screenshot. Default tool and default color are configurable.
- Multi-display aware; optional **capture delay** (1–5 s) for Capture & Annotate; SnapDesk's two feedback **sounds** (in / out) or silence.

### 🔤 Grab Text — OCR (⌃2)
- Drag over anything with text — app UIs, images, videos, PDFs — Apple **Live Text** and **Vision** recognize it entirely on-device and copy it.
- **Two engines.** *Automatic* reads with macOS Live Text first, which follows columns and wrapped paragraphs in the right order, and falls back to the detailed word-by-word pass whenever it finds nothing. *Detailed* always uses the detailed pass — small text, thin strips and busy regions get an upscale, a bigger retry, then overlapping tiles before SnapDesk ever says "no text found".
- **Recognition language** picker — Automatic (the default) or any language *this* macOS can actually recognize; the list is asked of the system, not hardcoded.
- **Copy style:** *Inline* (everything on a single line) or *Outline* (keeps line breaks), with an optional **blank line between paragraphs** — measured from the real line gaps, so a tight list never gets split.
- **Custom words** — names, jargon and identifiers the recognizer would otherwise autocorrect into something else.
- **Grab again (⌃7)** re-reads the last area with no drag. **Text stack (⌃8, or the switch in Settings → OCR)** collects several grabs into one clipboard payload — it always starts off after a launch, and while it's on the menu bar shows a count beside the icon. Both live in **Settings → OCR**, not in the menu.
- **Grab text from a screenshot** — inside the editor, ⌘⇧T reads the text out of the shot you just took.
- **Code mode** turns the language model off, so `getUserById()` and `--no-cache` come back intact. **Table mode** tab-separates real columns so a grid pastes into a spreadsheet as cells — it only fires on a genuine table, never on prose.
- Options: trim surrounding whitespace, notification confirming the copy.

### 🎨 Color Picker (⌃3)
- System magnified eyedropper loupe over every pixel on screen; the hex is copied the moment you click.
- **Recent colors** — the last 16 picks live in Settings → Color; click any swatch to copy it again.

### 📋 Clipboard History (⌃4)
- Solid card list with **All / Text / Images / Pinned** filters and live search.
- **One click on an item pastes it straight into the app you were using** — text or image alike, and the list keeps its order so the row you just used stays put. **Double-click copies only** and moves that item to the top as the newest copy, with the window staying open so you can collect several in a row. Star to pin favorites to the top.
- **Copy as** — right-click any item: strip line breaks, trim lines, case changes, slug, URL-decode, pretty-print JSON. The stored history entry is never rewritten; only what you paste this once.
- **Fully keyboard driven:** ↑ ↓ to move, ↵ to paste, **⌘1–⌘9** to paste that numbered row directly, ⌘⌫ to delete — just type to filter.
- History size 20–500 items, store-images toggle, clear-all, optional clear-on-quit.
- **Privacy built in:** anything a password manager marks concealed/transient **never enters the history** — your passwords are never stored.

### 🎥 Screen Recording (⌃5)
- Drag a region, press **F** for full screen, or menu → **Record Full Screen…** (records the display your mouse is on).
- A **pre-record options bar** appears on the selection — toggle everything without opening Settings:
  - 🔊 **System audio** — record what the Mac plays
  - 🎙 **Microphone** — your voice, with input-device picker and **Apple noise cancellation** (voice processing: room noise, keyboard clatter and echo suppressed, level evened out — all on-device)
  - 📷 **Webcam bubble** — camera overlay; pick the corner, the size and whether you're mirrored. The live preview always matches what lands in the video
  - 💬 **Auto captions** — your speech transcribed **on-device** (English / Spanish / German) and **burned into the video itself** — one file, nothing separate
  - 🔒 **Privacy blur** — drag boxes over the selection; those areas stay pixelated for the entire video (double-click a box to remove)
- **Presets** — Tutorial / Meeting / Silent demo set frame rate, audio, camera, captions and effects in one click.
- Optional **3/5-second countdown** (Esc cancels), or start instantly.
- While recording: floating control bar with live timer — **pause/resume** (paused time is *cut* from the video, no gap), stop, or ✕ cancel-discard. The menu-bar icon shows the elapsed time too. **SnapDesk's own windows never appear in the recording.**
- **Effects burned into the video:** 2× cursor boost, click highlight rings, keystroke overlay (shows what you type, presenter-style).
- Video: **30 or 60 fps**, **H.264** (plays everywhere) or **HEVC** (smaller), three quality presets, show/hide cursor. Keyframes are capped at 2 s apart so seeking stays predictable whatever the codec does, B-frames keep files lean, and SnapDesk tells you if the encoder dropped a meaningful share of frames.
- **Never loses a recording:** disk full mid-take stops cleanly and keeps what was written, and a pause/resume can't desync or fail the writer.
- Quitting the app mid-recording finishes and saves the file safely — a recording is never corrupted.
- Afterwards: **preview window with trim** — drag a range on the timeline, Cut Selection (mid-video cuts included), Undo, Export, then Reveal / Delete / Done. Videos save to any folder you choose.

### 📜 Scrolling Capture (⌃6)
- Select the area (a chat, a web page, a document), then scroll slowly — a counter shows captured frames.
- SnapDesk stitches the frames into **one tall seamless image**, copies it and saves it.


### 🧰 Everything else
- **Welcome & Setup window** — first-run tour + permission checklist.
- **Settings dashboard** — grouped sidebar (General / Shortcuts / Capture: Screenshot·Recording·OCR·Color / Data: Clipboard / About: Help·About), every feature fully configurable.
- **Built-in Help** — all shortcuts and per-feature guides inside the app.
- **Launch at login**; two custom feedback sounds — a rising pair when content comes IN (capture, copy, save), its falling mirror when it goes OUT (paste) — each with a test button, or silent mode.
- **Single-instance guard** — launching a second copy just focuses the first.
- Everything is **instant** — no animations anywhere, first click always lands.

## Install

### Requirements
- Any Mac — **Apple Silicon or Intel** (universal binary)
- **macOS 14.0 (Sonoma)** or later

### One-command install (easiest — no Gatekeeper warning)

Paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/BKStudioBD/SnapDesk/main/install.sh | bash
```

It downloads the latest release, installs SnapDesk into `/Applications`, clears the quarantine flag so macOS opens it with **no "unidentified developer" warning**, and launches it. No drag, no right-click. (Clearing quarantine on your own machine for an app you chose to install is exactly what right-click → Open does — the script just automates it; it does not weaken Gatekeeper system-wide.)

### Manual install (download the ZIP)

1. Download **SnapDesk.zip** from the [latest release](https://github.com/BKStudioBD/SnapDesk/releases/latest).
2. Double-click the ZIP (Safari unzips automatically) and **move SnapDesk to Applications**.
3. First launch: **right-click → Open** once (the app is self-signed, so macOS shows an "unidentified developer" prompt the first time).

### Build from source (one command)

```bash
git clone https://github.com/BKStudioBD/SnapDesk.git
cd SnapDesk
./build.sh
```

`./build.sh` compiles, signs and installs the app (`--zip` adds a release archive). `./test.sh` type-checks every source file in seconds. (Needs Xcode command-line tools: `xcode-select --install`.)

### Granting Screen Recording (important)

Screenshots and OCR need macOS **Screen Recording** permission. On first use SnapDesk opens the right Settings pane — **turn SnapDesk ON and it restarts itself automatically**; you don't need to quit or reopen anything.

> **The grant sticks.** SnapDesk is signed with a stable certificate and installs itself to `/Applications` on first run, so the Screen Recording permission you give it **persists across launches and updates** — you grant it once.
>
> **Why macOS may still re-ask occasionally:** on macOS Sequoia (15) and Tahoe (26), Apple re-confirms Screen Recording for **every** app periodically (roughly monthly, and after some reboots/updates) — this hits notarized App Store apps too, and there's no way for any app to disable it (only a managed/MDM Mac can). So if it asks again once in a while, that's Apple's prompt, not a lost grant: just toggle SnapDesk **ON** and it restarts. Notarization removes the *first-launch* "unidentified developer" warning but does **not** remove this periodic prompt.
>
> Microphone / Speech permissions are only requested if you turn on those recording options.

> **Gatekeeper note:** a locally-built app opens with no warning. If you distribute the app to another Mac without Apple notarization, first launch needs right-click → **Open** (or `xattr -dr com.apple.quarantine /Applications/SnapDesk.app`). For zero-warning distribution, sign with a Developer ID and notarize:
> ```bash
> DEV_ID="Developer ID Application: Your Name (TEAMID)" \
> NOTARY_PROFILE="your-notary-profile" ./build.sh
> ```

### Mac App Store variant

```bash
./build.sh --mas
```

Builds with **App Sandbox ON** (`SnapDesk-MAS.entitlements`).

## Architecture

```
App/         Entry point, AppDelegate, AppCoordinator (wires everything, builds the menu)
Capture/     RegionSelector (dimmed drag overlay) + CaptureService (capture full display, crop)
Features/
  Screenshot/  Annotation editor, pin windows, scrolling capture
  Recording/   ScreenCaptureKit recorder, pre-record bar, caption burner, effects
  OCR/         Vision text recognition
  Clipboard/   Pasteboard monitor, model, SwiftUI history window
  ColorPicker/ NSColorSampler + color formatting
Hotkeys/     Carbon global hotkey registration (no Accessibility permission needed)
Settings/    Preferences store + SwiftUI settings dashboard
Support/     Permissions, paster, notifier, sounds, diagnostics
```

## Testing

```bash
./test.sh        # full swiftc -typecheck over every source file (seconds)
./test-tools.sh  # headless render test of every annotation tool → PNGs
```

`./test.sh` type-checks every source **and runs the unit suite**: `swift test` — Swift Testing, **182 tests in 26 suites, about a second**. It needs no microphone, no screen recording and no permission of any kind, and it never writes to the real pasteboard.

What it pins down, chosen so every bug that actually shipped stays fixed:

| Suite | Locks |
|---|---|
| Clipboard classification / preview | links vs prose, `#`-required hex, bounded previews |
| Pasteboard text | trailing-newline trim (a paste lands where the caret is), byte-accurate size cap |
| Persist snapshot | clear-on-quit writes **no** unpinned plaintext, pinned survive the cap, aggregate byte budget |
| Hex | parse/format round-trip, malformed input refused, channel order not reversed |
| Hotkeys | glyph order, menu equivalents, JSON round-trip, Shift-only combos refused |
| OCR escalation | wide thin strips (over 40:1), tiny text, 1× captures, blank frames read empty, reading order |
| OCR layout | table → TSV on a real grid, **prose never turned into tabs**, code mode keeps identifiers |
| Text transforms | strip/trim/case/slug/URL-decode/JSON, and only offering ones that change something |
| Mic capture | PCM → CMSampleBuffer: host-clock PTS, attached bytes, CBR size, 48 kHz mono |
| Audio mixer | mic + system summed into ONE track, a late or gappy source never shifts the other, 44.1 kHz resampled onto the 48 kHz timeline, the limiter saturates instead of clipping flat |
| Audio level meter | RMS over the whole window (a quiet run can't be hidden by the buffer that closed it), dB scale, held peak decays, a clip stays reported for about a second |
| Clipboard image store | with clear-on-quit ON no unpinned image byte reaches disk, pinned written first, per-item and aggregate caps, files owner-only |
| Merge | oldest-first — the order things were actually copied — trailing newlines dropped and inner ones kept, an image row skipped instead of failing the merge |
| Selection | Command-click toggles, Shift-click reaches from the anchor either way, rows that vanished are pruned along with a stale anchor |
| Snippets | written through on every change and read back next launch, corrupt storage reads as none rather than blocking a launch, reorder clamped at both ends, oldest dropped at the byte budget |
| Crop box | a handle dragged outside clamps to the image, an edge stops at its opposite instead of flipping, eight handles with hit slop |
| Image transform | a quarter turn swaps the dimensions and rotate-left undoes rotate-right pixel for pixel, colour space and 2× scale survive, the crop rect is measured from the TOP |
| Selection geometry | arrow move / Option-arrow resize can't invert or leave the screen, the size chip is never clipped or under the crosshair, the view↔top-left flip uses each rect's OWN screen height |
| Wallpaper fill | every macOS fill mode reproduced or explicitly declined, an unsized image falls back to the screen, and the buffer is read as BGRA so red doesn't come back blue |
| Updater | numeric semver (1.10.0 > 1.9.0), equal versions refused, repository pinned |

Then a one-minute manual smoke test: try each hotkey (⌃1–⌃8), copy a password (must NOT appear in clipboard history), and toggle Launch at login.

## Install

**Homebrew** (a tap in this repo — no separate formula repo needed):

```bash
brew tap bkstudiobd/snapdesk https://github.com/BKStudioBD/SnapDesk
brew install --cask snapdesk
```

**Direct** — grab `SnapDesk.zip` from [Releases](https://github.com/BKStudioBD/SnapDesk/releases), unzip, drag to Applications.

**Updates** — Settings → General → *Check for updates on launch* (off by default), or menu bar → **Check for Updates…**. SnapDesk reads the public GitHub releases list, asks before downloading, and installs a build only if it's signed by the same identity as the copy you're running.

## Releasing

Tag it and CI does the rest — build, test, sign, notarize, staple, publish:

```bash
git tag -a v1.2.0 -m "What changed in this release"
git push origin v1.2.0
```

`.github/workflows/release.yml` runs `./test.sh` then `./build.sh --no-install --zip` on a macOS runner and uploads `SnapDesk.zip` to the release. The tag's annotation becomes the release notes — which is exactly what the app shows in **What's New** after it updates. Set the signing/notarization secrets listed at the top of that workflow before the first public release; without them the build is ad-hoc signed and the in-app updater will refuse to install it over a Developer-ID copy. Then bump `version` + `sha256` in `Casks/snapdesk.rb`.

## Security & privacy

- **Nothing is uploaded, ever.** OCR, captions and capture are 100% on-device; there is no analytics, no server of ours, no account. The single network call in the app is the **opt-in** update check — an unauthenticated read of the public GitHub releases list, off by default, sending no identifiers.
- **Updates are verified, not trusted.** A download is installed only if it carries a valid signature AND is signed by the same identity as the running copy; anything else is deleted and refused.
- **Secrets are never stored.** Clipboard history ignores concealed/transient pasteboard types, so passwords marked secret by your password manager never enter history.
- **Least privilege.** Screen Recording permission only when first needed; mic/speech only if you enable them. Carbon hotkeys avoid the broad Accessibility grant.
- **Hardened Runtime** enabled when signing — notarization-ready.
- **Destructive actions go to the Trash** — deleting a recording from its preview window is reversible, never an unrecoverable unlink.
- **Diagnostics stay private.** The OCR miss log and its screenshots live in `~/Library/Logs/SnapDesk`, created `0600` and capped at the last few — never in world-readable `/tmp`.

## License

See [LICENSE](LICENSE).
