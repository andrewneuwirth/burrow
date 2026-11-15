import AppKit
import SwiftUI

/// Finder's column view: one column per folder from `columnRoot` down to the pane's folder, the next folder
/// highlighted in each, and a preview column for a selected file. The last column is the pane itself
/// (its selection, sort and filter); the ones before it are read straight from disk.
struct ColumnView: View {
    @Bindable var pane: PaneModel
    private let width: CGFloat = 230

    private var ancestors: [URL] {
        var out: [URL] = [], u = pane.url
        while u.path != pane.columnRoot.path, u.path.hasPrefix(pane.columnRoot.path), u.path != "/" {
            u = u.deletingLastPathComponent().folder
            out.insert(u, at: 0)
        }
        return out
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(ancestors, id: \.self) { folder in
                        AncestorColumn(folder: folder, chosen: chosen(after: folder), pane: pane).frame(width: width)
                        Divider()
                    }
                    CurrentColumn(pane: pane).frame(width: width).id("current")
                    Divider()
                    if pane.selection.count == 1, let f = pane.selectedItems.first {
                        // A folder shows what's inside (→ or a click goes in); a file shows its preview.
                        if f.opensAsFolder {
                            AncestorColumn(folder: f.target, chosen: nil, pane: pane).frame(width: width).id("preview")
                        } else {
                            PreviewColumn(item: f).frame(width: 300).id("preview")
                        }
                        Divider()
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .onChange(of: pane.url) { withAnimation { proxy.scrollTo("current", anchor: .trailing) } }
            .onChange(of: pane.selection) { withAnimation { proxy.scrollTo(pane.selection.count == 1 ? "preview" : "current", anchor: .trailing) } }
        }
    }

    /// The child of `folder` on the way down to the pane's folder.
    private func chosen(after folder: URL) -> URL? {
        let rest = pane.url.path.dropFirst(folder.path == "/" ? 1 : folder.path.count + 1)
        guard let next = rest.split(separator: "/").first else { return nil }
        return folder.appendingPathComponent(String(next), isDirectory: true).folder
    }
}

private struct AncestorColumn: View {
    let folder: URL
    let chosen: URL?
    let pane: PaneModel
    @State private var items: [FileItem] = []

    var body: some View {
        List(items) { item in
            ColumnRow(item: item, selected: item.target.folder == chosen && item.opensAsFolder)
                .contentShape(Rectangle())
                .onTapGesture {
                    if item.opensAsFolder { pane.go(item.target) } else { pane.go(folder, select: [item.url]) }
                }
                .onDrag { NSItemProvider(object: item.url as NSURL) }
                .contextMenu { ItemMenu(pane: pane, urls: [item.url]) }
        }
        .listStyle(.plain)
        .task(id: "\(folder.path)#\(AppSettings.shared.showHidden)") {
            let hidden = AppSettings.shared.showHidden, folder = folder, foldersFirst = AppSettings.shared.foldersFirst
            items = await Task.detached {
                let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: FileItem.keys,
                                                                       options: hidden ? [] : [.skipsHiddenFiles])) ?? []
                let sorted = urls.map(FileItem.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return foldersFirst ? sorted.filter(\.opensAsFolder) + sorted.filter { !$0.opensAsFolder } : sorted
            }.value
        }
    }
}

private struct CurrentColumn: View {
    @Bindable var pane: PaneModel
    var body: some View {
        List(selection: $pane.selection) {
            ForEach(pane.visible) { item in
                ColumnRow(item: item, selected: false).tag(item.url)
                    .onDrag { NSItemProvider(object: item.url as NSURL) }
            }
        }
        .listStyle(.plain)
        .contextMenu(forSelectionType: URL.self) { sel in
            ItemMenu(pane: pane, urls: sel)
        } primaryAction: { sel in
            pane.open(pane.visible.filter { sel.contains($0.url) })
        }
    }
}

private struct ColumnRow: View {
    let item: FileItem
    let selected: Bool
    var body: some View {
        HStack(spacing: 6) {
            FileIcon(item: item, size: 16, thumbnail: false)
            Text(item.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if item.opensAsFolder { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 1)
        .listRowBackground(selected ? RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.25)) : nil)
    }
}

private struct PreviewColumn: View {
    let item: FileItem
    var body: some View {
        VStack(spacing: 8) {
            FileIcon(item: item, size: 220, thumbnail: true)
            Text(item.name).font(.headline).multilineTextAlignment(.center).lineLimit(3)
            Text(item.kind).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow { Text("Size").foregroundStyle(.secondary); Text(Fmt.size(item)) }
                GridRow { Text("Created").foregroundStyle(.secondary); Text(Fmt.date(item.created)) }
                GridRow { Text("Modified").foregroundStyle(.secondary); Text(Fmt.date(item.modified)) }
            }
            .font(.caption)
            Spacer()
        }
        .padding(14)
    }
}
