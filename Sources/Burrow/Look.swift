import AppKit
import SwiftUI

// Burrow's own look: glass folders (not the system's blue), files as cards with a real preview, folder tiles,
// kind tabs and the workspace header. Apps and files keep their own icons.

enum Palette {
    static let slate = Color(red: 0.42, green: 0.49, blue: 0.58)
    static let tints: [Color] = [slate, Color(red: 0.24, green: 0.52, blue: 0.85), .teal, .green, .orange, .pink, .red, .indigo,
                                 Color(white: 0.45)]
    static let names = ["Slate", "Blue", "Teal", "Green", "Orange", "Pink", "Red", "Indigo", "Graphite"]

    /// The folder colour picked in Settings (Slate unless changed).
    @MainActor static var folder: Color { tints[min(AppSettings.shared.folderTint, tints.count - 1)] }

    /// A folder takes its Finder tag's colour, else the folder colour.
    @MainActor static func tint(_ tags: [String]) -> Color {
        tags.lazy.compactMap { t in Tags.standard.first { $0.name == t }?.color }.first ?? folder
    }
}

enum IconSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var letter: String { String(rawValue.prefix(1)).uppercased() }
    var glyph: CGFloat { [56, 76, 100][index] }
    var card: CGFloat { [170, 220, 290][index] }
    private var index: Int { Self.allCases.firstIndex(of: self)! }
    func step(_ by: Int) -> IconSize { Self.allCases[min(max(index + by, 0), Self.allCases.count - 1)] }
}

/// What a folder's front shows: how many items, a symbol for what's mostly inside, and its size when Readout knows it.
struct FolderInfo {
    let count: Int
    let symbol: String?
    let size: Int64?

    @MainActor private static var cache: [String: FolderInfo] = [:]

    @MainActor static func load(_ url: URL) async -> FolderInfo {
        // shortcut: cached for the session; a folder that changes keeps its old count until relaunch
        if let c = cache[url.path] { return c }
        let path = url.path
        let info = await Task.detached(priority: .utility) { FolderInfo.read(path) }.value
        cache[path] = info
        return info
    }

    nonisolated static func read(_ path: String) -> FolderInfo {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }
        let all = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        let code = all.contains { [".git", "Package.swift", "package.json", "Cargo.toml", "pyproject.toml", "go.mod"].contains($0) }
        var kinds: [Bucket: Int] = [:]
        for n in names.prefix(300) where !(n as NSString).pathExtension.isEmpty {
            kinds[Bucket.forExtension((n as NSString).pathExtension), default: 0] += 1
        }
        let files = kinds.values.reduce(0, +)
        let top = kinds.filter { $0.key != .other }.max { $0.value < $1.value }
        let symbol = code ? Bucket.code.symbol : top.flatMap { $0.value >= 3 && $0.value * 2 > files ? $0.key.symbol : nil }
        return FolderInfo(count: names.count, symbol: symbol, size: Readout.sizes[path])
    }

    var summary: String {
        let items = count == 1 ? "1 item" : "\(count.formatted()) items"
        return size.map { "\(items) · \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? items
    }
}

/// A glass folder: a tinted back with its tab, a sheet of paper, and a translucent front with a symbol and the
/// item count. Drawn, so it stays sharp at any size and takes any colour.
struct FolderGlyph: View {
    var url: URL?
    var size: CGFloat
    var tint: Color = Palette.slate
    var symbol: String?
    var showCount = true
    @State private var info: FolderInfo?

