import AppKit
import SwiftUI

/// Smart Downloads: loose files sorted into folders by kind (preview first, every group can be unticked),
/// plus flags for what is probably safe to throw out. Nothing moves until "Sort", flagged files start
/// unticked and only ever go to the Trash, and ⌘Z puts everything back.
enum Tidy {
    static let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").folder

    /// Still arriving: browsers' partial files, and anything changed in the last minute.
    static func inProgress(_ item: FileItem, now: Date = Date()) -> Bool {
        ["crdownload", "download", "part", "partial", "opdownload", "tmp"].contains(item.url.pathExtension.lowercased())
            || (item.modified.map { now.timeIntervalSince($0) < 60 } ?? false)
    }

    struct Plan {
        var groups: [(bucket: Bucket, files: [FileItem])]
        var installers: [FileItem]   // a .dmg/.pkg for an app that is already in Applications
        var duplicates: [FileItem]   // "name (1).pdf" next to "name.pdf" of the same size
        var stale: [FileItem]        // in Downloads 90+ days and not opened since
    }

    static func plan(_ items: [FileItem], apps: [String] = installedApps(), now: Date = Date()) -> Plan {
        let loose = items.filter { !$0.opensAsFolder && !inProgress($0, now: now) && !$0.name.hasPrefix(".") }
        let groups = Bucket.allCases.filter { $0 != .folders }.compactMap { b -> (Bucket, [FileItem])? in
            let files = loose.filter { Bucket.of($0) == b }
            return files.isEmpty ? nil : (b, files)
        }
        let installers = loose.filter { f in
            ["dmg", "pkg", "mpkg"].contains(f.url.pathExtension.lowercased()) && apps.contains { appMatches($0, installer: f.name) }
        }
        let bySize = Dictionary(grouping: loose, by: { "\(original($0.name))#\($0.size ?? -1)" })
        let duplicates = loose.filter { f in
            original(f.name) != f.name && (bySize["\(original(f.name))#\(f.size ?? -1)"]?.contains { $0.name == original(f.name) } ?? false)
        }
        let stale = loose.filter { f in
            guard let added = f.added, now.timeIntervalSince(added) > 90 * 86_400 else { return false }
            return (lastUsed(f.url).map { now.timeIntervalSince($0) > 90 * 86_400 } ?? true)
        }
        return Plan(groups: groups, installers: installers, duplicates: duplicates, stale: stale)
    }

    /// "Report (1).pdf", "Report 2.pdf", "Report-1.pdf" → "Report.pdf".
    static func original(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        let stripped = base.replacing(#/(\s\(\d+\)|\s\d|-\d)$/#, with: "")
        guard stripped != base, !stripped.isEmpty else { return name }
        return ext.isEmpty ? stripped : "\(stripped).\(ext)"
    }

    /// "Slack-4.41.dmg" and "Slack.app": the installer's first word is the app's name.
    static func appMatches(_ app: String, installer: String) -> Bool {
        let first = (installer as NSString).deletingPathExtension.lowercased()
            .split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        return first.count >= 3 && app.lowercased().replacingOccurrences(of: " ", with: "").hasPrefix(first)
    }

    static func installedApps() -> [String] {
        ["/Applications", NSHomeDirectory() + "/Applications"].flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
            .filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
    }

    static func lastUsed(_ url: URL) -> Date? {
        guard let md = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(md, kMDItemLastUsedDate) as? Date
    }

    static func selfCheck() {
        precondition(original("Report (1).pdf") == "Report.pdf" && original("Report 2.pdf") == "Report.pdf" && original("Report.pdf") == "Report.pdf",
                     "tidy: duplicate names")
        precondition(appMatches("Slack", installer: "Slack-4.41.0-macOS.dmg") && !appMatches("Slack", installer: "Zoom.pkg"), "tidy: installer match")
        precondition(!appMatches("Notion", installer: "No.dmg"), "tidy: too-short names never match")
    }
}

struct TidySheet: View {
    let pane: PaneModel
    @Environment(\.dismiss) private var dismiss
    @State private var plan: Tidy.Plan?
    @State private var on: Set<Bucket> = []
    @State private var flagged: Set<URL> = []
    @State private var open: Set<Bucket> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tidy “\(pane.url.lastPathComponent)”").font(.title3.bold()).padding([.horizontal, .top], 18)
            Text("Loose files go into a folder per kind, inside this folder. Nothing moves until you press Sort, and ⌘Z undoes it.")
                .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 10)
            Divider()
            if let plan {
                List {
                    Section("Sort into folders") {
                        if plan.groups.isEmpty { Text("Nothing loose to sort.").foregroundStyle(.secondary) }
                        ForEach(plan.groups, id: \.bucket) { g in
                            DisclosureGroup(isExpanded: member($open, g.bucket)) {
                                ForEach(g.files) { f in Text(f.name).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary) }
                            } label: {
                                Toggle(isOn: member($on, g.bucket)) {
                                    Text("\(g.files.count) \(g.bucket.title.lowercased()) → \(g.bucket.title)/")
                                }
                            }
                        }
                    }
                    flags("Installers for apps you already have", plan.installers)
                    flags("Likely duplicates", plan.duplicates)
                    flags("Untouched for 90 days", plan.stale)
                }
                .listStyle(.inset)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                if !flagged.isEmpty {
                    Button("Move \(flagged.count) Flagged to Trash") {
                        FileOps.shared.trash(Array(flagged))
                        flagged = []
                        reload()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sort \(sortCount) Files") { sort(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sortCount == 0)
            }
            .padding(14)
        }
        .frame(width: 520, height: 520)
        .task { reload() }
    }

    private func member<T: Hashable>(_ set: Binding<Set<T>>, _ x: T) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(x) }, set: { if $0 { set.wrappedValue.insert(x) } else { set.wrappedValue.remove(x) } })
    }

    private var sortCount: Int { plan?.groups.filter { on.contains($0.bucket) }.reduce(0) { $0 + $1.files.count } ?? 0 }

    @ViewBuilder private func flags(_ title: String, _ files: [FileItem]) -> some View {
        if !files.isEmpty {
            Section(title) {
                ForEach(files) { f in
                    Toggle(isOn: member($flagged, f.url)) {
                        HStack {
                            Text(f.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Fmt.size(f)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func reload() {
        let items = pane.items
        Task.detached {
            let p = Tidy.plan(items)
            await MainActor.run {
                plan = p
                if on.isEmpty { on = Set(p.groups.map(\.bucket)) }
            }
        }
    }

    private func sort() {
        guard let plan else { return }
        for g in plan.groups where on.contains(g.bucket) {
            let dest = pane.url.appendingPathComponent(g.bucket.title, isDirectory: true)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            // A file flagged for the Trash is not also sorted.
            FileOps.shared.transfer(g.files.map(\.url).filter { !flagged.contains($0) }, to: dest, copy: false)
        }
    }
}
