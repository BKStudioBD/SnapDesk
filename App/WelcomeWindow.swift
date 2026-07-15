import AppKit
import SwiftUI
import Combine

/// First-run welcome: explains what SnapDesk does, shows the shortcuts, and walks
/// the user through the two permissions in one place. Reopen anytime from the menu.
final class WelcomeWindowController: NSWindowController {
    init(settings: SettingsStore) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Welcome to SnapDesk"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentViewController = NSHostingController(
            rootView: WelcomeView(settings: settings) { [weak self] in self?.window?.close() })
    }
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct WelcomeView: View {
    @ObservedObject var settings: SettingsStore
    var onDone: () -> Void

    @State private var screenOK = false
    @State private var axOK = false
    // Re-check permission status every couple of seconds WHILE the window is
    // open. Connected on appear, cancelled on disappear — no forever-firing
    // timer after close (the controller is cached, so the view lingers).
    private let tick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    @State private var polling = false

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Image(systemName: "viewfinder").font(.system(size: 44)).foregroundStyle(.tint)
                Text("SnapDesk").font(.title.bold())
                Text("Capture · Annotate · OCR · Color · Clipboard — one lightweight, on-device menu-bar app.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.top, 6)

            VStack(spacing: 0) {
                feature("camera.viewfinder", "Capture & Annotate", "Drag a region, mark it up, copy or save", settings.screenshotHotkey.displayString)
                Divider()
                feature("text.viewfinder", "Grab Text (OCR)", "Drag over text → copied to the clipboard", settings.ocrHotkey.displayString)
                Divider()
                feature("eyedropper", "Pick a Color", "Eyedropper → copies HEX / RGB / HSL…", settings.colorHotkey.displayString)
                Divider()
                feature("doc.on.clipboard", "Clipboard History", "Everything you copy, searchable", settings.clipboardHotkey.displayString)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(0.05)))

            VStack(spacing: 8) {
                Text("Two quick permissions").font(.headline)
                permission("Screen Recording", "Needed for capture, OCR and color picking.",
                           granted: screenOK, action: grantScreen)
                permission("Accessibility", "Needed for double-click paste into other apps.",
                           granted: axOK, action: grantAX)
                if !screenOK {
                    // macOS only honors a fresh Screen Recording grant after a
                    // relaunch, and the ✓ can't turn green until then.
                    HStack(spacing: 6) {
                        Text("Turned Screen Recording ON? It takes effect after a relaunch:")
                            .font(.caption2).foregroundStyle(.tertiary)
                        Button("Relaunch Now", action: relaunch)
                            .controlSize(.small)
                    }
                }
            }

            Button(action: onDone) {
                Text("Get Started").frame(maxWidth: .infinity)
            }
            .controlSize(.large).keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { polling = true; refresh() }
        .onDisappear { polling = false }
        .onReceive(tick) { _ in if polling { refresh() } }
    }

    private func feature(_ icon: String, _ title: String, _ detail: String, _ key: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).frame(width: 26).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(key).font(.system(.callout, design: .rounded).weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.08)))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func permission(_ title: String, _ detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted { Text("Granted").font(.caption).foregroundStyle(.green) }
            else { Button("Grant", action: action) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.05)))
    }

    private func refresh() {
        screenOK = Permissions.hasScreenRecording
        axOK = Permissions.hasAccessibility
    }

    private func grantScreen() { Permissions.requestScreenRecording() }

    private func grantAX() {
        _ = Permissions.ensureAccessibility(prompt: true)
        Permissions.openAccessibilitySettings()
    }

    /// Relaunch the app so a fresh Screen Recording grant takes effect.
    private func relaunch() { InstallHelper.relaunchSelf() }
}
