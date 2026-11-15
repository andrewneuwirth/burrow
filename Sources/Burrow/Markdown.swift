import AppKit
import SwiftUI

// MARK: Window

@MainActor
enum MarkdownWindow {
    private static var windows: [URL: NSWindow] = [:]

    static func open(_ url: URL) {
        let key = url.standardizedFileURL
        if let w = windows[key] { return w.makeKeyAndOrderFront(nil) }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = key.lastPathComponent
        w.representedURL = key
        w.contentViewController = NSHostingController(rootView: MarkdownDocView(url: key))
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("Markdown")
        w.center()
        w.makeKeyAndOrderFront(nil)
        windows[key] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { windows[key] = nil }
        }
    }
}

// MARK: Parser

indirect enum MDBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case list([MDListItem])
    case quote([MDBlock])
    case code(String, String)          // language, body
    case rule
    case table([String], [[String]])
    case image(String, String)         // alt, source
}

struct MDListItem: Equatable {
    var depth: Int
    var number: Int?                   // nil = bullet
    var done: Bool?                    // nil = not a task
    var text: String
}

enum MDParser {
    static func parse(_ source: String) -> [MDBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MDBlock] = []
        var i = 0
        while i < lines.count {
            let line = lines[i], t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { i += 1; continue }

            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                let fence = String(t.prefix(3)), lang = t.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { body.append(lines[i]); i += 1 }
                i += 1
                blocks.append(.code(lang, body.joined(separator: "\n")))
            } else if let h = heading(t) {
                blocks.append(.heading(h.0, h.1)); i += 1
            } else if isRule(t) {
                blocks.append(.rule); i += 1
            } else if t.hasPrefix(">") {
                var inner: [String] = []
                while i < lines.count, case let q = lines[i].trimmingCharacters(in: .whitespaces), q.hasPrefix(">") {
                    let rest = q.dropFirst()
                    inner.append(String(rest.hasPrefix(" ") ? rest.dropFirst() : rest)); i += 1
                }
                blocks.append(.quote(parse(inner.joined(separator: "\n"))))
            } else if t.hasPrefix("|"), i + 1 < lines.count, isSeparator(lines[i + 1]) {
                let header = cells(t)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, case let r = lines[i].trimmingCharacters(in: .whitespaces), r.hasPrefix("|") { rows.append(cells(r)); i += 1 }
                blocks.append(.table(header, rows))
            } else if listItem(line) != nil {
                var items: [MDListItem] = [], indents: [Int] = []
                while i < lines.count {
                    if let (indent, item) = listItem(lines[i]) {
                        while let last = indents.last, indent < last { indents.removeLast() }
                        if indents.last.map({ indent > $0 }) ?? true { indents.append(indent) }
                        var item = item
                        item.depth = indents.count - 1
                        items.append(item)
                    } else if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, lines[i].hasPrefix("  "), !items.isEmpty {
                        items[items.count - 1].text += " " + lines[i].trimmingCharacters(in: .whitespaces)   // wrapped continuation
                    } else if lines[i].trimmingCharacters(in: .whitespaces).isEmpty, i + 1 < lines.count, listItem(lines[i + 1]) != nil {
                        // a blank line between items keeps the list going
                    } else { break }
                    i += 1
                }
                blocks.append(.list(items))
            } else if let m = t.wholeMatch(of: try! Regex("!\\[(.*?)\\]\\((\\S+?)(?:\\s+\"[^\"]*\")?\\)")) {
                blocks.append(.image(m.output[1].substring.map(String.init) ?? "", m.output[2].substring.map(String.init) ?? ""))
                i += 1
            } else {
                var para: [String] = []
                while i < lines.count, case let p = lines[i].trimmingCharacters(in: .whitespaces), !p.isEmpty,
                      para.isEmpty || !startsBlock(lines[i]) {
                    para.append(p); i += 1
                }
                blocks.append(.paragraph(para.joined(separator: " ")))
            }
        }
        return blocks
    }

    private static func heading(_ t: String) -> (Int, String)? {
        let n = t.prefix { $0 == "#" }.count
        guard (1...6).contains(n), t.count == n || t.dropFirst(n).first == " " else { return nil }
        var text = t.dropFirst(n).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (n, text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ t: String) -> Bool {
        let s = t.filter { $0 != " " }
        return s.count >= 3 && ["-", "*", "_"].contains { c in s.allSatisfy { String($0) == c } }
    }

    private static func isSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.contains("-") && t.contains("|") && t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ row: String) -> [String] {
        var r = Substring(row)
        if r.hasPrefix("|") { r = r.dropFirst() }
        if r.hasSuffix("|") { r = r.dropLast() }
        return r.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// (indent in columns, item) when the line is a bullet or numbered item.
    private static func listItem(_ line: String) -> (Int, MDListItem)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let t = line.drop { $0 == " " || $0 == "\t" }
        var number: Int?, rest: Substring
        if let c = t.first, "-*+".contains(c), t.dropFirst().first == " " {
            rest = t.dropFirst(2)
        } else {
            let digits = t.prefix { $0.isNumber }
            let after = t.dropFirst(digits.count)
            guard !digits.isEmpty, digits.count < 10, let p = after.first, p == "." || p == ")", after.dropFirst().first == " " else { return nil }
            number = Int(digits); rest = after.dropFirst(2)
        }
        var done: Bool?
        if rest.hasPrefix("[ ] ") { done = false } else if rest.lowercased().hasPrefix("[x] ") { done = true }
        if done != nil { rest = rest.dropFirst(4) }
        return (indent, MDListItem(depth: 0, number: number, done: done, text: rest.trimmingCharacters(in: .whitespaces)))
    }

    private static func startsBlock(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("```") || t.hasPrefix("~~~") || t.hasPrefix(">") || heading(t) != nil || isRule(t) || listItem(line) != nil
            || (t.hasPrefix("|") && t.hasSuffix("|"))
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    static func selfCheck() {
        let doc = """
        # Title
        ## Sub ##
        Some *text*
        continues here.

        - one
          - nested
        - [x] done
        3. three

        ```swift
        let a = 1
        # not a heading
        ```
        | A | B |
        |---|:-:|
        | 1 | 2 |
        ---
        > quoted
        ![pic](img/a.png)
        """
        let b = parse(doc)
        assert(b.count == 9, "block count \(b.count): \(b)")
        assert(b[0] == .heading(1, "Title") && b[1] == .heading(2, "Sub"))
        assert(b[2] == .paragraph("Some *text* continues here."))
        assert(b[3] == .list([MDListItem(depth: 0, number: nil, done: nil, text: "one"),
                              MDListItem(depth: 1, number: nil, done: nil, text: "nested"),
                              MDListItem(depth: 0, number: nil, done: true, text: "done"),
                              MDListItem(depth: 0, number: 3, done: nil, text: "three")]))
        assert(b[4] == .code("swift", "let a = 1\n# not a heading"))
        assert(b[5] == .table(["A", "B"], [["1", "2"]]))
        assert(b[6] == .rule)
        assert(b[7] == .quote([.paragraph("quoted")]))
        assert(b[8] == .image("pic", "img/a.png"))
        assert(heading("#nope") == nil && listItem("2023. was a year")?.1.number == 2023)
    }
}

