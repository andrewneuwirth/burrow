import AppKit

/// What ⌘Z reverses. Every entry is reversible without data loss: copies and new items go to the Trash.
enum UndoEntry {
    case moved([(from: URL, to: URL)])
    case copied([URL])
    case created([URL])
    case renamed(from: URL, to: URL)
    case trashed([(original: URL, inTrash: URL)])
    case restored([URL])   // put back from the Trash (what redoing a Move to Trash reverses)

    var title: String {
        switch self {
        case .restored: "Put Back"
        case .moved: "Move"
        case .copied: "Copy"
        case .created: "New Item"
        case .renamed: "Rename"
        case .trashed: "Move to Trash"
        }
    }
}

@MainActor @Observable
final class Job: Identifiable {
    let title: String
    let total: Int
    var done = 0
    var cancelled = false
    init(title: String, total: Int) { self.title = title; self.total = total }
}

@MainActor @Observable
final class FileOps {
    static let shared = FileOps()
    private(set) var jobs: [Job] = []
    private(set) var undoStack: [UndoEntry] = []
    private(set) var redoStack: [UndoEntry] = []
    /// The last thing done, for the shelf's "Moved … to …  Undo" line.
    private(set) var lastMessage: (text: String, at: Date)?
    private let fm = FileManager.default

    var undoTitle: String { undoStack.last.map { "Undo \($0.title)" } ?? "Undo" }
    var redoTitle: String { redoStack.last.map { "Redo \($0.title)" } ?? "Redo" }

    private func push(_ e: UndoEntry, clearingRedo: Bool = true) {
        if clearingRedo { redoStack.removeAll() }
        undoStack.append(e)
        if undoStack.count > 100 { undoStack.removeFirst() }
    }

    /// A drop, with Finder's rules: same volume moves, another volume copies, ⌥ always copies, ⌘ always moves.
    func drop(_ urls: [URL], into dir: URL) {
        let flags = NSEvent.modifierFlags
        let copy = flags.contains(.option) ? true : flags.contains(.command) ? false : urls.contains { !Self.sameVolume($0, dir) }
        transfer(urls, to: dir, copy: copy)
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let k: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let x = try? a.resourceValues(forKeys: k).volumeIdentifier as? NSObject,
              let y = try? b.resourceValues(forKeys: k).volumeIdentifier as? NSObject else { return true }
        return x.isEqual(y)
    }

