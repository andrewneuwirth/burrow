import AppKit
import SwiftUI

extension URL {
    /// One spelling per folder (no trailing-slash or `..` differences), so equality and history work.
    var folder: URL { URL(fileURLWithPath: standardizedFileURL.path, isDirectory: true) }
}

struct FileItem: Identifiable, Hashable {
    static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey, .fileSizeKey,
                                         .contentModificationDateKey, .creationDateKey, .addedToDirectoryDateKey, .localizedTypeDescriptionKey, .tagNamesKey]
    let url: URL
    let name: String
    let opensAsFolder: Bool   // folders and links to folders; apps and other packages open like files
    let isPackage: Bool
    let target: URL           // where a symlink points; the item itself otherwise
    let size: Int64?
    let modified: Date?
    let created: Date?
    let added: Date?
    let tags: [String]
    let kind: String
    var id: URL { url }
    var sortSize: Int64 { size ?? -1 }
    var sortDate: Date { modified ?? .distantPast }

    init(url: URL) {
        let v = try? url.resourceValues(forKeys: Set(Self.keys))
        self.url = url
        name = url.lastPathComponent
        var dir = v?.isDirectory ?? false, pkg = v?.isPackage ?? false
        // Symlinks and Finder aliases both open their original (an alias handed to NSWorkspace would open Finder).
        if v?.isSymbolicLink == true || v?.isAliasFile == true {
            target = v?.isAliasFile == true ? ((try? URL(resolvingAliasFileAt: url)) ?? url) : url.resolvingSymlinksInPath()
            let r = try? target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            dir = r?.isDirectory ?? false
            pkg = r?.isPackage ?? false
        } else {
            target = url
        }
        opensAsFolder = dir && !pkg
        isPackage = pkg
        size = opensAsFolder || pkg ? nil : v?.fileSize.map(Int64.init)
        modified = v?.contentModificationDate
        created = v?.creationDate
        added = v?.addedToDirectoryDate
        tags = v?.tagNames ?? []
        kind = v?.localizedTypeDescription ?? ""
    }
}

enum SearchScope: String, CaseIterable { case folder, everywhere }

/// What was picked for which typed text (Pier's SearchUsage), so a search learns your usual answer.
@MainActor enum SearchMemory {
    static var usage = SearchUsage.load()
    static func picked(_ path: String, for query: String) { usage.record(path, query: query); usage.save() }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case icons, list, columns, gallery
    var id: String { rawValue }
    var symbol: String {
        ["icons": "square.grid.2x2", "list": "list.bullet", "columns": "rectangle.split.3x1", "gallery": "rectangle.bottomthird.inset.filled"][rawValue]!
    }
    var title: String { rawValue.capitalized }
}

/// One window (or tab): one or two panes side by side.
@MainActor @Observable
final class BrowserModel {
    var panes: [PaneModel]
    var activeIndex = 0
    var findTick = 0   // ⌘F: the window focuses its search field when this changes
    var palette = false   // ⌘K
    @ObservationIgnored weak var window: NSWindow?

    init(url: URL) {
        panes = [PaneModel(url: url)]
        panes[0].owner = self
    }

    var active: PaneModel { panes[min(activeIndex, panes.count - 1)] }
    var other: PaneModel? { panes.count == 2 ? panes[1 - min(activeIndex, 1)] : nil }

    func toggleSplit() {
        if panes.count == 1 {
            let p = PaneModel(url: active.url, viewMode: active.viewMode)
            p.owner = self
            panes.append(p)
            activeIndex = 1
        } else {
            let gone = 1 - activeIndex
            panes[gone].stop()
            panes.remove(at: gone)
            activeIndex = 0
        }
        updateWindow()
    }

    func activate(_ p: PaneModel) {
        guard let i = panes.firstIndex(where: { $0 === p }), i != activeIndex else { return }
        activeIndex = i
        updateWindow()
    }

    /// F5 / F6: the active pane's selection into the other pane's folder.
    func transferToOther(copy: Bool) {
        guard let o = other, !active.selection.isEmpty else { return NSSound.beep() }
        FileOps.shared.transfer(Array(active.selection), to: o.url, copy: copy)
    }

