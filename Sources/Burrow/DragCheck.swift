import AppKit
import SwiftUI

// MARK: Drag check (`Burrow --drag-check`)

/// Drops files on every kind of target in real, transparent Burrow windows over a temp folder: the pasteboard
/// ItemMouse writes, handed to the view AppKit's own drag hit test picks, in each view mode. No mouse events, so it
/// never touches what is on screen.
@MainActor
enum DragCheck {
    /// What AppKit gives a destination during a drag.
    final class Info: NSObject, NSDraggingInfo {
        let pb: NSPasteboard
        let point: NSPoint
        let window: NSWindow
        init(_ urls: [URL], at point: NSPoint, in window: NSWindow) {
            pb = NSPasteboard(name: .init("burrow-drag-check-\(UUID().uuidString)"))
            pb.clearContents()
            pb.writeObjects(urls.map { $0 as NSURL })   // what ItemMouse and the list rows put on the drag pasteboard
            self.point = point
            self.window = window
        }
        var draggingDestinationWindow: NSWindow? { window }
        var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .generic, .link] }
        var draggingLocation: NSPoint { point }
        var draggedImageLocation: NSPoint { point }
        var draggedImage: NSImage? { nil }
        var draggingPasteboard: NSPasteboard { pb }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 4242 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
            var stop: ObjCBool = false
            for (i, o) in (pb.readObjects(forClasses: classes, options: searchOptions) ?? []).enumerated() {
                block(NSDraggingItem(pasteboardWriter: o as! NSPasteboardWriting), i, &stop)
                if stop.boolValue { return }
            }
        }
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    static var failed = false

    static func run() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("burrow-drag-\(UUID().uuidString)", isDirectory: true)
        let target = dir.appendingPathComponent("Target", isDirectory: true), other = dir.appendingPathComponent("Other", isDirectory: true)
        for d in [target, other] { try! fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let one = dir.appendingPathComponent("one.txt"), two = dir.appendingPathComponent("two.txt"), inner = target.appendingPathComponent("inner.txt")
        for f in [one, two, inner, other.appendingPathComponent("keep.txt")] { try! "x".write(to: f, atomically: true, encoding: .utf8) }
        defer { try? fm.removeItem(at: dir) }
        // The move has finished and is on the undo stack, not only on disk.
        func moved(_ f: URL, _ d: URL) -> Bool {
            FileOps.shared.jobs.isEmpty && fm.fileExists(atPath: d.appendingPathComponent(f.lastPathComponent).path) && !fm.fileExists(atPath: f.path)
        }
        var alerts: [String] = []
        FileOps.alertSink = { alerts.append($0) }   // never a dialog on screen

        for mode in [ViewMode.icons, .list, .columns, .gallery] {
            print("--", mode.rawValue)
            let c = window(dir, mode)
            if let p = spot(of: target, in: c) {
                drop([one, two], at: p, in: c.window!, "two files onto the Target folder")
                wait("both moved into Target") { moved(one, target) && moved(two, target) }
                FileOps.shared.undo()
                wait("⌘Z puts them back") { fm.fileExists(atPath: one.path) && fm.fileExists(atPath: two.path) }
                check("Target onto itself is refused", !drop([target], at: p, in: c.window!, "onto itself"))
            } else { check("a drop target for the Target folder", false) }
            drop([two], at: NSPoint(x: c.window!.frame.width * 0.8, y: 90), in: c.window!, "background of its own folder")
            spin(0.5) { false }
            check("dropped on its own folder, it stays", fm.fileExists(atPath: two.path))
            c.close()

            let b = window(other, mode)
            drop([two], at: NSPoint(x: b.window!.frame.width * 0.8, y: 90), in: b.window!, "background of another folder")
            wait("two.txt moved into Other") { moved(two, other) }
            FileOps.shared.undo()
            wait("⌘Z puts it back") { fm.fileExists(atPath: two.path) }
            b.close()
        }
        print("-- sidebar")
        let w = window(dir, .icons)
        // Favorites are real folders, so only the hit test: AppKit picks the favorite's own drop target.
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let favorites = Set(AppSettings.shared.favorites.map(\.path))
        if let fav = all(w.window!.contentView!).compactMap({ $0 as? FileDropView }).first(where: { favorites.contains($0.dropInto?.path ?? "") }) {
            check("a drag over the \(fav.dropInto!.lastPathComponent) favorite goes to it",
                  destination([one], at: fav.convert(NSPoint(x: fav.bounds.midX, y: fav.bounds.midY), to: nil), in: w.window!) === fav)
        } else { check("a drop target for a favorite", AppSettings.shared.favorites.isEmpty) }
        w.close()
        print("-- path bar")
        let t = window(target, .icons)
        if let p = spot(of: dir, in: t) {
            drop([inner], at: p, in: t.window!, "onto the parent folder's crumb")
            wait("inner.txt moved up a folder") { moved(inner, dir) }
        } else { check("a drop target for the parent folder's crumb", false) }
        t.close()
        check("no alerts" + (alerts.isEmpty ? "" : ": \(alerts)"), alerts.isEmpty)
        print(failed ? "Burrow drag check FAILED" : "Burrow drag check passed")
        if failed { exit(1) }
    }

    static func window(_ url: URL, _ mode: ViewMode) -> BrowserWindowController {
        let c = BrowserWindowController(url: url)
        c.model.active.viewMode = mode
        c.window!.alphaValue = 0
        c.window!.orderFrontRegardless()
        spin { !c.model.active.visible.isEmpty }
        spin(0.8) { false }   // let layout settle
        return c
    }

    /// Window point of the drop target aimed at `url`: an icon, list cell, column row, gallery tile or crumb.
    static func spot(of url: URL, in c: BrowserWindowController) -> NSPoint? {
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let want = url.resolvingSymlinksInPath().path
        let v = all(c.window!.contentView!).compactMap { $0 as? FileDropView }
            .first { $0.dropInto?.resolvingSymlinksInPath().path == want && $0.bounds.width > 0 && $0.bounds.width < 600 }
        return v.map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) }
    }

    /// What AppKit does: its own drag hit test (NSView's private `_hitTest:dragTypes:`, from the window's frame view)
    /// picks the destination, which then gets entered, updated and perform. SwiftUI's drop targets don't answer it
    /// outside a real drag, which is why Burrow's file drops are AppKit views (FileDropView).
    @discardableResult
    static func drop(_ urls: [URL], at p: NSPoint, in w: NSWindow, _ label: String) -> Bool {
        let info = Info(urls, at: p, in: w)
        guard let dest = destination(urls, at: p, in: w) else { print("   \(label): nothing under the point takes file drops"); return false }
        _ = dest.draggingEntered(info)
        let op = dest.draggingUpdated(info)
        let ok = !op.isEmpty && dest.prepareForDragOperation(info) && dest.performDragOperation(info)
        dest.concludeDragOperation(info)
        print("   \(label): \(type(of: dest)), \(op.contains(.move) ? "move" : op.contains(.copy) ? "copy" : "none"), \(ok ? "dropped" : "refused")")
        return ok
    }

    static func destination(_ urls: [URL], at p: NSPoint, in w: NSWindow) -> NSView? {
        typealias HitTest = @convention(c) (NSView, Selector, UnsafeMutablePointer<NSPoint>, NSSet) -> NSView?
        let sel = NSSelectorFromString("_hitTest:dragTypes:")
        guard let m = class_getInstanceMethod(NSView.self, sel) else { check("AppKit has _hitTest:dragTypes:", false); return nil }
        var point = p
        let types = NSSet(array: (Info(urls, at: p, in: w).pb.types ?? []).map(\.rawValue))
        return unsafeBitCast(method_getImplementation(m), to: HitTest.self)(w.contentView!.superview!, sel, &point, types)
    }

    static func check(_ label: String, _ ok: Bool) {
        print(ok ? "ok  " : "FAIL", label)
        if !ok { failed = true }
    }

    static func spin(_ seconds: Double = 5, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    static func wait(_ label: String, _ done: () -> Bool) {
        spin(3, until: done)
        check(label, done())
    }
}