    var body: some View {
        let w = size, h = size * 0.8
        ZStack(alignment: .topLeading) {
            FolderBack()
                .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                .frame(width: w, height: h)
            if size >= 24 {
                RoundedRectangle(cornerRadius: w * 0.04)
                    .fill(.white.opacity(0.92))
                    .frame(width: w * 0.8, height: h * 0.55)
                    .offset(x: w * 0.1, y: h * 0.16)
            }
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: w * 0.09)
                    .fill(LinearGradient(colors: [tint.mix(with: .white, by: 0.35).opacity(0.93), tint.opacity(0.95)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: w * 0.09).strokeBorder(.white.opacity(0.35), lineWidth: max(0.5, w * 0.012)))
                    .shadow(color: .black.opacity(0.12), radius: w * 0.03, y: w * 0.01)
                if let s = symbol ?? info?.symbol, size >= 28 {
                    Image(systemName: s)
                        .font(.system(size: w * 0.2, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if showCount, size >= 64, symbol ?? info?.symbol == nil, let n = info?.count {   // the symbol or the count, not both
                    Text(n == 1 ? "1 item" : "\(n) items")
                        .font(.system(size: max(9, w * 0.11), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.leading, w * 0.09).padding(.bottom, w * 0.07)
                }
            }
            .frame(width: w, height: h * 0.66)
            .offset(y: h * 0.34)
        }
        .frame(width: w, height: h)
        .frame(width: size, height: size)
        .task(id: url) { if let url, size >= 28 { info = await FolderInfo.load(url) } }
    }
}

private struct FolderBack: Shape {
    func path(in r: CGRect) -> Path {
        let tabW = r.width * 0.42, tabH = r.height * 0.14, c = r.width * 0.08
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + c))
        p.addQuadCurve(to: CGPoint(x: r.minX + c, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + tabW - c, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + tabW + c * 0.6, y: r.minY + tabH), control: CGPoint(x: r.minX + tabW, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY + tabH))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + tabH + c), control: CGPoint(x: r.maxX, y: r.minY + tabH))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        p.addQuadCurve(to: CGPoint(x: r.maxX - c, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - c), control: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

extension Bucket {
    var symbol: String {
        switch self {
        case .folders: "folder"
        case .documents: "doc.text"
        case .images: "photo"
        case .videos: "film"
        case .audio: "music.note"
        case .installers: "shippingbox"
        case .archives: "archivebox"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .other: "doc"
        }
    }
}

// MARK: Cells

/// A file as a card: its real preview on top, then icon, name, kind and size, and a ⋯ menu.
struct FileCard: View {
    let item: FileItem
    let pane: PaneModel
    let width: CGFloat
    let selected: Bool

    var body: some View {
        VStack(spacing: 0) {
            ThumbFill(item: item, height: width * 0.62)
            HStack(spacing: 8) {
                FileIcon(item: item, size: 18, thumbnail: false)
                VStack(alignment: .leading, spacing: 1) {
                    if pane.renaming == item.url {
                        RenameField(item: item, pane: pane)
                    } else {
                        Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    }
                    Text([item.url.pathExtension.uppercased(), Fmt.size(item)].filter { !$0.isEmpty && $0 != "--" }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                TagDots(tags: item.tags)
                Color.clear.frame(width: 18, height: 1)   // room for the ⋯ menu the cell floats on top
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: selected ? 2 : 1))
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }
}

/// A preview filling its box (a document's first page, the photo, a video frame), or the file's icon.
struct ThumbFill: View {
    let item: FileItem
    let height: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.04)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(nsImage: Icons.icon(item.url)).resizable().scaledToFit().frame(width: height * 0.5, height: height * 0.5)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .task(id: "\(item.url.path)\(item.modified?.timeIntervalSince1970 ?? 0)") {
            image = item.opensAsFolder ? nil : await Icons.thumbnail(item.url, changed: item.modified, size: height * 1.6)
        }
    }
}

/// A folder in the icon view: a big glass folder, its name, and what's in it.
struct FolderTile: View {
    let item: FileItem
    let pane: PaneModel
    let glyph: CGFloat
    let selected: Bool
    @State private var info: FolderInfo?

    var body: some View {
        VStack(spacing: 6) {
            if item.isPackage {
                Image(nsImage: Icons.icon(item.url)).resizable().frame(width: glyph, height: glyph)
            } else {
                FolderGlyph(url: item.target, size: glyph, tint: Palette.tint(item.tags))
            }
            if pane.renaming == item.url {
                RenameField(item: item, pane: pane)
            } else {
                Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(2).multilineTextAlignment(.center).truncationMode(.middle)
            }
            if glyph >= 70 { Text(info?.summary ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(8)
        .frame(width: glyph + 56)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.accentColor.opacity(0.16) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5))
        .task(id: item.target) { if item.opensAsFolder { info = await FolderInfo.load(item.target) } }
    }
}

/// A folder in a workspace: a wide card with where it lives and when it changed.
struct FolderCard: View {
    let item: FileItem
    let selected: Bool
    @State private var info: FolderInfo?

    var body: some View {
        HStack(spacing: 12) {
            FolderGlyph(url: item.target, size: 50, tint: Palette.tint(item.tags), showCount: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text(info?.summary ?? " ").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(FileRank.place(item.url.deletingLastPathComponent().path, home: NSHomeDirectory())).lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 6)
                    if let d = item.modified { Text(FileRank.when(d)) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 250, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: selected ? 2 : 1))
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
        .task(id: item.target) { info = await FolderInfo.load(item.target) }
    }
}

// MARK: Tabs and headers

/// All / Folders / Documents / Images … with counts; picks what the pane shows.
struct KindTabs: View {
    let pane: PaneModel
    var allTitle = "All"

    var body: some View {
        let counts = pane.kindCounts
        // Always there (even while loading, or with one kind), so the grid below never jumps.
        if true {
            HStack(spacing: 18) {
                tab(allTitle, counts.reduce(0) { $0 + $1.count }, nil)
                ForEach(counts, id: \.bucket) { tab($0.bucket.title, $0.count, $0.bucket) }
                Spacer()
            }
            .frame(height: 30)
        }
    }

    private func tab(_ title: String, _ n: Int, _ b: Bucket?) -> some View {
        let on = pane.kindFilter == b
        return Button { pane.kindFilter = b } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12.5, weight: on ? .semibold : .regular)).foregroundStyle(on ? .primary : .secondary)
                Text("\(n)").font(.caption2.monospacedDigit()).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07))).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) { if on { Rectangle().fill(Color.accentColor).frame(height: 2) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A workspace's page head: a tinted banner, its glass folder, name, a summary line, Add, and the kind tabs.
struct WorkspaceHeader: View {
    let pane: PaneModel
    let ws: Workspace
    let tint: Color

    var body: some View {
        let files = pane.baseItems
        let folders = files.filter(\.opensAsFolder).count
        let size = files.reduce(Int64(0)) { $0 + ($1.size ?? Readout.sizes[$1.target.path] ?? 0) }
        let changed = files.compactMap(\.modified).max()
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [tint.opacity(0.42), tint.opacity(0.16)], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 84)
                FolderGlyph(size: 66, tint: tint, symbol: "square.stack.3d.up", showCount: false)
                    .offset(x: 24, y: 30)
            }
            HStack(alignment: .center) {
                Text(ws.name).font(.system(size: 26, weight: .bold))
                Spacer()
                Button { add() } label: { Label("Add", systemImage: "plus") }.buttonStyle(.borderedProminent).tint(tint)
                Menu {
                    Button("Rename…") { if let n = Workspaces.askName("Rename Workspace", initial: ws.name) { Workspaces.shared.rename(ws.id, to: n) } }
                    Menu("Colour") {
                        ForEach(Array(Palette.names.enumerated()), id: \.offset) { i, name in Button(name) { Workspaces.shared.setTint(ws.id, i) } }
                    }
                    Divider()
                    Button("Delete Workspace") { Workspaces.shared.delete(ws.id); pane.closePage() }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .padding(6).background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .padding(.top, 40).padding(.horizontal, 24)
            Text(["\(folders) folders, \(files.count - folders) files",
                  size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : nil,
                  changed.map { "changed \(FileRank.when($0).lowercased())" }].compactMap { $0 }.joined(separator: " · "))
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 24).padding(.top, 2)
            KindTabs(pane: pane, allTitle: "Overview").padding(.horizontal, 24).padding(.top, 10)
        }
    }

    private func add() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.prompt = "Add to Workspace"
        if p.runModal() == .OK { Workspaces.shared.add(p.urls, to: ws.id) }
    }
}

