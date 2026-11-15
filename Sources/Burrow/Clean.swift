import AppKit
import SwiftUI

/// Title, subtitle and a Refresh button, for pages shown in place of a folder listing.
struct PageHeader: View {
    let title: String, subtitle: String
    let refresh: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

/// Runs a command line tool and returns its standard output ("" when it can't run). Blocks: call off the main thread.
enum Sh {
    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()   // read before waiting, or a full pipe deadlocks
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// One suggestion on the Free Up Space page: what would go to the Trash, and how big it is.
struct CleanSpot: Identifiable, Sendable {
    enum Kind: Sendable { case contents, oldDownloads, file }
    let id: String, title: String, reason: String
    let roots: [URL]
    var kind: Kind = .contents
    var safe = true
    var skip: Set<String> = []   // children left out because another row owns them
    var items: [URL] = []        // what "Move to Trash" moves: a cache folder's children, never the folder
    var size: Int64?             // nil while calculating
    var blocked = false          // exists but unreadable (Full Disk Access)

    var visible: Bool { size == nil || blocked || size! > 0 }

    static let home = FileManager.default.homeDirectoryForCurrentUser
    static func h(_ p: String) -> URL { home.appendingPathComponent(p) }

    static let fixed: [CleanSpot] = [
        CleanSpot(id: "derived", title: "Xcode build files", reason: "DerivedData. Xcode rebuilds it on the next build.",
                  roots: [h("Library/Developer/Xcode/DerivedData")]),
        CleanSpot(id: "caches", title: "App caches", reason: "Apps rebuild or re-download these when they need them.",
                  roots: [h("Library/Caches")], skip: ["Homebrew", "pip", "CocoaPods", "Yarn"]),
        CleanSpot(id: "brew", title: "Homebrew downloads", reason: "Bottles and installers kept after installing.",
                  roots: [h("Library/Caches/Homebrew")]),
        CleanSpot(id: "pkg", title: "Package manager caches", reason: "npm, pip, CocoaPods, Gradle, Yarn and pnpm fetch these again.",
                  roots: [h(".npm/_cacache"), h("Library/Caches/pip"), h("Library/Caches/CocoaPods"), h(".gradle/caches"),
                          h("Library/Caches/Yarn"), h("Library/pnpm/store")]),
        CleanSpot(id: "devsupport", title: "iOS device support", reason: "Debug symbols Xcode copies again when the device connects.",
                  roots: [h("Library/Developer/Xcode/iOS DeviceSupport")]),
        CleanSpot(id: "downloads", title: "Old downloads", reason: "Sitting in Downloads for more than 90 days.",
                  roots: [h("Downloads")], kind: .oldDownloads, safe: false),
        CleanSpot(id: "mail", title: "Mail attachments", reason: "Copies of attachments you opened; Mail keeps the originals.",
                  roots: [h("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")], safe: false),
        CleanSpot(id: "archives", title: "Xcode archives", reason: "Archived builds. Keep any you still need for crash symbols.",
                  roots: [h("Library/Developer/Xcode/Archives")], safe: false),
    ]

    /// The rows this user sees: Xcode's leftovers only with Settings › Developer tools on.
    @MainActor static var shown: [CleanSpot] {
        AppSettings.shared.developerTools ? fixed : fixed.filter { !["derived", "devsupport", "archives"].contains($0.id) }
    }

    /// Lists the items and adds up their size. Slow on big caches: call off the main thread.
    static func measure(_ s: CleanSpot, now: Date = Date()) -> CleanSpot {
        var s = s
        let fm = FileManager.default
        var items: [URL] = []
        for r in s.roots {
            if s.kind == .file { if fm.fileExists(atPath: r.path) { items.append(r) }; continue }
            do {
                var kids = try fm.contentsOfDirectory(at: r, includingPropertiesForKeys: [.addedToDirectoryDateKey])
                    .filter { !s.skip.contains($0.lastPathComponent) }
                if s.kind == .oldDownloads {
                    kids = kids.filter { u in
                        guard !u.lastPathComponent.hasPrefix("."),
                              let added = try? u.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate else { return false }
                        return now.timeIntervalSince(added) > 90 * 86_400
                    }
                }
                items += kids
            } catch let e as NSError where e.code == NSFileReadNoPermissionError {
                s.blocked = true
            } catch {}   // missing: nothing to clear
        }
        // Items the Trash can't take (root-owned, protected) would each raise a "delete immediately?" prompt.
        s.items = items.filter { fm.isDeletableFile(atPath: $0.path) }
        s.size = s.items.reduce(0) { $0 + allocated($1) }
        return s
    }

