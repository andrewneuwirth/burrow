import AppKit
import QuickLook
import QuickLookThumbnailing
import SwiftUI

struct BrowserView: View {
    @Bindable var model: BrowserModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var pane = model.active
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 150, ideal: 190, max: 320)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(model.panes.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { Divider() }
                        PaneView(pane: p, highlighted: model.panes.count == 2 && i == model.activeIndex)
                            .simultaneousGesture(TapGesture().onEnded { model.activate(p) })
                    }
                }
                JobsBar()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { pane.goBack() } label: { Image(systemName: "chevron.left") }.disabled(pane.back.isEmpty).help("Back (⌘[)")
                Button { pane.goForward() } label: { Image(systemName: "chevron.right") }.disabled(pane.forward.isEmpty).help("Forward (⌘])")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("View", selection: $pane.viewMode) {
                    ForEach(ViewMode.allCases) { Image(systemName: $0.symbol).help("as \($0.title)").tag($0) }
                }
                .pickerStyle(.segmented)
                if pane.viewMode == .icons {
                    Picker("Size", selection: Binding(get: { AppSettings.shared.iconSize }, set: { AppSettings.shared.iconSize = $0 })) {
                        ForEach(IconSize.allCases) { Text($0.letter).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("Icon size (⌘+ / ⌘−)")
                }
                Button { model.toggleSplit() } label: {
                    Image(systemName: model.panes.count == 2 ? "rectangle" : "rectangle.split.2x1")
                }.help("Split (⌘D)")
                Menu {
                    BackgroundMenu(pane: pane)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .searchable(text: $pane.filter, placement: .toolbar, prompt: "Search")
        .searchScopes($pane.scope) {
            Text("This Folder").tag(SearchScope.folder)
            Text("Everywhere").tag(SearchScope.everywhere)
        }
        .searchFocused($searchFocused)
        .onSubmit(of: .search) { pane.deepSearch() }
        .onChange(of: model.findTick) { searchFocused = true }
        .sheet(isPresented: $model.palette) { GoPalette(model: model) }
        .frame(minWidth: 620, minHeight: 360)
    }
}

struct PaneView: View {
    @Bindable var pane: PaneModel
    let highlighted: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let page = pane.page, !page.listsFiles {
                ToolPage(page: page)
            } else {
                files
            }
        }
        .overlay(alignment: .top) { if highlighted { Rectangle().fill(Color.accentColor).frame(height: 2) } }
        .quickLookPreview($pane.preview, in: pane.visible.map(\.url))
        .sheet(isPresented: $pane.tidying) { TidySheet(pane: pane) }
        .onChange(of: pane.selection) { pane.owner?.activate(pane) }
    }

    @ViewBuilder private var files: some View {
            if case let .workspace(id) = pane.page, let ws = Workspaces.shared.list.first(where: { $0.id == id }) {
                WorkspaceHeader(pane: pane, ws: ws, tint: Workspaces.shared.tint(ws))
            } else {
                if let page = pane.page { PageBar(pane: pane, page: page) } else { PathBar(pane: pane) }
                if pane.viewMode != .columns, pane.searchResults == nil || pane.page != nil {
                    KindTabs(pane: pane).padding(.horizontal, 14)
                }
            }
            Divider()
            if pane.url == Tidy.downloads, pane.searchResults == nil {
                TidyBar(pane: pane)
                Divider()
            }
            ZStack {
                switch pane.viewMode {
                case .list: ListView(pane: pane)
                case .columns where pane.page != nil: ListView(pane: pane)   // a workspace or tag has no folder tree
                case .columns: ColumnView(pane: pane)
                case .icons: IconView(pane: pane)
                case .gallery: GalleryView(pane: pane)
                }
                if let e = pane.error {
                    ContentUnavailableView("Can't Open This Folder", systemImage: "lock", description: Text(e))
                } else if pane.visible.isEmpty, !pane.loading, !pane.searching {
                    Text(pane.filter.isEmpty ? "Empty Folder" : "No Matches").foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
            .overlay { if pane.dropTargeted { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2).padding(2) } }
            .paneDrop(pane)
            Divider()
            StatusBar(pane: pane)
    }
}

struct PathBar: View {
    @Bindable var pane: PaneModel
    @State private var text = ""
    @FocusState private var focused: Bool

    private var crumbs: [URL] {
        var out: [URL] = [], u = pane.url
        while u.path != "/" { out.insert(u, at: 0); u = u.deletingLastPathComponent().folder }
        return [URL(fileURLWithPath: "/", isDirectory: true)] + out
    }

    var body: some View {
        HStack(spacing: 4) {
            if pane.editingPath {
                Image(systemName: "arrow.right.circle").foregroundStyle(.secondary)
                TextField("Type a path, ~ works", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { if pane.goTyped(text) { pane.editingPath = false } }
                    .onExitCommand { pane.editingPath = false }
                    .onChange(of: focused) { if !focused { pane.editingPath = false } }
                    .onAppear {
                        text = (pane.url.path as NSString).abbreviatingWithTildeInPath + "/"
                        focused = true
                    }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(crumbs.enumerated()), id: \.offset) { i, u in
                            if i > 0 { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary) }
                            Crumb(url: u, pane: pane)
                        }
                    }
                }
                Spacer(minLength: 8)
                if let git = pane.git {
                    Label(git.changes == 0 ? git.branch : "\(git.branch) · \(git.changes) changed", systemImage: "arrow.triangle.branch")
                        .font(.caption).foregroundStyle(git.changes == 0 ? Color.secondary : Color.orange)
                        .lineLimit(1)
                        .help("Git: branch and uncommitted changes (read-only)")
                }
                Button { pane.editingPath = true } label: { Image(systemName: "character.cursor.ibeam") }
                    .buttonStyle(.borderless).help("Type a path (⌘L)")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 30)
    }
}

