import AppKit
import ServiceManagement
import SwiftUI

/// The first-launch walkthrough: what Burrow is, the shelf, the optional default-browser switch, permissions,
/// Open at Login. Only new users see it by itself; Settings › Show Welcome Tour opens it again.
@MainActor
enum Onboarding {
    private static var window: NSWindow?

    /// Anyone who has used Burrow before (or came over from an older bundle id) already knows it.
    nonisolated static func isExistingUser(_ d: UserDefaults = .standard) -> Bool {
        d.bool(forKey: "onboarded") || ["migratedFrom", "lastFolder", "recents", "favorites", "workspaces", "shelf"].contains { d.object(forKey: $0) != nil }
    }

    /// Called once per normal launch, before the first window opens.
    static func showIfNew() {
        if isExistingUser() { UserDefaults.standard.set(true, forKey: "onboarded") } else { show() }
    }

    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Walkthrough.size),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Welcome to Burrow"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: Walkthrough { window?.close() })
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                window = nil
                UserDefaults.standard.set(true, forKey: "onboarded")
            }
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// Welcome, the shelf, default browser, permissions, Open at Login, done. Every step can be skipped.
struct Walkthrough: View {
    static let size = NSSize(width: 620, height: 540)
    static let steps = 6
    let finish: () -> Void
    @State var step = 0

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: page("Drop Shelf", "tray.full.fill", .orange) { ShelfStep() }
                case 2: page("Default File Browser", "folder.fill", .blue) { DefaultStep() }
                case 3: page("Permissions", "lock.shield.fill", .green) { PermissionsStep() }
                case 4: page("Open at Login", "power", .purple) { LoginStep() }
                default: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step > 0 && step < Self.steps - 1 {
                    HStack(spacing: 6) {
                        ForEach(1..<Self.steps - 1, id: \.self) { i in
                            Capsule().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: i == step ? 18 : 6, height: 6)
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: step)
                }
                Spacer()
                Button(step == Self.steps - 1 ? "Start Browsing" : step == 0 ? "Get Started" : "Continue") {
                    if step == Self.steps - 1 { finish() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(18)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(.background)
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            IconArt().scaleEffect(0.11).frame(width: 112, height: 112)
            Text("Welcome to Burrow").font(.largeTitle.bold())
            Text("A file browser for people who live in Finder.").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                feature("rectangle.split.3x1", "Columns, list, icons and gallery, with tabs and a split view (⌘D)")
                feature("tray.full", "A Drop Shelf for moving files between apps")
                feature("square.stack.3d.up", "Workspaces: a project's files from anywhere, on one page")
                feature("arrow.down.circle", "Tidy Downloads, grouped by kind and date")
            }
            .padding(.top, 6)
        }
        .padding(26)
    }

    private var done: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
            Text("You're set").font(.largeTitle.bold())
            Text("⌘K jumps to any folder, ⌃⌥Space shows the shelf, and Space previews a file. "
                 + "This tour is in Burrow › Settings whenever you want it again.")
                .font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
        }
        .padding(26)
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 22) }
    }

    private func page(_ title: String, _ symbol: String, _ tint: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                StepIcon(symbol: symbol, tint: tint)
                Text(title).font(.title2.bold())
                Spacer()
            }
            .padding(.horizontal, 26).padding(.top, 38)
            content()
        }
    }
}

private struct StepIcon: View {
    let symbol: String, tint: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.gradient)
            .frame(width: 26, height: 26)
            .overlay(Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white))
    }
}