    func updateWindow() {
        window?.title = FileManager.default.displayName(atPath: active.url.path)
        window?.representedURL = active.url
    }
}

@MainActor @Observable
final class PaneModel: Identifiable {
    private(set) var url: URL
    private(set) var items: [FileItem] = [] { didSet { rebuild() } }
    private(set) var visible: [FileItem] = []
    var selection: Set<URL> = []
    var viewMode: ViewMode { didSet { if viewMode == .columns { columnRoot = url } } }
    @ObservationIgnored private var previousMode = ViewMode.list
    /// A tool page, a workspace or a tag shown in place of the folder (nil: the folder).
    private(set) var page: Page?
    /// Column view's first column; going deeper adds columns, leaving it starts again from the new folder.
    var columnRoot: URL
    /// Group without moving anything (Smart Downloads' "by kind or date added").
    var groupBy = GroupBy.none { didSet { rebuild() } }
    private(set) var groups: [(title: String, items: [FileItem])] = []
    /// The kind tab picked (nil: all), and how many of each kind there are before it applies.
    var kindFilter: Bucket? { didSet { rebuild() } }
    private(set) var kindCounts: [(bucket: Bucket, count: Int)] = []
    var baseItems: [FileItem] { searchResults ?? items }
    private(set) var git: GitInfo?
    var sortOrder = [KeyPathComparator(\FileItem.name, comparator: .localizedStandard)] { didSet { rankOrder = false; rebuild() } }
    var filter = "" {
        didSet {
            // On a workspace or tag page the field filters that list; elsewhere it searches.
            if page?.listsFiles == true { return rebuild() }
            if filter != searchQuery { searchResults = nil }
            rebuild()
            scheduleSearch()
        }
    }
    var scope = SearchScope.folder { didSet { searchQuery = ""; scheduleSearch() } }
    private(set) var searchResults: [FileItem]? { didSet { rebuild() } }
    private(set) var searchQuery = ""
    private(set) var searchTotal = 0
    @ObservationIgnored private var rankOrder = false   // search results stay in rank order until a column is clicked
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    private(set) var searching = false
    private(set) var loading = false
    private(set) var error: String?
    private(set) var freeSpace: Int64?
    var preview: URL?
    var renaming: URL?
    var editingPath = false
    var tidying = false
    var gridColumns = 1
    var cursor: URL?
    private(set) var back: [URL] = []
    private(set) var forward: [URL] = []
    @ObservationIgnored weak var owner: BrowserModel?
    @ObservationIgnored private var pendingSelect: Set<String>?
    @ObservationIgnored private var anchor: URL?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var reloadWork: DispatchWorkItem?
    @ObservationIgnored private var loadToken = 0

    init(url: URL, viewMode: ViewMode? = nil) {
        self.url = url.folder
        self.viewMode = viewMode ?? AppSettings.shared.viewMode
        columnRoot = url.folder
        groupBy = url.folder == Tidy.downloads ? .kind : .none
        load()
        watch()
    }

    var selectedItems: [FileItem] { visible.filter { selection.contains($0.url) } }

    // MARK: Navigation

    func go(_ target: URL, select: [URL] = [], record: Bool = true) {
        let t = target.folder
        pendingSelect = select.isEmpty ? nil : Set(select.map(\.standardizedFileURL.path))
        guard t != url else { return load() }
        if record { back.append(url); forward.removeAll() }
        url = t
        page = nil
        kindFilter = nil
        AppSettings.shared.noteRecent(t)
        if viewMode != .columns || !t.path.hasPrefix(columnRoot.path) { columnRoot = t }
        groupBy = t == Tidy.downloads ? .kind : .none
        selection = []
        filter = ""
        searchResults = nil
        renaming = nil
        preview = nil
        editingPath = false
        load()
        watch()
        owner?.updateWindow()
        AppSettings.shared.lastFolder = t
    }

