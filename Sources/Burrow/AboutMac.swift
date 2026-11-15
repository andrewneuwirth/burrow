import AppKit
import IOKit
import SwiftUI

/// Read-only facts about this Mac, from sysctl, IOKit, Mach and a few command line tools.
enum MacFacts {
    static func sysctl(_ name: String) -> String {
        var len = 0
        guard sysctlbyname(name, nil, &len, nil, 0) == 0, len > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: len)
        guard sysctlbyname(name, &buf, &len, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }

    struct Battery {
        var health: Int?
        var cycles: Int?
        var charge: Int?
        var condition: String
        var state: String
    }

    static func battery() -> Battery? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any], d["BatteryInstalled"] as? Bool != false else { return nil }
        // Apple silicon reports MaxCapacity as a percent and keeps the mAh figures in BatteryData.
        let data = d["BatteryData"] as? [String: Any] ?? [:]
        let rawMax = d["AppleRawMaxCapacity"] as? Int ?? data["FullChargeCapacity"] as? Int
        let design = d["DesignCapacity"] as? Int ?? data["DesignCapacity"] as? Int
        let health = rawMax.flatMap { r in design.flatMap { $0 > 0 ? min(100, r * 100 / $0) : nil } }
        let maxCap = d["MaxCapacity"] as? Int ?? 0
        let charge = (d["CurrentCapacity"] as? Int).map { maxCap > 0 ? $0 * 100 / maxCap : $0 }
        let failed = (d["PermanentFailureStatus"] as? Int ?? 0) != 0
        let condition = failed || (health ?? 100) < 80 ? "Service recommended" : "Normal"
        let state = d["IsCharging"] as? Bool == true ? "Charging"
            : d["ExternalConnected"] as? Bool == true ? "Plugged in, not charging" : "On battery"
        return Battery(health: health, cycles: d["CycleCount"] as? Int, charge: charge, condition: condition, state: state)
    }

    /// Used the way Activity Monitor counts it: app memory + wired + compressed.
    static func memoryUsed() -> Int64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard ok == KERN_SUCCESS else { return nil }
        let pages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        return pages * Int64(vm_kernel_page_size)
    }

    static func swapUsed() -> Int64? {
        var s = xsw_usage(), len = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &s, &len, nil, 0) == 0 ? Int64(s.xsu_used) : nil
    }

    static func marketingName() -> String? {
        let json = Sh.run("/usr/sbin/system_profiler", ["SPHardwareDataType", "-json"])
        let hw = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["SPHardwareDataType"] as? [[String: Any]]
        return hw?.first?["machine_name"] as? String
    }

    struct Check: Identifiable { let id: String, on: Bool? }

    static func security() -> [Check] {
        func has(_ out: String, _ word: String) -> Bool? { out.isEmpty ? nil : out.localizedCaseInsensitiveContains(word) }
        return [
            Check(id: "System Integrity Protection", on: has(Sh.run("/usr/bin/csrutil", ["status"]), "status: enabled")),
            Check(id: "FileVault", on: has(Sh.run("/usr/bin/fdesetup", ["status"]), "FileVault is On")),
            Check(id: "Gatekeeper", on: has(Sh.run("/usr/sbin/spctl", ["--status"]), "assessments enabled")),
            Check(id: "Firewall", on: has(Sh.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]), "is enabled")),
        ]
    }
}

/// "About This Mac": model, chip, battery, memory, storage, displays and security settings. Reads only.
struct AboutMacPage: View {
    @State private var marketing: String?
    @State private var checks: [MacFacts.Check]?
    @State private var generation = 0
    @State private var readout: Readout.Status?

