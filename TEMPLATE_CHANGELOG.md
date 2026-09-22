# Template Changelog

## 2026-09-22

- Changed: Paperclip pin `v2026.707.0` → `v2026.916.1` (latest stable). **Upgrade notes** for anyone jumping from a 7xx release: upstream ships 96 database migrations (`0184`–`0279`) that run automatically on first boot, plus breaking changes — per-agent AI provider credentials move into Connections, "cheap model profiles" are removed, invalid agent bearer tokens now return 401, Better Auth 1.7. **Take a database backup before deploying.** See the upstream release notes for [v2026.817.0](https://github.com/paperclipai/paperclip/releases/tag/v2026.817.0), [v2026.824.0](https://github.com/paperclipai/paperclip/releases/tag/v2026.824.0), [v2026.831.0](https://github.com/paperclipai/paperclip/releases/tag/v2026.831.0) and [v2026.916.0](https://github.com/paperclipai/paperclip/releases/tag/v2026.916.0).
- Changed: base images `node:22-bookworm` → `node:24-bookworm` (upstream now requires Node ≥ 24.11; `pnpm install` fails the engines check on 22). `package.json` engines updated to match.
- Added: pinned, checksum-verified `rustup` in the build stage. Upstream's `@paperclipai/server build` now compiles the native Paperclip Runner binary (`packages/paperclip-runner`, Rust) and vendors it into `server/dist`; the compiler version is read from the repo's own `rust-toolchain.toml`. Older refs without that package still build (the toolchain step is conditional). Expect a noticeably longer first build.
- Added: `tini` as PID 1 in front of the wrapper entrypoint, mirroring upstream's production image — agent runs leave orphaned `git`/`claude`/`sh` processes that otherwise pile up as zombies until the container's pid limit is exhausted.
- Note: the `hermes-agent` pin (`0.18.2`) is unchanged; the upstream Hermes adapter's CLI invocation did not change between v2026.722.0 and v2026.916.1.

## 2026-04-17

- Fixed: WebSocket proxy upstream errors no longer crash the Node process (#6, duplicate #7) — `http-proxy` can pass a socket on WS failures, which has no `writeHead`; the wrapper now sends JSON 503 only for HTTP responses and destroys the socket otherwise.
- Changed: Paperclip pin `v2026.325.0` → `v2026.416.0` (latest stable at bump time; routine upstream uptake). **Upgrade note:** upstream v2026.416.0 adds migrations including `pg_trgm`; embedded Postgres in this template should allow `CREATE EXTENSION`, but external DB users may need DBA to run `CREATE EXTENSION IF NOT EXISTS pg_trgm;` before upgrade — see [paperclip v2026.416.0 release notes](https://github.com/paperclipai/paperclip/releases/tag/v2026.416.0).
- Changed: Runtime image aligned with [upstream Paperclip production Dockerfile](https://github.com/paperclipai/paperclip/blob/master/Dockerfile) — `HOME=/paperclip`, `PAPERCLIP_INSTANCE_ID`, `PAPERCLIP_CONFIG`, `OPENCODE_ALLOW_ALL_MODELS=true`, and apt packages `git`, `openssh-client`, `jq`, `ripgrep` (agent/git tooling parity).

## 2026-04-02

- Fixed: Claude Code adapter fails with `--dangerously-skip-permissions cannot be used with root/sudo privileges` (#4)
  - Set `CLAUDE_CODE_BUBBLEWRAP=1` in Dockerfile — tells Claude Code it is running inside a container sandbox, bypassing the redundant root check while Docker's own isolation remains active
  - Replaced `gosu` with `setpriv --inh-caps=-all` in entrypoint to properly drop inherited Linux capabilities
  - Removed `gosu` package from Dockerfile (no longer needed; `setpriv` is part of the base image)
