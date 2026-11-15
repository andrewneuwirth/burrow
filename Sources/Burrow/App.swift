import AppKit
import SwiftUI

@main
struct BurrowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { SettingsView() }
            .commands { BurrowCommands() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The folder watcher only hears files being added, removed or renamed; a file rewritten in place by another app
    /// shows its new size, date and preview when you come back.
    func applicationDidBecomeActive(_ notification: Notification) { Windows.shared.reloadAll() }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // "Reveal in Finder" from other apps, once Burrow is the NSFileViewer: the 'misc'/'mvis' event Finder gets.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(reveal(_:reply:)),
                                                     forEventClass: AEEventClass(kAEMiscStandards), andEventID: AEEventID(kAEMakeObjectsVisible))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-check") { MainActor.assumeIsolated { SelfCheck.run() }; exit(0) }
        if let i = CommandLine.arguments.firstIndex(of: "--make-icon"), CommandLine.arguments.count > i + 1 {
            MainActor.assumeIsolated { try! IconArt.write(URL(fileURLWithPath: CommandLine.arguments[i + 1])) }
            exit(0)
        }
        // `Burrow --make-default` / `--give-back`: the Settings button's switch, from the command line.
        if let on = CommandLine.arguments.contains("--make-default") ? true : CommandLine.arguments.contains("--give-back") ? false : nil {
            Task {
                let notes = await DefaultBrowser.set(on)
                print(notes.isEmpty ? (on ? "Burrow is the default file browser" : "Finder is the default again") : notes.joined(separator: "\n"))
                exit(notes.isEmpty ? 0 : 1)
            }
            return
        }
        MainActor.assumeIsolated {
            Keys.install()
            Shelf.shared.install()
            DispatchQueue.main.async {   // after any open-file events from the launch
                if Windows.shared.controllers.isEmpty { Windows.shared.open(AppSettings.shared.startFolder) }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { Windows.shared.show(urls) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainActor.assumeIsolated { Windows.shared.open(AppSettings.shared.startFolder) } }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func reveal(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        let descs = list.numberOfItems == 0 ? [list] : (1...list.numberOfItems).compactMap { list.atIndex($0) }
        let urls = descs.compactMap { $0.coerce(toDescriptorType: typeFileURL).flatMap { URL(dataRepresentation: $0.data, relativeTo: nil) } }
        MainActor.assumeIsolated {
            Windows.shared.reveal(urls)
            NSApp.activate()
        }
    }
}

// MARK: Windows

@MainActor
final class Windows {
    static let shared = Windows()
    private(set) var controllers: [BrowserWindowController] = []

    /// The window the menus act on.
    var current: BrowserModel? {
        for w in [NSApp.keyWindow, NSApp.mainWindow] { if let c = w?.windowController as? BrowserWindowController { return c.model } }
        return nil
    }

    @discardableResult
    func open(_ url: URL, select: [URL] = [], asTabOf host: NSWindow? = nil) -> BrowserWindowController {
        let c = BrowserWindowController(url: url)
        if !select.isEmpty { c.model.active.go(url, select: select, record: false) }
        if let host, let w = c.window {
            host.addTabbedWindow(w, ordered: .above)
        } else if let last = controllers.last?.window, let w = c.window {
            w.setFrameTopLeftPoint(w.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        }
        controllers.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        return c
    }

    func newTab() {
        open(current?.active.url ?? AppSettings.shared.startFolder, asTabOf: NSApp.keyWindow)
    }

    /// Folders open; files open their folder with them selected.
    func show(_ urls: [URL]) {
        let folders = urls.filter { FileItem(url: $0).opensAsFolder }
        folders.forEach { open($0) }
        reveal(urls.filter { u in !folders.contains(u) })
    }

    func reveal(_ urls: [URL]) {
        let byFolder = Dictionary(grouping: urls) { $0.deletingLastPathComponent().folder }
        for (folder, items) in byFolder { open(folder, select: items) }
    }

    func closed(_ c: BrowserWindowController) { controllers.removeAll { $0 === c } }
    var panes: [PaneModel] { controllers.flatMap(\.model.panes) }
    func reloadAll() { panes.forEach { $0.load() } }
    func resortAll() { panes.forEach { $0.resort() } }
}

final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let model: BrowserModel

    @MainActor init(url: URL) {
        model = BrowserModel(url: url)
        let host = NSHostingController(rootView: BrowserView(model: model))
        host.sizingOptions = []
        host.sceneBridgingOptions = [.toolbars]
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 660),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = host
        w.setContentSize(NSSize(width: 1060, height: 660))
        w.tabbingMode = .preferred
        w.tabbingIdentifier = "Burrow"
        w.toolbarStyle = .unified
        w.center()
        super.init(window: w)
        w.delegate = self
        model.window = w
        model.updateWindow()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The tab bar's “+”.
    override func newWindowForTab(_ sender: Any?) {
        MainActor.assumeIsolated { Windows.shared.open(model.active.url, asTabOf: window) }
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            model.panes.forEach { $0.stop() }
            Windows.shared.closed(self)
        }
    }
}

