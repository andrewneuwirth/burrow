import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Model and storage

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var url: URL
    var title: String
    var summary: String?
    var imageURL: URL?
    var site: String
    var added = Date()
    var collection = Bookmarks.unsorted
}

@MainActor
final class BookmarkStore: ObservableObject {
    static let shared = BookmarkStore()
    @Published var items: [Bookmark] = []
    /// Collections made with "+ New Collection" that hold nothing yet; not saved until something moves in.
    @Published var empty: [String] = []

    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Burrow")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bookmarks.json")
    }()

    private init() {
        guard let data = try? Data(contentsOf: file) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        items = (try? dec.decode([Bookmark].self, from: data)) ?? []
    }

    var collections: [String] {
        var seen = Set<String>()
        return ([Bookmarks.unsorted] + items.map(\.collection).sorted() + empty).filter { seen.insert($0).inserted }
    }

    func save() {
        empty.removeAll { name in items.contains { $0.collection == name } }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(items) else { return }
        do { try data.write(to: file, options: .atomic) } catch { NSLog("Burrow bookmarks save failed: \(error)") }
    }

    func update(_ id: UUID, _ change: (inout Bookmark) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        save()
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }
}

// MARK: Adding

@MainActor
enum Bookmarks {
    nonisolated static let unsorted = "Unsorted"

    private static let browsers: [String: String] = [
        "com.apple.Safari": "tell application id \"com.apple.Safari\" to return URL of front document",
        "com.google.Chrome": "tell application id \"com.google.Chrome\" to return URL of active tab of front window",
        "company.thebrowser.Browser": "tell application id \"company.thebrowser.Browser\" to return URL of active tab of front window",
        "com.brave.Browser": "tell application id \"com.brave.Browser\" to return URL of active tab of front window",
        "com.microsoft.edgemac": "tell application id \"com.microsoft.edgemac\" to return URL of active tab of front window",
    ]

    static func addFromBrowserOrClipboard(collection: String? = nil) {
        if let url = frontBrowserURL() ?? clipboardURL() { add(url, collection: collection) } else { NSSound.beep() }
    }

