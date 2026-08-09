# SnapDesk

A native macOS menu-bar app that holds a whole capture workflow: screenshots with annotation, on-device OCR, a color picker, clipboard history, screen recording with a trim timeline, and a cleaner for disk and memory. Pure Swift on Apple frameworks, no external dependencies, small binary, low memory.

Everything is computed locally. The one network call in the app is an update check against GitHub Releases, and it is off unless you turn it on.

There is no Dock icon and no main window. Everything runs from the menu bar.

## Shortcuts

| Shortcut | Feature | What it does |
|---|---|---|
| ⌃1 | Capture & Annotate | Select a region (or click a window to snap), annotate in place, copy/save/pin |
| ⌃2 | Grab Text (OCR) | Drag over any text on screen, recognized on-device and copied instantly |
| ⌃3 | Pick a Color | Magnified eyedropper, copies the color as HEX or RGB |
| ⌃4 | Clipboard History | Searchable history of copied text and images: pin, filter, paste back |
| ⌃5 | Record Screen | Region or full-screen video with audio, captions, effects and privacy blur |
| ⌃6 | Scrolling Capture | Scroll through a long page, stitched into one tall image |
| ⌃7 | Grab Text Again | Re-reads the last OCR area with no drag, for a value that keeps changing |
| ⌃8 | Text Stack | Collect several grabs into one clipboard payload; press again to stop |

Every shortcut is rebindable in Settings → Shortcuts. Click a row, press a new combo. Conflicts are flagged, and changes apply instantly without a relaunch.

## Features

### Capture & Annotate (⌃1)

Press ⌃1 and the whole screen dims. Drag a region with a magnifier loupe following the cursor for pixel-perfect edges and a live W × H label, or click any window to snap to it exactly (hovering shows an outline hint). F selects the entire screen, Esc cancels.

The shot opens in an editor right where you captured it, with ten tools on a floating bar:

| Key | Tool | Key | Tool |
|---|---|---|---|
| A | Arrow | H | Highlighter (marker) |
| L | Line | B | Blur, pixelates the area to hide secrets |
| R | Rectangle | N | Numbered steps (1, 2, 3… auto-increment) |
| O | Ellipse | T | Text (click, type, styled) |
| P | Freehand pen | S | Spotlight, dims everything except the area |

Color swatches and a stroke-width slider sit on the bar, and the selection stays resizable by its handles while you edit.

Keys: ⌘C or ↵ copies, ⌘S saves (PNG or JPEG with a quality slider), ⌘Z undoes, ⌘⇧T grabs the text out of the shot, ⌘⇧R repeats the last annotation's tool, colour and width, and Esc closes.

Pin floats the capture as an always-on-top reference window. Multiple pins are allowed, each draggable and closable on its own.

Auto-save writes every capture to a folder of your choice, or you can stay copy-only. Default tool and default color are configurable in Settings → Screenshot. Capture is multi-display aware, an optional 1 to 5 second delay applies to Capture & Annotate, and the two feedback sounds can be silenced.

### Grab Text, OCR (⌃2)

Drag over anything with text: app interfaces, images, videos, PDFs. Apple's Live Text and Vision recognize it on-device and copy it.

There are two engines. Automatic reads with Live Text first, which follows columns and wrapped paragraphs in the right order, and falls back to the detailed word-by-word pass when Live Text finds nothing. Detailed always uses that pass, where small text, thin strips and busy regions get an upscale, a bigger retry, then overlapping tiles before SnapDesk says "no text found".

The recognition-language picker offers Automatic or any language this Mac can actually recognize, asked of the system rather than hardcoded. Copy style is either Inline (everything on one line) or Outline (keeps line breaks), with an optional blank line between paragraphs measured from the real line gaps, so a tight list never gets split. Custom words cover names, jargon and identifiers the recognizer would otherwise autocorrect.

