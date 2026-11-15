# AGENTS.md: Burrow

A native macOS file browser meant to stand in for Finder (Finder still draws the desktop and can't be removed).
Swift 6.2 tools in Swift 5 language mode, SwiftPM, macOS 15+, SwiftUI inside AppKit windows. One dependency: Kit's MacToolsUpdates (Sparkle updates).
Bundle id `app.newitools.Burrow` (set by `build.sh`; `config.local.env`, gitignored, can override `BUNDLE_ID`,
`SIGN_IDENTITY` and `PREVIOUS_BUNDLE_ID`, see `config.example.env`). Builds under an older id:
`Migration.swift` copies that UserDefaults domain once when `PREVIOUS_BUNDLE_ID` is set (never overwriting a key).
Bookmarks live in `~/Library/Application Support/Burrow/` (named by app, not bundle id), so they carry over on their own.

## Commands

```sh
swift build && .build/debug/Burrow --self-check   # file ops + undo in a temp folder (drag pasteboard, drops onto symlinks/aliases), search ranking, migration, defaults, Holding
.build/debug/Burrow --drag-check                  # drops in every view, transparent windows over a temp folder, through AppKit's own drag hit test; no mouse events
.build/debug/Burrow --welcome-preview DIR          # the walkthrough and Settings as PNGs (light + dark), offscreen
./build.sh                                        # build/Burrow.app (Apple Development signature, so folder grants stick)
./build.sh --install                              # /Applications, lsregister, relaunch: only when the owner asks
./build.sh --release                              # Developer ID + hardened runtime + timestamp; ignores config.local.env
```

## Code map

- `App.swift`: app delegate (open-folder events, the `misc/mvis` reveal event other apps send to the NSFileViewer), `Windows` (AppKit windows with native tabs), menus, and `Keys` (Space, Return, F5/F6, grid arrows, type-to-select).
- `Model.swift`: `FileItem`, `BrowserModel` (one or two panes), `PaneModel` (folder, history, live refresh, selection, search), `AppSettings`.
- `FileOps.swift`: copy/move with conflict choices and a progress bar, Trash, rename, new folder, duplicate, compress, and ⌘Z undo. Everything destructive goes through the Trash first.
- `Views.swift`: sidebar, path bar, list / icon / gallery views, context menus, icons and thumbnails.
- `Extras.swift`: Get Info, Settings (including "Make Burrow the Default" and "Show Welcome Tour…"), the self-check.
- Drag and drop: file drop targets are AppKit views (`FileDropView` in Views.swift: the icons' `ItemMouse`, and `DropZone`
  via `paneDrop`/`itemDrop`/`rowDrop`/`folderDrop`), not SwiftUI `.onDrop`. AppKit hands a drag to the topmost registered
  view, so the icons' mouse view hid SwiftUI targets under it, and a Table or List with SwiftUI drops swallows the rest.
  `DragCheck.swift` checks them. Checks set `FileOps.alertSink`, so no dialog ever opens during a check.
- `Onboarding.swift`: the first-launch walkthrough (welcome, shelf, default browser, permissions, Open at Login). Shown only
  when `Onboarding.isExistingUser` is false (no `onboarded`, `migratedFrom`, recents, favorites, workspaces...).
- `Migration.swift`: the one-time settings copy from `PREVIOUS_BUNDLE_ID`.
- `Columns.swift`: column view (⌘3): ancestors from `columnRoot` read from disk, the pane as the last column, a lookahead column for a selected folder and a preview for a file.
- `Shelf.swift`: the Drop Shelf panel (pinned folders + Holding), ⌃⌥Space through Carbon `RegisterEventHotKey`, and the drag monitors that show it while files are dragged in any app (mouse monitors need no permission).
- `Tidy.swift`: Smart Downloads: grouping buckets, the Tidy sheet (sort into kind folders, flag installers already installed / duplicates / 90-day untouched; flags start unticked and only go to the Trash).
- Pages (`Page` in Model.swift): workspaces and tags list files through the pane's `searchResults` (so every view and file action works on them); tool pages (`ToolPage`) draw their own: `Clean.swift` (Free Up Space), `AboutMac.swift`, `Installed.swift`, `Agents.swift`, `Bookmarks.swift`. `Markdown.swift` opens .md files in their own window.
- Developer tools (`AppSettings.developerTools`, Settings toggle): gates `Page.developerOnly` (Installed, AI Agents), the Xcode rows in Free Up Space (`CleanSpot.shown`) and `~/Developer` shortcuts. `settleDeveloperTools` decides the default once at launch: on for existing users (`Onboarding.isExistingUser`), off for new ones.
- Workspaces (`Workspaces` in Model.swift) only remember paths, in UserDefaults `workspaces`; nothing is copied or moved.
- `Readout.swift`: memory and disks for About This Mac from `readout status --json`, and the biggest folders for Free Up Space from Readout's saved scan (`~/Library/Application Support/Readout/disk-usage.tsv`). Nil without Readout; the pages fall back to their own readers.
- `Look.swift`: the look: glass folders (`FolderGlyph`, tinted by Finder tag or workspace), file cards with previews, folder tiles and cards, kind tabs, the workspace header, S/M/L sizes.
- `SearchRank.swift`, `FileQuery.swift`: copied from Pier (Spotlight query + ranking). Keep them in step with Pier, or move them into Kit.

## Default browser

Settings › Make Burrow the Default sets Launch Services' `public.folder` handler and `defaults write -g NSFileViewer`.
"Give It Back to Finder" reverses both. Only flip it when the owner asks. `Burrow --make-default` / `--give-back` do the same from
the command line, and also turn Open at Login on/off (SMAppService) so the shelf's ⌃⌥Space always works.

macOS refuses `public.folder` changes through the API (`setDefaultApplication` fails, `LSSetDefaultRoleHandlerForContentType`
returns -50), so on 2026-11-13 Burrow was also added as an `LSHandlers` entry
(`LSHandlerContentType=public.folder`) in `com.apple.LaunchServices/com.apple.launchservices.secure`, as other Finder
replacements do. It may only apply after logging out, or not at all on this macOS. To undo it, delete that one entry
(PlistBuddy on `~/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist`).
"Show in Finder" (NSFileViewer) works without it: other apps' reveal requests open in Burrow.
