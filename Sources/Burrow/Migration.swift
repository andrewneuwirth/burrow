import Foundation

/// One-time copy of settings (favorites, shelf folders, workspaces, recents, search picks...) from the app's previous
/// bundle id. The Application Support folder didn't change, so bookmarks.json carries over on its own.
enum Migration {
    /// The previous bundle id, read from the optional `BurrowPreviousBundleID` Info.plist key that build.sh
    /// writes from config.local.env; a build without it has nothing to migrate.
    static var oldDomain: String? { Bundle.main.object(forInfoDictionaryKey: "BurrowPreviousBundleID") as? String }

    static func run(into new: UserDefaults = .standard, from old: String? = oldDomain) {
        // persistentDomain reads only that domain's own keys, not the global ones a UserDefaults(suiteName:) would add.
        guard let old, new.string(forKey: "migratedFrom") == nil,
              let keys = UserDefaults.standard.persistentDomain(forName: old), !keys.isEmpty else { return }
        for (k, v) in keys where new.object(forKey: k) == nil { new.set(v, forKey: k) }   // never overwrite
        new.set(old, forKey: "migratedFrom")
    }

    static func selfCheck() {
        let oldName = "burrow-selfcheck-old-\(UUID().uuidString)", newName = "burrow-selfcheck-new-\(UUID().uuidString)"
        let old = UserDefaults(suiteName: oldName)!, new = UserDefaults(suiteName: newName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: oldName); UserDefaults.standard.removePersistentDomain(forName: newName) }
        let ws = try! JSONEncoder().encode([Workspace(name: "Thesis", paths: ["/tmp/a", "/tmp/b"])])
        old.set(ws, forKey: "workspaces"); old.set(["/tmp/Desk", "/tmp/Docs"], forKey: "shelf")
        old.set("icons", forKey: "viewMode"); new.set("list", forKey: "viewMode")
        run(into: new, from: oldName)
        let back = new.data(forKey: "workspaces").flatMap { try? JSONDecoder().decode([Workspace].self, from: $0) }
        precondition(back?.first?.name == "Thesis" && back?.first?.paths == ["/tmp/a", "/tmp/b"], "migration: workspaces carry over")
        precondition(new.stringArray(forKey: "shelf") == ["/tmp/Desk", "/tmp/Docs"], "migration: shelf folders carry over")
        precondition(new.string(forKey: "viewMode") == "list" && new.string(forKey: "migratedFrom") == oldName, "migration: keeps keys already set, marks it")
        precondition(Onboarding.isExistingUser(new), "migration: a migrated user never sees the walkthrough")
        new.removeObject(forKey: "shelf")
        run(into: new, from: oldName)
        precondition(new.object(forKey: "shelf") == nil, "migration: never runs twice")
        run(into: new, from: nil)
        precondition(new.object(forKey: "shelf") == nil, "migration: no previous id, nothing happens")
    }
}