    static func allocated(_ u: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let v = try? u.resourceValues(forKeys: keys) else { return 0 }
        guard v.isDirectory == true else { return Int64(v.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [], errorHandler: { _, _ in true })
        while let f = e?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Files over 1 GB in the home folder, leaving out what other rows already cover and files inside packages
    /// (a movie inside a Photos library is not the user's to trash file by file).
    static func bigFiles() -> [CleanSpot] {
        let skipRoots = fixed.flatMap(\.roots).map { $0.path + "/" } + [h(".Trash").path + "/"]
        return Sh.run("/usr/bin/mdfind", ["-onlyin", home.path, "kMDItemFSSize > 1000000000"])
            .split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            .filter { u in !skipRoots.contains { u.path.hasPrefix($0) } && !insidePackage(u) }
            .map { u in
                let parent = u.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "~", options: .anchored)
                return measure(CleanSpot(id: u.path, title: u.lastPathComponent, reason: parent, roots: [u], kind: .file, safe: false))
            }
            .sorted { ($0.size ?? 0) > ($1.size ?? 0) }
    }

    static func insidePackage(_ u: URL) -> Bool {
        var p = u.deletingLastPathComponent()
        while p.path.count > home.path.count {
            if (try? p.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return true }
            p = p.deletingLastPathComponent()
        }
        return false
    }
}

/// "Free Up Space": how full the startup disk is, and caches and leftovers that can go to the Trash (⌘Z brings them back).
struct SmartCleanPage: View {
    @State private var spots = CleanSpot.shown
    @State private var big: [CleanSpot]?   // nil while Spotlight looks
    @State private var checked = Set(CleanSpot.shown.filter(\.safe).map(\.id))
    @State private var disk: (used: Int64, total: Int64, free: Int64)?
    @State private var trash: CleanSpot?
    @State private var generation = 0
    @State private var folders: (folders: [Readout.Folder], scanned: Date)?

    private var all: [CleanSpot] { spots + (big ?? []) }
    private var picked: [CleanSpot] { all.filter { checked.contains($0.id) && $0.visible && !$0.blocked } }
    private var pickedSize: Int64 { picked.reduce(0) { $0 + ($1.size ?? 0) } }
    private var ready: Bool { !picked.isEmpty && picked.allSatisfy { $0.size != nil } }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Free Up Space", subtitle: "Caches and leftovers you can move to the Trash. ⌘Z puts them back.") { generation += 1 }
            Divider()
            Form {
                Section("Startup disk") { diskRow }
                Section("Safe to clear") {
                    ForEach(spots.filter { $0.safe && $0.visible }) { row($0) }
                }
                Section("Your call") {
                    ForEach(spots.filter { !$0.safe && $0.visible }) { row($0) }
                }
                Section("Big files (over 1 GB)") {
                    if let big {
                        if big.isEmpty { Text("None found.").foregroundStyle(.secondary) }
                        ForEach(big.filter(\.visible)) { row($0) }
                    } else {
                        Text("Searching…").foregroundStyle(.secondary)
                    }
                }
                if let folders {
                    // Readout's saved scan: a map of where the space went, to look at, not a list of things to delete.
                    Section {
                        ForEach(folders.folders) { f in
                            HStack {
                                Image(nsImage: Icons.icon(URL(fileURLWithPath: f.path))).resizable().frame(width: 18, height: 18)
                                Text(FileRank.place(f.path, home: NSHomeDirectory())).lineLimit(1).truncationMode(.head)
                                Spacer()
                                Text(fmt(f.bytes)).monospacedDigit().foregroundStyle(.secondary)
                                Button("Show") { Windows.shared.open(URL(fileURLWithPath: f.path, isDirectory: true)) }.controlSize(.small)
                            }
                        }
                    } header: {
                        Text("Biggest folders")
                    } footer: {
                        Text("From Readout's disk scan \(folders.scanned.formatted(.relative(presentation: .named))). Rescan in Readout › Disks.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    HStack {
                        Spacer()
                        Button("Move Checked to Trash" + (ready ? " (\(fmt(pickedSize)))" : "")) { trashPicked() }
                            .buttonStyle(.borderedProminent).disabled(!ready)
                    }
                }
                Section("Trash") { trashRow }
            }
            .formStyle(.grouped)
        }
        .task(id: generation) { await load() }
    }

