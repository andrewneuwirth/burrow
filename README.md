# Burrow

A file browser for people who live in Finder. Columns, list, icons and gallery with tabs and a split view, a Drop Shelf
for moving files between apps, workspaces that gather a project's files from anywhere, and a tidier Downloads folder.
It can stand in for Finder as your default file browser. SwiftUI and AppKit, macOS 15 or later, no server.

From [newi tools](https://newitools.app/burrow/).

## Features

- **Four views**: icons, list, columns (⌘3) and gallery, with tabs, a split view (⌘D, F5 copies and F6 moves to the other
  side), Quick Look on Space and ⌘K to jump to any folder.
- **Drop Shelf** (⌃⌥Space from any app, or by itself while you drag files): drop on a pinned folder to move a file there
  (⌥ copies), or keep files in Holding and drag them out later.
- **Workspaces**: a project's files and folders from anywhere (your Mac, iCloud Drive, external drives) on one page.
  Nothing is copied or moved; a workspace only remembers paths.
- **Smart Downloads and Tidy**: group by kind or date, sort into kind folders, and flag installers you already installed,
  duplicates and files untouched for 90 days. Flagged files only ever go to the Trash.
- **Free Up Space**: caches, old downloads, Mail attachments and more, each explained, everything to the Trash.
- **Bookmarks** and an **About This Mac** page.
- **Developer tools** (Settings › Developer tools, off for new installs): an **AI Agents** page (projects set up for
  Claude Code, Codex and Cursor), **Installed** (Homebrew, npm, pip and other packages), Xcode build files and archives
  in Free Up Space, and `~/Developer` in the sidebar and Go menu.
- **Undo for everything**: rename, move, copy, new folder and Trash are all ⌘Z-able.
- **Optional default file browser**: folders and every app's "Show in Finder" open in Burrow. One click gives it back to
  Finder. Finder still draws the desktop.
- A short **first-launch walkthrough**: the shelf, the default-browser switch, permissions, Open at Login.

## Screenshots

_Coming soon._

## Build from source

Needs Xcode 26 or later (Swift 6.2 tools); the app runs on macOS 15 or later.

```sh
git clone https://github.com/andrewneuwirth/burrow.git Burrow && cd Burrow
swift build && .build/debug/Burrow --self-check   # should print "Burrow self-check passed"
./build.sh                                        # makes build/Burrow.app
open build/Burrow.app
```

`build.sh` signs with your Apple Development identity if you have one (a stable signature keeps the Desktop, Documents
and Downloads grants across rebuilds), otherwise ad hoc. To use your own bundle id or signing identity, copy
`config.example.env` to `config.local.env` and edit it.

## Making it the default, and going back

Settings › Make Burrow the Default (or the walkthrough) sets the `NSFileViewer` default, so every app's "Show in Finder"
opens in Burrow, asks Launch Services to open folders with it, and turns on Open at Login so the shelf's shortcut is
always there. **Give It Back to Finder** in the same place undoes all three. From Terminal:

```sh
/Applications/Burrow.app/Contents/MacOS/Burrow --make-default
/Applications/Burrow.app/Contents/MacOS/Burrow --give-back
# or by hand: defaults delete -g NSFileViewer
```

macOS may still hand some plain folder opens to Finder; "Show in Finder" requests always come to Burrow.

## Permissions

Desktop, Documents and Downloads (macOS asks once for each), external and network drives when you open them, and
Automation for your browser the first time you use Add Bookmark. Full Disk Access is optional: it removes the prompts and
lets Free Up Space measure Library folders. The walkthrough shows what's on.

## Privacy

Burrow runs entirely on your Mac and collects nothing. It only goes online for web pages you bookmark (to read their title
and preview image) and images inside Markdown files you open. Full policy: [PRIVACY.md](PRIVACY.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security issues: [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