private struct ShelfStep: View {
    @Bindable private var s = AppSettings.shared
    var body: some View {
        Form {
            Section {
                LabeledContent("Show or hide it from any app") { Text("⌃⌥Space").font(.body.monospaced()).foregroundStyle(.secondary) }
                Toggle("Show the shelf while I drag files", isOn: $s.shelfOnDrag)
            } footer: {
                Text("Drop a file on a pinned folder to move it there (hold ⌥ to copy), or into Holding to keep it handy and drag it out later.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

private struct DefaultStep: View {
    @State private var isDefault = DefaultBrowser.isDefault
    @State private var working = false
    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button(isDefault ? "Give It Back to Finder" : "Make Burrow My Default") {
                        working = true
                        Task {
                            await DefaultBrowser.set(!isDefault)
                            isDefault = DefaultBrowser.isDefault
                            working = false
                        }
                    }
                    .disabled(working)
                } label: {
                    Text(isDefault ? "Burrow is your default" : "Finder is your default")
                    Text(isDefault ? "Folders and every app's “Show in Finder” open in Burrow."
                                   : "Optional. Burrow works fine alongside Finder.")
                }
            } footer: {
                Text("Finder still draws the desktop either way. To go back at any time, use Burrow › Settings › Give It Back to Finder.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

private struct PermissionsStep: View {
    @AppStorage("askedFolderAccess") private var asked = false
    var body: some View {
        // Re-read every second so a grant made in System Settings shows up without reopening.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Form {
                Section {
                    PermissionRow(title: "Desktop, Documents and Downloads", symbol: "folder.fill", tint: .blue,
                                  text: "So Burrow can show those folders. macOS asks once for each.",
                                  granted: Access.fullDisk || asked ? Access.homeFolders : nil) {
                        asked = true
                        _ = Access.homeFolders   // listing them is what makes macOS ask
                    }
                    PermissionRow(title: "Full Disk Access (optional)", symbol: "externaldrive.fill", tint: .gray,
                                  text: "No prompts at all, and Free Up Space can measure Library folders.",
                                  granted: Access.fullDisk) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                } footer: {
                    Text("External and network drives, and the browser address used by Add Bookmark, are asked for the first time you use them. "
                         + "Change any of these in System Settings › Privacy & Security.")
                }
            }
            .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        }
    }
}

private struct PermissionRow: View {
    let title: String, symbol: String, tint: Color, text: String
    let granted: Bool?
    let request: () -> Void
    var body: some View {
        LabeledContent {
            if granted == true {
                Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(granted == false ? "Open Settings…" : "Allow…") {
                    if granted == false {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
                    } else { request() }
                }
            }
        } label: {
            Label { Text(title); Text(text) } icon: { StepIcon(symbol: symbol, tint: tint) }
        }
    }
}

private struct LoginStep: View {
    @State private var on = SMAppService.mainApp.status == .enabled
    @State private var note: String?
    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { on }, set: { set($0) })) {
                    Text("Open Burrow at login")
                    Text("Keeps ⌃⌥Space and the drag shelf ready from the moment you log in.")
                }
                if let note { Text(note).foregroundStyle(.red) }
            } footer: {
                Text("Turn it off any time here or in System Settings › General › Login Items.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func set(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            note = nil
        } catch { note = error.localizedDescription }
        on = SMAppService.mainApp.status == .enabled
    }
}

/// Folder-access checks that never prompt by themselves (except `homeFolders`, read only after the user asks).
enum Access {
    static var homeFolders: Bool {
        let h = FileManager.default.homeDirectoryForCurrentUser
        return ["Desktop", "Documents", "Downloads"].allSatisfy { (try? FileManager.default.contentsOfDirectory(atPath: h.appendingPathComponent($0).path)) != nil }
    }
    /// ~/Library/Safari is readable only with Full Disk Access, and reading it never shows a prompt.
    static var fullDisk: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Library/Safari")) != nil
    }
}

// MARK: Preview

/// `Burrow --welcome-preview DIR`: renders every walkthrough step to PNGs offscreen, light and dark.
/// No window is shown, and nothing is changed (the buttons are never pressed).
@MainActor
enum WelcomePreview {
    static func run(into folder: String) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for step in 0..<Walkthrough.steps {
                // Form needs a real window to lay out; it's never ordered on screen.
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: Walkthrough.size),
                                      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                let host = NSHostingView(rootView: Walkthrough(finish: {}, step: step))
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let name = "welcome-\(step)" + (appearance == .darkAqua ? "-dark" : "") + ".png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
            }
        }
        print("wrote \(Walkthrough.steps * 2) pictures to \(folder)")
    }
}
