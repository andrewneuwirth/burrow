import AppKit
import CoreServices
import ServiceManagement
import SwiftUI
import MacToolsUpdates
import UniformTypeIdentifiers

// MARK: Get Info (⌘I)

@MainActor
enum Info {
    private static var windows: [NSWindow] = []

    static func show(_ items: [FileItem]) {
        guard !items.isEmpty else { return NSSound.beep() }
        for item in items.prefix(8) {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "\(item.name) Info"
            w.contentViewController = NSHostingController(rootView: InfoView(item: item))
            w.isReleasedWhenClosed = false
            w.center()
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { windows.removeAll { $0 === w } }
            }
        }
    }
}

struct InfoView: View {
    let item: FileItem
    @State private var total: (bytes: Int64, count: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                FileIcon(item: item, size: 64, thumbnail: true)
                VStack(alignment: .leading) {
                    Text(item.name).font(.headline).lineLimit(2)
                    Text(item.kind).foregroundStyle(.secondary)
                }
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                row("Size", sizeText)
                row("Where", (item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                row("Created", Fmt.date(item.created))
                row("Modified", Fmt.date(item.modified))
                if item.target != item.url { row("Original", item.target.path) }
                if let from = Self.whereFrom(item.url) { row("Where from", from) }
            }
            .font(.callout)
            Spacer()
        }
        .padding(16)
        .frame(width: 340, alignment: .topLeading)
        .frame(minHeight: 260)
        .task { if item.opensAsFolder || item.isPackage { total = await Self.measure(item.target) } }
    }

    private var sizeText: String {
        if let s = item.size { return ByteCountFormatter.string(fromByteCount: s, countStyle: .file) }
        guard let total else { return "Calculating…" }
        return "\(ByteCountFormatter.string(fromByteCount: total.bytes, countStyle: .file)) on disk, \(total.count.formatted()) items"
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(v).textSelection(.enabled).lineLimit(3)
        }
    }

    /// Where a download came from (Spotlight's kMDItemWhereFroms, as Finder shows it).
    static func whereFrom(_ url: URL) -> String? {
        guard let md = MDItemCreateWithURL(nil, url as CFURL),
              let list = MDItemCopyAttribute(md, kMDItemWhereFroms) as? [String], !list.isEmpty else { return nil }
        return list.joined(separator: "\n")
    }

    static func measure(_ url: URL) async -> (Int64, Int) {
        await Task.detached(priority: .utility) {
            var bytes: Int64 = 0, count = 0
            let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
            while let u = e?.nextObject() as? URL {
                bytes += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
                count += 1
            }
            return (bytes, count)
        }.value
    }
}

// MARK: Settings

struct SettingsView: View {
    @Bindable private var s = AppSettings.shared
    @State private var isDefault = DefaultBrowser.isDefault
    @State private var working = false

    private var starts: [(String, String)] {
        let h = FileManager.default.homeDirectoryForCurrentUser.path
        let dev = s.developerTools || s.startPath == h + "/Developer"
        return [("Home", h), ("Desktop", h + "/Desktop"), ("Documents", h + "/Documents"), ("Downloads", h + "/Downloads")] + (dev ? [("Developer", h + "/Developer")] : [])
    }