// MARK: View

struct MarkdownDocView: View {
    let url: URL
    enum Mode: String, CaseIterable { case preview = "Preview", edit = "Edit", split = "Split" }

    @State private var mode = Mode.preview
    @State private var text = ""
    @State private var saved = ""
    @State private var encoding = String.Encoding.utf8
    @State private var modified: Date?
    @State private var error: String?
    @State private var loaded = false
    @State private var autosave: Task<Void, Never>?

    private var blocks: [MDBlock] { MDParser.parse(text) }

    var body: some View {
        let blocks = blocks
        let outline = blocks.enumerated().compactMap { i, b -> (Int, Int, String)? in
            if case let .heading(level, title) = b, level <= 3 { return (i, level, title) }
            return nil
        }
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack {
                    Picker("Mode", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    if let error { Text(error).foregroundStyle(.red).lineLimit(1) }
                    else if text != saved { Text("Edited").foregroundStyle(.secondary) }
                    Button("Save", action: save).keyboardShortcut("s").disabled(text == saved)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                HSplitView {
                    if !outline.isEmpty && mode != .edit {
                        List(outline, id: \.0) { i, level, title in
                            Button(title) { withAnimation { proxy.scrollTo(i, anchor: .top) } }
                                .buttonStyle(.plain).lineLimit(1)
                                .font(level == 1 ? .body.weight(.semibold) : .body)
                                .padding(.leading, CGFloat(level - 1) * 12)
                        }
                        .listStyle(.sidebar).frame(minWidth: 140, idealWidth: 190, maxWidth: 300)
                    }
                    if mode != .preview {
                        TextEditor(text: $text).font(.system(size: 13, design: .monospaced)).frame(minWidth: 280)
                    }
                    if mode != .edit {
                        ScrollView {
                            MDBlocksView(blocks: blocks, base: url.deletingLastPathComponent())
                                .padding(24).frame(maxWidth: 820, alignment: .leading)
                                .frame(maxWidth: .infinity)
                        }
                        .frame(minWidth: 280)
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onDisappear(perform: save)
        .onChange(of: text) {
            autosave?.cancel()
            autosave = Task {
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled { save() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in reloadIfChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reloadIfChanged() }
    }

    private var diskDate: Date? { try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }

    private func load() {
        do {
            var enc = String.Encoding.utf8
            let s = try String(contentsOf: url, usedEncoding: &enc)
            encoding = enc; text = s; saved = s; modified = diskDate; error = nil; loaded = true
        } catch { self.error = "Couldn't read: \(error.localizedDescription)" }
    }

    /// Picks up edits made elsewhere, but never over unsaved typing here.
    private func reloadIfChanged() {
        guard text == saved, let d = diskDate, d != modified else { return }
        load()
    }

    private func save() {
        guard loaded, text != saved else { return }   // never write over a file that failed to load
        do {
            try text.write(to: url, atomically: true, encoding: encoding)
            saved = text; modified = diskDate; error = nil
        } catch { self.error = "Couldn't save: \(error.localizedDescription)" }
    }
}

private struct MDBlocksView: View {
    let blocks: [MDBlock]
    let base: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in block(b).id(i) }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func block(_ b: MDBlock) -> some View {
        switch b {
        case let .heading(level, t):
            VStack(alignment: .leading, spacing: 4) {
                Text(MDParser.inline(t)).font(.system(size: [28, 22, 18, 16, 14, 13][level - 1], weight: level <= 2 ? .bold : .semibold))
                    .padding(.top, level <= 2 ? 8 : 4)
                if level <= 2 { Divider() }
            }
        case let .paragraph(t):
            Text(MDParser.inline(t)).fixedSize(horizontal: false, vertical: true)
        case let .list(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let done = item.done {
                            Image(systemName: done ? "checkmark.square.fill" : "square").foregroundStyle(done ? Color.accentColor : .secondary)
                        } else {
                            Text(item.number.map { "\($0)." } ?? ["•", "◦", "▪︎"][item.depth % 3]).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Text(MDParser.inline(item.text)).fixedSize(horizontal: false, vertical: true)
                            .strikethrough(item.done == true, color: .secondary)
                    }
                    .padding(.leading, CGFloat(item.depth) * 20)
                }
            }
        case let .quote(inner):
            MDBlocksView(blocks: inner, base: base)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 3) }
        case let .code(_, body):
            ScrollView(.horizontal) {
                Text(body).font(.system(size: 12, design: .monospaced)).fixedSize().padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
        case .rule:
            Divider().padding(.vertical, 4)
        case let .table(header, rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { ForEach(Array(header.enumerated()), id: \.offset) { Text(MDParser.inline($1)).bold() } }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { Text(MDParser.inline($1)) } }
                }
            }
            .padding(10)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        case let .image(alt, src):
            image(alt, src)
        }
    }

    @ViewBuilder private func image(_ alt: String, _ src: String) -> some View {
        if let u = URL(string: src), let s = u.scheme, s == "http" || s == "https" {
            AsyncImage(url: u) { $0.resizable().scaledToFit() } placeholder: { Text(alt).foregroundStyle(.secondary) }
                .frame(maxWidth: 700, alignment: .leading)
        } else if let path = src.removingPercentEncoding,
                  // shortcut: reads the file on every render; add a cache if big local images make typing in Split lag
                  let img = NSImage(contentsOf: path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)) {
            Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: min(700, img.size.width), alignment: .leading)
        } else {
            Label(alt.isEmpty ? src : alt, systemImage: "photo").foregroundStyle(.secondary)
        }
    }
}