    func goBack() {
        if page != nil { return closePage() }
        guard let p = back.popLast() else { return NSSound.beep() }
        forward.append(url)
        go(p, select: [url], record: false)
    }

    func goForward() {
        guard let n = forward.popLast() else { return NSSound.beep() }
        back.append(url)
        go(n, record: false)
    }

    func up() {
        if page != nil { return closePage() }
        guard url.path != "/" else { return NSSound.beep() }
        go(url.deletingLastPathComponent(), select: [url])
    }

    /// A typed path (⌘L): folders open, files open their folder with the file selected.
    @discardableResult func goTyped(_ text: String) -> Bool {
        var path = (text.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = url.appendingPathComponent(path).path }
        let target = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir) else { NSSound.beep(); return false }
        if isDir.boolValue && !FileItem(url: target).isPackage { go(target) } else { go(target.deletingLastPathComponent(), select: [target]) }
        return true
    }

    func open(_ targets: [FileItem]? = nil) {
        let list = targets ?? selectedItems
        if searchResults != nil { list.forEach { SearchMemory.picked($0.url.path, for: searchQuery) } }
        if list.count == 1, list[0].opensAsFolder { return go(list[0].target) }
        for f in list {
            if f.opensAsFolder { Windows.shared.open(f.target, asTabOf: owner?.window) }
            else if AppSettings.shared.openMarkdownHere, ["md", "markdown", "mdown"].contains(f.url.pathExtension.lowercased()) { MarkdownWindow.open(f.url) }
            else { NSWorkspace.shared.open(f.url) }
        }
    }

    /// ⌘1–⌘4: switch to a view; the same key again goes back to the one before.
    func show(_ mode: ViewMode) {
        if viewMode == mode {
            viewMode = previousMode == mode ? (mode == .list ? .icons : .list) : previousMode
        } else {
            previousMode = viewMode
            viewMode = mode
        }
    }

    // MARK: Pages (tools, workspaces, tags)

    func showPage(_ p: Page) {
        owner?.activate(self)
        page = p
        kindFilter = nil
        selection = []
        renaming = nil
        preview = nil
        filter = ""
        switch p {
        case let .workspace(id):
            let ws = Workspaces.shared.list.first { $0.id == id }
            searchQuery = ""
            rankOrder = false
            searchResults = (ws?.paths ?? []).filter { FileManager.default.fileExists(atPath: $0) }.map { FileItem(url: URL(fileURLWithPath: $0)) }
        case let .tag(name):
            searchResults = []
            searching = true
            Task.detached(priority: .userInitiated) {
                let found = Self.mdfind("kMDItemUserTags == '\(name.replacingOccurrences(of: "'", with: "\\'"))'")
                await MainActor.run {
                    guard self.page == p else { return }
                    self.searching = false
                    self.searchResults = found
                }
            }
        default:
            searchResults = nil
        }
        owner?.updateWindow()
    }

    func closePage() {
        page = nil
        searchResults = nil
        searching = false
        load()
        owner?.updateWindow()
    }

    /// Refresh a workspace page after its list changed.
    func reloadWorkspace() { if case .workspace = page, let p = page { showPage(p) } }

    nonisolated static func mdfind(_ query: String) -> [FileItem] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = [query]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(2000).map { FileItem(url: URL(fileURLWithPath: String($0))) }
    }

    // MARK: Loading

    func load() {
        let url = self.url, hidden = AppSettings.shared.showHidden
        loadToken += 1
        let token = loadToken
        loading = true
        Task.detached(priority: .userInitiated) {
            let result = Result { try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: FileItem.keys,
                                                                             options: hidden ? [] : [.skipsHiddenFiles]) }
                // /Applications/Utilities is an empty leftover; the real utilities live in /System/Applications/Utilities.
                .map { $0.filter { $0.path != "/Applications/Utilities" }.map(FileItem.init) }
            let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
            let git = GitInfo.read(url)
            await MainActor.run {
                guard token == self.loadToken else { return }
                self.loading = false
                self.freeSpace = free
                self.git = git
                switch result {
                case let .success(items): self.error = nil; self.items = items
                case let .failure(e): self.error = e.localizedDescription; self.items = []
                }
                let paths = Set(self.items.map(\.url.path))
                if let p = self.pendingSelect {
                    self.selection = Set(self.items.filter { p.contains($0.url.path) }.map(\.url))
                    self.cursor = self.selection.first
                    self.pendingSelect = nil
                } else {
                    self.selection = self.selection.filter { paths.contains($0.path) }
                }
            }
        }
    }

    private func rebuild() {
        var list = searchResults ?? items
        if searchResults == nil || page?.listsFiles == true, !filter.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(filter) } }
        let present = Dictionary(grouping: list, by: Bucket.of).mapValues(\.count)
        kindCounts = Bucket.allCases.compactMap { b in present[b].map { (b, $0) } }
        if let k = kindFilter { list = list.filter { Bucket.of($0) == k } }
        if searchResults != nil, rankOrder { visible = list; groups = [("", list)]; return }
        list.sort(using: sortOrder)
        if AppSettings.shared.foldersFirst { list = list.filter(\.opensAsFolder) + list.filter { !$0.opensAsFolder } }
        guard groupBy != .none, searchResults == nil else { visible = list; groups = [("", list)]; return }
        // Grouped: the groups in a fixed order, each keeping the sort; `visible` follows the shown order so arrows match.
        let keyed = list.map { (groupBy.group($0), $0) }
        let order = groupBy.order
        groups = order.compactMap { title in
            let members = keyed.filter { $0.0 == title }.map(\.1)
            return members.isEmpty ? nil : (title, members)
        }
        visible = groups.flatMap(\.items)
    }

    func resort() { rebuild() }

    /// Live refresh: the folder's own vnode reports entries added, removed or renamed.
    private func watch() {
        watcher?.cancel()
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !FileManager.default.fileExists(atPath: self.url.path) { return self.up() }
                self.reloadWork?.cancel()
                let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.load() } }
                self.reloadWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        watcher = src
    }

    func stop() { watcher?.cancel(); watcher = nil }

    // MARK: Search

    /// Pier's search: Spotlight finds names containing every typed word, then FileRank orders them (how the
    /// name fits, documents before code, recent, Downloads first, your past picks) and drops the noise
    /// (node_modules, caches, ~/Library, insides of apps). Runs 250 ms after typing stops; Return runs it now.
    private func scheduleSearch(delay: Duration = .milliseconds(250)) {
        searchTask?.cancel()
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { searching = false; return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            searching = true
            // shortcut: FileRank drops ~/Library and other "noise", so This Folder inside them finds nothing; widen keep() if that bites
            let found = await FileQuery.ranked(q, in: scope == .folder ? url.path : nil, usage: SearchMemory.usage)
            guard !Task.isCancelled, filter.trimmingCharacters(in: .whitespaces) == q else { return }
            searching = false
            guard let found else { return }
            searchQuery = q
            searchTotal = found.total
            rankOrder = true
            searchResults = found.rows.map { FileItem(url: URL(fileURLWithPath: $0.path)) }
        }
    }

    func deepSearch() { scheduleSearch(delay: .zero) }

    func clearSearch() { searchTask?.cancel(); searching = false; filter = ""; searchQuery = ""; searchResults = nil }

    // MARK: Selection

    func click(_ item: FileItem) {
        owner?.activate(self)
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(item.url) { selection.remove(item.url) } else { selection.insert(item.url) }
        } else if flags.contains(.shift), let a = anchor, let i = visible.firstIndex(where: { $0.url == a }),
                  let j = visible.firstIndex(where: { $0.url == item.url }) {
            selection = Set(visible[min(i, j)...max(i, j)].map(\.url))
            return
        } else {
            selection = [item.url]
        }
        anchor = item.url
        cursor = item.url
    }

    /// Arrow keys in the icon and gallery views (the list view's table does its own).
    func moveCursor(_ dx: Int, _ dy: Int, extend: Bool) {
        guard !visible.isEmpty else { return }
        let step = viewMode == .icons ? dx + dy * max(gridColumns, 1) : dx + dy
        let now = (cursor ?? selectedItems.last?.url).flatMap { c in visible.firstIndex { $0.url == c } }
        let next = now.map { min(max($0 + step, 0), visible.count - 1) } ?? 0
        let u = visible[next].url
        if extend { selection.insert(u) } else { selection = [u]; anchor = u }
        cursor = u
        if preview != nil { preview = u }
    }

    @ObservationIgnored private var typed = ""
    @ObservationIgnored private var typedAt = Date.distantPast
    func typeSelect(_ s: String) {
        if Date().timeIntervalSince(typedAt) > 1 { typed = "" }
        typed += s.lowercased()
        typedAt = Date()
        guard let hit = visible.first(where: { $0.name.lowercased().hasPrefix(typed) }) else { return }
        selection = [hit.url]
        anchor = hit.url
        cursor = hit.url
    }

    func selectAll() { selection = Set(visible.map(\.url)) }

    func togglePreview() { preview = preview == nil ? (selectedItems.first ?? visible.first)?.url : nil }

    // MARK: Actions

    func startRename() {
        guard selection.count == 1 else { return NSSound.beep() }
        renaming = selection.first
    }

    func commitRename(_ item: FileItem, _ name: String) {
        guard renaming == item.url else { return }
        renaming = nil
        if let new = FileOps.shared.rename(item.url, to: name) { pendingSelect = [new.path]; load() }
    }

    func newFolder() {
        guard let u = FileOps.shared.newFolder(in: url) else { return }
        pendingSelect = [u.path]
        renaming = URL(fileURLWithPath: u.path, isDirectory: true)
        load()
    }

    func paste(move: Bool) {
        let urls = Clipboard.urls()
        guard !urls.isEmpty else { return NSSound.beep() }
        FileOps.shared.transfer(urls, to: url, copy: !move)
    }
}