Grab again (⌃7) re-reads the last area with no drag. Text stack (⌃8, or the switch in Settings → OCR) collects several grabs into one clipboard payload. It always starts off after a launch, and while it is on the menu bar shows a count beside the icon. Both live in Settings → OCR rather than in the menu.

Inside the editor, ⌘⇧T reads the text out of the shot you just took.

Code mode turns the language model off, so `getUserById()` and `--no-cache` come back intact. Table mode tab-separates real columns so a grid pastes into a spreadsheet as cells, and it only fires on a genuine table, never on prose. Trimming surrounding whitespace and a confirmation notification are both options.

### Color Picker (⌃3)

The system magnified eyedropper over every pixel on screen. Copy format is `#RRGGBB` or `rgb(r, g, b)`, with an uppercase-hex toggle. The recent-colors palette in Settings keeps the last 16 picks, and clicking a swatch copies it again. A notification per pick is optional.

### Clipboard History (⌃4)

A solid card list with All / Text / Images / Pinned filters and live search.

One click on an item pastes it straight into the app you were using, text or image alike, and the list keeps its order so the row you just used stays put. Double-click copies only and moves that item to the top as the newest copy, with the window staying open so you can collect several in a row. Star an item to pin it.

Right-click gives Copy as: strip line breaks, trim lines, case changes, slug, URL-decode, pretty-print JSON. The stored entry is never rewritten, only what you paste this once.

The window is fully keyboard driven. ↑ ↓ move, ↵ pastes, ⌘1 through ⌘9 paste that numbered row directly, ⌘⌫ deletes, and typing filters. History size runs from 20 to 500 items, with a store-images toggle, clear-all, and optional clear-on-quit.

Anything a password manager marks concealed or transient never enters the history, so passwords are never stored.

### Screen Recording (⌃5)

Drag a region, press F for full screen, or use menu → Record Full Screen… to record the display your mouse is on.

A pre-record options bar appears on the selection so you can toggle everything without opening Settings:

- System audio records what the Mac plays.
- Microphone records your voice, with an input-device picker and Apple noise cancellation (voice processing suppresses room noise, keyboard clatter and echo, and evens out the level, all on-device).
- Webcam bubble overlays the camera. Pick the corner, the size and whether you are mirrored; the live preview always matches what lands in the video.
- Auto captions transcribe your speech on-device (English, Spanish or German) and burn it into the video itself, so there is one file and nothing separate.
- Privacy blur takes drag boxes over the selection, and those areas stay pixelated for the entire video. Double-click a box to remove it.

Presets for Tutorial, Meeting and Silent demo set frame rate, audio, camera, captions and effects in one click. A 3 or 5 second countdown is optional (Esc cancels), or recording starts instantly.

While recording, a floating control bar shows a live timer with pause/resume (paused time is cut from the video, leaving no gap), stop, and a cancel-discard ✕. The menu-bar icon shows the elapsed time too. SnapDesk's own windows never appear in the recording.

Effects burned into the video: 2× cursor boost, click highlight rings, and a keystroke overlay that shows what you type, presenter-style.

Video is 30 or 60 fps, H.264 (plays everywhere) or HEVC (smaller), with three quality presets and show/hide cursor. Keyframes are capped at 2 seconds apart so seeking stays predictable whatever the codec does, B-frames keep files lean, and SnapDesk tells you if the encoder dropped a meaningful share of frames.

A recording is never lost. Disk full mid-take stops cleanly and keeps what was written, a pause/resume cannot desync or fail the writer, and quitting the app mid-recording finishes and saves the file.

Afterwards a preview window opens with trim: drag a range on the timeline, Cut Selection (mid-video cuts included), Undo, Export, then Reveal, Delete or Done. Videos save to any folder you choose.

### Scrolling Capture (⌃6)

Select the area, a chat or a web page or a document, and a small bar appears with a frame counter, Full Page, and Done.