    var body: some View {
        Form {
            Section("Browsing") {
                Toggle("Show hidden files", isOn: $s.showHidden)
                Toggle("Keep folders on top", isOn: $s.foldersFirst)
                Toggle("Open Markdown files in Burrow", isOn: $s.openMarkdownHere)
                Picker("Folder colour", selection: $s.folderTint) {
                    ForEach(Array(Palette.names.enumerated()), id: \.offset) { i, name in
                        Label { Text(name) } icon: { Image(systemName: "circle.fill").foregroundStyle(Palette.tints[i]) }.tag(i)
                    }
                }
                Picker("New windows open", selection: $s.startPath) {
                    ForEach(starts, id: \.1) { Text($0.0).tag($0.1) }
                }
                Picker("New windows show", selection: $s.viewMode) {
                    ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Toggle("Developer tools", isOn: $s.developerTools)
                Text("The Installed and AI Agents pages, Xcode leftovers in Free Up Space, and ~/Developer shortcuts.")
                    .foregroundStyle(.secondary)
            }
            Section("Drop Shelf") {
                Toggle("Show the shelf while dragging files", isOn: $s.shelfOnDrag)
                Text("⌃⌥Space shows or hides it from any app.").foregroundStyle(.secondary)
                Toggle("Start without a window when opening at login", isOn: $s.quietLogin)
            }
            Section("Default file browser") {
                Text(isDefault ? "Burrow opens folders and every app's “Show in Finder”."
                               : "Finder opens folders and “Show in Finder”. Finder still draws the desktop either way.")
                    .foregroundStyle(.secondary)
                Button(isDefault ? "Give It Back to Finder" : "Make Burrow the Default") {
                    working = true
                    Task {
                        await DefaultBrowser.set(!isDefault)
                        isDefault = DefaultBrowser.isDefault
                        working = false
                    }
                }
                .disabled(working)
                if isDefault {
                    Text("Removing Burrow? Give it back to Finder first, so folders and “Show in Finder” don't point at a missing app.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            AppUpdateSettings()
            Section {
                Button("Show Welcome Tour…") { Onboarding.show() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}

/// Folders (Launch Services' public.folder handler) and “reveal” requests from other apps (the NSFileViewer default).
enum DefaultBrowser {
    static var id: String { Bundle.main.bundleIdentifier ?? "app.newitools.Burrow" }
    static var isDefault: Bool { UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["NSFileViewer"] as? String == id }

    /// Burrow › Give It Back to Finder…: the way out before uninstalling, said back in plain words.
    @MainActor static func giveBack() async {
        let alert = NSAlert()
        if isDefault {
            let notes = await set(false)
            alert.messageText = notes.isEmpty ? "Finder is your file browser again" : "Finder is back, with a note"
            alert.informativeText = (notes.isEmpty ? "" : notes.joined(separator: "\n") + "\n\n") + "To remove Burrow, quit it and move it to the Trash."
        } else {
            alert.messageText = "Finder is already your file browser"
            alert.informativeText = "Nothing to undo. To remove Burrow, quit it and move it to the Trash."
        }
        alert.runModal()
    }

    /// Folders, "Show in Finder" from every app, and opening at login (so the shelf's hot key is always there).
    @discardableResult static func set(_ on: Bool) async -> [String] {
        var notes: [String] = []
        let app = on ? Bundle.main.bundleURL : URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        do { try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .folder) } catch { notes.append("folders: \(error.localizedDescription)") }
        do { if on { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() } } catch { notes.append("open at login: \(error.localizedDescription)") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = on ? ["write", "-g", "NSFileViewer", "-string", id] : ["delete", "-g", "NSFileViewer"]
        try? p.run()
        p.waitUntilExit()
        return notes
    }
}

// MARK: Self-check (`Burrow --self-check`)

@MainActor
enum SelfCheck {
    static func run() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("burrow-check-\(UUID().uuidString)", isDirectory: true)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt")
        try! "hi".write(to: a, atomically: true, encoding: .utf8)

        precondition(FileOps.unique(a).lastPathComponent == "a 2.txt", "unique: numbered")
        precondition(FileOps.unique(a, copy: true).lastPathComponent == "a copy.txt", "unique: copy")
        let sub = dir.appendingPathComponent("my.folder", isDirectory: true)
        try! fm.createDirectory(at: sub, withIntermediateDirectories: false)
        precondition(FileOps.unique(sub).lastPathComponent == "my.folder 2", "unique: folders keep dots")

        let ops = FileOps.shared
        let b = ops.rename(a, to: "b.txt")!
        precondition(fm.fileExists(atPath: b.path) && !fm.fileExists(atPath: a.path), "rename")
        ops.undo()
        precondition(fm.fileExists(atPath: a.path), "undo rename")
        ops.redo()
        precondition(fm.fileExists(atPath: b.path) && !fm.fileExists(atPath: a.path), "redo rename")
        ops.undo()
        precondition(fm.fileExists(atPath: a.path), "undo after redo")
        let A = ops.rename(a, to: "A.txt")!
        precondition(fm.fileExists(atPath: A.path) && (try! fm.contentsOfDirectory(atPath: dir.path)).contains("A.txt"), "case-only rename")
        ops.undo()

        let made = ops.newFolder(in: dir)!
        precondition(made.lastPathComponent == "untitled folder", "new folder")
        ops.trash([made])
        precondition(!fm.fileExists(atPath: made.path), "trash")
        ops.undo()
        precondition(fm.fileExists(atPath: made.path), "undo trash")

        let pane = PaneModel(url: dir, viewMode: .list)
        pane.show(.columns)
        precondition(pane.viewMode == .columns, "⌘3 shows columns")
        pane.show(.columns)
        precondition(pane.viewMode == .list, "⌘3 again goes back")
        pane.stop()

        let item = FileItem(url: sub)
        precondition(item.opensAsFolder && item.size == nil, "folder item")
        precondition(!FileItem(url: URL(fileURLWithPath: "/System/Applications/Calculator.app")).opensAsFolder, "apps open, not browse")
        FileRank.selfCheck()
        check("a file you don't own goes through Finder's Trash", FileOps.isPermission(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
              && FileOps.isPermission(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))) && !FileOps.isPermission(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
        Tidy.selfCheck()
        MDParser.selfCheck()
        Vitals.selfCheck()
        Migration.selfCheck()
        Shelf.selfCheck(in: dir)
        let fresh = UserDefaults(suiteName: "burrow-selfcheck-empty-\(UUID().uuidString)")!
        precondition(!Onboarding.isExistingUser(fresh), "a new user sees the walkthrough")
        AppSettings.settleDeveloperTools(fresh)
        precondition(fresh.object(forKey: "developerTools") as? Bool == false, "new user: developer tools off")
        fresh.set(true, forKey: "onboarded")
        AppSettings.settleDeveloperTools(fresh)
        precondition(fresh.bool(forKey: "developerTools") == false, "developer tools: decided once, finishing the tour doesn't flip it")
        let old = UserDefaults(suiteName: "burrow-selfcheck-old-\(UUID().uuidString)")!
        old.set(["/tmp"], forKey: "recents")
        AppSettings.settleDeveloperTools(old)
        precondition(old.bool(forKey: "developerTools"), "existing user: developer tools on")
        print("Burrow self-check passed")
    }
}