@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    var showHidden: Bool { didSet { d.set(showHidden, forKey: "showHidden"); Windows.shared.reloadAll() } }
    var foldersFirst: Bool { didSet { d.set(foldersFirst, forKey: "foldersFirst"); Windows.shared.resortAll() } }
    var viewMode: ViewMode { didSet { d.set(viewMode.rawValue, forKey: "viewMode") } }
    var startPath: String { didSet { d.set(startPath, forKey: "startPath") } }
    var favorites: [URL] { didSet { d.set(favorites.map(\.path), forKey: "favorites") } }
    var shelf: [URL] { didSet { d.set(shelf.map(\.path), forKey: "shelf") } }
    var shelfOnDrag: Bool { didSet { d.set(shelfOnDrag, forKey: "shelfOnDrag") } }
    var openMarkdownHere: Bool { didSet { d.set(openMarkdownHere, forKey: "openMarkdownHere") } }
    var iconSize: IconSize { didSet { d.set(iconSize.rawValue, forKey: "iconSize") } }
    var folderTint: Int { didSet { d.set(folderTint, forKey: "folderTint") } }
    private(set) var recents: [String]

    func noteRecent(_ u: URL) {
        recents.removeAll { $0 == u.path }
        recents.insert(u.path, at: 0)
        recents = Array(recents.prefix(25))
        d.set(recents, forKey: "recents")
    }
    var lastFolder: URL? {
        get { d.string(forKey: "lastFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { d.set(newValue?.path, forKey: "lastFolder") }
    }

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        showHidden = d.bool(forKey: "showHidden")
        foldersFirst = d.object(forKey: "foldersFirst") as? Bool ?? true
        viewMode = ViewMode(rawValue: d.string(forKey: "viewMode") ?? "") ?? .list
        startPath = d.string(forKey: "startPath") ?? home.path
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let defaults = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Desktop"),
                        home.appendingPathComponent("Documents"), home.appendingPathComponent("Downloads"), home, home.appendingPathComponent("Developer")]
            + (FileManager.default.fileExists(atPath: icloud.path) ? [icloud] : [])
        shelfOnDrag = d.object(forKey: "shelfOnDrag") as? Bool ?? true
        openMarkdownHere = d.object(forKey: "openMarkdownHere") as? Bool ?? true
        iconSize = IconSize(rawValue: d.string(forKey: "iconSize") ?? "") ?? .medium
        folderTint = d.object(forKey: "folderTint") as? Int ?? 0
        recents = d.stringArray(forKey: "recents") ?? []
        shelf = (d.stringArray(forKey: "shelf")?.map { URL(fileURLWithPath: $0) }
                 ?? ["Desktop", "Documents", "Downloads"].map { home.appendingPathComponent($0) }).map(\.folder)
        favorites = (d.stringArray(forKey: "favorites")?.map { URL(fileURLWithPath: $0) } ?? defaults)
            .filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.folder)
    }

    var startFolder: URL { URL(fileURLWithPath: startPath).folder }
}