// MARK: Menus

@MainActor
enum Act {
    static var pane: PaneModel? { Windows.shared.current?.active }
    /// A text field has the keyboard: the standard edit commands belong to it.
    static var editingText: Bool { NSApp.keyWindow?.firstResponder is NSText }
    static func text(_ action: String) { NSApp.sendAction(Selector(action), to: nil, from: nil) }
    static func go(_ path: String) { pane?.go(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) }

    static func openIn(_ ids: [String], _ url: URL?) {
        guard let url, let app = ids.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else { return NSSound.beep() }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static let terminals = ["com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.apple.Terminal"]
    static let editors = ["com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "dev.zed.Zed", "com.apple.dt.Xcode"]

    /// The selected folder, else the folder being shown.
    static var targetFolder: URL? {
        guard let p = pane else { return nil }
        let sel = p.selectedItems
        return sel.count == 1 && sel[0].opensAsFolder ? sel[0].target : p.url
    }
}

struct BurrowCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { Windows.shared.open(Act.pane?.url ?? AppSettings.shared.startFolder) }.keyboardShortcut("n")
            Button("New Tab") { Windows.shared.newTab() }.keyboardShortcut("t")
            Button("New Folder") { Act.pane?.newFolder() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Open") { Act.pane?.open() }.keyboardShortcut("o")
            Button("Open Selection") { Act.pane?.open() }.keyboardShortcut(.downArrow)
            Button("Get Info") { Info.show(Act.pane?.selectedItems ?? []) }.keyboardShortcut("i")
            Button("Rename") { Act.pane?.startRename() }
            Button("Duplicate") { FileOps.shared.duplicate(Act.pane?.selectedItems.map(\.url) ?? []) }
            Button("Compress") { FileOps.shared.compress(Act.pane?.selectedItems.map(\.url) ?? []) }
            Divider()
            Button("Move to Trash") {
                if Act.editingText { Act.text("deleteToBeginningOfLine:") } else { FileOps.shared.trash(Act.pane?.selectedItems.map(\.url) ?? []) }
            }.keyboardShortcut(.delete)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(FileOps.shared.undoTitle) { Act.editingText ? Act.text("undo:") : FileOps.shared.undo() }.keyboardShortcut("z")
            Button(FileOps.shared.redoTitle) { Act.editingText ? Act.text("redo:") : FileOps.shared.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { Act.text("cut:") }.keyboardShortcut("x")
            Button("Copy") { Act.editingText ? Act.text("copy:") : Clipboard.copy(Act.pane?.selectedItems.map(\.url) ?? []) }.keyboardShortcut("c")
            Button("Paste") { Act.editingText ? Act.text("paste:") : Act.pane?.paste(move: false) }.keyboardShortcut("v")
            Button("Move Item Here") { Act.pane?.paste(move: true) }.keyboardShortcut("v", modifiers: [.command, .option])
            Button("Copy Path") { Clipboard.copyPaths(Act.pane.map { $0.selectedItems.isEmpty ? [$0.url] : $0.selectedItems.map(\.url) } ?? []) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Select All") { Act.editingText ? Act.text("selectAll:") : Act.pane?.selectAll() }.keyboardShortcut("a")
        }
        CommandGroup(before: .toolbar) {
            // The same key again goes back to the previous view (⌘3 twice leaves columns).
            Button("as Icons") { Act.pane?.show(.icons) }.keyboardShortcut("1")
            Button("as List") { Act.pane?.show(.list) }.keyboardShortcut("2")
            Button("as Columns") { Act.pane?.show(.columns) }.keyboardShortcut("3")
            Button("as Gallery") { Act.pane?.show(.gallery) }.keyboardShortcut("4")
            Button("Bigger Icons") { AppSettings.shared.iconSize = AppSettings.shared.iconSize.step(1) }.keyboardShortcut("+")
            Button("Smaller Icons") { AppSettings.shared.iconSize = AppSettings.shared.iconSize.step(-1) }.keyboardShortcut("-")
            Divider()
            Button("Split / Unsplit") { Windows.shared.current?.toggleSplit() }.keyboardShortcut("d")
            Button("Drop Shelf") { Shelf.shared.toggle() }.keyboardShortcut(" ", modifiers: [.control, .option])
            Button("Tidy This Folder…") { Act.pane?.tidying = true }
            Button("Free Up Space") { Act.pane?.showPage(.clean) }.keyboardShortcut("k", modifiers: [.command, .option])
            Button("Add Bookmark") { Bookmarks.addFromBrowserOrClipboard() }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Show / Hide Hidden Files") { AppSettings.shared.showHidden.toggle() }.keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Quick Look") { Act.pane?.togglePreview() }.keyboardShortcut("y")
            Button("Find") { Windows.shared.current?.findTick += 1 }.keyboardShortcut("f")
            Divider()
        }
        CommandMenu("Go") {
            Button("Go to…") { Windows.shared.current?.palette = true }.keyboardShortcut("k")
            ForEach(1...9, id: \.self) { n in
                Button("Workspace \(n)") {
                    let list = Workspaces.shared.list
                    if list.indices.contains(n - 1) { Act.pane?.showPage(.workspace(list[n - 1].id)) } else { NSSound.beep() }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .control)
            }
            Divider()
            Button("Back") { Act.pane?.goBack() }.keyboardShortcut("[")
            Button("Forward") { Act.pane?.goForward() }.keyboardShortcut("]")
            Button("Enclosing Folder") { Act.pane?.up() }.keyboardShortcut(.upArrow)
            Divider()
            Button("Home") { Act.go("~") }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Desktop") { Act.go("~/Desktop") }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Documents") { Act.go("~/Documents") }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Downloads") { Act.go("~/Downloads") }.keyboardShortcut("l", modifiers: [.command, .option])
            Button("Applications") { Act.go("/Applications") }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Developer") { Act.go("~/Developer") }
            Divider()
            Button("Go to Folder…") { Act.pane?.editingPath = true }.keyboardShortcut("l")
            Button("Go to Folder… ") { Act.pane?.editingPath = true }.keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("Copy to Other Pane (F5)") { Windows.shared.current?.transferToOther(copy: true) }
            Button("Move to Other Pane (F6)") { Windows.shared.current?.transferToOther(copy: false) }
            Divider()
            Button("Open in Terminal") { Act.openIn(Act.terminals, Act.targetFolder) }.keyboardShortcut("t", modifiers: [.command, .option, .shift])
            Button("Open in Editor") { Act.openIn(Act.editors, Act.targetFolder) }.keyboardShortcut("e", modifiers: [.command, .option, .shift])
        }
    }
}