    /// The folder a drop really lands in: a Finder alias or symlink of a folder is followed to the original.
    nonisolated static func realFolder(_ url: URL) -> URL {
        let original = (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true ? (try? URL(resolvingAliasFileAt: url)) ?? url : url
        return original.resolvingSymlinksInPath().folder
    }

    func transfer(_ urls: [URL], to dir: URL, copy: Bool) {
        let dir = Self.realFolder(dir)
        var plan: [(URL, URL)] = []
        var replacing: Set<String> = []
        var always: Conflict?
        for raw in urls {
            let src = raw.standardizedFileURL
            let real = src.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(src.lastPathComponent).path
            let inPlace = (real as NSString).deletingLastPathComponent == dir.path
            if inPlace && !copy { continue }   // moved onto its own folder: nothing to do
            if dir.path == real || dir.path.hasPrefix(real + "/") { NSSound.beep(); continue }   // into itself
            var dst = dir.appendingPathComponent(src.lastPathComponent)
            if inPlace {
                dst = Self.unique(dst, copy: true)   // ⌥-drag in the same folder duplicates
            } else if fm.fileExists(atPath: dst.path) {
                switch always ?? askConflict(src.lastPathComponent, many: urls.count > 1, always: &always) {
                case .skip: continue
                case .keepBoth: dst = Self.unique(dst)
                case .replace: replacing.insert(dst.path)
                }
            }
            plan.append((src, dst))
        }
        guard !plan.isEmpty else { return }
        let name = plan.count == 1 ? "“\(plan[0].0.lastPathComponent)”" : "\(plan.count) items"
        let job = Job(title: (copy ? "Copying " : "Moving ") + name, total: plan.count)
        jobs.append(job)
        Task.detached(priority: .userInitiated) {
            let fm = FileManager()
            var done: [(URL, URL)] = []
            var failure: String?
            for (src, dst) in plan {
                if await job.cancelled { break }
                do {
                    // The replaced item goes to the Trash, not away: a wrong "Replace" stays recoverable.
                    if replacing.contains(dst.path) { try fm.trashItem(at: dst, resultingItemURL: nil) }
                    // shortcut: progress counts items, so one huge file shows 0 → 1; read byte progress if that matters
                    if copy { try fm.copyItem(at: src, to: dst) } else { try fm.moveItem(at: src, to: dst) }
                    done.append((src, dst))
                } catch {
                    failure = error.localizedDescription
                    break
                }
                await MainActor.run { job.done += 1 }
            }
            let finished = done, failed = failure
            await MainActor.run {
                self.jobs.removeAll { $0 === job }
                let done = finished, failure = failed
                if !done.isEmpty {
                    self.push(copy ? .copied(done.map(\.1)) : .moved(done.map { (from: $0.0, to: $0.1) }))
                    let what = done.count == 1 ? done[0].0.lastPathComponent : "\(done.count) items"
                    self.lastMessage = ("\(copy ? "Copied" : "Moved") \(what) to \(dir.lastPathComponent)", Date())
                }
                if let failure { Self.alert(copy ? "Couldn't Finish Copying" : "Couldn't Finish Moving", failure) }
            }
        }
    }

    enum Conflict { case keepBoth, replace, skip }

    private func askConflict(_ name: String, many: Bool, always: inout Conflict?) -> Conflict {
        if let sink = Self.alertSink { sink("conflict: \(name)"); return .skip }
        let a = NSAlert()
        a.messageText = "An item named “\(name)” already exists here."
        a.informativeText = "Replacing it moves the existing item to the Trash."
        a.addButton(withTitle: "Keep Both")
        a.addButton(withTitle: "Replace")
        a.addButton(withTitle: "Skip")
        if many { a.showsSuppressionButton = true; a.suppressionButton?.title = "Apply to all" }
        let choice: Conflict = switch a.runModal() {
        case .alertFirstButtonReturn: .keepBoth
        case .alertSecondButtonReturn: .replace
        default: .skip
        }
        if a.suppressionButton?.state == .on { always = choice }
        return choice
    }

    /// `ask`: offer to delete what can't go to the Trash. Bulk cleaning passes false and just skips those.
    func trash(_ urls: [URL], ask: Bool = true) {
        var done: [(URL, URL)] = []
        for u in urls {
            var res: NSURL?
            do {
                try fm.trashItem(at: u, resultingItemURL: &res)
                if let r = res as URL? { done.append((u, r)) }
            } catch {
                // Owned by another user (root leftovers in /Applications): Finder asks for an admin password and trashes it.
                if Self.isPermission(error) {
                    if ask, let r = Self.finderTrash(u) { done.append((u, r)) }
                    continue
                }
                // Some volumes (network, some USB) have no Trash: deleting there is permanent, so ask.
                guard ask else { continue }
                let a = NSAlert()
                a.messageText = "“\(u.lastPathComponent)” can't go to the Trash."
                a.informativeText = "Delete it immediately? This can't be undone."
                a.addButton(withTitle: "Cancel")
                a.addButton(withTitle: "Delete")
                if a.runModal() == .alertSecondButtonReturn {
                    do { try fm.removeItem(at: u) } catch { Self.alert("Couldn't Delete", error.localizedDescription) }
                }
            }
        }
        if !done.isEmpty { push(.trashed(done.map { (original: $0.0, inTrash: $0.1) })) }
    }

    func rename(_ url: URL, to raw: String) -> URL? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != url.lastPathComponent else { return nil }
        guard !name.contains("/"), !name.contains(":") else { Self.alert("Can't Use That Name", "Names can't contain “/” or “:”."); return nil }
        let dst = url.deletingLastPathComponent().appendingPathComponent(name)
        let caseOnly = name.lowercased() == url.lastPathComponent.lowercased()
        if !caseOnly, fm.fileExists(atPath: dst.path) {
            Self.alert("“\(name)” Is Taken", "Choose a different name.")
            return nil
        }
        do {
            if caseOnly {   // case-insensitive volumes see the new name as taken; go through a temporary name
                let tmp = url.deletingLastPathComponent().appendingPathComponent(".burrow-rename-\(UUID().uuidString)")
                try fm.moveItem(at: url, to: tmp)
                try fm.moveItem(at: tmp, to: dst)
            } else {
                try fm.moveItem(at: url, to: dst)
            }
            push(.renamed(from: url, to: dst))
            return dst
        } catch {
            Self.alert("Couldn't Rename", error.localizedDescription)
            return nil
        }
    }

    func newFolder(in dir: URL) -> URL? {
        let u = Self.unique(dir.appendingPathComponent("untitled folder", isDirectory: true))
        do {
            try fm.createDirectory(at: u, withIntermediateDirectories: false)
            push(.created([u]))
            return u
        } catch {
            Self.alert("Couldn't Make a Folder", error.localizedDescription)
            return nil
        }
    }

    func duplicate(_ urls: [URL]) {
        var made: [URL] = []
        for u in urls {
            let dst = Self.unique(u, copy: true)
            do { try fm.copyItem(at: u, to: dst); made.append(dst) } catch { Self.alert("Couldn't Duplicate", error.localizedDescription) }
        }
        if !made.isEmpty { push(.copied(made)) }
    }