private struct Crumb: View {
    let url: URL
    let pane: PaneModel
    @State private var targeted = false
    var body: some View {
        Button { pane.go(url) } label: {
            HStack(spacing: 4) {
                if url.path == "/" { Image(nsImage: Icons.icon(url)).resizable().frame(width: 14, height: 14) }
                else { FolderGlyph(size: 15, showCount: false) }
                Text(FileManager.default.displayName(atPath: url.path)).lineLimit(1)
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(targeted ? Color.accentColor.opacity(0.25) : .clear))
        }
        .buttonStyle(.plain)
        .folderDrop(url, targeted: $targeted)
    }
}

struct StatusBar: View {
    let pane: PaneModel
    var body: some View {
        HStack(spacing: 8) {
            if pane.searching { ProgressView().controlSize(.small); Text("Searching…") }
            else if let page = pane.page {
                Text("\(pane.visible.count) items · \(page.title)")
            } else if pane.searchResults != nil {
                let place = pane.scope == .everywhere ? "everywhere" : "in “\(pane.url.lastPathComponent)” and below"
                Text(pane.searchTotal > pane.visible.count ? "Best \(pane.visible.count) of \(pane.searchTotal) \(place)" : "\(pane.visible.count) found \(place)")
                Button("Clear") { pane.clearSearch() }.buttonStyle(.link)
            } else {
                Text(pane.selection.isEmpty ? "\(pane.visible.count) items" : "\(pane.selection.count) of \(pane.visible.count) selected")
            }
            Spacer()
            if let free = pane.freeSpace { Text("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) available") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 22)
    }
}

struct JobsBar: View {
    var ops = FileOps.shared
    var body: some View {
        if !ops.jobs.isEmpty {
            VStack(spacing: 6) {
                ForEach(ops.jobs) { job in
                    HStack {
                        Text(job.title).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        ProgressView(value: Double(job.done), total: Double(max(job.total, 1))).frame(width: 160)
                        Text("\(job.done) of \(job.total)").monospacedDigit().foregroundStyle(.secondary)
                        Button("Cancel") { job.cancelled = true }.disabled(job.cancelled)
                    }
                }
            }
            .font(.callout)
            .padding(10)
            .background(.bar)
        }
    }
}

// MARK: Sidebar

struct Volume: Identifiable, Hashable {
    let url: URL, name: String, ejectable: Bool, symbol: String
    var id: URL { url }

    static func list() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey,
                                      .volumeIsLocalKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [])
            .compactMap { u in
                guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false else { return nil }
                let eject = v.volumeIsEjectable == true || v.volumeIsRemovable == true || v.volumeIsLocal == false
                let symbol = v.volumeIsLocal == false ? "server.rack" : v.volumeIsInternal == true ? "internaldrive" : "externaldrive"
                return Volume(url: u.folder, name: v.volumeLocalizedName ?? u.lastPathComponent, ejectable: eject && v.volumeIsRootFileSystem != true, symbol: symbol)
            }
    }
}

enum SidebarTarget: Hashable { case folder(URL), page(Page) }

struct Sidebar: View {
    let model: BrowserModel
    var settings = AppSettings.shared
    var spaces = Workspaces.shared
    @State private var volumes = Volume.list()

