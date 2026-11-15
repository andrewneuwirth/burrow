import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The Drop Shelf: a small floating panel at the right edge with your pinned folders (drop a file on one to
/// move it there, ⌥ copies) and Holding (drop files to keep them handy, drag them out later). It appears
/// on ⌃⌥Space from any app, or by itself while you drag files anywhere.
@MainActor @Observable
final class Shelf {
    static let shared = Shelf()
    var holding: [URL] = []
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var auto = false          // shown by a drag, so it hides again when the drag ends
    @ObservationIgnored var used = false                  // something was dropped on it during this drag
    @ObservationIgnored private var dragCount = NSPasteboard(name: .drag).changeCount
    @ObservationIgnored private var dragStarted: Date?

    var isShown: Bool { panel?.isVisible == true }

    func toggle() { isShown ? hide() : show() }

    func show(auto: Bool = false) {
        self.auto = auto
        used = false
        let p = panel ?? make()
        panel = p
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        // Hangs from the top edge, centred under the notch, and slides down into place.
        let size = p.frame.size
        let end = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
        p.setFrame(end.offsetBy(dx: 0, dy: size.height * 0.4), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        if !auto { p.makeKey() }   // from the hot key: 1–9 and esc work at once
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().setFrame(end, display: true)
            p.animator().alphaValue = 1
        }
    }

    func hide() { panel?.orderOut(nil) }

    private func make() -> NSPanel {
        let p = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 214),
                           styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentViewController = NSHostingController(rootView: ShelfView())
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            MainActor.assumeIsolated {
                guard e.window === p else { return e }
                if e.keyCode == 53 { Shelf.shared.hide(); return nil }
                if let c = e.characters, let n = Int(c), (1...9).contains(n) {
                    let pinned = AppSettings.shared.shelf
                    if pinned.indices.contains(n - 1) { Windows.shared.open(pinned[n - 1]); NSApp.activate(); Shelf.shared.hide() } else { NSSound.beep() }
                    return nil
                }
                return e
            }
        }
        return p
    }

    // MARK: Showing itself during a file drag (any app)

    func install() {
        HotKey.register(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)) { Shelf.shared.toggle() }
        // Mouse monitors need no permission (only key monitors do). Global ones see other apps, local ones Burrow.
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { _ in MainActor.assumeIsolated { Shelf.shared.dragged() } }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in MainActor.assumeIsolated { Shelf.shared.released() } }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { e in MainActor.assumeIsolated { Shelf.shared.dragged() }; return e }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { e in MainActor.assumeIsolated { Shelf.shared.released() }; return e }
    }

    private func dragged() {
        guard AppSettings.shared.shelfOnDrag else { return }
        let pb = NSPasteboard(name: .drag)
        if pb.changeCount != dragCount {   // a new drag began
            dragCount = pb.changeCount
            dragStarted = pb.types?.contains(.fileURL) == true ? Date() : nil
        }
        // A short pause first, so ordinary drags inside a window don't flash it.
        if let start = dragStarted, Date().timeIntervalSince(start) > 0.35, !isShown { show(auto: true) }
    }

    private func released() {
        dragStarted = nil
        guard auto, isShown else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            MainActor.assumeIsolated { if self.auto && !self.used && self.holding.isEmpty { self.hide() }; self.auto = false }
        }
    }
}

