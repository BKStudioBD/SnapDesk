# SnapDesk

One lightweight, fully native macOS menu-bar app that replaces **Lightshot + TextSniper + CleanShot X + a clipboard manager + a color picker + a Mac cleaner**. Pure Swift on Apple frameworks — no Electron, no external dependencies, tiny binary, low memory, and **100% on-device: SnapDesk never touches the network.**

Everything runs from a crisp menu-bar icon. No Dock icon, no main window.

## Features at a glance

| Shortcut | Feature | What it does |
|---|---|---|
| ⌃1 | 📸 **Capture & Annotate** | Select a region (or click a window to snap), annotate in place, copy/save/pin |
| ⌃2 | 🔤 **Grab Text (OCR)** | Drag over any text on screen → recognized on-device and copied instantly |
| ⌃3 | 🎨 **Pick a Color** | Magnified eyedropper → copies HEX / RGB / RGBA / HSL / CSS / SwiftUI / NSColor |
| ⌃4 | 📋 **Clipboard History** | Searchable history of copied text & images — pin, filter, paste back |
| ⌃5 | 🎥 **Record Screen** | Region or full-screen video with audio, captions, effects and privacy blur |
| ⌃6 | 📜 **Scrolling Capture** | Scroll through a long page → stitched into one tall image |
| menu | 🧹 **Cleaner** | One-click RAM + junk clean, and a full app uninstaller |

Every shortcut is rebindable live in **Settings → Shortcuts** (click, press a new combo — conflicts are flagged, changes apply instantly, no relaunch).

## Feature details

### 📸 Capture & Annotate (⌃1)
- Press ⌃1 → the whole screen dims instantly. Drag a region — a **magnifier loupe** follows the cursor for pixel-perfect edges and a live **W × H label** shows the size — **or just click any window** to snap to it exactly (hovering shows an outline hint). **F** selects the entire screen. **Esc** cancels.
- The shot opens in an **in-place editor** (Lightshot-style) right where you captured, with 10 tools on a floating bar:

  | Key | Tool | Key | Tool |
  |---|---|---|---|
  | **A** | Arrow | **H** | Highlighter (marker) |
  | **L** | Line | **B** | Blur — pixelates the area (hide secrets) |
  | **R** | Rectangle | **N** | Numbered steps (1, 2, 3… auto-increment) |
  | **O** | Ellipse | **T** | Text (click, type, styled) |
  | **P** | Freehand pen | **S** | Spotlight — dims everything except the area |

- Color swatches + stroke-width slider on the bar; the selection itself stays **resizable by its handles** while editing.
- **⌘C / ↵** copy · **⌘S** save (PNG or JPEG with quality slider) · **⌘Z** undo · **Esc** close.
- **📌 Pin** — floats the capture as an always-on-top reference window (multiple pins allowed, drag anywhere, close individually).
- **Auto-save** every capture to a folder of your choice, or copy-only — your call in Settings → Screenshot. Default tool and default color are configurable.
- Multi-display aware; optional **capture delay** (1–5 s) for catching menus; four shutter **sounds** or silence.

### 🔤 Grab Text — OCR (⌃2)
- Drag over anything with text — app UIs, images, videos, PDFs — Apple **Vision** recognizes it entirely on-device and copies it.
- **Recognition language** picker (English, Spanish, German, French, more).
- **Copy style:** *Inline* (single line, TextSniper-style) or *Outline* (keeps line breaks).
- Options: trim surrounding whitespace, **append to existing clipboard** instead of replacing, notification showing what was copied.

### 🎨 Color Picker (⌃3)
- System magnified eyedropper loupe over every pixel on screen.
- **Copy format:** HEX / RGB / RGBA / HSL / CSS variable / SwiftUI `Color` / `NSColor` code — with uppercase-hex toggle.
- **Keep sampling** mode: pick color after color until Esc — great for building palettes.
- **Recent colors** palette lives in Settings — click any swatch to re-copy it later. Optional notification per pick.

### 📋 Clipboard History (⌃4)
- Solid card list (CopyEm-style) with **All / Text / Images / Pinned** filters and live search.
- Click an item → copy. **Double-click → pastes straight into the app you were using.** Star to pin favorites to the top.
- History size 20–500 items, store-images toggle, clear-all, optional clear-on-quit.
- **Privacy built in:** anything a password manager marks concealed/transient (1Password, Keychain, browser passwords) **never enters the history.**

### 🎥 Screen Recording (⌃5)
- Drag a region, press **F** for full screen, or menu → **Record Full Screen…** (records the display your mouse is on).
- A **pre-record options bar** (CleanShot-style) appears on the selection — toggle everything without opening Settings:
  - 🔊 **System audio** — record what the Mac plays
  - 🎙 **Microphone** — your voice, with input-device picker
  - 📷 **Webcam bubble** — camera overlay in the corner
  - 💬 **Auto captions** — your speech transcribed **on-device** (English / Spanish / German) and **burned into the video itself** — one file, nothing separate
  - 🔒 **Privacy blur** — drag boxes over the selection; those areas stay pixelated for the entire video (double-click a box to remove)
- Optional **3/5-second countdown**, or start instantly.
- While recording: floating control bar with live timer — **pause/resume** (paused time is *cut* from the video, no gap), stop, or ✕ cancel-discard. The menu-bar icon shows the elapsed time too. **SnapDesk's own windows never appear in the recording.**
- **Effects burned into the video:** 2× cursor boost, click highlight rings, keystroke overlay (shows what you type, presenter-style).
- Video: **30 or 60 fps**, **H.264** (plays everywhere) or **HEVC** (smaller), three quality presets, show/hide cursor.
- Quitting the app mid-recording finishes and saves the file safely — a recording is never corrupted.
- Afterwards: **preview window with trim** — cut the start/end, then Reveal / Delete / Done. Videos save to any folder you choose.