    var body: some View {
        let selection = Binding<SidebarTarget?>(
            get: { model.active.page.map { .page($0) } ?? .folder(model.active.url) },
            set: {
                switch $0 {
                case let .folder(u): model.active.go(u)
                case let .page(p): model.active.showPage(p)
                case nil: break
                }
            })
        List(selection: selection) {
            Section("Favorites") {
                ForEach(settings.favorites, id: \.self) { u in
                    SidebarRow(url: u, title: FileManager.default.displayName(atPath: u.path), symbol: Self.symbol(u))
                        .contextMenu {
                            Button("Open in New Tab") { Windows.shared.open(u, asTabOf: model.window) }
                            Button("Remove from Sidebar") { settings.favorites.removeAll { $0 == u } }
                        }
                }
                .onMove { settings.favorites.move(fromOffsets: $0, toOffset: $1) }
                .onInsert(of: [.fileURL]) { at, providers in
                    _ = Drops.load(providers) { urls in
                        let add = urls.filter { FileItem(url: $0).opensAsFolder }.map(\.folder).filter { !settings.favorites.contains($0) }
                        settings.favorites.insert(contentsOf: add, at: min(at, settings.favorites.count))
                    }
                }
            }
            Section {
                ForEach(Array(spaces.list.enumerated()), id: \.element.id) { i, ws in
                    WorkspaceRow(ws: ws, number: i + 1)
                }
                .onMove { spaces.move(from: $0, to: $1) }
            } header: {
                HStack {
                    Text("Workspaces")
                    Spacer()
                    Button { if let n = Workspaces.askName("New Workspace") { model.active.showPage(.workspace(spaces.create(n).id)) } } label: {
                        Image(systemName: "plus")
                    }.buttonStyle(.borderless).help("New Workspace")
                }
            }
            Section("Tools") {
                ForEach(Page.tools, id: \.self) { p in
                    Label { Text(p.title) } icon: { SidebarIcon(symbol: p.symbol, color: Sidebar.color(p.symbol)) }.tag(SidebarTarget.page(p))
                }
            }
            Section("Tags") {
                ForEach(Tags.standard, id: \.name) { t in
                    Label { Text(t.name) } icon: { Image(systemName: "circle.fill").foregroundStyle(t.color) }
                        .tag(SidebarTarget.page(.tag(t.name)))
                }
            }
            Section("Locations") {
                ForEach(volumes) { v in
                    HStack {
                        SidebarRow(url: v.url, title: v.name, symbol: v.symbol)
                        if v.ejectable {
                            Spacer()
                            Button { eject(v) } label: { Image(systemName: "eject.fill") }.buttonStyle(.borderless).help("Eject")
                        }
                    }
                    .tag(SidebarTarget.folder(v.url))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
                Text("Burrow").font(.system(size: 15, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 6)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in volumes = Volume.list() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in volumes = Volume.list() }
    }

    private func eject(_ v: Volume) {
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: v.url) } catch { FileOps.alert("Couldn't Eject “\(v.name)”", error.localizedDescription) }
    }

    /// Each sidebar tile's colour, by its symbol: varied, like System Settings, never one accent for all.
    static func color(_ symbol: String) -> Color {
        switch symbol {
        case "arrow.down": .green
        case "square.grid.3x3.fill": Color(red: 0.24, green: 0.52, blue: 0.85)
        case "menubar.dock.rectangle": .teal
        case "doc.fill": .orange
        case "house.fill": Color(red: 0.45, green: 0.5, blue: 0.58)
        case "hammer.fill": Color(red: 0.36, green: 0.38, blue: 0.42)
        case "icloud.fill": Color(red: 0.35, green: 0.68, blue: 0.95)
        case "bookmark.fill": .red
        case "gauge.with.dots.needle.33percent": .green
        case "shippingbox.fill": .brown
        case "cpu.fill": .pink
        case "laptopcomputer": Color(white: 0.45)
        default: Color(white: 0.5)
        }
    }

    static func symbol(_ u: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.folder
        switch u.path {
        case "/Applications": return "square.grid.3x3.fill"
        case home.path: return "house.fill"
        case home.appendingPathComponent("Desktop").path: return "menubar.dock.rectangle"
        case home.appendingPathComponent("Documents").path: return "doc.fill"
        case home.appendingPathComponent("Downloads").path: return "arrow.down"
        case home.appendingPathComponent("Developer").path: return "hammer.fill"
        default: return u.path.contains("com~apple~CloudDocs") ? "icloud.fill" : "folder.fill"
        }
    }
}

private struct SidebarRow: View {
    let url: URL, title: String, symbol: String
    @State private var targeted = false
    var body: some View {
        Label { Text(title) } icon: { SidebarIcon(symbol: symbol, color: Sidebar.color(symbol)) }
            .tag(SidebarTarget.folder(url))
            .listRowBackground(targeted ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.3)) : nil)
            .folderDrop(url, targeted: $targeted)
    }
}

private struct WorkspaceRow: View {
    let ws: Workspace
    let number: Int
    @State private var targeted = false
    var body: some View {
        HStack {
            Label { Text(ws.name) } icon: { FolderGlyph(size: 17, tint: Workspaces.shared.tint(ws), showCount: false) }
            Spacer()
            if number <= 9 { Text("⌃\(number)").font(.caption2).foregroundStyle(.tertiary) }
        }
        .tag(SidebarTarget.page(.workspace(ws.id)))
        .listRowBackground(targeted ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.3)) : nil)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { Drops.load($0) { Workspaces.shared.add($0, to: ws.id) } }
        .contextMenu {
            Button("Rename…") { if let n = Workspaces.askName("Rename Workspace", initial: ws.name) { Workspaces.shared.rename(ws.id, to: n) } }
            Button("Delete Workspace") { Workspaces.shared.delete(ws.id) }
        }
        .help("Drop files or folders here to add them (nothing moves)")
    }
}

// MARK: Content

struct ListView: View {
    @Bindable var pane: PaneModel
    var body: some View {
        Table(of: FileItem.self, selection: $pane.selection, sortOrder: $pane.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { NameCell(item: $0, pane: pane).rowDrop($0, pane) }
                .width(min: 160, ideal: 340)
            TableColumn("Date Modified", value: \.sortDate) { Text(Fmt.date($0.modified)).foregroundStyle(.secondary).rowDrop($0, pane) }
                .width(min: 100, ideal: 170)
            TableColumn("Size", value: \.sortSize) { item in
                Group {
                    if item.opensAsFolder { FolderCount(url: item.target) } else { Text(Fmt.size(item)).foregroundStyle(.secondary) }
                }.rowDrop(item, pane)
            }
                .width(min: 56, ideal: 80)
            TableColumn("Kind", value: \.kind) { Text($0.kind).foregroundStyle(.secondary).rowDrop($0, pane) }
                .width(min: 70, ideal: 150)
        } rows: {
            ForEach(pane.groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items) { item in
                        TableRow(item).itemProvider { NSItemProvider(object: item.url as NSURL) }
                    }
                }
            }
        }
        .contextMenu(forSelectionType: URL.self) { sel in
            ItemMenu(pane: pane, urls: sel)
        } primaryAction: { sel in
            pane.open(pane.visible.filter { sel.contains($0.url) })
        }
    }
}

