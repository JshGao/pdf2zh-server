# PDF2ZH Web 菜单栏应用 — 实现规格（v1）

本文是实现规格与验收依据。`main.swift` 是本文的权威实现；两者不一致时以本文描述的行为为准，
并修正 `main.swift`。

---

## 0. 背景

[PDFMathTranslate-next](https://github.com/PDFMathTranslate-next/PDFMathTranslate-next)（`pdf2zh_next`）
是一个 PDF 文档翻译工具，自带 Gradio 编写的 WebUI。启动它是 `pdf2zh_next --gui`，界面在
<http://127.0.0.1:7860/>。

日常使用有三个摩擦点：

1. 每次都要打开终端敲命令，关掉终端窗口服务可能一起没；
2. `pdf2zh_next --gui` 启动时会调用 `webbrowser.open()`，即使你只是想让它常驻后台，它也会弹浏览器抢焦点；
3. 服务在后台跑着，没有任何地方能看到"它到底活着没有"。

本项目仿照 [DSH-desktop-server](https://github.com/JshGao/DSH-desktop-server) 的概念，做一个只有状态栏
图标、不占程序坞的包装器，把这三件事一次解决。

---

## 1. 目标

- 双击即用：启动 App 就等于在后台跑起 `pdf2zh_next --gui`，无需终端。
- 状态可见：状态栏图标常驻，菜单第一行实时显示服务的真实状态。
- 一键可达：菜单里能直接打开 WebUI、复制地址、打开日志与输出文件夹。
- 退得干净：退出 App（含注销 / 关机 / 崩溃 / 强杀）后不留任何残留进程和端口占用。
- 不越权：不修改上游源码，不接管用户的翻译引擎配置，不悄悄改动用户的 pdf2zh 配置文件。

---

## 2. 非目标

- **不安装依赖。** App 只启动本机已装的 `pdf2zh_next`；未安装时给安装引导，不代替用户执行安装。
- **不管理翻译引擎。** 引擎选型、API key、源/目标语言属于 pdf2zh_next 自己的配置
  （`~/.config/pdf2zh/config.v3.toml` 与 WebUI 界面），App 一概不碰。
- **不做翻译功能。** 不调用 pdf2zh_next 的命令行翻译模式，不解析 / 转发 PDF 文件。
- **不做公证与 Developer ID 签名。** ad-hoc 签名 + README 说明 Gatekeeper 处理方式即可。
- **不内嵌 Python 运行时。** 不打包 Python、不打包 pdf2zh_next、不做独立发行版。

---

## 3. 需求

### 3.1 功能需求

| 编号 | 需求 |
|---|---|
| FR-1 | 启动 App 后在后台拉起 `pdf2zh_next --gui`，端口由配置决定（默认 7860） |
| FR-2 | 状态栏常驻图标，不占程序坞、不进 Cmd-Tab |
| FR-3 | 菜单第一行显示状态：启动中 / 运行中（端口）/ 已停止 / 异常原因 / 未找到 pdf2zh_next |
| FR-4 | "在浏览器中打开"打开 `http://127.0.0.1:<port>/` |
| FR-5 | "复制服务地址"把同一地址写入剪贴板 |
| FR-6 | "打开输出文件夹"、"打开日志"分别打开对应路径 |
| FR-7 | "重启 PDF2ZH Web"停止当前服务再重新拉起 |
| FR-8 | "退出并停止 PDF2ZH Web"退出 App 并终止服务及其所有子进程 |
| FR-9 | 未找到 pdf2zh_next 时：状态行明示 + 弹窗给安装命令（可一键复制）+ 菜单项可重新检查 |
| FR-10 | App 崩溃或被 `kill -9` 后，服务必须在 5 秒内被清理 |
| FR-11 | 注销 / 关机 / `kill -TERM` 走正常退出路径，做同样的清理 |
| FR-12 | 同时只允许一个 App 实例；端口已被占用时不重复启动，而是提示 |
| FR-13 | 首次启动生成带说明的配置模板，让配置项可被发现 |
| FR-14 | 菜单可查看 pdf2zh_next 版本与运行环境（路径、端口、工作目录、日志路径） |

### 3.2 非功能需求

| 编号 | 需求 |
|---|---|
| NFR-1 | 仅依赖 Cocoa + Darwin，单文件 `main.swift`；构建只需 `swiftc`，不需要 Xcode 工程 |
| NFR-2 | 模块缓存写在 `build/` 内，构建可在沙箱 / CI 中完成 |
| NFR-3 | 日志权限 0600（含翻译引擎设置等隐私信息）；超过 `logMaxBytes` 自动轮转为 `.log.1` |
| NFR-4 | 从 Finder 双击启动也要正确工作：环境变量不依赖 `~/.zshrc` |
| NFR-5 | 与上游的耦合面必须小且明确（见 §5），上游发新版本不需要重新构建 |
| NFR-6 | 所有对外文案为中文；源码注释为英文（与参考项目一致） |

---

## 4. 技术方案

### 4.1 总体结构

```
NSApplication(.accessory)
  └─ AppDelegate
       ├─ AppConfig         启动时一次性加载（环境变量 > config.json > 默认值）
       ├─ 状态机            starting / running / stopped / problem / missingDependency
       ├─ NSStatusItem      状态栏图标 + 菜单
       ├─ posix_spawn       /bin/zsh -c <supervisor 脚本>，独立进程组
       └─ Timer(0.5s)       回收子进程 + 探测端口就绪
```

### 4.2 状态机

| 状态 | 进入条件 | 菜单首行 |
|---|---|---|
| `stopped` | 初始；用户主动停止后 | `PDF2ZH Web：已停止` |
| `starting` | spawn 成功后 | `PDF2ZH Web：启动中…（端口 N）` |
| `running(url)` | 端口可连接，或日志解析出 Gradio URL | `PDF2ZH Web：运行中（端口 N）` |
| `problem(reason)` | 端口被占用 / 启动超时 / 进程异常退出 | `PDF2ZH Web：<原因>` |
| `missingDependency` | 探测不到 pdf2zh_next 可执行文件 | `PDF2ZH Web：未找到 pdf2zh_next` |

只有 `running` 状态下"在浏览器中打开"和"复制服务地址"才可用。

### 4.3 就绪判定（与参考项目的关键差异）

参考项目的 DSH 有进程级 token，就绪信号是日志里的 `dsh web: <带 token 的 URL>`，且必须用该 URL
才能通过认证。

**pdf2zh_next 不是这样**：它的 Gradio 界面默认既没有 token 也没有认证，裸地址
`http://127.0.0.1:<port>/` 直接可用。因此没有"必须解析出来的 URL"，就绪判定改为：

1. **主信号：TCP 端口探测。** 用 `socket` + `connect(127.0.0.1, port)` 判断。Gradio 只在应用
   构建完成、真正开始服务之后才 bind，所以"能连上"就等于"可用"。这是唯一不依赖上游输出格式的信号。
2. **补充信号：解析 Gradio banner。** 日志中出现 `* Running on local URL:  http://127.0.0.1:7860`
   时取该 URL。若 host 是 `0.0.0.0`（pdf2zh_next 默认绑定）则改写为 `127.0.0.1`，因为 `0.0.0.0`
   不是浏览器能拨的地址。

> 实测结论：`pdf2zh_next --gui` 在 stdout 不是 tty 时**不打印** Gradio banner，日志里只有 rich 格式的
> 引擎信息。所以第 2 条只是增强，第 1 条才是必须可靠的那条。

超过 `startupTimeoutSeconds`（默认 60）仍未就绪 → `problem("启动超时")` 并弹窗提示看日志。

### 4.4 进程组与清理

与参考项目一致，这是保证"退得干净"的核心：

- `posix_spawn` 时设 `POSIX_SPAWN_SETPGROUP` 且 `setpgroup(0)`，让 supervisor 成为新进程组的组长。
  不用 `zsh -m`：zsh 没有 tty 时无法开启 job control。
- supervisor 脚本内部再 `&` 起真正的服务，于是进程组覆盖 `zsh → pdf2zh_next → python` 整棵树。
- 退出用 `killpg(pgid, SIGTERM)`，4 秒不退升级 `SIGKILL`。
- 停止后不强等整个组：组内的看门狗对 TERM 免疫且要待满 3 秒宽限期，若等它则每次退出都多花 3 秒。
  只等组长（supervisor）退出，剩下的交给看门狗收尾。

### 4.5 看门狗（FR-10）

`applicationWillTerminate` 在崩溃 / 强杀时不会执行，所以清理不能只依赖它。supervisor 脚本在组内
先起一个看门狗子 shell：

```zsh
( trap '' TERM
  while kill -0 "$wrapper" 2>/dev/null && kill -0 "$pgid" 2>/dev/null; do sleep 1; done
  kill -TERM -"$pgid" 2>/dev/null
  sleep 3
  kill -KILL -"$pgid" 2>/dev/null ) &
```

看门狗每秒检查 App 进程（`$wrapper` 在 spawn 时被写成字面量）与进程组是否还在；App 一旦消失，
它把整个组杀掉。它 `trap '' TERM` 是刻意的：正常退出时不会被 App 的 `killpg(SIGTERM)` 立刻带走，
从而保证"强杀"这条路径也有收尾者。

### 4.6 抑制自动弹浏览器

`pdf2zh_next --gui` 最终走到 Gradio 的 `webbrowser.open(link)`（`inbrowser=True` 是硬编码默认值，
CLI 没有暴露开关），而 Python 的 `webbrowser` 模块会遵循 `BROWSER` 环境变量。因此在子进程环境里设：

```
BROWSER=/usr/bin/true
```

`webbrowser.open()` 于是变成执行 `/usr/bin/true <url>` —— 调用成功但什么也不做。这比改上游源码或
monkey-patch 更干净，且不产生任何副作用。需要恢复自动打开的用户把 `autoOpenBrowser` 设为 `true`，
届时由 App 在端口就绪后主动打开。

---

## 5. 与上游的耦合面（FR-5 / NFR-5）

包装器只依赖以下四件事，全部经实测确认：

| 耦合点 | 内容 | 证据 |
|---|---|---|
| 可执行文件名 | `pdf2zh_next` | `pyproject.toml` 的 `[project.scripts]` 同时提供 `pdf2zh` / `pdf2zh2` / `pdf2zh_next` |
| 启动 flag | `--gui` | `pdf2zh_next --help` 输出 `--gui  Enable GUI mode` |
| 端口 flag | `--server-port` | `pdf2zh_next --help` 的 `GUISettings` 段列出 `--server-port SERVER_PORT`；实测 `--server-port 7861` 确实监听 7861 |
| 默认端口 | 7860 | `GUISettings.server_port` 默认值；`--help` 与 `~/.config/pdf2zh/config.v3.toml` 一致 |

**上游发新版本不需要重新构建**，因为 App 只调用 CLI、不加任何版本约束。

另有两条重要实测结论，决定了实现的取值：

1. **`--server-port` 是扁平名**，不是 `--gui-settings.server-port`。argparse 的构造逻辑
   （`pdf2zh_next/config/main.py`）对嵌套设置做了扁平化，以 `--help` 的输出为准。
2. **启动 `--gui` 不会回写用户配置文件**。`ConfigManager.initialize_config()` 只读取并合并
   （`~/.config/pdf2zh/config.v3.toml` 优先级低于 CLI 与环境变量），回写只发生在 GUI 里点保存时。
   实测：以 `--gui --server-port 7861` 启动后，`config.v3.toml` 的 `gui = false` 与
   `server_port = 7860` 均未变化，文件 mtime 未变。因此 App 的端口覆盖是"仅本次运行有效"的，
   用户自己的配置不会被污染。

---

## 6. 文件布局

```text
pdf2zh-server/
├── main.swift                  # 菜单栏 App 全部源码（配置、状态机、posix_spawn、就绪探测、清理）
├── build.sh                    # 构建 .app：编译 + 图标 + Info.plist + ad-hoc 签名
├── assets/
│   ├── AppIcon.icns            # 提交的 App 图标产物（构建时的真源）
│   ├── pdf2zh-status.png       # 提交的状态栏图标产物（黑字 + 透明底，可作模板图）
│   └── icon-preview.png        # README 预览图
├── scripts/
│   ├── make-icons.swift        # CoreGraphics/CoreText 渲染图标（原创"译"字标识，不含上游美术资源）
│   ├── package.sh              # 打包 .dmg / .zip
│   └── verify.sh               # 验收：静态检查 + 运行期检查 + 退出清理检查
├── .github/workflows/build.yml # CI：构建 + 验收；打标签时发布 Release
├── VIBE_CODING.md              # 本文件（实现规格）
├── README.md                   # 中文 README
├── README.en.md                # 英文 README
├── LICENSE                     # MIT
└── .gitignore
```

`build/` 是构建产物目录，已在 `.gitignore` 中忽略。

---

## 7. 实现规格

### 7.1 配置项

配置文件 `~/Library/Application Support/PDF2ZHWeb/config.json`，首次启动自动生成模板（权限 0600）。
优先级：**环境变量 > config.json > 默认值**。

| 键 | 环境变量 | 默认值 | 说明 |
|---|---|---|---|
| `pdf2zhPath` | `PDF2ZH_PATH` | 自动探测 | 见 §7.2；探测不到则为空并进入 `missingDependency` |
| `workingDirectory` | `PDF2ZH_WORKDIR` | `~/PDF2ZH Workspace` | 服务工作目录，不存在自动创建 |
| `webPort` | `PDF2ZH_WEB_PORT` | `7860` | 传给 `--server-port` |
| `outputDirectory` | `PDF2ZH_OUTPUT_DIR` | 同 `workingDirectory` | "打开输出文件夹"指向的目录 |
| `extraArguments` | — | `[]` | 追加到 `pdf2zh_next` 之后的参数 |
| `environment` | — | `{}` | 追加给服务的环境变量 |
| `envFile` | `PDF2ZH_ENV_FILE` | `~/Library/Application Support/PDF2ZHWeb/env` | `KEY=VALUE` 行，`#` 注释，不存在则忽略 |
| `logPath` | `PDF2ZH_LOG_PATH` | `~/Library/Logs/pdf2zh-web.log` | 追加写入，权限 0600 |
| `logMaxBytes` | — | `5242880` | 超过则轮转为 `.log.1` |
| `startupTimeoutSeconds` | — | `60` | 等端口就绪的超时 |
| `autoOpenBrowser` | `PDF2ZH_AUTO_OPEN` | `false` | true 时端口就绪后由 App 打开浏览器 |

### 7.2 pdf2zh_next 路径探测

按顺序探测，取第一个可执行的。由 uv tool 安装（官方文档推荐的方式）排在最前：

1. `~/.local/share/uv/tools/pdf2zh-next/bin/pdf2zh_next`
2. `~/.local/bin/pdf2zh_next`
3. `~/.local/pipx/venvs/pdf2zh-next/bin/pdf2zh_next`
4. `/opt/homebrew/bin/pdf2zh_next`、`/usr/local/bin/pdf2zh_next`
5. `~/.venv/bin/pdf2zh_next`、`~/venv/bin/pdf2zh_next`
6. `~/.pyenv/versions/*/bin/pdf2zh_next`（版本号倒序）
7. 继承来的 `PATH` 中任意目录下的 `pdf2zh_next`

全部落空 → `pdf2zhPath` 为空 → 状态 `missingDependency`，菜单状态行明示并弹安装引导。

### 7.3 状态栏图标

优先使用 bundle 里的 `pdf2zh-status.png`（22pt，`isTemplate = true`）：macOS 会按菜单栏明暗
自动着色，浅色栏显示黑色、深色栏显示白色。取不到时回退到 SF Symbols
（`translate` → `character.book.closed` → `doc.text.magnifyingglass` → `doc.text`），再不行用文字"译"。

图形是**圆角方框 + "译"字**：纯汉字在菜单栏里视觉重量偏轻，跟旁边的系统图标不搭；加一圈描边后
重量相当，同时兼作图形元素，比裸字更像个图标。全部尺寸由画布比例推导（描边 7.5%、圆角半径 26%、
字号 52%、内缩 2%），所以同一份描述在 16pt 和 1024pt 都成立，不存在位图缩放。

**垂直定位必须基于墨迹边界，不能用 ascent/descent。** PingFang 报告 ascent 1.06em、descent 0.34em，
行框高 1.4em，而汉字墨迹只有约 0.92em 且完全在基线之上；由 ascent/descent 反推原点会把字顶高
（实测偏移约 13% 画布高）。因此统一用 `CTLineGetBoundsWithOptions(.useGlyphPathBounds)` 的墨迹框
居中，再用 `opticalShiftEm = -0.018` 做光学补偿——汉字上半部笔画更密，几何居中看起来仍偏高。
App 图标里的"译"字同理。

图标由 `scripts/make-icons.swift` 用 CoreGraphics/CoreText 直接光栅化生成，矢量描述在代码里，
每个尺寸独立渲染而不是位图缩放。这是**原创标识**（深蓝圆角底板 + 白色"译"字），不使用上游
PDFMathTranslate 的任何美术资源。

### 7.4 状态栏菜单

| 菜单项 | 行为 |
|---|---|
| `PDF2ZH Web：<状态>` | 禁用状态行，实时反映状态机 |
| 在浏览器中打开 ⌘O | 仅 `running` 可用 |
| 复制服务地址 | 仅 `running` 可用；无 token，裸地址即可用 |
| 打开输出文件夹 | 不存在则创建后再打开 |
| 打开日志 | 无日志时提示 |
| 重新检查 pdf2zh_next | 重新探测路径；未装则弹安装引导 |
| 重启 PDF2ZH Web ⌘R | stop → 等 0.4s → start（`waitForPortFree`） |
| `pdf2zh_next：<版本>` | 点击显示运行环境详情（FR-14） |
| 退出并停止 PDF2ZH Web ⌘Q | `NSApp.terminate` → 走清理路径 |

### 7.5 启动序列

1. 取得单实例锁（flock）；失败则提示已有实例并退出。
2. 后台异步执行 `pdf2zh_next --version` 取版本（也充当可执行性检查）。
3. 首次启动时写配置模板。
4. `pdf2zhPath` 为空 → `missingDependency` + 安装引导，结束。
5. 创建 `workingDirectory` / `stateDirectory` / `outputDirectory`。
6. 端口已被占用 → `problem("端口 N 已被占用")` + 弹窗，不重复启动。
7. 准备日志文件（轮转 + 权限 0600），记录起始偏移量。
8. `posix_spawn` supervisor，进入 `starting`，启动 0.5s 轮询。

### 7.6 supervisor 脚本模板

```zsh
cd <workingDirectory> || { print -r -- "pdf2zh-web: cannot cd to" <workingDirectory>; exit 1; }

pgid=$$
wrapper=<App 的 pid>

( trap '' TERM
  while kill -0 "$wrapper" 2>/dev/null && kill -0 "$pgid" 2>/dev/null; do sleep 1; done
  kill -TERM -"$pgid" 2>/dev/null
  sleep 3
  kill -KILL -"$pgid" 2>/dev/null ) &
watchdog_pid=$!

<pdf2zhPath> --gui --server-port <port> [extraArguments] &
server_pid=$!
print -r -- "$pgid $server_pid" > <stateDirectory>/pdf2zh-web.pid

trap 'kill -TERM -"$pgid" 2>/dev/null; kill -TERM "$watchdog_pid" 2>/dev/null; exit 0' TERM INT HUP
wait "$server_pid"
rc=$?
kill -TERM "$watchdog_pid" 2>/dev/null
exit $rc
```

`stdin` 接 `/dev/null`，`stdout`/`stderr` 都追加到日志文件（`adddup2(1, 2)`）。

### 7.7 子进程环境

- `PATH`：可执行文件所在目录 + `~/.local/bin` + `/opt/homebrew/bin` + `/usr/local/bin` + 系统目录 + 继承的 PATH，去重。
  从 Finder 启动的 App 只有极简 PATH，而 pdf2zh_next 会调用外部程序，必须自己补全。
- `HOME`、`LANG`（缺省 `en_US.UTF-8`）、`LC_CTYPE`（缺省 `UTF-8`）。
- `BROWSER=/usr/bin/true`：抑制自动弹浏览器（§4.6）。
- 先读 `envFile` 再叠加 `config.json` 的 `environment`，后者优先。

### 7.8 停止序列

1. 停轮询。
2. `killpg(pgid, SIGTERM)`，最多等 4 秒组长退出；未退则 `killpg(pgid, SIGKILL)` 再等 2 秒。
3. `waitpid(WNOHANG)` 收尸。
4. 重置状态为 `stopped`（`problem` / `missingDependency` 保持不变，避免掩盖原因）。

### 7.9 异常与退出处理

| 场景 | 处理 |
|---|---|
| 服务进程自行退出（非主动停止） | 轮询发现 → `problem(日志尾部摘要)`，摘要优先取含 `EADDRINUSE` / `error` / `Traceback` 的行 |
| App 崩溃 / `kill -9` | 组内看门狗清理（§4.5） |
| 注销 / 关机 / `kill -TERM/-INT/-HUP` | 安装 `DispatchSourceSignal` 转 `NSApp.terminate`，走 `applicationWillTerminate` 的清理 |
| `pdf2zh_next --version` 失败 | 空闲态下报 `problem("pdf2zh_next 无法执行")`；运行态下不覆盖端口这一更强证据 |

---

## 8. 构建

```bash
./build.sh                       # 生成 build/PDF2ZH Web.app
PDF2ZH_VERSION=1.2.3 ./build.sh  # 指定版本号
PDF2ZH_REGEN_ICONS=1 ./build.sh  # 改了 scripts/make-icons.swift 后重渲染图标
./scripts/package.sh 1.0.0       # 打包 .dmg / .zip 到 build/dist/
```

要点：

- 模块缓存固定在 `build/.swift-module-cache`，构建自包含、可在沙箱与 CI 中运行
  （`~/Library/Caches` 不可写时默认路径会失败）。
- 图标产物提交在 `assets/`，是构建时的真源；只有显式要求或产物缺失时才重新渲染并刷新 `assets/`。
- `Info.plist` 由 `build.sh` 生成，关键项：`LSUIElement=true`（只有状态栏）、
  `LSMinimumSystemVersion=11.0`、`CFBundleIconFile=AppIcon`。
- 最后 ad-hoc 签名（`codesign --force --sign -`）并 `--verify --strict`。
  不用已废弃的 `--deep`。

### 8.1 打包与发布

- `scripts/package.sh <版本>` 产出 `PDF2ZH Web-<版本>.zip`（`ditto`，保留 bundle 元数据与签名）
  与 `.dmg`（内含 App 与指向 `/Applications` 的符号链接）。
- CI（`.github/workflows/build.yml`）在 macOS runner 上构建 + 验收；推 `v*` 标签时把两个产物挂到 Release。
- 产物是 ad-hoc 签名、未公证，Release 说明里必须附 Gatekeeper 处理办法（见 README）。

---

## 9. 关键实现片段

### 9.1 进程组 spawn

```swift
var attributes: posix_spawnattr_t?
posix_spawnattr_init(&attributes)
posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
posix_spawnattr_setpgroup(&attributes, 0) // 0 => 子进程自建进程组并成为组长
...
let result = posix_spawn(&pid, "/bin/zsh", &actions, &attributes, argv, envp)
```

### 9.2 端口探测

```swift
address.sin_port = in_port_t(UInt16(port).bigEndian)
address.sin_addr.s_addr = inet_addr("127.0.0.1")
let result = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
return result == 0
```

### 9.3 就绪 URL 解析（支持 0.0.0.0 改写）

```swift
let markers = ["Running on local URL:", "Running on public URL:"]
...
if url.host == "0.0.0.0" || url.host == "::" {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.host = "127.0.0.1"
    if let rewritten = components?.url { url = rewritten }
}
```

### 9.4 单实例锁

`~/Library/Application Support/PDF2ZHWeb/pdf2zh-web.lock` 上 `flock(LOCK_EX | LOCK_NB)`，
拿到后写入自己的 pid；fd 持有到进程结束。

---

## 10. 开发步骤

1. 读本文件，确认要改动的需求编号。
2. 改 `main.swift`（唯一源码文件）；改图标改 `scripts/make-icons.swift`。
3. `./build.sh`（改了图标则加 `PDF2ZH_REGEN_ICONS=1`）。
4. `./scripts/verify.sh` 必须全部通过。
5. 涉及行为变更时同步更新本文件与 README。
6. 提交时把 `assets/` 里的图标产物一并提交。

---

## 11. 验收测试

`./scripts/verify.sh` 覆盖下列全部检查，退出码非 0 即失败。以下命令可用于手工复核。

### 11.1 构建验收

```bash
./build.sh
/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "build/PDF2ZH Web.app/Contents/Info.plist"  # true
codesign --verify --strict "build/PDF2ZH Web.app"
sips -g hasAlpha "build/PDF2ZH Web.app/Contents/Resources/pdf2zh-status.png"                 # hasAlpha: yes
```

状态栏图标必须带 alpha 通道，否则 `isTemplate` 上色后整块可见、不可用。

### 11.2 运行期验收

```bash
open "build/PDF2ZH Web.app"
sleep 5
pgrep -f PDF2ZHWebMenuBar                       # App 在
lsof -nP -iTCP:7860 -sTCP:LISTEN                # 服务在监听
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7860/   # 200
stat -f '%Lp' ~/Library/Logs/pdf2zh-web.log     # 600
```

首次运行要下载 babeldoc 资产，端口就绪可能需要数十秒，属正常。

### 11.3 退出清理验收

```bash
pkill -TERM -x PDF2ZHWebMenuBar
sleep 6
pgrep -f 'PDF2ZHWebMenuBar|pdf2zh_next'         # 应无输出
lsof -nP -iTCP:7860 -sTCP:LISTEN                # 应无输出
```

等 6 秒而不是立刻判定的原因：组内看门狗对 TERM 免疫且要待满 3 秒宽限期，随后才 `exit`。

### 11.4 崩溃清理验收（FR-10）

```bash
kill -9 "$(pgrep -f PDF2ZHWebMenuBar | head -1)"
sleep 5
pgrep -f 'PDF2ZHWebMenuBar|pdf2zh_next'         # 应无输出
lsof -nP -iTCP:7860 -sTCP:LISTEN                # 应无输出
```

实测：`kill -9` 后 1 秒内端口即释放，残留的 supervisor shell 在宽限期结束后自行消失。

### 11.5 上游不改配置验收（§5 结论 2）

```bash
md5 ~/.config/pdf2zh/config.v3.toml   # 记录
open "build/PDF2ZH Web.app"; sleep 10; pkill -TERM -x PDF2ZHWebMenuBar; sleep 5
md5 ~/.config/pdf2zh/config.v3.toml   # 必须与之前一致
```

---

## 12. 完成定义（DoD）

- [x] `./build.sh` 一条命令产出可运行的 `build/PDF2ZH Web.app`
- [x] `./scripts/verify.sh` 全部通过
- [x] FR-1 ~ FR-14 全部有对应实现，且 §11 各项实测通过
- [x] 未安装 pdf2zh_next 的机器上：状态行明示 + 安装引导，不静默失败
- [x] 崩溃与正常退出两条路径均无残留进程、无端口占用
- [x] 不修改用户 `~/.config/pdf2zh/` 下的任何配置
- [x] 构建自包含（模块缓存在 `build/` 内），可在沙箱 / CI 中运行
- [x] README（中英）、LICENSE、`.gitignore`、CI workflow 齐备

---

## 13. 已知限制

- 状态栏图标受菜单栏高度限制：`NSStatusItem.squareLength` 是正方形，约 22pt 已接近上限。
- **服务默认监听 `0.0.0.0`**（pdf2zh_next 上游行为，不是本 App 的选择），且 WebUI 无认证，
  因此同局域网内可访问。介意的话用 macOS 防火墙限制该进程入站，或自行修改上游配置的绑定地址。
  本 App 不覆盖 `server_name`，以免与上游行为打架。
- 首次运行要下载 babeldoc 资产（模型/字体），耗时取决于网络；这与本 App 无关。
- 同一时间只应有一个实例在跑：服务与其它 `pdf2zh_next` 实例共享 `~/.config/pdf2zh`，
  且端口会冲突。
- 不做公证签名，首次打开需用户手动放行（README 已说明）。

---

## 14. 来源与许可

- 本项目是 [PDFMathTranslate-next](https://github.com/PDFMathTranslate-next/PDFMathTranslate-next)
  的**非官方**启动器，不修改上游源码，只调用其 CLI（`pdf2zh_next --gui`）。
- 概念与工程结构参考 [DSH-desktop-server](https://github.com/JshGao/DSH-desktop-server)（MIT）。
- 图标为本项目原创（`scripts/make-icons.swift` 渲染的"译"字标识），不含上游美术资源。
- 本项目代码以 [MIT](LICENSE) 许可发布。
