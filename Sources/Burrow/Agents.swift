import AppKit
import SwiftUI

// "AI Agents": projects set up for Claude Code, Codex and Cursor, read from local files only.
// MCP configs can hold keys, so only server names and a command name / URL host are ever kept.

struct AgentProject: Identifiable {
    var id: String { path }
    let path: String
    let agents: [String]
    let files: [URL]
    let mcp: [String]
    let transcripts: URL?
    let lastActive: Date?
}

struct AgentMCP: Identifiable {
    var id: String { source + name }
    let source: String
    let name: String
    let target: String
}

struct AgentTokens {
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
}

enum AgentScan {
    static let fm = FileManager.default
    static let home = fm.homeDirectoryForCurrentUser.path
    static let markers = ["CLAUDE.md", "AGENTS.md", ".claude", ".cursor", ".cursorrules", ".mcp.json", ".codex"]
    static let setupFiles = ["CLAUDE.md", "AGENTS.md", ".cursorrules", ".mcp.json", ".claude/settings.json", ".claude/settings.local.json", ".cursor/mcp.json", ".codex/config.toml"]

    /// Claude Code names ~/.claude/projects folders by replacing every non-alphanumeric character with "-".
    static func encode(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// The encoding is lossy, so walk the disk and keep the child whose encoded name matches.
    static func decode(_ enc: String) -> String? {
        let base = encode(home)
        guard enc.hasPrefix(base + "-") else { return enc == base ? home : nil }
        func walk(_ dir: String, _ rest: Substring) -> String? {
            for kid in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                let e = encode(kid), path = dir + "/" + kid
                if rest == e { return path }
                if rest.hasPrefix(e + "-"), isDir(path), let hit = walk(path, rest.dropFirst(e.count + 1)) { return hit }
            }
            return nil
        }
        return walk(home, enc.dropFirst(base.count + 1))
    }

    static func isDir(_ p: String) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue
    }

    static func jsonDict(_ path: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: Any] ?? [:]
    }

    static func target(_ server: Any?) -> String {
        let s = server as? [String: Any] ?? [:]
        if let u = s["url"] as? String { return URL(string: u)?.host ?? "remote" }
        return (s["command"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
    }

    static func load() -> ([AgentProject], [AgentMCP]) {
        let claude = jsonDict(home + "/.claude.json")
        let claudeProjects = claude["projects"] as? [String: [String: Any]] ?? [:]
        let codexToml = (try? String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8)) ?? ""
        let codexPaths = Set(codexToml.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("[projects.\""), let end = line.lastIndex(of: "\"") else { return nil }
            return String(line[line.index(line.startIndex, offsetBy: 11)..<end])
        })
        let transcriptRoot = home + "/.claude/projects"

        var paths = Set(claudeProjects.keys).union(codexPaths)
        for enc in (try? fm.contentsOfDirectory(atPath: transcriptRoot)) ?? [] { if let p = decode(enc) { paths.insert(p) } }
        func scan(_ dir: String, _ depth: Int) {
            guard depth <= 3, let kids = try? fm.contentsOfDirectory(atPath: dir) else { return }
            if depth > 0, kids.contains(where: markers.contains) { paths.insert(dir) }
            for k in kids where !k.hasPrefix(".") && !["node_modules", "build", "Pods", "DerivedData"].contains(k) {
                let p = dir + "/" + k
                if isDir(p) { scan(p, depth + 1) }
            }
        }
        scan(home + "/Developer", 0)

        let projects = paths.filter { $0.hasPrefix(home + "/") && !$0.contains("/.claude/worktrees/") && isDir($0) }.map { path -> AgentProject in
            let has = { (f: String) in fm.fileExists(atPath: path + "/" + f) }
            let tdir = transcriptRoot + "/" + encode(path)
            let tURL = isDir(tdir) ? URL(fileURLWithPath: tdir) : nil
            var agents: [String] = []
            if has("CLAUDE.md") || has(".claude") || has(".mcp.json") || claudeProjects[path] != nil || tURL != nil { agents.append("Claude Code") }
            if has("AGENTS.md") || has(".codex") || codexPaths.contains(path) { agents.append("Codex") }
            if has(".cursor") || has(".cursorrules") { agents.append("Cursor") }
            var mcp = Set((jsonDict(path + "/.mcp.json")["mcpServers"] as? [String: Any] ?? [:]).keys)
            mcp.formUnion((claudeProjects[path]?["mcpServers"] as? [String: Any] ?? [:]).keys)
            mcp.formUnion((jsonDict(path + "/.cursor/mcp.json")["mcpServers"] as? [String: Any] ?? [:]).keys)
            let last = tURL.flatMap { u in
                (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.contentModificationDateKey]))?
                    .filter { $0.pathExtension == "jsonl" }
                    .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
            }
            return AgentProject(path: path, agents: agents, files: setupFiles.filter(has).map { URL(fileURLWithPath: path + "/" + $0) },
                                mcp: mcp.sorted(), transcripts: tURL, lastActive: last)
        }.sorted { ($0.lastActive ?? .distantPast, $1.path) > ($1.lastActive ?? .distantPast, $0.path) }

        var global: [AgentMCP] = []
        for (src, dict) in [("Claude Code", claude), ("Cursor", jsonDict(home + "/.cursor/mcp.json"))] {
            let servers = dict["mcpServers"] as? [String: Any] ?? [:]
            global += servers.keys.sorted().map { AgentMCP(source: src, name: $0, target: target(servers[$0])) }
        }
        // config.toml: [mcp_servers.<name>] tables with `command = "…"` or `url = "…"`.
        var current: String?, codexServers: [String: [String: Any]] = [:]
        for raw in codexToml.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = line.hasPrefix("[mcp_servers.") && !line.dropFirst(13).contains(".")
                    ? String(line.dropFirst(13).dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) : nil
                if let c = current, codexServers[c] == nil { codexServers[c] = [:] }
            } else if let c = current, let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                if key == "command" || key == "url" {
                    codexServers[c]?[key] = line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                }
            }
        }
        global += codexServers.keys.sorted().map { AgentMCP(source: "Codex", name: $0, target: target(codexServers[$0])) }
        return (projects, global)
    }

    /// Sums `usage` from every transcript, streaming line by line. A reply is logged once per content block
    /// with the same usage, so each message id is counted once.
    static func tokens(_ dir: URL) async -> AgentTokens {
        var t = AgentTokens(), seen = Set<String>()
        let files = (fm.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "jsonl" }
        for file in files {
            do {
                for try await line in file.lines where line.contains("\"usage\"") {
                    guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                          let msg = obj["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] else { continue }
                    if let id = msg["id"] as? String, !seen.insert(id).inserted { continue }
                    t.input += u["input_tokens"] as? Int ?? 0
                    t.output += u["output_tokens"] as? Int ?? 0
                    t.cacheWrite += u["cache_creation_input_tokens"] as? Int ?? 0
                    t.cacheRead += u["cache_read_input_tokens"] as? Int ?? 0
                }
            } catch { continue }
        }
        return t
    }
}