private struct NameCell: View {
    let item: FileItem
    @Bindable var pane: PaneModel
    var body: some View {
        HStack(spacing: 6) {
            FileIcon(item: item, size: 16, thumbnail: false)
            if pane.renaming == item.url {
                RenameField(item: item, pane: pane)
            } else {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                TagDots(tags: item.tags)
                if pane.searchResults != nil {   // where it is, as Pier's search shows it
                    Text(FileRank.place(item.url.deletingLastPathComponent().path, home: NSHomeDirectory()))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
        }
    }
}

struct RenameField: View {
    let item: FileItem
    let pane: PaneModel
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear { draft = item.name; focused = true }
            .onSubmit { pane.commitRename(item, draft) }
            .onExitCommand { pane.renaming = nil }
            .onChange(of: focused) { if !focused { pane.commitRename(item, draft) } }
    }
}

struct IconView: View {
    @Bindable var pane: PaneModel
    var settings = AppSettings.shared
    @State private var frames: [URL: CGRect] = [:]
    @State private var marquee: CGRect?
    @State private var base: Set<URL> = []

    /// Folders as tiles, then files as cards (or the chosen groups, each in turn).
    private var sections: [(title: String, items: [FileItem])] {
        if pane.groupBy != .none { return pane.groups }
        let folders = pane.visible.filter { $0.opensAsFolder || $0.isPackage && $0.url.pathExtension != "app" }
        let files = pane.visible.filter { !($0.opensAsFolder || $0.isPackage && $0.url.pathExtension != "app") }
        let apps = !files.isEmpty && files.allSatisfy { $0.url.pathExtension == "app" }
        return [("Folders", folders), (apps ? "Apps" : "Files", files)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        let size = settings.iconSize
        let inWorkspace: Bool = { if case .workspace = pane.page { return true }; return false }()
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(sections, id: \.title) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                if !section.title.isEmpty {
                                    HStack(spacing: 6) {
                                        Text(section.title).font(.system(size: 12.5, weight: .semibold))
                                        Text("\(section.items.count)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                // Apps as plain icons with their names below, like folders, not file cards.
                                let tiles = section.items.allSatisfy { $0.opensAsFolder || $0.url.pathExtension == "app" } && !inWorkspace
                                let width = tiles ? size.glyph + 56 : inWorkspace && section.items.allSatisfy(\.opensAsFolder) ? 250 : size.card
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width), spacing: 14, alignment: .top)],
                                          alignment: .leading, spacing: 14) {
                                    ForEach(section.items) { IconCell(item: $0, pane: pane, size: size, card: !tiles, wide: inWorkspace).id($0.url) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 16)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
                    .coordinateSpace(name: "grid")
                    .onPreferenceChange(CellFrames.self) { frames = $0 }
                    .contentShape(Rectangle())
                    .onTapGesture { pane.selection = []; pane.owner?.activate(pane) }
                    // Box selection: drag on empty space; ⌘ or ⇧ adds to what was selected.
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("grid"))
                        .onChanged { v in
                            if marquee == nil {
                                let f = NSEvent.modifierFlags
                                base = f.contains(.command) || f.contains(.shift) ? pane.selection : []
                                pane.owner?.activate(pane)
                            }
                            let r = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                           width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                            marquee = r
                            pane.selection = base.union(frames.filter { $0.value.intersects(r) }.keys)
                        }
                        .onEnded { _ in marquee = nil })
                    .overlay(alignment: .topLeading) {
                        if let m = marquee {
                            Rectangle().fill(Color.accentColor.opacity(0.12)).overlay(Rectangle().stroke(Color.accentColor.opacity(0.6)))
                                .frame(width: m.width, height: m.height).offset(x: m.minX, y: m.minY).allowsHitTesting(false)
                        }
                    }
                    .contextMenu { BackgroundMenu(pane: pane) }
                }
                .onChange(of: pane.cursor) { if let c = pane.cursor { proxy.scrollTo(c) } }
            }
            .onAppear { pane.gridColumns = max(1, Int((geo.size.width - 40) / (size.card + 14))) }
            .onChange(of: geo.size.width) { pane.gridColumns = max(1, Int((geo.size.width - 40) / (size.card + 14))) }
        }
    }
}

private struct IconCell: View {
    let item: FileItem
    let pane: PaneModel
    let size: IconSize
    let card: Bool
    let wide: Bool
    @State private var targeted = false
    private var selected: Bool { pane.selection.contains(item.url) || targeted }

