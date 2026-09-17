# PDF2ZH Web (macOS menu bar app)

English | [中文](README.md)

A tiny launcher that lives in the menu bar, takes no Dock space, and runs the WebUI of
[PDFMathTranslate-next](https://github.com/PDFMathTranslate-next/PDFMathTranslate-next) (`pdf2zh_next`)
in the background — so you never have to type `pdf2zh_next --gui` again.

<img src="assets/icon-preview.png" width="112" alt="PDF2ZH Web icon">

The concept and the project layout follow [DSH-desktop-server](https://github.com/JshGao/DSH-desktop-server).
The implementation spec is `VIBE_CODING.md`; the app is a single `main.swift`.

**Requirements**

- macOS 11+ (verified on macOS 26.7 / Apple Silicon)
- To build: `swiftc` (Xcode, or `xcode-select --install`)
- To run: `pdf2zh_next` installed locally (verified with 2.9.0)

> This app is only a launcher: it does **not** bundle `pdf2zh_next` and never installs it. When the
> executable is missing, the status line says so and an alert shows the install command (with a
> one-click copy). The upstream-recommended install (after installing [uv](https://docs.astral.sh/uv/)):
>
> ```bash
> uv tool install --python 3.12 pdf2zh-next   # recommended upstream
> pipx install pdf2zh-next                    # or pipx
> ```

---

## Build from source

```bash
./build.sh                        # produces build/PDF2ZH Web.app
open "build/PDF2ZH Web.app"       # launch it
./scripts/package.sh 1.0.0        # optional: .dmg / .zip into build/dist/
```

Other switches:

```bash
PDF2ZH_VERSION=1.2.3 ./build.sh   # set the version (default 1.0.0)
PDF2ZH_REGEN_ICONS=1 ./build.sh   # re-render icons after editing scripts/make-icons.swift
```

Building needs nothing but `swiftc` — no Xcode project. The module cache is kept inside
`build/.swift-module-cache`, so builds are self-contained and work in sandboxes and CI. The icon
artefacts are committed under `assets/` and are the source of truth at build time, so a normal build
does not re-render them.

You can also grab a prebuilt `PDF2ZH Web-<version>.dmg` (the app plus a shortcut to `/Applications`)
or `PDF2ZH Web-<version>.zip` from Releases. Push a `v*` tag and CI builds, verifies and packages
both on a macOS runner.

Once launched, **two interlocking loops** (the author's own vector mark) appear in the menu bar: it is a black-on-transparent template image,
so macOS draws it black on a light menu bar and white on a dark one. It never shows up in the Dock or
in Cmd-Tab (`LSUIElement=true`). In Finder, the app icon is a rounded blue gradient tile with a
centred white ∞.

### Menu

| Item | What it does |
|---|---|
| `PDF2ZH Web：运行中（端口 7860）` | Status line (disabled): 启动中…（端口 N）/ 运行中（端口 N）/ 已停止 / failure reason / 未找到 pdf2zh_next |
| 在浏览器中打开 ⌘O | Opens `http://127.0.0.1:<port>/`; enabled only while running |
| 复制服务地址 | Copies the same URL to the clipboard; enabled only while running |
| 打开输出文件夹 | Opens `outputDirectory`, creating it first if needed |
| 打开日志 | Opens `~/Library/Logs/pdf2zh-web.log`, or says there is no log yet |
| 重新检查 pdf2zh_next | Re-probes for the executable; shows the install guide when missing |
| 重启 PDF2ZH Web ⌘R | Stops the service and starts it again (use this after editing `config.json`) |
| `pdf2zh_next：2.9.0` | Version line; click for the runtime details (version, executable, workdir, port, log, config path) |
| 退出并停止 PDF2ZH Web ⌘Q | Quits the app and terminates the service with all of its children |

(The menu itself is Chinese, matching the upstream tool's audience.)

Default address: <http://127.0.0.1:7860/>

> **No token — but the service listens on `0.0.0.0`, so your LAN can reach it.** This is the exact
> opposite of the reference project DSH Web: DSH protects its GUI with a per-process token, while
> pdf2zh_next's Gradio UI has no token and no auth at all, so the bare
> `http://127.0.0.1:7860/` just works. For the same reason upstream binds `0.0.0.0` by default —
> **any other device on your local network can open that UI and submit translation jobs.** If that
> bothers you, do one of these:
>
> - restrict inbound connections to that process with the macOS firewall (System Settings → Network → Firewall);
> - or change the bind address in upstream's own config file `~/.config/pdf2zh/config.v3.toml`
>   (this app deliberately does not override `server_name`, to avoid fighting upstream behaviour).

### Gatekeeper blocks the first launch

> The app is ad-hoc signed and not notarised, so the first double-click says Apple cannot check it for
> malicious software. Either:
>
> - in Finder, **right-click (or Control-click) the icon → Open → then click "Open"**; double-clicking
>   works normally afterwards;
> - or run `xattr -dr com.apple.quarantine "/Applications/PDF2ZH Web.app"` in Terminal.
>
> Removing the prompt for good would need an Apple Developer ID signature plus notarisation, which this
> project does not do.

### Keep it around

1. Drag `PDF2ZH Web.app` into `/Applications`.
2. System Settings → General → Login Items, and add it as an "Open at Login" item.

---

## Configuration

Config file (a self-documenting template is written on first launch, mode 0600):

```text
~/Library/Application Support/PDF2ZHWeb/config.json
```

Precedence: **environment variables > config.json > defaults**.

| Key | Environment variable | Default | Meaning |
|---|---|---|---|
| `pdf2zhPath` | `PDF2ZH_PATH` | auto-detected | Absolute path to the `pdf2zh_next` executable; empty means "未找到 pdf2zh_next" |
| `workingDirectory` | `PDF2ZH_WORKDIR` | `~/PDF2ZH Workspace` | Working directory of the service, created if missing |
| `webPort` | `PDF2ZH_WEB_PORT` | `7860` | Passed to `pdf2zh_next --server-port` |
| `outputDirectory` | `PDF2ZH_OUTPUT_DIR` | same as `workingDirectory` | Where "打开输出文件夹" points |
| `extraArguments` | — | `[]` | Extra arguments appended to `pdf2zh_next`, e.g. `["--debug"]` |
| `environment` | — | `{}` | Extra environment variables for the service (PATH, API keys, ...) |
| `envFile` | `PDF2ZH_ENV_FILE` | `~/Library/Application Support/PDF2ZHWeb/env` | `KEY=VALUE` lines, `#` comments, ignored when absent |
| `logPath` | `PDF2ZH_LOG_PATH` | `~/Library/Logs/pdf2zh-web.log` | Appended to, permissions pinned to 0600 |
| `logMaxBytes` | — | `5242880` | Rotated to `.log.1` on the next start once exceeded |
| `startupTimeoutSeconds` | — | `60` | How long to wait for the port to come up |
| `autoOpenBrowser` | `PDF2ZH_AUTO_OPEN` | `false` | When true, the app opens the browser once the port is live |

Example:

```json
{
  "webPort": 7860,
  "workingDirectory": "/Users/me/PDF2ZH Workspace",
  "environment": { "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" },
  "autoOpenBrowser": true
}
```

Changes take effect from the menu item "重启 PDF2ZH Web" — no rebuild needed.

**About environment variables:** an app launched from Finder reads no shell profile, so `PATH`, API
keys and friends put in `~/.zshrc` never reach it. Put them in `config.json`'s `environment` or in
`envFile` instead. The app builds its own PATH (directory of the executable + `~/.local/bin` +
`/opt/homebrew/bin` + `/usr/local/bin` + system directories + the inherited PATH, deduplicated),
because `pdf2zh_next` shells out to helper binaries.

`autoOpenBrowser` parsing: `PDF2ZH_AUTO_OPEN` counts as true for `1`, `true`, `yes` or `on`
(case-insensitive); any other value is false.

---

## About translation engines

This app does **not** manage translation engines. Engine selection, API keys and the source/target
languages all belong to pdf2zh_next itself:

- `~/.config/pdf2zh/config.v3.toml` (already configured with DeepSeek on this machine);
- or the WebUI itself.

All the app does is add `--gui --server-port <port>` at launch. **Starting it never writes back to
your pdf2zh config**: measured with `--server-port 7861`, `config.v3.toml` kept both its contents and
its mtime, so the port override lasts for that run only (upstream writes the file only when you press
save in the GUI).

---

## How it works (short version)

- `posix_spawn` with `POSIX_SPAWN_SETPGROUP` makes the supervisor its own process-group leader, so
  `zsh → pdf2zh_next → python` all live in one group and a single `killpg` reaps the tree on exit;
  a SIGTERM that is ignored for 4 seconds is escalated to SIGKILL.
- Readiness is decided by **TCP port probing** (`connect` to `127.0.0.1:<port>`): pdf2zh_next's Gradio
  UI exposes no token-bearing ready URL, and Gradio only binds once the app is actually serving. The
  Gradio banner in the log (`* Running on local URL:`) is parsed too, but only as a bonus — upstream
  does not print it at all when stdout is not a tty.
- A watchdog subshell inside the group kills the whole group within a second of the app crashing or
  being `kill -9`'d (measured: the port is released within 1 second of a `kill -9`).
- Logout, shutdown and `kill -TERM` are routed onto the normal exit path and do the same cleanup.
- The child environment sets `BROWSER=/usr/bin/true`, which turns the `webbrowser.open()` call inside
  `pdf2zh_next --gui` into a no-op so it cannot steal focus on every restart; set `autoOpenBrowser` if
  you want the browser opened anyway.
- Only one app instance may run at a time (`flock` on
  `~/Library/Application Support/PDF2ZHWeb/pdf2zh-web.lock`); the port is probed before starting, and
  an occupied port is reported instead of starting a second server.

The source carries more detailed comments; `VIBE_CODING.md` holds the full spec.

---

## Troubleshooting

**pdf2zh_next not found**: the status line reads "未找到 pdf2zh_next" and an alert shows the install
command (one-click copy of `uv tool install --python 3.12 pdf2zh-next`). Once installed, use
"重新检查 pdf2zh_next" in the menu. If it lives somewhere unusual, set `pdf2zhPath` to its absolute
path in `config.json`. Note that when the probe finds a *different* path, the menu asks you to quit and
reopen the app so the new install is picked up.

**Port already in use**: the menu shows "端口 7860 已被占用" and an alert appears; the app does not
start a second server.

```bash
lsof -nP -iTCP:7860 -sTCP:LISTEN     # see who holds it
kill -TERM <pid>                     # only after confirming it is a leftover; kill -9 <pid> if needed
```

If that process is your own `pdf2zh_next` running in a terminal, just use it — you do not need this app.

**Stuck on "启动中…"**: the first run downloads the babeldoc assets (models and fonts), which can take
from tens of seconds to minutes; after `startupTimeoutSeconds` (60 by default) an alert appears. Check
the log:

```bash
tail -50 ~/Library/Logs/pdf2zh-web.log
```

**The status line shows a failure**: the tail of the log supplies the reason — the last line containing
`EADDRINUSE`, `error`, `Traceback` or `Address already in use`.

**Log safety**: the log contains translation-engine settings, so its permissions are pinned to 0600 —
do not share it. If you suspect a leak, `rm ~/Library/Logs/pdf2zh-web.log` and restart the app.

---

## Project layout

```text
pdf2zh-server/
├── main.swift                  # the whole menu bar app (config, state machine, posix_spawn, readiness, cleanup)
├── build.sh                    # builds the .app: compile + icons + Info.plist + ad-hoc signature
├── assets/
│   ├── download.svg            # the mark's source of truth (hand-drawn vector)
│   ├── AppIcon.icns            # committed app icon artefact
│   ├── pdf2zh-status.png       # committed status bar icon (interlocking loops, black on transparent)
│   └── icon-preview.png        # preview image used by the READMEs
├── scripts/
│   ├── make-icons.swift        # renders the icons with CoreGraphics/CoreText (original ∞ mark)
│   ├── package.sh              # packages .dmg / .zip
│   └── verify.sh               # acceptance: static checks + runtime checks + teardown checks
├── .github/workflows/build.yml # CI: build + verify; publishes a Release on tags
├── VIBE_CODING.md              # implementation spec
├── README.md                   # Chinese README
├── README.en.md                # English README (this file)
├── LICENSE                     # MIT
└── .gitignore
```

`build/` holds build artefacts and is ignored by `.gitignore`.

---

## Known limitations

- The coupling to upstream is exactly three things: the `--gui` and `--server-port` flags, the
  executable name `pdf2zh_next`, and the fact that readiness is decided by the port. Only an upstream
  **rename** forces a change to `main.swift` and a rebuild; **new upstream releases need no rebuild**
  (the app only calls the CLI and pins no version).
- The status bar icon is limited by menu bar height: `NSStatusItem.squareLength` is a square and about
  22pt is already near the ceiling, so making it larger changes nothing.
- The service listens on `0.0.0.0` by default (upstream behaviour) with no authentication, so the LAN
  can reach it — see the security note above.
- This app is an **unofficial** launcher and is not affiliated with the PDFMathTranslate-next project.
- It does not install dependencies and does not notarise its builds.
- Run one instance at a time: multiple `pdf2zh_next` instances share `~/.config/pdf2zh` and fight over
  the port.

---

## Credits and licence

- This project is an **unofficial** launcher for
  [PDFMathTranslate-next](https://github.com/PDFMathTranslate-next/PDFMathTranslate-next). It does not
  modify upstream sources; it only calls its CLI (`pdf2zh_next --gui`).
- Concept and engineering layout follow [DSH-desktop-server](https://github.com/JshGao/DSH-desktop-server) (MIT).
- The icons are original to this project: an ∞ mark rendered directly by `scripts/make-icons.swift`
  with CoreGraphics/CoreText (a stroked infinity symbol; a rounded gradient tile for the app icon).
  They contain **no** artwork from
  upstream PDFMathTranslate.
- The code in this project is released under the [MIT](LICENSE) licence.

---

## Rebuild / verify / uninstall

```bash
./build.sh              # rebuild after editing main.swift
./scripts/verify.sh     # acceptance run
rm -rf "build/PDF2ZH Web.app"                        # uninstall the app
rm -rf ~/Library/Application\ Support/PDF2ZHWeb      # uninstall config and state
rm -f  ~/Library/Logs/pdf2zh-web.log                 # uninstall the log
```

`./scripts/verify.sh` checks the bundle structure, `LSUIElement`, the signature, the status icon's
alpha channel, the port listening at runtime, that the WebUI answers HTTP 200, that the log is mode
0600, that the config template was generated, and that no processes or port bindings survive the
shutdown (the script starts the app itself and leaves it stopped).