    /// Finder's Compress: one item → “name.zip”, several → “Archive.zip”.
    func compress(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let dir = first.deletingLastPathComponent()
        let out = Self.unique(dir.appendingPathComponent(urls.count == 1 ? first.lastPathComponent + ".zip" : "Archive.zip"))
        let job = Job(title: "Compressing \(urls.count == 1 ? "“\(first.lastPathComponent)”" : "\(urls.count) items")", total: 1)
        jobs.append(job)
        Task.detached {
            let p = Process()
            if urls.count == 1 {
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, out.path]
            } else {
                p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                p.currentDirectoryURL = dir
                p.arguments = ["-r", "-y", "-q", out.path] + urls.map(\.lastPathComponent)
            }
            let ok = (try? p.run()) != nil && { p.waitUntilExit(); return p.terminationStatus == 0 }()
            await MainActor.run {
                self.jobs.removeAll { $0 === job }
                if ok { self.push(.created([out])) } else { Self.alert("Couldn't Compress", "The archive tool failed.") }
            }
        }
    }

    func undo() {
        guard let e = undoStack.popLast() else { return NSSound.beep() }
        if let back = reverse(e) { redoStack.append(back) }
    }

    func redo() {
        guard let e = redoStack.popLast() else { return NSSound.beep() }
        if let back = reverse(e) { push(back, clearingRedo: false) }
    }

    /// Does the opposite of `e` and returns the entry that would reverse that again (nil if it failed).
    private func reverse(_ e: UndoEntry) -> UndoEntry? {
        do {
            switch e {
            case let .moved(pairs):
                for p in pairs.reversed() { try fm.moveItem(at: p.to, to: p.from) }
                return .moved(pairs.map { (from: $0.to, to: $0.from) })
            case let .renamed(from, to):
                try fm.moveItem(at: to, to: from)
                return .renamed(from: to, to: from)
            case let .trashed(pairs):
                for p in pairs { try fm.moveItem(at: p.inTrash, to: p.original) }
                return .restored(pairs.map(\.original))
            case let .copied(urls), let .created(urls), let .restored(urls):
                var back: [(original: URL, inTrash: URL)] = []
                for u in urls {
                    var res: NSURL?
                    try fm.trashItem(at: u, resultingItemURL: &res)
                    if let r = res as URL? { back.append((u, r)) }
                }
                return .trashed(back)
            }
        } catch {
            Self.alert("Couldn't \(e.title == "Put Back" ? "Undo" : "Undo \(e.title)")", error.localizedDescription)
            return nil
        }
    }

    /// “name 2.ext”, or “name copy.ext” for duplicates; folders and packages keep their whole name as the base.
    nonisolated static func unique(_ url: URL, copy: Bool = false) -> URL {
        let fm = FileManager.default
        if !copy, !fm.fileExists(atPath: url.path) { return url }
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let plainFolder = (v?.isDirectory ?? url.hasDirectoryPath) && !(v?.isPackage ?? false)
        let ext = plainFolder ? "" : url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var n = 1
        while true {
            let name = copy ? (n == 1 ? "\(base) copy" : "\(base) copy \(n)") : "\(base) \(n + 1)"
            let c = dir.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
            if !fm.fileExists(atPath: c.path) { return c }
            n += 1
        }
    }

    nonisolated static func isPermission(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSCocoaErrorDomain, e.code == NSFileWriteNoPermissionError || e.code == NSFileReadNoPermissionError { return true }
        if e.domain == NSPOSIXErrorDomain, e.code == Int(EACCES) || e.code == Int(EPERM) { return true }
        return false
    }

    /// Moves `url` to the Trash through Finder, which asks for an administrator's password when needed. Returns where it went.
    static func finderTrash(_ url: URL) -> URL? {
        let path = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var err: NSDictionary?
        let out = NSAppleScript(source: "tell application \"Finder\" to POSIX path of (delete (POSIX file \"\(path)\" as alias) as alias)")?
            .executeAndReturnError(&err).stringValue
        if let out { return URL(fileURLWithPath: out) }
        // -128: the user cancelled the password prompt.
        if (err?[NSAppleScript.errorNumber] as? Int) != -128 {
            alert("Couldn't Move to Trash", "“\(url.lastPathComponent)” belongs to another user, and Finder couldn't move it. Allow Burrow to control Finder in System Settings › Privacy & Security › Automation, then try again.")
        }
        return nil
    }

    /// Checks set this so nothing pops up: alerts are collected, and a conflict skips.
    static var alertSink: ((String) -> Void)?

    static func alert(_ title: String, _ text: String) {
        if let sink = alertSink { return sink("\(title): \(text)") }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

enum Clipboard {
    static func copy(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    static func copyPaths(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    static func urls() -> [URL] {
        NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

enum Drops {
    /// File URLs out of a SwiftUI drop, delivered on the main thread.
    static func load(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let file = providers.filter { $0.canLoadObject(ofClass: NSURL.self) }
        guard !file.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for p in file {
            group.enter()
            _ = p.loadObject(ofClass: NSURL.self) { obj, _ in
                if let u = obj as? URL, u.isFileURL { lock.lock(); urls.append(u); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { if !urls.isEmpty { done(urls) } } }
        return true
    }
}