    var body: some View {
        Group {
            if item.opensAsFolder && wide { FolderCard(item: item, selected: selected) }
            else if item.opensAsFolder || !card { FolderTile(item: item, pane: pane, glyph: size.glyph, selected: selected) }
            else { FileCard(item: item, pane: pane, width: size.card, selected: selected) }
        }
        .background(GeometryReader { g in Color.clear.preference(key: CellFrames.self, value: [item.url: g.frame(in: .named("grid"))]) })
        // On top: SwiftUI content would otherwise take the clicks and double-clicks never arrive.
        .overlay {
            if pane.renaming != item.url {
                ItemMouse(selected: pane.selection.contains(item.url), click: { pane.click(item) }, open: { pane.open([item]) },
                          dragged: { pane.selection.contains(item.url) ? pane.selectedItems.map(\.url) : [item.url] },
                          // AppKit sends drags to this view, not to SwiftUI drop targets under it: a folder takes them,
                          // a file passes them to its pane like the background would.
                          dropInto: item.opensAsFolder ? item.target : pane.takesDrops ? pane.url : nil,
                          drop: { pane.drop($0, onto: item) },
                          hover: { on in targeted = on && item.opensAsFolder })
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if card, !item.opensAsFolder {
                Menu { ItemMenu(pane: pane, urls: pane.selection.contains(item.url) ? pane.selection : [item.url]) } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .padding(.trailing, 10).padding(.bottom, 14)
            }
        }
        .contextMenu { ItemMenu(pane: pane, urls: pane.selection.contains(item.url) ? pane.selection : [item.url]) }
    }
}

extension View {
    /// Drops on a pane's background: into its folder (or onto its workspace).
    func paneDrop(_ pane: PaneModel) -> some View {
        background(DropZone(into: pane.takesDrops ? pane.url : nil, drop: { pane.take($0) }, hover: { pane.dropTargeted = $0 }))
    }

    /// Drops on an item (list row, column, gallery): a folder takes them and lights up; a file passes them to
    /// `folder`, or to the pane like its background would.
    func itemDrop(_ item: FileItem, _ pane: PaneModel, folder: URL? = nil) -> some View {
        let into = item.opensAsFolder ? item.target : folder ?? (pane.takesDrops ? pane.url : nil)
        return background(pane.dropRow == item.url ? RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.3)).padding(-3) : nil)
            .overlay(DropZone(into: into, drop: { urls in
                if folder == nil || item.opensAsFolder { pane.drop(urls, onto: item) } else if let into { FileOps.shared.drop(urls, into: into) }
            }, hover: { on in
                if on, item.opensAsFolder { pane.dropRow = item.url } else if pane.dropRow == item.url { pane.dropRow = nil }
            }))
    }

    /// A list cell fills its column, so the whole row takes drops.
    func rowDrop(_ item: FileItem, _ pane: PaneModel) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).itemDrop(item, pane)
    }

    /// A folder that takes drops (sidebar, path bar).
    func folderDrop(_ url: URL, targeted: Binding<Bool>) -> some View {
        overlay(DropZone(into: url, drop: { FileOps.shared.drop($0, into: url) }, hover: { targeted.wrappedValue = $0 }))
    }
}

struct GalleryView: View {
    @Bindable var pane: PaneModel
    private var current: FileItem? { pane.selectedItems.first ?? pane.visible.first }

