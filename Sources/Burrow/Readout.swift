import Foundation

/// Readings from Readout, the newi tools system monitor (a separate app: Burrow runs its `readout status --json`
/// command and reads its saved disk scan). Both apps then show the same numbers.
/// Everything is nil when Readout isn't installed; the pages fall back to their own readers.
enum Readout {
    struct Memory: Decodable {
        let used, total, app, wired, compressed, swap: Int64
        let pressure_percent: Double
        let pressure: String
    }

    struct Disk: Decodable, Identifiable {
        let name, mount: String
        let total, free: Int64
        var id: String { mount }
    }

    struct Status: Decodable {
        let memory: Memory
        let disks: [Disk]
    }

    struct Folder: Identifiable {
        let path: String
        let bytes: Int64
        var id: String { path }
    }

    static var command: String? {
        [NSHomeDirectory() + "/.local/bin/readout", "/Applications/Readout.app/Contents/MacOS/readout"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Blocks for about half a second (Readout measures CPU over that long); call it off the main thread.
    static func status() -> Status? {
        guard let command else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command)
        p.arguments = ["status", "--json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return try? JSONDecoder().decode(Status.self, from: data)
    }

    /// Folder sizes from Readout's last scan (folders of 50 MB and up, 4 levels deep), read once per launch.
    static let sizes: [String: Int64] = {
        let file = NSHomeDirectory() + "/Library/Application Support/Readout/disk-usage.tsv"
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [:] }
        var out: [String: Int64] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 2)
            if f.count == 3, f[0] == "dir" || f[0] == "root", let n = Int64(f[1]) { out[String(f[2])] = n }
        }
        return out
    }()

    /// The biggest folders from Readout's background scan (every 3 hours), and when it ran.
    /// A folder is left out when one of its own subfolders holds most of it, so the list names the folder
    /// that is actually big ("ml-studio-web", not every parent above it).
    static func biggestFolders(top: Int = 12) -> (folders: [Folder], scanned: Date)? {
        let file = NSHomeDirectory() + "/Library/Application Support/Readout/disk-usage.tsv"
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        var scanned: Date?
        var dirs: [Folder] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard f.count == 3, let n = Int64(f[1]) else { continue }
            if f[0] == "scanned" { scanned = Date(timeIntervalSince1970: TimeInterval(n)) }
            if f[0] == "dir" { dirs.append(Folder(path: f[2], bytes: n)) }
        }
        guard let scanned else { return nil }
        return (Array(owners(dirs).prefix(top)), scanned)
    }

    /// Biggest first, dropping any folder whose one subfolder holds 60% or more of it.
    static func owners(_ dirs: [Folder]) -> [Folder] {
        let big = dirs.sorted { $0.bytes > $1.bytes }
        return big.filter { d in !big.contains { $0.path.hasPrefix(d.path + "/") && $0.bytes * 10 >= d.bytes * 6 } }
    }

    static func selfCheck() {
        let a = Folder(path: "/a", bytes: 100), ab = Folder(path: "/a/b", bytes: 70), c = Folder(path: "/c", bytes: 50)
        let small = Folder(path: "/c/d", bytes: 20)
        precondition(owners([c, a, ab, small]).map(\.path) == ["/a/b", "/c", "/c/d"], "readout: a parent mostly made of one child gives way to it")
    }
}