// MARK: Grouping (Smart Downloads)

enum GroupBy: String, CaseIterable, Identifiable {
    case none, kind, dateAdded
    var id: String { rawValue }
    var title: String { ["none": "None", "kind": "Kind", "dateAdded": "Date Added"][rawValue]! }

    var order: [String] {
        self == .kind ? Bucket.allCases.map(\.title) : ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "Earlier"]
    }

    func group(_ item: FileItem, now: Date = Date()) -> String {
        guard self == .dateAdded else { return Bucket.of(item).title }
        guard let d = item.added ?? item.created else { return "Earlier" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let days = now.timeIntervalSince(d) / 86_400
        return days < 7 ? "Previous 7 Days" : days < 30 ? "Previous 30 Days" : "Earlier"
    }
}

/// What a file is, for grouping and for Tidy's folders.
enum Bucket: String, CaseIterable {
    case folders, documents, images, videos, audio, installers, archives, code, other

    var title: String { rawValue.capitalized }

    static func of(_ item: FileItem) -> Bucket {
        item.opensAsFolder ? .folders : forExtension(item.url.pathExtension)
    }

    static func forExtension(_ raw: String) -> Bucket {
        let ext = raw.lowercased()
        if ["dmg", "pkg", "mpkg", "app"].contains(ext) { return .installers }
        if ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"].contains(ext) { return .archives }
        if ["pdf", "doc", "docx", "pages", "key", "ppt", "pptx", "xls", "xlsx", "numbers", "txt", "md", "rtf", "epub", "csv"].contains(ext) { return .documents }
        if ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "svg", "bmp", "raw", "psd"].contains(ext) { return .images }
        if ["mp4", "mov", "m4v", "mkv", "avi", "webm"].contains(ext) { return .videos }
        if ["mp3", "m4a", "wav", "aac", "flac", "aiff", "ogg"].contains(ext) { return .audio }
        if ["swift", "py", "js", "ts", "tsx", "jsx", "json", "jsonl", "html", "css", "sh", "rb", "go", "rs", "java", "c", "cpp", "h", "ipynb", "yml", "yaml", "toml", "xml", "sql"].contains(ext) { return .code }
        return .other
    }
}