    var body: some View {
        VStack(spacing: 0) {
            if let c = current {
                VStack(spacing: 6) {
                    FileIcon(item: c, size: 420, thumbnail: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onTapGesture(count: 2) { pane.open([c]) }
                    Text(c.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text([c.kind, Fmt.size(c), Fmt.date(c.modified)].filter { !$0.isEmpty && $0 != "--" }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            } else {
                Spacer()
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 6) {
                        ForEach(pane.visible) { item in
                            FileIcon(item: item, size: 56, thumbnail: true)
                                .padding(5)
                                .background(RoundedRectangle(cornerRadius: 8).fill(item.url == current?.url ? Color.accentColor.opacity(0.35) : .clear))
                                .contentShape(Rectangle())
                                .gesture(TapGesture(count: 2).onEnded { pane.open([item]) })
                                .simultaneousGesture(TapGesture().onEnded { pane.click(item) })
                                .onDrag { NSItemProvider(object: item.url as NSURL) }
                                .itemDrop(item, pane)
                                .contextMenu { ItemMenu(pane: pane, urls: [item.url]) }
                                .help(item.name)
                                .id(item.url)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 86)
                .onChange(of: current?.url) { if let u = current?.url { withAnimation { proxy.scrollTo(u, anchor: .center) } } }
            }
        }
    }
}

// MARK: Menus

struct ItemMenu: View {
    let pane: PaneModel
    let urls: Set<URL>
    private var items: [FileItem] { pane.visible.filter { urls.contains($0.url) } }

    var body: some View {
        if urls.isEmpty {
            BackgroundMenu(pane: pane)
        } else {
            let items = self.items
            Button("Open") { pane.open(items) }
            if items.count == 1, !items[0].opensAsFolder { OpenWithMenu(url: items[0].url) }
            if items.allSatisfy(\.opensAsFolder) {
                Button("Open in New Tab") { items.forEach { Windows.shared.open($0.target, asTabOf: pane.owner?.window) } }
            }
            if pane.searchResults != nil, let first = items.first {
                Button("Show in Enclosing Folder") { pane.go(first.url.deletingLastPathComponent(), select: [first.url]) }
            }
            Divider()
            Button("Move to Trash") { FileOps.shared.trash(items.map(\.url)) }
            Divider()
            Button("Get Info") { Info.show(items) }
            Button("Rename") { pane.selection = [items[0].url]; pane.renaming = items[0].url }.disabled(items.count != 1)
            Button("Duplicate") { FileOps.shared.duplicate(items.map(\.url)) }
            Button("Compress") { FileOps.shared.compress(items.map(\.url)) }
            Divider()
            Button("Copy") { Clipboard.copy(items.map(\.url)) }
            Button("Copy Path") { Clipboard.copyPaths(items.map(\.url)) }
            if let other = pane.owner?.other, other !== pane {
                Button("Copy to Other Pane") { FileOps.shared.transfer(items.map(\.url), to: other.url, copy: true) }
                Button("Move to Other Pane") { FileOps.shared.transfer(items.map(\.url), to: other.url, copy: false) }
            }
            Divider()
            if items.count == 1, items[0].opensAsFolder {
                Button("Add to Sidebar") { AppSettings.shared.favorites.append(items[0].target.folder) }
                Button("Pin to Shelf") { AppSettings.shared.shelf.append(items[0].target.folder) }
                Button("Open in Terminal") { Act.openIn(Act.terminals, items[0].target) }
            }
            Divider()
            Menu("Tags") {
                ForEach(Tags.standard, id: \.name) { t in
                    Button { Tags.toggle(t.name, on: items) } label: {
                        Label(t.name, systemImage: items.allSatisfy { $0.tags.contains(t.name) } ? "checkmark.circle.fill" : "circle.fill")
                    }
                    .tint(t.color)
                }
            }
            Menu("Add to Workspace") {
                ForEach(Workspaces.shared.list) { ws in Button(ws.name) { Workspaces.shared.add(items.map(\.url), to: ws.id) } }
                if !Workspaces.shared.list.isEmpty { Divider() }
                Button("New Workspace…") {
                    if let name = Workspaces.askName("New Workspace") { Workspaces.shared.create(name, with: items.map(\.url)) }
                }
            }
            if case let .workspace(id) = pane.page {
                Button("Remove from Workspace") { Workspaces.shared.remove(items.map(\.url), from: id) }
            }
            // Finder by bundle id: a plain `open -R` asks the NSFileViewer, which is Burrow itself once it's the default.
            Button("Show in Finder") { Process.launchedProcess(launchPath: "/usr/bin/open", arguments: ["-b", "com.apple.finder", "-R"] + items.map(\.url.path)) }
        }
    }
}

struct BackgroundMenu: View {
    let pane: PaneModel
    var settings = AppSettings.shared
    var body: some View {
        Button("New Folder") { pane.newFolder() }
        Button("Paste") { pane.paste(move: false) }
        Divider()
        Picker("View", selection: Binding(get: { pane.viewMode }, set: { pane.viewMode = $0 })) {
            ForEach(ViewMode.allCases) { Text("as \($0.title)").tag($0) }
        }
        Picker("Group By", selection: Binding(get: { pane.groupBy }, set: { pane.groupBy = $0 })) {
            ForEach(GroupBy.allCases) { Text($0.title).tag($0) }
        }
        Button("Tidy This Folder…") { pane.tidying = true }
        Toggle("Show Hidden Files", isOn: Binding(get: { settings.showHidden }, set: { settings.showHidden = $0 }))
        Toggle("Folders on Top", isOn: Binding(get: { settings.foldersFirst }, set: { settings.foldersFirst = $0 }))
        Divider()
        Button("Get Info") { Info.show([FileItem(url: pane.url)]) }
        Button("Add to Sidebar") { AppSettings.shared.favorites.append(pane.url) }.disabled(settings.favorites.contains(pane.url))
        Button("Open in Terminal") { Act.openIn(Act.terminals, pane.url) }
        Button("Open in Editor") { Act.openIn(Act.editors, pane.url) }
    }
}

struct OpenWithMenu: View {
    let url: URL
    var body: some View {
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        Menu("Open With") {
            ForEach(apps, id: \.self) { app in
                Button(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")) {
                    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                }
            }
        }
    }
}

// MARK: Icons and formatting

struct FileIcon: View {
    let item: FileItem
    let size: CGFloat
    let thumbnail: Bool
    @State private var thumb: NSImage?

    var body: some View {
        if item.opensAsFolder {
            FolderGlyph(url: size >= 28 ? item.target : nil, size: size, tint: Palette.tint(item.tags), showCount: size >= 64)
        } else {
            fileImage
        }
    }

    private var fileImage: some View {
        Image(nsImage: thumb ?? Icons.icon(item.url))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .task(id: thumbnail && !item.opensAsFolder ? "\(item.url.path)\(item.modified?.timeIntervalSince1970 ?? 0)" : nil) {
                thumb = nil
                guard thumbnail, !item.opensAsFolder else { return }
                thumb = await Icons.thumbnail(item.url, changed: item.modified, size: size)
            }
    }
}

@MainActor
enum Icons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(_ url: URL) -> NSImage {
        if let i = cache.object(forKey: url.path as NSString) { return i }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(i, forKey: url.path as NSString)
        return i
    }

    /// Real previews (documents, photos, video frames); nil for types that only have an icon.
    /// Keyed by `changed` too, so a file rewritten in place gets a new preview.
    static func thumbnail(_ url: URL, changed: Date?, size: CGFloat) async -> NSImage? {
        let key = "\(url.path)#\(Int(size))#\(changed?.timeIntervalSince1970 ?? 0)" as NSString
        if let c = cache.object(forKey: key) { return c }
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
        cache.setObject(rep.nsImage, forKey: key)
        return rep.nsImage
    }
}

enum Fmt {
    static func size(_ item: FileItem) -> String {
        item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "--"
    }

    static func date(_ d: Date?) -> String {
        guard let d else { return "--" }
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return "Today at \(time)" }
        if cal.isDateInYesterday(d) { return "Yesterday at \(time)" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}


/// Downloads' strip: how many loose files there are, and the Tidy sheet.
struct TidyBar: View {
    let pane: PaneModel
    var body: some View {
        let loose = pane.items.filter { !$0.opensAsFolder && !Tidy.inProgress($0) }.count
        HStack(spacing: 8) {
            Image(systemName: "tray.full").foregroundStyle(.secondary)
            Text(loose == 0 ? "Downloads is tidy" : "\(loose) loose files").foregroundStyle(.secondary)
            Spacer()
            Picker("Group", selection: Binding(get: { pane.groupBy }, set: { pane.groupBy = $0 })) {
                ForEach(GroupBy.allCases) { Text($0 == .none ? "No Groups" : "By \($0.title)").tag($0) }
            }
            .labelsHidden().fixedSize()
            Button("Tidy…") { pane.tidying = true }.disabled(loose == 0)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 30)
    }
}

/// "12 items" for a folder in the list's Size column, counted once per folder per session.
struct FolderCount: View {
    let url: URL
    @State private var count: Int?
    @MainActor private static var cache: [String: Int] = [:]

    var body: some View {
        Text(count.map { $0 == 1 ? "1 item" : "\($0) items" } ?? "--")
            .foregroundStyle(.secondary)
            .task(id: url) {
                // shortcut: counted once per session; a folder that changes later shows the old count until relaunch
                if let c = Self.cache[url.path] { count = c; return }
                let path = url.path
                let c = await Task.detached(priority: .utility) {
                    ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }.count
                }.value
                Self.cache[path] = c
                count = c
            }
    }
}


// MARK: Pages

/// A workspace or tag page's bar, in place of the path bar.
struct PageBar: View {
    let pane: PaneModel
    let page: Page
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: page.symbol).foregroundStyle(page.symbol == "tag" ? Tags.color(page.title) : .secondary)
            Text(page.title).font(.callout.bold())
            if case .workspace = page { Text("· files stay where they are").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if case let .workspace(id) = page {
                Button("Add…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true
                    p.allowsMultipleSelection = true
                    if p.runModal() == .OK { Workspaces.shared.add(p.urls, to: id) }
                }
                .controlSize(.small)
            }
            Button { pane.closePage() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless).help("Back to the folder (Esc)")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }
}

/// The tool pages, each drawing its own header.
struct ToolPage: View {
    let page: Page
    var body: some View {
        switch page {
        case .bookmarks: BookmarksPage()
        case .clean: SmartCleanPage()
        case .installed: InstalledPage()
        case .agents: AgentsPage()
        case .about: AboutMacPage()
        case .workspace, .tag: EmptyView()
        }
    }
}

struct TagDots: View {
    let tags: [String]
    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: -3) {
                ForEach(tags, id: \.self) { t in
                    Circle().fill(Tags.color(t)).frame(width: 8, height: 8).overlay(Circle().stroke(.background, lineWidth: 1))
                }
            }
            .help(tags.joined(separator: ", "))
        }
    }
}