Press Full Page and SnapDesk does the scrolling: it rewinds to the very top first, then captures straight down to the bottom, so one press grabs the whole page no matter where you were scrolled to. It stops on its own when the area stops changing, and a five-minute limit ends a runaway page by stitching what it has.

Or scroll yourself and press Done, which captures the part you scrolled through. Either way the frames are stitched into one tall image, copied and saved.

### Cleaner (menu bar → Cleaner…)

A two-tab window for getting disk and memory back, built from the same system controls as the rest of the app and following your Mac's light or dark appearance. Nothing is removed without being listed, sized and ticked first, and everything goes to the Trash. The one exception, emptying the Trash itself, is named out loud in the interface.

**Dashboard** shows live processor, memory, disk and network readings with a 0 to 100 health score, and a Free up memory button. The memory pass targets reclaimable pages (inactive, purgeable, speculative) through `vm_allocate`, backs off the instant macOS reports memory pressure, and scales its reserve to the size of the Mac.

**Clean** groups caches into Browsers (Chrome, Safari, Firefox, Arc), Apps (Spotify, Slack, Discord) and System (everything else in `~/Library/Caches`, temp, logs, Trash). Developer tooling is left alone: Xcode, SwiftPM, Homebrew, npm and pip caches are neither offered nor swept up by the catch-all row. Tick a whole group from its header or the lot from Select all, and the button says exactly how much it will free. Anything written in the last ten minutes is skipped, because `unlink` succeeds on a file another app still has open, and a cache deleted mid-write is a corrupted app rather than a cleaned one.

### Everything else

- A first-run Welcome & Setup window with a tour and a permission checklist, reopenable from Settings → General → Setup.
- A menu bar you can read at a glance: the six capture actions, then the Cleaner and Settings. Shortcuts, the update check and the setup window all live inside Settings rather than crowding the menu.
- A grouped Settings sidebar (General / Shortcuts / Capture: Screenshot, Recording, OCR, Color Picker / Data: Clipboard / About: Help, About) where every feature is configurable.
- Built-in Help with all shortcuts and per-feature guides.
- Launch at login, and two feedback sounds: a rising pair when content comes in (capture, copy, save) and its falling mirror when it goes out (paste). Each has a test button, and silence is an option.
- A single-instance guard, so launching a second copy focuses the first.
- No animations anywhere. The first click always lands.

## Install

### Requirements

- Any Mac, Apple Silicon or Intel (universal binary)
- macOS 14.0 (Sonoma) or later

### One command, no Gatekeeper warning

```bash
curl -fsSL https://raw.githubusercontent.com/BKStudioBD/SnapDesk/main/install.sh | bash
```

It downloads the latest release, installs SnapDesk into `/Applications`, clears the quarantine flag so macOS opens it without the "unidentified developer" warning, and launches it. No drag, no right-click. Clearing quarantine on your own machine for an app you chose to install is what right-click → Open does by hand; the script automates that one step and does not weaken Gatekeeper system-wide.

### Homebrew

The tap lives in this repo, so no separate formula repo is needed:

```bash
brew tap bkstudiobd/snapdesk https://github.com/BKStudioBD/SnapDesk
brew install --cask snapdesk
```

### Manual

