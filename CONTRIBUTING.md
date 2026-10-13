# Contributing

## The most useful contribution

A misclassified port, with the raw output attached.

Quaydeck's classifier decides whether a listener is a dev server, local infrastructure,
ordinary macOS noise, or something worth a second look. It was tuned on a handful of
machines, and yours is probably different. If it gets something wrong, that is a real
bug and it is cheap to fix, provided you include the input.

Run these and paste the output into an issue:

```sh
lsof -nP -iTCP -sTCP:LISTEN -FpcPn
ps -ww -o pid=,ppid=,etime=,pcpu=,rss=,args= -p <the pid in question>
```

Replace anything you would rather not share; only the shape of the paths matters.
That output becomes a file in `Tests/QuaydeckCoreTests/Fixtures/` and a test that fails
until the classifier is right.

## Setup

```sh
swift build
swift test
./Scripts/build-app.sh --install
```

No Xcode project. Everything is Swift Package Manager, so the whole build is text you
can read in a diff.

## How the code is arranged

| Target | Contains | May import |
|---|---|---|
| `QuaydeckCore` | scanning, classification, advice | Foundation only |
| `QuaydeckUI` | menu, settings, welcome, system actions | AppKit, SwiftUI, Core |
| `Quaydeck` | app entry, Sparkle, composition root | everything |

`QuaydeckCore` deliberately does not import AppKit. Keeping it that way is what makes
it testable without a running app.

## The CommandRunner rule

Nothing in `QuaydeckCore` may call `Process` directly. Every invocation of `lsof`, `ps`,
`git` or `kill` goes through the `CommandRunner` protocol, and every filesystem read
goes through `FileSystemProbe`. This is not ceremony: it is the reason the test suite
runs in under a second, needs no dev servers running, and never signals a real process.

If you add something that needs to shell out, add a method to the runner rather than
reaching around it.

The one exception is `KernelSource`, which reads sockets and processes through libproc
and sysctl so the app never has to start `lsof` or `ps`. It is the production twin of
the `lsof`/`ps` path the fixtures use. If you change it, run
`QUAYDECK_LIVE=1 swift test --filter LiveMachineTests`, which checks it against real
`lsof` and `ps` output on your machine.

## Tests

Every parser, the project resolver, the classifier and the advisor are covered by tests
that run off recorded output. If you change classification behaviour, add the fixture
that motivated it.

```sh
swift test
```

## Style

- No em-dashes.
- Comments explain why, not what. If a line needs a comment to say what it does, the
  line is the problem.
- British or American spelling, whichever the surrounding file already uses.

## Scope

Quaydeck watches local ports. Things it is not: a process manager, a Docker UI, a
network monitor, a terminal multiplexer. Proposals that make it one of those will
probably be declined, kindly.