### 📜 Scrolling Capture (⌃6)
- Select the area (a chat, a web page, a document), then scroll slowly — a counter shows captured frames.
- SnapDesk stitches the frames into **one tall seamless image**, copies it and saves it.

### 🧹 Cleaner (menu → Cleaner)
- **Clean tab** — live free-RAM readout up top. Tick what to clear, each with its live size:
  - **User caches** (apps rebuild them automatically)
  - **Temp files**
  - **Logs** (app + diagnostic logs)
  - **Empty Trash** (permanent — never pre-checked, marked red)
  
  One **Clean** click force-frees inactive memory *and* clears the ticked junk, then reports the total freed.
- **Uninstall tab** — AppCleaner-style deep uninstaller:
  1. Pick any installed app from the list.
  2. If it's running, SnapDesk **force-quits it first** (a running app can't be removed).
  3. It scans **25+ leftover locations** — Application Support, Caches, Preferences (+ByHost), Logs & crash reports, Containers & Group Containers, Saved App State, LaunchAgents/Daemons, WebKit data, Cookies, Services, PreferencePanes, and **vendor-nested folders** (finds `Google/Chrome`, `Microsoft/EdgeUpdater`-style data other uninstallers miss).
  4. You review the complete file list with checkboxes and sizes, then everything goes to the **Trash — fully reversible.**

### 🧰 Everything else
- **Welcome & Setup window** — first-run tour + permission checklist.
- **Settings dashboard** — grouped sidebar (General / Shortcuts / Capture: Screenshot·Recording·OCR·Color / Data: Clipboard / About: Help·About), every feature fully configurable.
- **Built-in Help** — all shortcuts and per-feature guides inside the app.
- **4 menu-bar icon styles** to pick from.
- **Launch at login**, four action sounds (with test button) or silent mode.
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

### Manual install (download the DMG)

1. Download **SnapDesk.dmg** from the [latest release](https://github.com/BKStudioBD/SnapDesk/releases/latest).
2. Open the DMG and **drag SnapDesk into Applications**.
3. First launch: **right-click → Open** once (the app is self-signed, so macOS shows an "unidentified developer" prompt the first time).

### Build from source (one command)

```bash
git clone https://github.com/BKStudioBD/SnapDesk.git
cd SnapDesk
./build.sh
```

`./build.sh` compiles, signs and produces `build/SnapDesk.dmg`. `./test.sh` type-checks every source file in seconds. (Needs Xcode command-line tools: `xcode-select --install`.)

### Granting Screen Recording (important)

Screenshots and OCR need macOS **Screen Recording** permission. On first use SnapDesk opens the right Settings pane — **turn SnapDesk ON and it restarts itself automatically**; you don't need to quit or reopen anything.

> **The grant sticks.** SnapDesk is signed with a stable certificate and installs itself to `/Applications` on first run, so the Screen Recording permission you give it **persists across launches and updates** — you grant it once.
>
> **Why macOS may still re-ask occasionally:** on macOS Sequoia (15) and Tahoe (26), Apple re-confirms Screen Recording for **every** app periodically (roughly monthly, and after some reboots/updates) — this hits notarized App Store apps too, and there's no way for any app to disable it (only a managed/MDM Mac can). So if it asks again once in a while, that's Apple's prompt, not a lost grant: just toggle SnapDesk **ON** and it restarts. Notarization removes the *first-launch* "unidentified developer" warning but does **not** remove this periodic prompt.
>
> Microphone / Speech permissions are only requested if you turn on those recording options.

> **Gatekeeper note:** a locally-built app opens with no warning. If you distribute the DMG to another Mac without Apple notarization, first launch needs right-click → **Open** (or `xattr -dr com.apple.quarantine /Applications/SnapDesk.app`). For zero-warning distribution, sign with a Developer ID and notarize:
> ```bash
> DEV_ID="Developer ID Application: Your Name (TEAMID)" \
> NOTARY_PROFILE="your-notary-profile" ./build.sh
> ```

### Mac App Store variant

```bash
./build.sh --mas
```

Builds with **App Sandbox ON** (`SnapDesk-MAS.entitlements`). Note: sandbox restrictions limit the Cleaner's uninstaller in this variant — use the direct build for full functionality.

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
  RAM/         Cleaner window (RAM/junk clean + uninstaller UI)
Hotkeys/     Carbon global hotkey registration (no Accessibility permission needed)
Settings/    Preferences store + SwiftUI settings dashboard
Support/     RAM/cache cleaners, app uninstaller, notifier, sounds
```

## Testing

```bash
./test.sh        # full swiftc -typecheck over every source file (seconds)
./test-tools.sh  # headless render test of every annotation tool → PNGs
```

Then a one-minute manual smoke test: try each hotkey (⌃1–⌃6), copy a password (must NOT appear in clipboard history), and toggle Launch at login.

## Security & privacy

- **No network. Ever.** OCR, captions, capture, cleaning — 100% on-device. No analytics, no servers, no uploads.
- **Secrets are never stored.** Clipboard history ignores concealed/transient pasteboard types (1Password / Keychain / browser passwords never enter history).
- **Least privilege.** Screen Recording permission only when first needed; mic/speech only if you enable them. Carbon hotkeys avoid the broad Accessibility grant.
- **Hardened Runtime** enabled when signing — notarization-ready.
- **Destructive actions go to the Trash** (uninstaller, junk clean) — reversible; only "Empty Trash" is permanent and clearly marked.

## License

See [LICENSE](LICENSE).