    var body: some View {
        // Cheap reads happen on each render; the shell tools load in .task.
        let _ = generation
        VStack(spacing: 0) {
            PageHeader(title: "About This Mac", subtitle: "Hardware, storage and security at a glance.") { generation += 1 }
            Divider()
            Form {
                Section("Mac") {
                    let model = MacFacts.sysctl("hw.model")
                    LabeledContent("Model", value: marketing.map { "\($0) (\(model))" } ?? model)
                    LabeledContent("Chip", value: MacFacts.sysctl("machdep.cpu.brand_string"))
                    LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                    LabeledContent("Uptime", value: Duration.seconds(ProcessInfo.processInfo.systemUptime)
                        .formatted(.units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2)))
                }
                if let b = MacFacts.battery() {
                    Section("Battery") {
                        LabeledContent("Health", value: b.health.map { "\($0)% of design capacity" } ?? "Unknown")
                        LabeledContent("Condition", value: b.condition)
                        LabeledContent("Cycle count", value: b.cycles.map(String.init) ?? "Unknown")
                        LabeledContent("Charge", value: (b.charge.map { "\($0)%, " } ?? "") + b.state)
                    }
                }
                Section {
                    if let m = readout?.memory {
                        bar(used: m.used, total: m.total)
                        LabeledContent("Pressure", value: "\(m.pressure.capitalized), \(Int(m.pressure_percent))%")
                        LabeledContent("Apps", value: fmt(m.app))
                        LabeledContent("Wired", value: fmt(m.wired))
                        LabeledContent("Compressed", value: fmt(m.compressed))
                        LabeledContent("Swap used", value: fmt(m.swap))
                    } else {
                        ownMemory
                    }
                } header: {
                    Text("Memory")
                } footer: {
                    if readout != nil { Text("From Readout, so both apps agree.").font(.caption).foregroundStyle(.secondary) }
                }
                Section("Storage") {
                    if let disks = readout?.disks, !disks.isEmpty {
                        ForEach(disks) { d in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(d.name.isEmpty ? d.mount : d.name, systemImage: d.mount == "/" ? "internaldrive" : "externaldrive")
                                if d.total > 0 { bar(used: d.total - d.free, total: d.total) }
                            }
                        }
                    } else {
                        ownStorage
                    }
                }
                Section("Displays") {
                    ForEach(NSScreen.screens, id: \.self) { s in
                        let pts = s.frame.size
                        let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
                        let mode = CGDisplayCopyDisplayMode(id)
                        let px = mode.map { "\($0.pixelWidth) × \($0.pixelHeight)" } ?? "\(Int(pts.width * s.backingScaleFactor)) × \(Int(pts.height * s.backingScaleFactor))"
                        LabeledContent(s.localizedName) {
                            Text("\(Int(pts.width)) × \(Int(pts.height)) points, \(px) pixels, up to \(s.maximumFramesPerSecond) Hz")
                        }
                    }
                }
                Section("Security") {
                    if let checks {
                        ForEach(checks) { c in
                            LabeledContent(c.id) {
                                switch c.on {
                                case true?: Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                case false?: Label("Off", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                                case nil: Text("Unknown").foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        Text("Checking…").foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .task(id: generation) {
            checks = nil
            async let m = Task.detached { MacFacts.marketingName() }.value
            async let c = Task.detached { MacFacts.security() }.value
            async let v = Task.detached { Readout.status() }.value
            (marketing, checks, readout) = await (m, c, v)
        }
    }

    /// Burrow's own readers, when Readout isn't installed.
    @ViewBuilder private var ownMemory: some View {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        if let used = MacFacts.memoryUsed() {
            bar(used: used, total: total)
            LabeledContent("Used", value: fmt(used))
            LabeledContent("Available", value: fmt(max(0, total - used)))
        }
        LabeledContent("Installed", value: fmt(total))
        LabeledContent("Swap used", value: MacFacts.swapUsed().map(fmt) ?? "Unknown")
    }

    @ViewBuilder private var ownStorage: some View {
        ForEach(Volume.list()) { v in
            let r = try? v.url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            let total = Int64(r?.volumeTotalCapacity ?? 0)
            let free = r?.volumeAvailableCapacityForImportantUsage ?? Int64(r?.volumeAvailableCapacity ?? 0)
            VStack(alignment: .leading, spacing: 4) {
                Label(v.name, systemImage: v.symbol)
                if total > 0 { bar(used: total - free, total: total) }
            }
        }
    }

    private func bar(used: Int64, total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: Double(used), total: Double(max(total, 1)))
            Text("\(fmt(used)) used of \(fmt(total))").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func fmt(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}