1. Download SnapDesk.zip from the [latest release](https://github.com/BKStudioBD/SnapDesk/releases/latest).
2. Double-click the ZIP (Safari unzips automatically) and move SnapDesk to Applications.
3. On first launch, right-click → Open once. The app is self-signed, so macOS shows an "unidentified developer" prompt that first time.

### Build from source

```bash
git clone https://github.com/BKStudioBD/SnapDesk.git
cd SnapDesk
./build.sh
```

`./build.sh` compiles, signs and installs the app, and `--zip` adds a release archive. `./test.sh` type-checks every source file and runs the unit suite. Both need the Xcode command-line tools (`xcode-select --install`).

### Updates

Settings → General → Check for updates on launch (off by default), or menu bar → Check for Updates…. SnapDesk reads the public GitHub releases list, asks before downloading, and installs a build only if it is signed by the same identity as the copy you are running.

### Granting Screen Recording

Screenshots, OCR, recording and scrolling capture need macOS Screen Recording permission. On first use SnapDesk opens the right Settings pane; turn SnapDesk on there.

A permission granted after SnapDesk started is only honoured by a new process, so the app has to be restarted once for it to take effect. SnapDesk will not do that on its own. While capture is unavailable the menu-bar icon carries an orange badge, and the menu says which of the two states you are in and offers the one action that fixes it: **Open Screen Recording Settings…** when the permission is off, **Restart SnapDesk to finish** when it is on but not yet picked up. Pressing one of the five capture shortcuts in that state gives you the same explanation instead of doing nothing.

The grant sticks. SnapDesk is signed with a stable certificate and installs itself to `/Applications` on first run, so the permission you give it persists across launches and updates.

macOS may still re-ask occasionally. On macOS Sequoia (15) and Tahoe (26), Apple re-confirms Screen Recording for every app periodically, roughly monthly and after some reboots or updates. This happens to notarized App Store apps too and no app can disable it, only a managed/MDM Mac can. So an occasional prompt is Apple's, not a lost grant: toggle SnapDesk on and it restarts. Notarization removes the first-launch "unidentified developer" warning, but not this periodic prompt.

Microphone and Speech permissions are only requested if you turn on those recording options.

A locally built app opens with no Gatekeeper warning. If you distribute the app to another Mac without Apple notarization, the first launch needs right-click → Open (or `xattr -dr com.apple.quarantine /Applications/SnapDesk.app`). For zero-warning distribution, sign with a Developer ID and notarize:

```bash
DEV_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="your-notary-profile" ./build.sh
```

### Mac App Store variant

```bash
./build.sh --mas
```

This builds with App Sandbox on, using `SnapDesk-MAS.entitlements`.

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
  Cleaner/     Dashboard and cache-cleaning tabs
Hotkeys/     Carbon global hotkey registration (no Accessibility permission needed)
Settings/    Preferences store + SwiftUI settings dashboard
Support/     Permissions, paster, notifier, sounds, diagnostics
             + the cleaner's engines: system stats, cache catalog, memory pass
```

## Testing

```bash
./test.sh        # swiftc -typecheck over every source file, then the unit suite
./test-tools.sh  # headless render test of every annotation tool, writes PNGs
```

`./test.sh` type-checks every source and runs `swift test`: Swift Testing, 295 tests in 42 suites, about two seconds. It needs no microphone, no screen recording and no permission of any kind, and it never writes to the real pasteboard.

What it pins down, chosen so every bug that actually shipped stays fixed:

| Suite | Locks |
|---|---|
| Clipboard classification / preview | links vs prose, `#`-required hex, bounded previews |
| Pasteboard text | trailing-newline trim (a paste lands where the caret is), byte-accurate size cap |
| Persist snapshot | clear-on-quit writes no unpinned plaintext, pinned survive the cap, aggregate byte budget |
| Hex | parse/format round-trip, malformed input refused, channel order not reversed |
| Colour formats | HEX and rgb() describe the same colour, lowercase honoured, a pattern colour falls back instead of trapping |
| Cleaner safety | a clean offers the CONTENTS and never the directory itself, exclusions hold, a running app's cache is skipped |
| Hotkeys | glyph order, menu equivalents, JSON round-trip, Shift-only combos refused |
| OCR escalation | wide thin strips (over 40:1), tiny text, 1× captures, blank frames read empty, reading order |
| OCR layout | table to TSV on a real grid, prose never turned into tabs, code mode keeps identifiers |
| Text transforms | strip/trim/case/slug/URL-decode/JSON, and only offering ones that change something |
| Mic capture | PCM to CMSampleBuffer: host-clock PTS, attached bytes, CBR size, 48 kHz mono |
| Audio mixer | mic and system summed into one track, a late or gappy source never shifts the other, 44.1 kHz resampled onto the 48 kHz timeline, the limiter saturates instead of clipping flat |
| Audio level meter | RMS over the whole window (a quiet run can't be hidden by the buffer that closed it), dB scale, held peak decays, a clip stays reported for about a second |
| Clipboard image store | with clear-on-quit on, no unpinned image byte reaches disk; pinned written first, per-item and aggregate caps, files owner-only |
| Merge | oldest first, the order things were actually copied; trailing newlines dropped and inner ones kept, an image row skipped instead of failing the merge |
| Selection | Command-click toggles, Shift-click reaches from the anchor either way, rows that vanished are pruned along with a stale anchor |
| Snippets | written through on every change and read back next launch, corrupt storage reads as none rather than blocking a launch, reorder clamped at both ends, oldest dropped at the byte budget |
| Crop box | a handle dragged outside clamps to the image, an edge stops at its opposite instead of flipping, eight handles with hit slop |
| Image transform | a quarter turn swaps the dimensions and rotate-left undoes rotate-right pixel for pixel, colour space and 2× scale survive, the crop rect is measured from the top |
| Selection geometry | arrow move and Option-arrow resize can't invert or leave the screen, the size chip is never clipped or under the crosshair, the view/top-left flip uses each rect's own screen height |
| Wallpaper fill | every macOS fill mode reproduced or explicitly declined, an unsized image falls back to the screen, and the buffer is read as BGRA so red doesn't come back blue |
| Webcam bubble | the bubble lands in the chosen corner at the chosen size, masked to a circle, mirroring flips nothing else, any sensor shape fills the circle, nothing drawn before the first frame |
| Updater | numeric semver (1.10.0 > 1.9.0), equal versions refused, repository pinned |
| System stats | busy vs idle ticks, counters that went backwards read as zero, network as a rate, the health weighting |
| Cache catalog | the Trash is never pre-ticked, the catch-all excludes the folders named categories own, ids stay unique |
| In-use guard | a file written seconds ago, even one nested deep, keeps its whole folder |

Then a one-minute manual smoke test: try each hotkey (⌃1 to ⌃8), copy a password and confirm it does not appear in clipboard history, and toggle Launch at login.

## Releasing

Tag it and CI does the rest: build, test, sign, notarize, staple, publish.

```bash
git tag -a v1.2.0 -m "What changed in this release"
git push origin v1.2.0
```

`.github/workflows/release.yml` runs `./test.sh` then `./build.sh --no-install --zip` on a macOS runner and uploads `SnapDesk.zip` to the release. The tag's annotation becomes the release notes, which is what the app shows in What's New after it updates. Set the signing and notarization secrets listed at the top of that workflow before the first public release; without them the build is ad-hoc signed and the in-app updater will refuse to install it over a Developer-ID copy. Then bump `version` and `sha256` in `Casks/snapdesk.rb`.

## Security and privacy

- Nothing is uploaded. OCR, captions and capture are computed on-device, and there is no analytics, no server of ours, and no account. The single network call is the opt-in update check, an unauthenticated read of the public GitHub releases list, off by default and sending no identifiers.
- Updates are verified rather than trusted. A download is installed only if it carries a valid signature and is signed by the same identity as the running copy. Anything else is deleted and refused.
- Secrets are never stored. Clipboard history ignores concealed and transient pasteboard types, so passwords marked secret by your password manager never enter history.
- Least privilege. Screen Recording permission is requested only when first needed, and mic and speech only if you enable them. Carbon hotkeys avoid the broad Accessibility grant.
- Hardened Runtime is enabled when signing, so the app is notarization-ready.
- Destructive actions go to the Trash. Deleting a recording from its preview window is reversible, never an unrecoverable unlink.
- Diagnostics stay private. The OCR miss log and its screenshots live in `~/Library/Logs/SnapDesk`, created `0600` and capped at the last few, never in world-readable `/tmp`.

## License

See [LICENSE](LICENSE).