// MARK: Git (read-only)

struct GitInfo: Equatable {
    let branch: String
    let changes: Int

    /// `git status` for the folder, nil outside a repository (or without git). Never writes anything.
    static func read(_ url: URL) -> GitInfo? {
        let git = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: git) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", url.path, "status", "--porcelain=v1", "-b", "--untracked-files=normal"]
        p.environment = ["GIT_OPTIONAL_LOCKS": "0"]   // status must not take the index lock
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        guard let head = lines.first, head.hasPrefix("## ") else { return nil }
        var branch = String(head.dropFirst(3))
        if let dots = branch.range(of: "...") { branch = String(branch[..<dots.lowerBound]) }
        branch = branch.replacingOccurrences(of: "No commits yet on ", with: "")
        return GitInfo(branch: branch, changes: lines.count - 1)
    }
}


// MARK: Pages, workspaces, tags

enum Page: Hashable {
    case workspace(UUID), tag(String), bookmarks, clean, installed, agents, about

    @MainActor var title: String {
        switch self {
        case let .workspace(id): Workspaces.shared.list.first { $0.id == id }?.name ?? "Workspace"
        case let .tag(name): name
        case .bookmarks: "Bookmarks"
        case .clean: "Free Up Space"
        case .installed: "Installed"
        case .agents: "AI Agents"
        case .about: "About This Mac"
        }
    }

