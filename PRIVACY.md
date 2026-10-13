# Privacy

Quaydeck is a menu bar utility that shows which ports are listening on your Mac. This
note describes exactly what it reads, what it stores, and what it sends. It is short
because the app does very little.

Last updated: 13 October 2026.

## What Quaydeck sends

Two things, and nothing else.

1. **HTTP GET requests to `localhost` on your own machine.** For each dev server it
   finds, Quaydeck requests `http://localhost:<port>/` to learn whether the server is
   answering, what status code it returns, and what its page title is. These requests
   never leave your computer.

2. **Update checks, if you leave them on.** Quaydeck asks a feed for the current
   version number. This is an ordinary HTTPS request and carries no identifier for you
   or your machine beyond what any HTTP request carries. You can switch it off in
   Settings → General.

There is no account, no sign-in, no analytics, no crash reporting, no usage
statistics, and no server that belongs to Quaydeck holding anything about you.

## What Quaydeck reads

All of this stays on your Mac.

- **Listening TCP sockets**, via `lsof`: port numbers, the process holding each one,
  and whether it is bound to loopback or to every interface.
- **Process details**, via `ps`: process id, parent process id, command line, elapsed
  time, CPU and memory. The parent chain is walked to see whether a coding agent
  started a server.
- **Ten named environment variables** of a listening process, and no others:
  `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SESSION_ID`,
  `CLAUDE_CONFIG_DIR`, `CODEX_THREAD_ID`, `CODEX_SHELL`, `CODEX_SANDBOX`, `CODEX_CI`,
  `CODEX_HOME` and `AI_AGENT`. Claude Code and Codex set these on every command they
  run, which is how Quaydeck knows an agent started a server after the agent itself
  has exited. Every other variable, including any token or key, is discarded while
  reading and never stored.
- **Agent session titles**, for servers an agent started: the chat name from Codex's
  `session_index.jsonl`, or the session title from the end of that session's Claude
  Code transcript. Only the title is read out of either file, and it stays in memory.
- **Code signatures** of listeners running from outside the usual install
  locations, checked by macOS on this Mac with network access switched off, so
  there is no revocation lookup. Only the signing organisation's name is kept.
- **Running containers**, via `docker ps`, but only when Docker (or OrbStack, Colima,
  Rancher) is holding a port: container name, image, status, published ports and
  their compose project and folder. This talks to the Docker daemon over its local
  socket. Stopping or restarting a container from the menu runs `docker stop` or
  `docker restart` with that container's id.
- **Project files**, for servers it can trace to a directory: `package.json` (for the
  project name and dependencies) and the presence of files like `go.mod`, `Cargo.toml`
  and `Gemfile`.
- **Git state**, via `git`: the current branch name and whether there are uncommitted
  changes to tracked files.

## What Quaydeck stores

In `UserDefaults`, under `app.quaydeck.Quaydeck`, on your Mac only:

- which projects you pinned
- a list of up to 30 recently-seen projects, with their path, name, framework and last
  port, so they can be restarted after they stop
- any project folders you added in Settings
- whether notifications and automatic update checks are on
- whether you have seen the welcome screen

Delete all of it with:

```sh
defaults delete app.quaydeck.Quaydeck
```

## Permissions Quaydeck asks for

- **Notifications**, only if you switch them on. Off by default.
- **Automation (Terminal)**, only when you use "Restart in Terminal". macOS will ask
  the first time, and declining simply disables that one action.
- **Start at login**, only if you tick the box. Quaydeck never registers itself.

## Sandbox

Quaydeck is not sandboxed, because reading the system process table and stopping
processes it did not start are both forbidden inside the App Sandbox. It is signed with
an Apple Developer ID and notarised by Apple. The source is public, so you can read
every system call it makes.

## Questions

Open an issue at https://github.com/quaydeck/quaydeck/issues.