struct CellFrames: PreferenceKey {
    static let defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// Clicks and drags on an icon handled by AppKit, so a drag can carry the whole selection (SwiftUI's onDrag
/// carries one item). Selects on mouse-down like Finder; a click on an already-selected item of a group only
/// narrows the selection on mouse-up, so the group can still be dragged. Right-clicks fall through to SwiftUI's menu.
struct ItemMouse: NSViewRepresentable {
    let selected: Bool
    let click: () -> Void
    let open: () -> Void
    let dragged: () -> [URL]
    let dropInto: URL?            // where a drop on this item goes; nil takes none
    let drop: ([URL]) -> Void
    let hover: (Bool) -> Void

    func makeNSView(context: Context) -> MouseView { MouseView() }
    func updateNSView(_ v: MouseView, context: Context) {
        v.owner = self
        (v.dropInto, v.onDrop, v.onHover) = (dropInto, drop, hover)
    }

    final class MouseView: FileDropView, NSDraggingSource {
        var owner: ItemMouse?
        private var down: NSPoint?
        private var deferred = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with e: NSEvent) {
            guard let owner else { return }
            down = e.locationInWindow
            if e.clickCount == 2 { down = nil; return owner.open() }
            deferred = owner.selected && e.modifierFlags.intersection([.command, .shift]).isEmpty
            if !deferred { owner.click() }
        }

        override func mouseDragged(with e: NSEvent) {
            guard let d = down, let owner, hypot(e.locationInWindow.x - d.x, e.locationInWindow.y - d.y) > 4 else { return }
            down = nil
            deferred = false
            let items = owner.dragged().enumerated().map { i, u -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: u as NSURL)
                let offset = CGFloat(min(i, 4)) * 5
                item.setDraggingFrame(NSRect(x: bounds.midX - 28 + offset, y: bounds.midY - 28 - offset, width: 56, height: 56),
                                      contents: NSWorkspace.shared.icon(forFile: u.path))
                return item
            }
            beginDraggingSession(with: items, event: e, source: self)
        }

        override func mouseUp(with e: NSEvent) {
            if deferred, down != nil { owner?.click() }
            down = nil
            deferred = false
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            [.copy, .move, .generic, .link]
        }
    }
}

