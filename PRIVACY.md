# Burrow Privacy Policy

_Last updated: November 2026_

Burrow is an open-source file browser that runs on your Mac. This policy covers the Burrow app built from this repository.

## The short version

Burrow has no server and collects nothing: no analytics, tracking, crash reporting or advertising. The authors never
receive your data. Your files, folders and settings stay on your Mac. Burrow only goes online in the two cases below.

## What Burrow reads on your Mac

- **Your files and folders**: the ones you browse, with their names, sizes, dates, Finder tags, thumbnails and "where
  from" information, and file names from the Spotlight index when you search.
- **Git status** of a folder you open that is a repository (branch and number of changes), read with `git status`, which
  never writes anything.
- **AI Agents page** (only when you open it): which projects under your home folder have Claude Code, Codex or Cursor
  set up, read from `~/.claude.json`, `~/.claude/projects`, `~/.codex/config.toml`, `~/.cursor/mcp.json` and project
  files such as `CLAUDE.md` and `.mcp.json`. Those config files can hold keys, so Burrow keeps only server names and a
  command name or host, and counts tokens in Claude Code transcripts locally. Nothing is sent anywhere.
- **Installed, About This Mac and Free Up Space**: your Mac's model, memory, disks and security settings (from
  `system_profiler`, `csrutil`, `fdesetup` and similar), the packages Homebrew, npm, pip, pipx, uv and gem have installed
  (from their own list commands), and the sizes of cache folders, all read locally. If the Vitals app is installed, Burrow reads its `vitals status` output
  and its saved disk scan so both apps show the same numbers.
- **Your browser's current tab address**, only when you choose Add Bookmark, through Automation (macOS asks first).

## When Burrow goes online

- **Bookmarks**: when you add a web bookmark, Burrow fetches that page once to read its title and preview image, and
  loads the preview image when it shows the bookmark. Requests go only to the bookmarked site and the image's host.
- **Markdown**: images with web addresses inside a Markdown file you open are loaded from where they live.

## Changes Burrow makes to your Mac

- File operations you ask for. Anything deleted goes to the Trash first, except on volumes without a Trash (Burrow asks
  before deleting there) and Empty Trash (Burrow asks first).
- Only if you choose **Make Burrow the Default**: the `NSFileViewer` default, the folder handler in Launch Services, and an
  Open at Login item. **Give It Back to Finder** removes all three.

## Where your settings live

- macOS user defaults (view options, favorites, shelf folders, workspaces, recent folders, search picks):
  `defaults delete app.newitools.Burrow` (or your own bundle id) removes them.
- `~/Library/Application Support/Burrow/bookmarks.json` (your bookmarks) and `holding.plist` (references to the files
  in the shelf's Holding, so they're still there after a restart; the files themselves stay where they are).

## Changes and contact

Changes to this policy are made in this file and visible in the repository history. Questions: hello@newitools.app or open
an issue.
