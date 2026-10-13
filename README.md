<div align="center">

# Quaydeck

**Every dev server running on your Mac, in your menu bar.**

Which ports are listening, which project each one belongs to, which branch it is on,
which of them you forgot about three days ago, and one click to stop any of them.

Free, open source, no account, no telemetry.

</div>

---

## What it does

Quaydeck watches the listening TCP ports on your Mac and works out what is behind each
one.

- **Names your servers.** Not "node on :4321" but "shop · Astro · main ✦ · 2h 14m · 210MB".
- **Tells you which are healthy.** A green dot means it answers HTTP, orange means it
  answers with a 5xx, grey means the port is open but nothing is talking yet.
- **Finds what you forgot.** Two copies of the same project on different ports, a
  server idle for three days, a `tsc --watch` pegging a core with no server attached.
- **Flags what you did not start.** Anything listening from a path that is not a normal
  install location, especially if it is reachable from your network.
- **Restarts from memory.** Projects you have run before stay in a list even after they
  stop, one click to bring them back in a terminal.
- **Knows who started what.** Servers you started, servers Claude Code started and
  servers Codex started each get their own section, with the chat or session that
  started them. That includes the quick previews agents leave behind in folders with
  no project, and servers whose chat has long since closed.
- **Shows Docker as containers, not as `com.docker.backend`.** One row per container,
  named after its compose project, with its published ports and health. Stopping one
  stops that container, never Docker itself.

Everything it knows, it read from your own machine with `lsof`, `ps` and, when
Docker is running, `docker ps`.

## Install

Download the latest DMG from [Releases](https://github.com/quaydeck/quaydeck/releases),
or build it yourself:

```sh
git clone https://github.com/quaydeck/quaydeck
cd quaydeck
swift Scripts/make-icon.swift build/Quaydeck.iconset
iconutil -c icns build/Quaydeck.iconset -o Resources/AppIcon.icns
./Scripts/build-app.sh --install
```

Requires macOS 13 or later. Universal, Apple Silicon and Intel.

## Privacy

Quaydeck makes no network requests except HTTP GETs to `localhost` ports on your own
machine, to read the page title and status code of your own servers. There is no
account, no analytics, no crash reporting, no phone-home of any kind. Everything it
remembers lives in `UserDefaults` on your Mac.

Full detail in [PRIVACY.md](PRIVACY.md).

## Why it is not on the Mac App Store

Quaydeck reads the system process table and signals processes it did not start. The App
Sandbox forbids both, and the App Store requires the sandbox. So it is distributed
directly, signed with a Developer ID and notarised by Apple.

## Free forever

Everything in this repository is free, permanently, under the MIT licence. If a paid
tier ever arrives it will be for capabilities that do not exist here yet, and it will
never remove something that was free.

## How it is put together

```
Sources/
  QuaydeckCore/   scanning, classification, advice. No AppKit, no SwiftUI.
  QuaydeckUI/     the menu, settings, first run. Everything that touches AppKit.
  Quaydeck/       app entry, Sparkle, composition root.
Tests/
  QuaydeckCoreTests/
    Fixtures/     recorded lsof and ps output
```

The important seam is `CommandRunner`. Every call out to `lsof`, `ps`, `git` and `kill`
goes through it, so the entire scan pipeline can be driven from recorded output:

```swift
let inventory = PortInventory(
    runner: FixtureRunner([("lsof", "-iTCP", recordedOutput), ...]),
    fileSystem: StubFileSystem(directories: [...], files: [...]),
    home: "/Users/dev"
)
let snapshot = inventory.snapshot()
```

This is why a bug report is cheap to fix. See below.

## Reporting a misclassified port

The classifier is the part most likely to be wrong on a machine that is not the
author's. If Quaydeck labels something incorrectly, paste the output of:

```sh
lsof -nP -iTCP -sTCP:LISTEN -FpcPn
ps -ww -o pid=,ppid=,etime=,pcpu=,rss=,args= -p <the pid>
```

into an issue. That output becomes a fixture and a failing test, and the fix is
verified rather than guessed.

## Development

```sh
swift build          # build
swift test           # 63 tests, no system dependency, runs in under a second
./Scripts/build-app.sh --install
```

## Licence

MIT. See [LICENSE](LICENSE).

Quaydeck grew out of Poort, a private tool that only worked on one person's Mac.