    var symbol: String {
        switch self {
        case .workspace: "square.stack.3d.up"
        case .tag: "tag"
        case .bookmarks: "bookmark.fill"
        case .clean: "gauge.with.dots.needle.33percent"
        case .installed: "shippingbox.fill"
        case .agents: "cpu.fill"
        case .about: "laptopcomputer"
        }
    }

    /// Workspaces and tags list files (with the folder views and file actions); tools draw their own page.
    var listsFiles: Bool {
        switch self { case .workspace, .tag: true; default: false }
    }

    static let tools: [Page] = [.bookmarks, .clean, .installed, .agents, .about]
}

/// A project's files and folders from anywhere (Mac, iCloud Drive, Dropbox, external drives) on one page.
/// Nothing is copied or moved: a workspace only remembers paths.
struct Workspace: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var paths: [String] = []
    var tint: Int?
}

@MainActor @Observable
final class Workspaces {
    static let shared = Workspaces()
    private(set) var list: [Workspace]
    private static let key = "workspaces"

    private init() {
        list = (UserDefaults.standard.data(forKey: Self.key)).flatMap { try? JSONDecoder().decode([Workspace].self, from: $0) } ?? []
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: Self.key)
        Windows.shared.panes.forEach { $0.reloadWorkspace() }
    }

    @discardableResult func create(_ name: String, with urls: [URL] = []) -> Workspace {
        let ws = Workspace(name: name, paths: urls.map(\.path))
        list.append(ws)
        save()
        return ws
    }

    func add(_ urls: [URL], to id: UUID) {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].paths += urls.map(\.path).filter { !list[i].paths.contains($0) }
        save()
    }

    func remove(_ urls: [URL], from id: UUID) {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        let gone = Set(urls.map(\.path))
        list[i].paths.removeAll { gone.contains($0) }
        save()
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = list.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        list[i].name = name
        save()
    }

    func setTint(_ id: UUID, _ tint: Int) {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].tint = tint
        save()
    }

    func tint(_ ws: Workspace) -> Color {
        let i = ws.tint ?? (list.firstIndex { $0.id == ws.id } ?? 0)
        return Palette.tints[i % Palette.tints.count]
    }

    func delete(_ id: UUID) { list.removeAll { $0.id == id }; save() }
    func move(from: IndexSet, to: Int) { list.move(fromOffsets: from, toOffset: to); save() }

    /// Asks for a name (an NSAlert with a text field); nil when cancelled.
    static func askName(_ title: String, initial: String = "") -> String? {
        let a = NSAlert()
        a.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        a.accessoryView = field
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

/// Finder tags: the seven standard colours, written with the same resource key Finder uses.
enum Tags {
    static let standard: [(name: String, color: Color)] = [("Red", .red), ("Orange", .orange), ("Yellow", .yellow), ("Green", .green),
                                                            ("Blue", .blue), ("Purple", .purple), ("Gray", .gray)]

    static func color(_ name: String) -> Color { standard.first { $0.name == name }?.color ?? .secondary }

    /// Adds the tag to all of them, or takes it off all of them if every one already has it.
    @MainActor static func toggle(_ name: String, on items: [FileItem]) {
        let allHave = items.allSatisfy { $0.tags.contains(name) }
        for item in items {
            var tags = item.tags.filter { $0 != name }
            if !allHave { tags.append(name) }
            do { try (item.url as NSURL).setResourceValue(tags, forKey: .tagNamesKey) }
            catch { FileOps.alert("Couldn't Tag “\(item.name)”", error.localizedDescription) }
        }
        Windows.shared.reloadAll()
    }
}
