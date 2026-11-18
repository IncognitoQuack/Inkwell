# Contributing to Strokebook

Bug reports and pull requests are welcome.

## Set up

macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`). No Xcode project, no packages.

```bash
zsh test.sh                    # ~250 core checks, no XCTest needed
ARCHS=arm64 zsh build.sh       # dev build -> build/Strokebook.app
```

`Sources/Core` has no AppKit and is covered by `Tests/main.swift`. `Sources/App` is the UI; it has a built-in self-test that drives the real event handlers:

```bash
build/Strokebook.app/Contents/MacOS/Strokebook --library /tmp/sb-lib --screenshot /tmp/sb-shots
```

Always use a throwaway `--library` so the self-test never touches real notebooks.

## Before you send a change

- Run `zsh test.sh`. Add a check to `Tests/main.swift` for any bug you fix, and confirm it fails without your fix.
- If you touch a file parser (notebook codec, importers, encryption), also run the fuzz targets:
  `zsh Tools/fuzz/fuzz.sh codec-deep 5000` (see the header of `Tools/fuzz/main.swift` for all targets). Any trap is a bug.
- Keep it dependency-free, and keep the on-disk format backward compatible (never silently drop data from files saved by newer versions).
- For anything that changes how ink feels, say how you tested it (tablet model, driver settings).

## Good first issues

See [ROADMAP.md](ROADMAP.md). Typed text and pictures in GoodNotes import, and more tablet profiles, are the most useful gaps.

## Reporting a security problem

Please do not open a public issue for a crash on a crafted file that might be exploitable. Use GitHub's private vulnerability reporting on this repository instead.