// MARK: Keys the menus can't own (Space, Return, F5/F6, arrows in the grid, type-to-select)

@MainActor
enum Keys {
    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            MainActor.assumeIsolated { handle(e) } ? nil : e
        }
    }

    static func handle(_ e: NSEvent) -> Bool {
        guard let model = (e.window?.windowController as? BrowserWindowController)?.model,
              !(e.window?.firstResponder is NSText) else { return false }
        let pane = model.active
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock])
        let shift = flags == [.shift]
        switch e.keyCode {
        case 49 where flags.isEmpty: pane.togglePreview(); return true           // Space
        case 36 where flags.isEmpty, 76 where flags.isEmpty: pane.startRename(); return true   // Return
        case 96: model.transferToOther(copy: true); return true                  // F5
        case 97: model.transferToOther(copy: false); return true                 // F6
        case 53 where pane.page != nil: pane.closePage(); return true                                      // Esc
        case 53 where pane.searchResults != nil || !pane.filter.isEmpty: pane.clearSearch(); return true
        case 124 where pane.viewMode == .columns && flags.isEmpty:                // → into the selected folder
            if pane.selection.count == 1, let f = pane.selectedItems.first, f.opensAsFolder { pane.go(f.target) }
            return true
        case 123 where pane.viewMode == .columns && flags.isEmpty:                // ← back out, keeping the folder selected
            if pane.url != pane.columnRoot { pane.up() }
            return true
        case 123...126 where (pane.viewMode == .icons || pane.viewMode == .gallery) && (flags.isEmpty || shift):
            let (dx, dy) = [123: (-1, 0), 124: (1, 0), 125: (0, 1), 126: (0, -1)][Int(e.keyCode)]!
            pane.moveCursor(dx, dy, extend: shift)
            return true
        default: break
        }
        if flags.isEmpty || shift, let s = e.characters, s.count == 1, s.first!.isLetter || s.first!.isNumber {
            pane.typeSelect(s)
            return true
        }
        return false
    }
}