@MainActor @Observable
final class AgentsStore {
    static let shared = AgentsStore()
    var projects: [AgentProject] = []
    var global: [AgentMCP] = []
    var tokens: [String: AgentTokens] = [:]
    var loading = false
    private var counting = Set<String>()

    func reload() async {
        loading = true
        (projects, global) = await Task.detached { AgentScan.load() }.value
        tokens = [:]
        counting = []
        loading = false
    }

    func countTokens(_ p: AgentProject) async {
        guard let dir = p.transcripts, tokens[p.path] == nil, counting.insert(p.path).inserted else { return }
        tokens[p.path] = await Task.detached { await AgentScan.tokens(dir) }.value
    }
}

struct AgentsPage: View {
    @State private var store = AgentsStore.shared
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Agents").font(.title2.bold())
                    Text("Projects set up for Claude Code, Codex and Cursor. Read from this Mac only, nothing is sent anywhere.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await store.reload() } }.disabled(store.loading)
            }
            .padding()
            TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).padding(.horizontal).padding(.bottom, 8)
            List {
                let shown = store.projects.filter { filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter) || $0.mcp.contains { $0.localizedCaseInsensitiveContains(filter) } }
                Section("Projects (\(shown.count))") { ForEach(shown, content: card) }
                let g = store.global.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
                if !g.isEmpty {
                    Section("Global MCP Servers") {
                        ForEach(g) { s in
                            HStack {
                                Text(s.name)
                                Text(s.target).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Spacer()
                                Text(s.source).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .task { if store.projects.isEmpty { await store.reload() } }
    }

    private func card(_ p: AgentProject) -> some View {
        let url = URL(fileURLWithPath: p.path)
        return HStack(alignment: .top, spacing: 10) {
            Image(nsImage: Icons.icon(url)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(url.lastPathComponent).font(.headline)
                    ForEach(p.agents, id: \.self) { a in
                        Text(a).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                    Spacer()
                    if let d = p.lastActive { Text(Fmt.date(d)).font(.caption).foregroundStyle(.secondary) }
                }
                Text((p.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary)
                if !p.files.isEmpty {
                    HStack {
                        ForEach(p.files, id: \.self) { f in
                            Button(f.path.dropFirst(p.path.count + 1)) { NSWorkspace.shared.open(f) }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                }
                if !p.mcp.isEmpty { Text("MCP: " + p.mcp.joined(separator: ", ")).font(.caption) }
                if p.transcripts != nil { Text(tokenLine(store.tokens[p.path])).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { Windows.shared.open(url) }
        .task(id: p.path) { await store.countTokens(p) }
    }

    private func tokenLine(_ t: AgentTokens?) -> String {
        guard let t else { return "Claude Code tokens: —" }
        let f = { (n: Int) in n.formatted(.number.notation(.compactName)) }
        return "Claude Code tokens: \(f(t.input)) in · \(f(t.output)) out · \(f(t.cacheWrite)) cache write · \(f(t.cacheRead)) cache read"
    }
}