// MARK: App icon (`Burrow --make-icon out.icns`)

/// The app icon: the slate glass folder on a deep slate tile, on Apple's icon grid (824 pt tile in a
/// 1024 pt canvas, transparent margin, soft shadow), so it sits right in the Dock and the sidebar.
struct IconArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.27, green: 0.33, blue: 0.43), Color(red: 0.13, green: 0.16, blue: 0.22)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 186, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 4))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 12)
            FolderGlyph(size: 560, tint: Color(red: 0.62, green: 0.71, blue: 0.83), showCount: false)
                .shadow(color: .black.opacity(0.3), radius: 16, y: 10)
                .offset(y: 24)
        }
        .frame(width: 1024, height: 1024)
    }

    /// Renders every size macOS wants into an .iconset and packs it with iconutil.
    @MainActor static func write(_ out: URL) throws {
        let set = FileManager.default.temporaryDirectory.appendingPathComponent("Burrow-\(UUID().uuidString).iconset")
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: set) }
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let r = ImageRenderer(content: IconArt())
                r.scale = CGFloat(base * scale) / 1024
                guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { continue }
                try png.write(to: set.appendingPathComponent("icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"))
            }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        p.arguments = ["-c", "icns", set.path, "-o", out.path]
        try p.run()
        p.waitUntilExit()
    }
}