    private var diskRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let disk {
                ProgressView(value: Double(disk.used), total: Double(max(disk.total, 1)))
                Text("\(fmt(disk.used)) used of \(fmt(disk.total)), \(fmt(disk.free)) available").foregroundStyle(.secondary)
            } else {
                Text("Can't read the startup disk.").foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ s: CleanSpot) -> some View {
        HStack(spacing: 10) {
            Toggle(s.title, isOn: Binding(get: { checked.contains(s.id) && !s.blocked },
                                          set: { if $0 { checked.insert(s.id) } else { checked.remove(s.id) } }))
                .toggleStyle(.checkbox).labelsHidden().disabled(s.blocked)
            if s.kind == .file { Image(nsImage: Icons.icon(s.roots[0])).resizable().frame(width: 20, height: 20) }
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).lineLimit(1).truncationMode(.middle)
                Text(s.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(s.blocked ? "Needs Full Disk Access" : s.size.map(fmt) ?? "Calculating…")
                .monospacedDigit().foregroundStyle(.secondary)
            Button("Show") { show(s) }
        }
    }

    private var trashRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Trash")
                Text("Emptying deletes for good; ⌘Z can't bring these back.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(trash.map { $0.blocked ? "Needs Full Disk Access" : $0.size.map(fmt) ?? "Calculating…" } ?? "Calculating…")
                .monospacedDigit().foregroundStyle(.secondary)
            Button("Empty Trash…") { emptyTrash() }.disabled((trash?.items.isEmpty ?? true))
        }
    }

    private func fmt(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private func load() async {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        if let total = v?.volumeTotalCapacity, let free = v?.volumeAvailableCapacityForImportantUsage {
            disk = (Int64(total) - free, Int64(total), free)
        }
        spots = CleanSpot.shown
        big = nil
        folders = await Task.detached { Readout.biggestFolders() }.value
        trash = nil
        await withTaskGroup(of: Void.self) { g in
            for s in CleanSpot.shown {
                g.addTask { @MainActor in
                    let m = await Task.detached { CleanSpot.measure(s) }.value
                    if let i = spots.firstIndex(where: { $0.id == m.id }) { spots[i] = m }
                }
            }
            g.addTask { @MainActor in big = await Task.detached { CleanSpot.bigFiles() }.value }
            g.addTask { @MainActor in
                trash = await Task.detached { CleanSpot.measure(CleanSpot(id: "trash", title: "Trash", reason: "", roots: [CleanSpot.h(".Trash")])) }.value
            }
        }
    }

    private func show(_ s: CleanSpot) {
        let fm = FileManager.default
        guard let u = s.roots.first(where: { fm.fileExists(atPath: $0.path) }) else { return }
        if s.kind == .file { Windows.shared.open(u.deletingLastPathComponent(), select: [u]) } else { Windows.shared.open(u) }
    }

    private func trashPicked() {
        let urls = picked.flatMap(\.items)
        let a = NSAlert()
        a.messageText = "Move \(fmt(pickedSize)) to the Trash?"
        a.informativeText = "\(urls.count) item\(urls.count == 1 ? "" : "s") from \(picked.count) place\(picked.count == 1 ? "" : "s"). ⌘Z puts them back."
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        FileOps.shared.trash(urls, ask: false)
        generation += 1
    }

    private func emptyTrash() {
        guard let trash, !trash.items.isEmpty else { return }
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = "Permanently delete \(trash.items.count) item\(trash.items.count == 1 ? "" : "s") in the Trash?"
        a.informativeText = "\(fmt(trash.size ?? 0)) will be erased. This can't be undone."
        a.addButton(withTitle: "Empty Trash").hasDestructiveAction = true
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var failed: [String] = []
        for u in trash.items {
            do { try FileManager.default.removeItem(at: u) } catch { failed.append(u.lastPathComponent) }
        }
        if !failed.isEmpty { FileOps.alert("Some Items Couldn't Be Deleted", failed.prefix(10).joined(separator: ", ")) }
        generation += 1
    }
}
