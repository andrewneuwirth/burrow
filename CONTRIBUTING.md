# Contributing

Thanks for helping. Read [AGENTS.md](AGENTS.md) first: it explains every source file, where data lives and the rules.

## Build and check

```sh
swift build && .build/debug/Burrow --self-check   # must print "Burrow self-check passed"
.build/debug/Burrow --welcome-preview /tmp/shots   # the first-launch walkthrough as PNGs, light and dark
./build.sh                                         # build/Burrow.app
```

The self-check is the test suite: file operations and undo in a temporary folder, search ranking, Tidy rules, the
Markdown parser and the settings migration. New non-trivial logic gets a check next to the existing ones. CI runs the
same build and self-check on every push and pull request.

Don't test "Make Burrow the Default" on a Mac you rely on without knowing the way back: Settings › Give It Back to
Finder, or `build/Burrow.app/Contents/MacOS/Burrow --give-back`.

## Style

- No third-party dependencies. Apple frameworks only.
- Small, focused code. No speculative abstractions or options nobody asked for.
- Anything destructive goes through the Trash and ⌘Z first.
- A one-line comment for each non-obvious *why*; skip comments that restate the code.
- Swift 5 language mode.
- Never put real names, paths, email addresses or credentials in code, tests or docs; use `/Users/me`, `example.com`.

## Pull requests

Keep them focused on one change, describe what you checked, and include a screenshot for UI changes.
