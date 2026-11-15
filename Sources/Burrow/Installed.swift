import AppKit
import SwiftUI

// "Installed": what package managers put on this Mac. Read-only: cleanup and uninstall commands are only ever copied.

struct InstPkg: Identifiable {
    let id = UUID()
    let name: String
    let version: String
    var note = ""
    let uninstall: String
    var folder: URL? = nil
}

struct InstSection: Identifiable {
    var id: String { title }
    let title: String
    let pkgs: [InstPkg]
    let restore: [String]   // lines for the new-Mac list
}

struct InstTidy: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let command: String
}

fileprivate enum InstSh {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    // The app's PATH is minimal; /usr/bin is left out so Xcode's pip3 stub can't pop an install dialog.
    static let dirs = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.cargo/bin", home + "/.volta/bin"]

    static func tool(_ name: String) -> String? {
        dirs.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs off the main thread, stdout only, killed after `timeout` seconds.
    static func run(_ exe: String?, _ args: [String], timeout: Double = 10) async -> String {
        guard let exe else { return "" }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = (dirs + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
                env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
                p.environment = env
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { return cont.resume(returning: "") }
                let kill = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: kill)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                kill.cancel()
                cont.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }

    static func json(_ s: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(s.utf8)) }

    static func dirSize(_ path: String) -> Int64 {
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0) }
        return total
    }

    static func kids(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

enum InstScan {
    static func load() async -> ([InstSection], [InstTidy]) {
        let fm = FileManager.default, home = InstSh.home
        let brewPrefix = ["/opt/homebrew", "/usr/local"].first { fm.fileExists(atPath: $0 + "/Cellar") }
        let pip = InstSh.tool("pip3"), pipx = InstSh.tool("pipx"), uv = InstSh.tool("uv"), npm = InstSh.tool("npm")
        let gem = ["/opt/homebrew/opt/ruby/bin/gem", "/usr/local/opt/ruby/bin/gem", home + "/.rbenv/shims/gem"].first { fm.isExecutableFile(atPath: $0) }
        async let npmOut = InstSh.run(npm, ["ls", "-g", "--depth=0", "--json"])
        async let npmRoot = InstSh.run(npm, ["root", "-g"])
        async let pipOut = InstSh.run(pip, ["list", "--format=json"])
        async let pipxOut = InstSh.run(pipx, ["list", "--json"])
        async let uvOut = InstSh.run(uv, ["tool", "list"])
        async let gemOut = InstSh.run(gem, ["list", "--local"])

        var sections: [InstSection] = [], tidy: [InstTidy] = []

        // Homebrew: read the Cellar and Caskroom directly (faster than `brew list`, and survives untrusted-tap errors).
        if let bp = brewPrefix {
            var formulae: [InstPkg] = [], restore: [String] = [], taps = Set<String>(), old: [String] = [], oldSize: Int64 = 0
            for name in InstSh.kids(bp + "/Cellar") {
                let dir = bp + "/Cellar/" + name, versions = InstSh.kids(dir)
                guard let last = versions.last else { continue }
                let receipt = InstSh.json((try? String(contentsOfFile: dir + "/" + last + "/INSTALL_RECEIPT.json", encoding: .utf8)) ?? "") as? [String: Any]
                let onRequest = receipt?["installed_on_request"] as? Bool ?? true
                let tap = (receipt?["source"] as? [String: Any])?["tap"] as? String ?? "homebrew/core"
                let full = tap == "homebrew/core" ? name : tap + "/" + name
                formulae.append(InstPkg(name: name, version: versions.joined(separator: ", "), note: onRequest ? "" : "dependency",
                                        uninstall: "brew uninstall \(name)", folder: URL(fileURLWithPath: dir)))
                if onRequest { restore.append("brew \"\(full)\""); if tap != "homebrew/core" { taps.insert(tap) } }
                if versions.count > 1 {
                    old.append(name)
                    oldSize += versions.dropLast().reduce(0) { $0 + InstSh.dirSize(dir + "/" + $1) }
                }
            }
            if !old.isEmpty {
                tidy.append(InstTidy(title: "Older versions of \(old.count) formulae (\(ByteCountFormatter.string(fromByteCount: oldSize, countStyle: .file)))",
                                     detail: old.joined(separator: ", "), command: "brew cleanup"))
            }
            sections.append(InstSection(title: "Homebrew Formulae", pkgs: formulae, restore: taps.sorted().map { "tap \"\($0)\"" } + restore))
            let casks = InstSh.kids(bp + "/Caskroom").map { name in
                InstPkg(name: name, version: InstSh.kids(bp + "/Caskroom/" + name).joined(separator: ", "),
                        uninstall: "brew uninstall --cask \(name)", folder: URL(fileURLWithPath: bp + "/Caskroom/" + name))
            }
            sections.append(InstSection(title: "Homebrew Casks", pkgs: casks, restore: casks.map { "cask \"\($0.name)\"" }))
        }

        if let deps = (InstSh.json(await npmOut) as? [String: Any])?["dependencies"] as? [String: [String: Any]] {
            let root = (await npmRoot).trimmingCharacters(in: .whitespacesAndNewlines)
            let pkgs = deps.keys.sorted().map { n in
                InstPkg(name: n, version: deps[n]?["version"] as? String ?? "", uninstall: "npm uninstall -g \(n)",
                        folder: root.isEmpty ? nil : URL(fileURLWithPath: root + "/" + n))
            }
            let mine = pkgs.map(\.name).filter { !["npm", "corepack"].contains($0) }
            sections.append(InstSection(title: "npm (global)", pkgs: pkgs, restore: mine.isEmpty ? [] : ["npm install -g " + mine.joined(separator: " ")]))
        }

        if let list = InstSh.json(await pipOut) as? [[String: Any]] {
            let pkgs = list.map { InstPkg(name: $0["name"] as? String ?? "?", version: $0["version"] as? String ?? "", uninstall: "pip3 uninstall \($0["name"] as? String ?? "")") }
            let mine = pkgs.map(\.name).filter { !["pip", "setuptools", "wheel"].contains($0.lowercased()) }
            sections.append(InstSection(title: "pip", pkgs: pkgs, restore: mine.isEmpty ? [] : ["pip3 install " + mine.joined(separator: " ")]))
        }

        if let venvs = (InstSh.json(await pipxOut) as? [String: Any])?["venvs"] as? [String: [String: Any]] {
            let pkgs = venvs.keys.sorted().map { n in
                let main = (venvs[n]?["metadata"] as? [String: Any])?["main_package"] as? [String: Any]
                return InstPkg(name: n, version: main?["package_version"] as? String ?? "", uninstall: "pipx uninstall \(n)",
                               folder: URL(fileURLWithPath: home + "/.local/pipx/venvs/" + n))
            }
            sections.append(InstSection(title: "pipx", pkgs: pkgs, restore: pkgs.map { "pipx install \($0.name)" }))
        }

        // `uv tool list` prints "name vX.Y" lines, each followed by "- executable" lines.
        let uvPkgs = (await uvOut).split(separator: "\n").filter { !$0.hasPrefix("-") }.compactMap { line -> InstPkg? in
            let parts = line.split(separator: " ")
            guard let n = parts.first.map(String.init) else { return nil }
            return InstPkg(name: n, version: parts.dropFirst().first.map { String($0.drop { $0 == "v" }) } ?? "",
                           uninstall: "uv tool uninstall \(n)", folder: URL(fileURLWithPath: home + "/.local/share/uv/tools/" + n))
        }
        if !uvPkgs.isEmpty { sections.append(InstSection(title: "uv tools", pkgs: uvPkgs, restore: uvPkgs.map { "uv tool install \($0.name)" })) }

        // Cargo: .crates.toml lists `"name version (source)" = [bins]`; rustup's own proxies in ~/.cargo/bin aren't installs.
        let crates = ((try? String(contentsOfFile: home + "/.cargo/.crates.toml", encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line -> InstPkg? in
            guard line.hasPrefix("\"") else { return nil }
            let parts = line.dropFirst().split(separator: " ")
            guard parts.count >= 2 else { return nil }
            return InstPkg(name: String(parts[0]), version: String(parts[1]), uninstall: "cargo uninstall \(parts[0])")
        }
        if !crates.isEmpty { sections.append(InstSection(title: "Cargo", pkgs: crates, restore: crates.map { "cargo install \($0.name)" })) }

        // `gem list --local` prints "name (1.2, default: 1.1)".
        let gems = (await gemOut).split(separator: "\n").compactMap { line -> InstPkg? in
            guard let open = line.firstIndex(of: "(") else { return nil }
            let n = line[..<open].trimmingCharacters(in: .whitespaces)
            return InstPkg(name: n, version: line[line.index(after: open)...].replacingOccurrences(of: ")", with: ""), uninstall: "gem uninstall \(n)")
        }
        if !gems.isEmpty {
            // Left out of the new-Mac list: Ruby's bundled gems can't be told apart from ones installed on purpose.
            sections.append(InstSection(title: "Ruby Gems", pkgs: gems, restore: []))
        }

        let caches: [(String, String, String)] = [
            ("Homebrew", home + "/Library/Caches/Homebrew", "brew cleanup --prune=all"),
            ("npm", home + "/.npm/_cacache", "npm cache clean --force"),
            ("pip", home + "/Library/Caches/pip", "pip3 cache purge"),
            ("uv", home + "/.cache/uv", "uv cache clean"),
            ("Yarn", home + "/Library/Caches/Yarn", "yarn cache clean"),
            ("pnpm", home + "/Library/pnpm/store", "pnpm store prune"),
            ("Cargo registry", home + "/.cargo/registry/cache", "rm -rf ~/.cargo/registry/cache"),
            ("Go modules", home + "/go/pkg/mod", "go clean -modcache"),
        ]
        var cacheRows: [InstTidy] = []
        for (name, path, cmd) in caches where fm.fileExists(atPath: path) {
            let size = InstSh.dirSize(path)
            if size > 0 { cacheRows.append(InstTidy(title: "\(name) cache", detail: ByteCountFormatter.string(fromByteCount: size, countStyle: .file), command: cmd)) }
        }

        // Several Pythons: Homebrew's python@3.x formulae and uv-managed ones (uv keeps "cpython-3.12" aliases next to "cpython-3.12.4").
        if let bp = brewPrefix {
            let pys = InstSh.kids(bp + "/Cellar").filter { $0.hasPrefix("python@") }
            if pys.count > 1 { tidy.append(InstTidy(title: "\(pys.count) Homebrew Pythons", detail: pys.joined(separator: ", "), command: "brew uses --installed \(pys[0])")) }
        }
        let uvPys = InstSh.kids(home + "/.local/share/uv/python").compactMap { n -> String? in
            let v = n.split(separator: "-").dropFirst().first.map(String.init) ?? ""
            return v.split(separator: ".").count == 3 ? v : nil
        }
        if uvPys.count > 1 {
            tidy.append(InstTidy(title: "\(uvPys.count) uv Pythons", detail: uvPys.joined(separator: ", "), command: "uv python uninstall " + uvPys.dropLast().joined(separator: " ")))
        }
        return (sections, cacheRows + tidy)
    }
}

struct InstalledPage: View {
    @State private var sections: [InstSection] = []
    @State private var tidy: [InstTidy] = []
    @State private var loading = false
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Installed").font(.title2.bold())
                    Text("Everything package managers put on this Mac. Burrow only copies commands, it never runs them.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await reload() } }.disabled(loading)
                Button("Save List for a New Mac…", action: saveList).disabled(sections.isEmpty)
            }
            .padding()
            TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).padding(.horizontal).padding(.bottom, 8)
            List {
                ForEach(sections) { s in
                    let pkgs = s.pkgs.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
                    if !pkgs.isEmpty {
                        Section("\(s.title) (\(pkgs.count))") { ForEach(pkgs, content: row) }
                    }
                }
                let t = tidy.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }
                if !t.isEmpty {
                    Section("Tidy Up") {
                        ForEach(t) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.title)
                                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(item.command).font(.caption.monospaced()).textSelection(.enabled)
                                Button("Copy") { copy(item.command) }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
        }
        .task { if sections.isEmpty { await reload() } }
    }

    private func row(_ p: InstPkg) -> some View {
        HStack {
            Text(p.name)
            if !p.note.isEmpty { Text(p.note).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Text(p.version).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Copy Uninstall Command") { copy(p.uninstall) }
            if let f = p.folder, FileManager.default.fileExists(atPath: f.path) {
                Button("Show in Burrow") { Windows.shared.open(f) }
            }
        }
    }

    private func reload() async {
        loading = true
        (sections, tidy) = await Task.detached { await InstScan.load() }.value
        loading = false
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func saveList() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "New Mac Setup.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var out = "# Homebrew: save this part as a Brewfile and run `brew bundle`\n"
        for s in sections where s.title.hasPrefix("Homebrew") { out += s.restore.joined(separator: "\n") + "\n" }
        out += "\n# Other package managers\n"
        for s in sections where !s.title.hasPrefix("Homebrew") && !s.restore.isEmpty { out += s.restore.joined(separator: "\n") + "\n" }
        do { try out.write(to: url, atomically: true, encoding: .utf8) } catch { FileOps.alert("Couldn't save the list", error.localizedDescription) }
    }
}