    static func add(_ url: URL, collection: String? = nil) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return NSSound.beep() }
        let store = BookmarkStore.shared
        if let existing = store.items.first(where: { $0.url == url }) {
            if let collection { store.update(existing.id) { $0.collection = collection } }
            return
        }
        let host = url.host()?.replacingOccurrences(of: "www.", with: "", options: .anchored) ?? url.absoluteString
        let mark = Bookmark(url: url, title: host, site: host, collection: collection ?? unsorted)
        store.items.insert(mark, at: 0)
        store.save()
        Task {
            guard let meta = await fetchMeta(url) else { return }
            store.update(mark.id) {
                if let t = meta.title, !t.isEmpty { $0.title = t }
                $0.summary = meta.summary
                $0.imageURL = meta.image
            }
        }
    }

    /// The front tab of the browser whose window is frontmost on screen (Burrow itself is frontmost when its button is clicked).
    private static func frontBrowserURL() -> URL? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in windows where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { continue }
            if id == Bundle.main.bundleIdentifier { continue }
            guard let source = browsers[id] else { return nil }
            var err: NSDictionary?
            let out = NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue
            if let err { NSLog("Burrow bookmark AppleScript failed: \(err)") }
            return out.flatMap(URL.init(string:)).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
        }
        return nil
    }

    private static func clipboardURL() -> URL? {
        let pb = NSPasteboard.general
        if let url = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first(where: { !$0.isFileURL }) { return url }
        return pb.string(forType: .string).flatMap(webURL)
    }

    nonisolated static func webURL(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t), let s = url.scheme?.lowercased(), s == "http" || s == "https", url.host() != nil else { return nil }
        return url
    }

    // MARK: Page metadata

    struct Meta { var title: String?, summary: String?, image: URL? }

    nonisolated static func fetchMeta(_ url: URL) async -> Meta? {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return nil }
        let html = String(decoding: data.prefix(400_000), as: UTF8.self)
        let head = html.range(of: "</head>", options: .caseInsensitive).map { String(html[..<$0.lowerBound]) } ?? html
        return parseMeta(head, base: response.url ?? url)
    }

    nonisolated static func parseMeta(_ head: String, base: URL) -> Meta {
        var tags: [String: String] = [:]
        for m in head.matches(of: try! Regex("(?is)<meta\\s[^>]*>")) {
            let tag = String(head[m.range])
            func attr(_ name: String) -> String? {
                (try? Regex("(?is)\\b\(name)\\s*=\\s*(\"[^\"]*\"|'[^']*')")).flatMap { tag.firstMatch(of: $0) }
                    .flatMap { $0.output[1].substring }.map { String($0.dropFirst().dropLast()) }
            }
            if let key = (attr("property") ?? attr("name"))?.lowercased(), let content = attr("content"), tags[key] == nil {
                tags[key] = entities(content)
            }
        }
        let title = head.firstMatch(of: try! Regex("(?is)<title[^>]*>(.*?)</title>"))
            .flatMap { $0.output[1].substring }.map { entities(String($0)) }
        let image = (tags["og:image"] ?? tags["twitter:image"]).flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
        return Meta(title: tags["og:title"] ?? title, summary: tags["og:description"] ?? tags["description"] ?? tags["twitter:description"], image: image)
    }

    nonisolated private static func entities(_ s: String) -> String {
        var s = s
        for (k, v) in [("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

// MARK: Page

enum BookmarkStyle: String, CaseIterable {
    case grid = "Grid", headlines = "Headlines", masonry = "Masonry", list = "List"
    var symbol: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .headlines: "text.justify.left"
        case .masonry: "rectangle.3.group"
        case .list: "list.bullet"
        }
    }
}

struct BookmarksPage: View {
    @ObservedObject private var store = BookmarkStore.shared
    @AppStorage("bookmarksStyle") private var style = BookmarkStyle.grid
    @State private var collection: String?   // nil = All
    @State private var query = ""
    @State private var naming = false
    @State private var newName = ""
    @State private var targeted = false

    private var shown: [Bookmark] {
        store.items.filter { b in
            (collection == nil || b.collection == collection)
                && (query.isEmpty || [b.title, b.site, b.summary ?? "", b.url.absoluteString].contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if shown.isEmpty {
                ContentUnavailableView(store.items.isEmpty ? "No Bookmarks" : "Nothing Here", systemImage: "bookmark",
                                       description: Text("Drop a link here, or use Add Current Tab."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { content.padding(16) }
            }
        }
        .background(targeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .onDrop(of: [.url, .plainText], isTargeted: $targeted, perform: drop)
        .alert("New Collection", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !store.collections.contains(name) { store.empty.append(name) }
                if !name.isEmpty { collection = name }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bookmarks").font(.title2.bold())
                Spacer()
                TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                Picker("View", selection: $style) {
                    ForEach(BookmarkStyle.allCases, id: \.self) { Image(systemName: $0.symbol).help($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button { Bookmarks.addFromBrowserOrClipboard(collection: collection) } label: { Label("Add Current Tab", systemImage: "plus") }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("All", nil)
                    ForEach(store.collections, id: \.self) { chip($0, $0) }
                    Button { newName = ""; naming = true } label: { Label("New Collection", systemImage: "plus") }
                        .buttonStyle(.borderless).padding(.horizontal, 6)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func chip(_ title: String, _ value: String?) -> some View {
        Button(title) { collection = value }
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(collection == value ? Color.accentColor : Color.secondary.opacity(0.15)))
            .foregroundStyle(collection == value ? Color.white : Color.primary)
    }

    @ViewBuilder private var content: some View {
        switch style {
        case .grid:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                ForEach(shown) { b in card(b, summary: false).frame(height: 210, alignment: .top) }
            }
        case .headlines:
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { b in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(b.title).font(.title3.weight(.semibold)).lineLimit(2)
                        Text("\(b.site) · \(b.added.formatted(date: .abbreviated, time: .omitted))").font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(BookmarkActions(mark: b))
                    Divider()
                }
            }
        case .masonry:
            GeometryReader { geo in
                let n = min(4, max(2, Int(geo.size.width / 240)))
                HStack(alignment: .top, spacing: 14) {
                    ForEach(0..<n, id: \.self) { col in
                        // shortcut: round-robin columns, not height-balanced; fine until columns look uneven
                        LazyVStack(spacing: 14) {
                            ForEach(Array(shown.enumerated()).filter { $0.offset % n == col }.map(\.element)) { card($0, summary: true) }
                        }
                    }
                }
            }
            .frame(minHeight: 400) // GeometryReader in a ScrollView has no intrinsic height
        case .list:
            LazyVStack(spacing: 0) {
                ForEach(shown) { b in
                    HStack(spacing: 8) {
                        thumb(b).frame(width: 28, height: 20).clipShape(RoundedRectangle(cornerRadius: 3))
                        Text(b.title).lineLimit(1)
                        Spacer()
                        Text(b.site).foregroundStyle(.secondary).lineLimit(1)
                        Text(b.added.formatted(date: .numeric, time: .omitted)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.vertical, 5)
                    .modifier(BookmarkActions(mark: b))
                    Divider()
                }
            }
        }
    }

    private func card(_ b: Bookmark, summary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if b.imageURL != nil || !summary {
                thumb(b).frame(height: 120).frame(maxWidth: .infinity).clipped()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(b.title).font(.headline).lineLimit(summary ? 4 : 2)
                if summary, let s = b.summary { Text(s).font(.callout).foregroundStyle(.secondary).lineLimit(6) }
                Text(b.site).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background).shadow(color: .black.opacity(0.12), radius: 3, y: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .modifier(BookmarkActions(mark: b))
    }

    private func thumb(_ b: Bookmark) -> some View {
        // AsyncImage goes through URLSession.shared, whose URLCache keeps recently loaded images in memory.
        AsyncImage(url: b.imageURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.12)
                    Text(b.site.prefix(1).uppercased()).font(.title.bold()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        let target = collection
        var took = false
        for p in providers {
            if p.canLoadObject(ofClass: URL.self) {
                took = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in Bookmarks.add(url, collection: target) }
                }
            } else if p.canLoadObject(ofClass: String.self) {
                took = true
                _ = p.loadObject(ofClass: String.self) { text, _ in
                    guard let url = text.flatMap(Bookmarks.webURL) else { return }
                    Task { @MainActor in Bookmarks.add(url, collection: target) }
                }
            }
        }
        return took
    }
}

private struct BookmarkActions: ViewModifier {
    let mark: Bookmark
    @ObservedObject private var store = BookmarkStore.shared

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { NSWorkspace.shared.open(mark.url) }
            .help(mark.url.absoluteString)
            .contextMenu {
                Button("Open") { NSWorkspace.shared.open(mark.url) }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([mark.url as NSURL])
                    NSPasteboard.general.setString(mark.url.absoluteString, forType: .string)
                }
                Menu("Move to Collection") {
                    ForEach(store.collections, id: \.self) { name in
                        Button(name) { store.update(mark.id) { $0.collection = name } }.disabled(name == mark.collection)
                    }
                }
                Divider()
                Button("Delete", role: .destructive) { store.delete(mark.id) }
            }
    }
}