/// Takes the keyboard without activating Burrow, so 1–9 and esc work over any app.
final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct ShelfView: View {
    var shelf = Shelf.shared
    var settings = AppSettings.shared
    var ops = FileOps.shared
    @State private var holdTarget = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                holding
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("PINNED FOLDERS").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.white.opacity(0.55))
                        Spacer()
                        Text("click or press its number to open").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                    }
                    HStack(spacing: 10) {
                        ForEach(Array(settings.shelf.prefix(9).enumerated()), id: \.element) { i, u in ShelfTile(url: u, number: i + 1) }
                        PinTile()
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 18).padding(.top, 40)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.top, 14)
            HStack(spacing: 10) {
                if let last = ops.lastMessage, Date().timeIntervalSince(last.at) < 120 {
                    Text("JUST NOW").font(.system(size: 9.5, weight: .semibold)).tracking(0.6).foregroundStyle(.white.opacity(0.45))
                    Text(last.text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    Button("Undo") { ops.undo() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 3).background(Capsule().fill(Color.accentColor))
                }
                Spacer()
                Text("esc").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                Button("Close") { shelf.hide() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 18).frame(height: 34)
        }
        .frame(width: 780, height: 214)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24).fill(Color(white: 0.04)))
        .environment(\.colorScheme, .dark)
    }

    private var holding: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "tray").font(.system(size: 15)).foregroundStyle(.orange)
                    .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Holding").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    Text(shelf.holding.isEmpty ? "drop files to keep them here" : "\(shelf.holding.count) file\(shelf.holding.count == 1 ? "" : "s") · drag one into any app")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
                if !shelf.holding.isEmpty {
                    Button { shelf.holding = [] } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.35)).help("Clear Holding")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shelf.holding, id: \.self) { u in
                        HStack(spacing: 6) {
                            Image(nsImage: Icons.icon(u)).resizable().frame(width: 16, height: 16)
                            Text(u.lastPathComponent).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).lineLimit(1).truncationMode(.middle)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08)))
                        .onDrag { NSItemProvider(object: u as NSURL) }
                        .contextMenu { Button("Remove") { shelf.holding.removeAll { $0 == u } } }
                    }
                }
            }
            .frame(maxHeight: 64)
        }
        .padding(12)
        .frame(width: 236, height: 124, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(holdTarget ? Color.accentColor : .white.opacity(0.1),
                                                                 style: StrokeStyle(lineWidth: holdTarget ? 2 : 1, dash: [4])))
        .onDrop(of: [.fileURL], isTargeted: $holdTarget) { providers in
            Drops.load(providers) { urls in
                shelf.used = true
                shelf.holding += urls.filter { !shelf.holding.contains($0) }
            }
        }
    }
}

private struct ShelfTile: View {
    let url: URL
    let number: Int
    @State private var targeted = false
    var body: some View {
        VStack(spacing: 6) {
            FolderGlyph(url: url, size: 44, showCount: false)
            Text(FileManager.default.displayName(atPath: url.path)).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1)
        }
        .frame(width: 88, height: 92)
        .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? Color.accentColor.opacity(0.35) : .white.opacity(0.07)))
        .overlay(alignment: .topLeading) {
            Text("\(number)").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                .frame(width: 16, height: 16).background(Circle().fill(.white.opacity(0.12))).padding(5)
        }
        .contentShape(Rectangle())
        .onTapGesture { Windows.shared.open(url); NSApp.activate(); Shelf.shared.hide() }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Drops.load(providers) { urls in
                Shelf.shared.used = true
                FileOps.shared.drop(urls, into: url)
            }
        }
        .contextMenu {
            Button("Open in Burrow") { Windows.shared.open(url); NSApp.activate() }
            Button("Unpin") { AppSettings.shared.shelf.removeAll { $0 == url } }
        }
        .help("Drop to move here (⌥ copies)")
    }
}

private struct PinTile: View {
    var body: some View {
        Button {
            let p = NSOpenPanel()
            p.canChooseDirectories = true
            p.canChooseFiles = false
            p.prompt = "Pin"
            NSApp.activate()
            if p.runModal() == .OK, let u = p.url { AppSettings.shared.shelf.append(u.folder) }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 15)).foregroundStyle(.white.opacity(0.6))
                Text("Pin a folder").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: 88, height: 92)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A system-wide hot key through Carbon (no Accessibility permission needed).
@MainActor
enum HotKey {
    private static var action: (() -> Void)?
    private static var ref: EventHotKeyRef?

    static func register(keyCode: UInt32, modifiers: UInt32, _ run: @escaping () -> Void) {
        action = run
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.action?() } }
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x4252_5257), id: 1), GetApplicationEventTarget(), 0, &ref)
    }
}