/// A file drop target in AppKit. AppKit gives a drag to the topmost registered view under the pointer and stops at
/// AppKit views that aren't (like the icons' mouse view), so SwiftUI drop targets under them never hear about it.
class FileDropView: NSView {
    var dropInto: URL?            // where a drop here goes; nil takes none
    var onDrop: ([URL]) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func files(_ s: NSDraggingInfo) -> [URL] { Self.files(s.draggingPasteboard) }
    static func files(_ pb: NSPasteboard) -> [URL] {
        pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Finder's badge: ⌥ or another volume copies, otherwise move; nothing onto itself or into what's being dragged.
    private func operation(_ s: NSDraggingInfo) -> NSDragOperation {
        guard let dir = dropInto?.standardizedFileURL.path else { return [] }
        let urls = files(s)
        if urls.isEmpty || urls.contains(where: { dir == $0.standardizedFileURL.path || dir.hasPrefix($0.standardizedFileURL.path + "/") }) { return [] }
        let copy = NSEvent.modifierFlags.contains(.option) || urls.contains { !FileOps.sameVolume($0, URL(fileURLWithPath: dir)) }
        let mask = s.draggingSourceOperationMask
        return copy || !mask.contains(.move) ? (mask.contains(.copy) ? .copy : []) : .move
    }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { draggingUpdated(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        let op = operation(s)
        onHover(!op.isEmpty)
        return op
    }
    override func draggingExited(_ s: NSDraggingInfo?) { onHover(false) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        onHover(false)
        guard !operation(s).isEmpty else { return false }
        onDrop(files(s))
        return true
    }
}

/// A drop target laid over SwiftUI content that clicks pass straight through (list rows).
struct DropZone: NSViewRepresentable {
    let into: URL?
    let drop: ([URL]) -> Void
    var hover: (Bool) -> Void = { _ in }

    final class Zone: FileDropView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Zone { Zone() }
    func updateNSView(_ v: Zone, context: Context) { (v.dropInto, v.onDrop, v.onHover) = (into, drop, hover) }
}

/// ⌘K: jump to any workspace, favourite, tool, recent folder, or (as you type) any folder Spotlight knows.
struct GoPalette: View {
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var found: [URL] = []
    @State private var index = 0
    @FocusState private var focused: Bool

    private struct Jump: Identifiable {
        let id: String, title: String, detail: String, symbol: String, target: SidebarTarget
    }

    private var jumps: [Jump] {
        let home = NSHomeDirectory()
        var all: [Jump] = Workspaces.shared.list.map { Jump(id: "w\($0.id)", title: $0.name, detail: "Workspace", symbol: "square.stack.3d.up", target: .page(.workspace($0.id))) }
        all += AppSettings.shared.favorites.map { Jump(id: $0.path, title: FileManager.default.displayName(atPath: $0.path), detail: FileRank.place($0.path, home: home), symbol: "folder", target: .folder($0)) }
        all += Page.tools.map { Jump(id: "t\($0.title)", title: $0.title, detail: "Tool", symbol: $0.symbol, target: .page($0)) }
        all += AppSettings.shared.recents.map { URL(fileURLWithPath: $0) }.map { Jump(id: $0.path, title: $0.lastPathComponent, detail: FileRank.place($0.path, home: home), symbol: "clock", target: .folder($0)) }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            all = all.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.detail.localizedCaseInsensitiveContains(q) }
            all += found.map { Jump(id: $0.path, title: $0.lastPathComponent, detail: FileRank.place($0.deletingLastPathComponent().path, home: home), symbol: "folder", target: .folder($0)) }
        }
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }.prefix(40).map { $0 }
    }

    var body: some View {
        let list = jumps
        VStack(spacing: 0) {
            TextField("Go to a workspace, folder or tool", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .focused($focused)
                .onSubmit { if list.indices.contains(index) { go(list[index]) } }
                .onKeyPress(.downArrow) { index = min(index + 1, max(list.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                .onExitCommand { dismiss() }
            Divider()
            ScrollViewReader { proxy in
                List(Array(list.enumerated()), id: \.element.id) { i, j in
                    HStack {
                        Image(systemName: j.symbol).frame(width: 20).foregroundStyle(.secondary)
                        Text(j.title)
                        Spacer()
                        Text(j.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .listRowBackground(i == index ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.25)) : nil)
                    .onTapGesture { go(j) }
                    .id(i)
                }
                .listStyle(.plain)
                .onChange(of: index) { proxy.scrollTo(index) }
            }
        }
        .frame(width: 560, height: 420)
        .onAppear { focused = true }
        .onChange(of: query) { index = 0 }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { found = []; return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let hits = await FileQuery.run(FileRank.words(q)) else { return }
            let ranked = FileRank.rank(q, hits.filter(\.isFolder), home: NSHomeDirectory(), limit: 15).rows
            if !Task.isCancelled { found = ranked.map { URL(fileURLWithPath: $0.path, isDirectory: true) } }
        }
    }

    private func go(_ j: Jump) {
        switch j.target {
        case let .folder(u): model.active.go(u)
        case let .page(p): model.active.showPage(p)
        }
        dismiss()
    }
}


/// A sidebar icon: a small filled tile in the row's own colour with a white symbol.
struct SidebarIcon: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5.5).fill(LinearGradient(colors: [color.mix(with: .white, by: 0.15), color], startPoint: .top, endPoint: .bottom)))
    }
}
