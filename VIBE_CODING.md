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

另外还有一个**完全不同的**服务容易被混淆：Zotero 的 PDF2zh 插件并不调用上面的 Gradio 界面，
而是调用另一个上游项目 [zotero-pdf2zh](https://github.com/guaguastandup/zotero-pdf2zh) 的
`server.py`（Flask HTTP API，默认 8890）。两者协议不同、端口不同、连仓库都不同；插件指向
Gradio 的端口时会报"这个地址上不是 PDF2zh Server"。本 App 因此同时托管两个服务。

本项目仿照 [DSH-desktop-server](https://github.com/JshGao/DSH-desktop-server) 的概念，做一个只有状态栏
图标、不占程序坞的包装器，把这些事一次解决。

---

## 1. 目标

- 双击即用：启动 App 就等于在后台跑起 `pdf2zh_next --gui`，无需终端。
- 状态可见：状态栏图标常驻，菜单第一行实时显示服务的真实状态。
- 一键可达：菜单里能直接打开 WebUI、复制地址、打开日志与输出文件夹。
- 两个服务一起管：WebUI（7860）与 Zotero API（8890）各自独立启停、各自显示状态。
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
| FR-15 | 托管 zotero-pdf2zh 的 `server.py`，默认端口 8890，与 WebUI 独立启停 |
| FR-16 | 状态栏菜单为两个服务各显示一行状态；并提供"复制 Zotero 插件地址" |
| FR-17 | 未安装 server.py 时如实显示"未安装"，并给出获取方式；不影响 WebUI 运行 |
| FR-18 | 翻译进行中时，状态栏图标按总进度由左向右变绿；全部完成后回到常态，菜单显示进度百分比与任务数 |
| FR-19 | 自动检查 pdf2zh_next 与 zotero-pdf2zh 是否有新版本，有则提醒（**只检查与提醒，不自动升级**） |

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
       ├─ NSStatusItem      状态栏图标 + 菜单
       ├─ ManagedService    服务生命周期（每个服务一个实例）
       │    ├─ spec         名字、可执行文件、参数、端口、日志、超时
       │    ├─ 状态机       stopped / starting / running / problem / missing
       │    ├─ posix_spawn  /bin/zsh -c <supervisor 脚本>，独立进程组
       │    └─ 看门狗       组内子 shell，App 消失后收尾
       ├─ webService        pdf2zh_next --gui        → 7860
       ├─ zoteroService     server.py（可选）        → 8890
       └─ Timer(0.5s)       对两个服务各做一次回收 + 端口探测
```

**两个服务共用同一个 `ManagedService`。** 进程组、看门狗、日志轮转、端口探测、超时与清理
对两者完全一致，只有"可执行文件 + 参数 + 端口 + 超时"不同，因此抽成 `ServiceSpec` 数据，
生命周期逻辑只实现一次——避免两份几乎相同的 spawn / killpg 代码各自漂移。

### 4.2 状态机

每个 `ManagedService` 各有一个状态机，两个服务互不影响（WebUI 启动失败不会阻止 Zotero 服务）。

| 状态 | 进入条件 | 菜单行（以 Zotero 为例） |
|---|---|---|
| `stopped` | 初始；用户主动停止后 | `Zotero 服务：已停止` |
| `starting` | spawn 成功后 | `Zotero 服务：启动中…（端口 8890）` |
| `running` | 端口可连接 | `Zotero 服务：运行中（端口 8890）` |
| `problem(reason)` | 端口被占用 / 启动超时 / 进程异常退出 | `Zotero 服务：<原因>` |
| `missing` | 探测不到 server.py | `Zotero 服务：未安装（点击查看获取方式）` |

就绪只以**端口可连接**为准（不再解析日志 URL）：两个服务都是绑定端口之后才能应答，这个信号
对两者都可靠，且不依赖各自的输出格式。WebUI 仍会解析 Gradio banner，但那只是增强。

### 4.2.1 Zotero 服务（第二个被托管的服务）

| 项目 | 值 |
|---|---|
| 上游 | [zotero-pdf2zh](https://github.com/guaguastandup/zotero-pdf2zh)（与 pdf2zh_next 是**不同**项目） |
| 客户端 | Zotero 的 PDF2zh 插件（`pdf2zh@guaguastandup.com.xpi`） |
| 入口 | `server.py`，默认 `~/zotero-pdf2zh/server/server.py` |
| 解释器 | 同目录的 `.venv/bin/python`（Flask 等依赖装在这里，不是系统 Python） |
| 端口 | 8890 |
| 健康端点 | `GET /health` → `{"message":"PDF2zh Server is running","status":"ok",...}` |

**插件正是靠 `/health` 的这句 message 识别服务**；指向 Gradio 的 7860 时会拿不到它，
于是报"这个地址上不是 PDF2zh Server"。这也解释了为什么两个服务不能互相替代。

**一个必须绕开的坑：`server.py` 会在启动时做环境检查，发现问题就 `input()` 等一个 y/n 回答。**
本 App 给子进程的 stdin 是 `/dev/null`，那个 `input()` 会抛 `EOFError` 直接退出——无人值守
启动必须处理。做法是用管道喂答案：

```zsh
printf 'y\nn\n' | <venv>/bin/python <server.py> --port 8890
```

第一个 `y` 答"是否继续启动"（该检查是提示性的，答 y 即可正常启动；答 n 会直接取消）；
第二个 `n` 答"是否更新翻译环境"——**已配置好的环境必须保持不动**，一个每次启动都静默重装
依赖的服务比不自动更新糟糕得多。用户想更新时按上游文档跑 `update_packages.py`。

配置项见 §7.1；`zoteroAutoStart` 为 false 时可只跑 WebUI（回到单服务行为）。

只有 `running` 状态下"在浏览器中打开"和"复制服务地址"才可用。

### 4.2.2 翻译进度（FR-18）

进度数据只有一个来源：zotero-pdf2zh 的 **`GET /api/tasks`**，它返回活跃任务列表，每个任务带
`progress`（0–100）与 `status`，由 server 驱动 pdf2zh_next 时更新。**Gradio WebUI 没有等价的
接口**，所以进度显示只在装了 Zotero 服务时可用；没有它时菜单不会出现进度行，行为与以前一致。

**多个任务时取各任务百分比的算术平均**作为总进度。这些任务是独立、量级相近的翻译作业，
平均是诚实的汇总，也符合用户问"还剩多少"时的本意。

**图标如何变绿**：常态图标是 *template image*——macOS 自己按菜单栏明暗着色，这正是它能自动
适配深浅色的原因，但也意味着**模板图永远不可能是绿色**。因此有进度时改用自绘的彩色位图
（`ProgressIcon`）：同一份矢量（来自 `assets/download.svg`）先整块画成"菜单栏前景色"，
再把左侧 `fraction` 宽度的区域裁切后画成 `systemGreen`。读起来就是绿色从左向右扫过。

- 未完成部分的颜色由 `button.effectiveAppearance` 判断深浅色决定；系统切换外观时通过
  KVO 监听 `NSApp.effectiveAppearance` 重新绘制。
- 完成瞬间任务会从 `/api/tasks` 消失，拿不到 100%。因此**进入"完成"状态时图标保持满绿 4 秒**
  （`justCompleted`），再回到常态模板图标——这样"全部完成"是可见的，而不是直接跳回。
- 该窗口内继续轮询，避免图标卡在满绿；窗口结束才停表。
- 只在图标依赖的东西真正变化时重绘（`lastIconSignature` 比较），因为绘制的开销远大于比较。

**为什么进度会长时间停在 0%——这不是故障。** server 的 `MAIN_PROGRESS_RE` 只认
`translate X/Y` 这种逐页进度行；在此之前 pdf2zh_next 要走完 BabelDOC 的一长串子步骤
（`DetectScannedFile`、`Layout`、`Paragraphs`、术语抽取……），那些行形如 `Layout (1/1) 2/2`，
只会更新任务的 `message`（"正在初始化…"），**不会更新 `progress`**。所以一篇论文的进度条
可能几分钟都停在 0%，之后才开始逐页爬升。判断链路是否正常，看 `message` 是否在变，而不是
看百分比。

**一个已修复的严重 bug（记录以免重犯）**：轮询的停止判据最初写成
`fraction == nil && !justCompleted` 就停表。但 `fraction == nil` 在**启动时**也成立
（什么都还没观察到），于是追踪器在第一次 tick 后就把自己停了——之后再开始的翻译
永远不会被看到，图标自然一直不变绿。正确判据必须是"**曾经观察到过任务**、且完成提示已过期"
（`hasSeenTasks && !justCompleted`）。教训：用"当前值为空"表达"已经结束"，会在"还没开始"
时误触发；这类状态必须用独立标志区分三态（未开始 / 进行中 / 已结束）。

### 4.2.3 更新检查（FR-19）

**只检查，不下载、不安装。** 升级 pdf2zh_next 可能带来新的 BabelDOC 并触发资产重新下载；
升级 zotero-pdf2zh 会替换用户可能已改过的 server——两者都应当由用户显式决定，App 只负责
把"有更新"这件事说出来。

数据源用各自项目自己文档里的那个：

| 项目 | 来源 | 说明 |
|---|---|---|
| pdf2zh_next | PyPI JSON API `pypi.org/pypi/pdf2zh-next/json` | 它就是 `uv tool install` 装的包；`releases` 的键即版本，跳过含 `-` 的预发布 |
| zotero-pdf2zh | GitHub `releases/latest` 的 `tag_name` | 上游文档把用户指向 releases |

**版本比较必须逐段按数字比**，不能比字符串——`"2.10.0" < "2.9.0"` 在字符串序里成立，而它恰好会
把新版本误判成旧版本、让提醒永远不出现。`UpdateChecker.compareVersions` 按 `.` 切分转 Int 比较。

已安装版本从磁盘读，不启动解释器：pdf2zh_next 读 `pdf2zh_next/__init__.py` 的 `__version__`
（**用精确路径候选，不枚举 site-packages**——深度优先会先扫过数千个无关包，任何遍历预算要么
在命中前截断要么耗时数百毫秒）；zotero-pdf2zh 读 `server.py` 的 `__version__`，并以文件头的
`## server.py vX.Y.Z` 注释作兜底。

启动时检查一次，之后每 24 小时一次；菜单项"检查更新"手动触发。有更新时该项标题列出
`名称 当前 → 最新`，点击弹出升级指引（含 `uv tool upgrade pdf2zh-next` 与 release 地址）。

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
│   ├── download.svg            # 图形真源（作者手绘矢量稿，320x240 viewBox）
│   ├── AppIcon.icns            # 提交的 App 图标产物
│   ├── pdf2zh-status.png       # 提交的状态栏图标产物（互锁环，黑字 + 透明底，可作模板图）
│   └── icon-preview.png        # README 预览图
├── scripts/
│   ├── make-icons.swift        # CoreGraphics/CoreText 渲染图标（原创"文A"标识，不含上游美术资源）
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
| `pdf2zhPath` | `PDF2ZH_PATH` | 自动探测 | 见 §7.2；探测不到则为空并进入 `missing` |
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
| `zoteroServerPath` | `PDF2ZH_ZOTERO_SERVER` | 自动探测 | `server.py` 路径；探测不到则整个 Zotero 服务不托管 |
| `zoteroPythonPath` | `PDF2ZH_ZOTERO_PYTHON` | 同目录 `.venv/bin/python` | 运行 server.py 的解释器（Flask 装在这里） |
| `zoteroPort` | `PDF2ZH_ZOTERO_PORT` | `8890` | Zotero 插件里要填的端口 |
| `zoteroLogPath` | `PDF2ZH_ZOTERO_LOG` | `~/Library/Logs/pdf2zh-zotero.log` | 追加写入，权限 0600 |
| `zoteroAutoStart` | `PDF2ZH_ZOTERO_AUTOSTART` | `true` | false 时只跑 WebUI |
| `zoteroProgressPollSeconds` | — | `2` | 轮询 `/api/tasks` 的间隔（进度显示用） |
| `checkUpdatesOnLaunch` | `PDF2ZH_CHECK_UPDATES` | `true` | false 时不在启动时检查更新（仍可手动检查） |

### 7.2 pdf2zh_next 路径探测

按顺序探测，取第一个可执行的。由 uv tool 安装（官方文档推荐的方式）排在最前：

1. `~/.local/share/uv/tools/pdf2zh-next/bin/pdf2zh_next`
2. `~/.local/bin/pdf2zh_next`
3. `~/.local/pipx/venvs/pdf2zh-next/bin/pdf2zh_next`
4. `/opt/homebrew/bin/pdf2zh_next`、`/usr/local/bin/pdf2zh_next`
5. `~/.venv/bin/pdf2zh_next`、`~/venv/bin/pdf2zh_next`
6. `~/.pyenv/versions/*/bin/pdf2zh_next`（版本号倒序）
7. 继承来的 `PATH` 中任意目录下的 `pdf2zh_next`

全部落空 → `pdf2zhPath` 为空 → WebUI 状态为 `missing`，菜单状态行明示并弹安装引导。

**Zotero 服务的探测**（`resolveZoteroServer` / `resolveZoteroPython`）：按
`~/zotero-pdf2zh/server/server.py`、`~/Documents/…`、`~/Downloads/…`、`~/Applications/…`、
`~/.zotero-pdf2zh/…` 依次探测 `server.py`；解释器优先取与 `server/` 同级的 `.venv/bin/python`
（上游 release 的布局），再退到系统 python3。**探测不到 `server.py` 时整个 Zotero 服务不托管**
——菜单只显示"未安装"，WebUI 完全不受影响；这是刻意的，因为多数用户并不用 Zotero 插件。

### 7.3 图标

**状态栏图标**优先使用 bundle 里的 `pdf2zh-status.png`（22pt，`isTemplate = true`）：macOS 会按
菜单栏明暗自动着色，浅色栏显示黑色、深色栏显示白色。取不到时回退到 SF Symbols
（`translate` → `character.book.closed` → `doc.text.magnifyingglass` → `doc.text`），再不行用文字"∞"。

图形是**两个互锁的环**（interlocking loops）：一条带子在中心折返穿过自身，形成"无损往返"的
视觉表达，也与 PDF → 中文的双向转换呼应。

**几何的真源是 `assets/download.svg`**（项目作者手绘的矢量稿，viewBox 320x240）。
`scripts/make-icons.swift` 里的 `interlockingLoopsPath()` 是它的**逐条转换结果**——转换时把
SVG 的 y 向下坐标翻成 CoreGraphics 的 y 向上（`y → 240 - y`），并且**只做一次、写死在代码里**，
不在运行时解析 SVG。这样构建不引入 SVG 解析依赖，改图形只需重新导出 SVG 并重新转换。

**必须用 non-zero 填充规则，不能用 even-odd。** 两个子路径是**互锁**关系：副路径与主路径的
重叠区是"带子穿过自身"的那一段，even-odd 会把它挖空、互锁感消失；non-zero 才让它保持实心，
读起来是一条连续的带子。这是本图标唯一一处填充规则的坑。

**尺寸适配按墨迹包围盒计算**（`fittedMark(in:fill:)`）：用 `boundingBoxOfPath` 量出实际墨迹，
再等比缩放居中。因此 SVG 自带的留白会被自动忽略，图形总是填满给定空间——不管以后导出的
SVG 换了什么 viewBox 或带多少边距，都不用改代码。

| 用途 | 适配 |
|---|---|
| 状态栏 | 墨迹高 **16pt**、填充 94%（菜单栏可用高度约 22pt；18pt 显大、20pt 贴边） |
| App 图标 | 圆角底板、墨迹填充 80%，液态玻璃风格（见下） |

**状态栏图标必须紧密裁剪。** 早期版本用正方形画布，App 只能猜宽高比，1.8:1 的标识在 1:1 图里
被按错误维度缩放，于是显示得很小。现在生成器按墨迹边界裁剪，**图片自身的宽高比就是标识的真实
比例**，App 只需选高度、宽度自动跟随，并按 2x 渲染以保证放大后仍锐利。

**App 图标是液态玻璃（Liquid Glass）风格**，手绘合成，共五层：

1. 对角蓝色渐变——玻璃本体；
2. 从上方射入的径向高光——玻璃表面的镜面反射；
3. 从下缘升起的冷色反光——来自图标所置表面的反射光；
4. 标识本身，带一层柔和的深色投影（读起来像"嵌进"玻璃而非贴在上面），填充白→冷白微渐变；
5. 两道边缘描边：外缘亮细线 + 内侧稍暗线——这是玻璃"厚度"的来源。

第 2、3、5 层是全部诀窍——**只有渐变会读成塑料**。macOS 26 有 `NSGlassEffectView`，
但那是视图级材质、无法离屏渲染进 .icns，所以只能手绘。

**状态栏图标**优先使用 bundle 里的 `pdf2zh-status.png`（`isTemplate = true`）：macOS 会按
菜单栏明暗自动着色，浅色栏显示黑色、深色栏显示白色。取不到时回退到 SF Symbols
（`translate` → `character.book.closed` → `doc.text.magnifyingglass` → `doc.text`），再不行用文字"∞"。

**曾经的方案与放弃原因**（避免后人重走）：

- 圆角框 + 单字"译"：视觉重量偏轻，字与框容易挤。
- 圆角框 + "文 A" 并置：模仿常见翻译类图标，但两个复杂形状在 22pt 下互相挤压。
- "译"字压在 ∞ 上、或嵌入环内：实测确认 22pt 下两个复杂形状无法都保持可辨。
- 描边 ∞：22pt 下挨着系统实心图标像一根头发丝。**要块面重量，就用填充，不要描边。**
- 实心 ∞ + 两个正圆孔 / 倾斜椭圆孔：观感尚可但只是"甜甜圈戳洞"，与参考图的互锁结构无关。
- 双纽线参数方程（`x = a·cosθ/(1+sin²θ)`）画外轮廓：填充后腰部内凹成"沙漏"、四角带尖。
- 参数化螺旋复刻互锁结构（极坐标渐开线、对数螺线、Catmull-Rom 平滑、显式贝塞尔、`addArc`
  组合、通道内折返，共二十余轮迭代）：**全部失败**，失败模式互相矛盾——通道窄则中心不连通，
  宽则把轮廓劈成两半。**结论：手工设计的曲线不要试图用参数方程反推**，
  直接要矢量路径（`<path d="...">`），转换一次即可，成本是几分钟而不是几小时。

若要再改这个图标，先确认新方案在 **22pt**、浅色与深色菜单栏下都成立，再动手。

另一条教训：本项目自制的参考图解析工具曾把**透明背景误判为墨迹**（RGBA 图里透明像素 RGB 全 0，
按亮度判据必然判成"黑"），导致"扫描位图反推几何"的尝试全部建立在假数据上。
若要做同类分析，先用纯 alpha 判据，并用已知图形校准扫描函数——否则会在假数据上反复调参。

改图形的工作流：改 `assets/download.svg` → 按上面的转换规则更新 `interlockingLoopsPath()`
（y 翻转为 `240 - y`）→ `PDF2ZH_REGEN_ICONS=1 ./build.sh` → 检查 22pt 与深色菜单栏下的效果。

### 7.4 状态栏菜单

| 菜单项 | 行为 |
|---|---|
| `PDF2ZH Web：<状态>` | 禁用状态行，实时反映 WebUI 状态机 |
| `Zotero 服务：<状态>` | 禁用状态行；未安装时提示点击查看获取方式 |
| `翻译中：<N>%（M 个任务）` | 仅在有翻译任务时显示；完成后短暂显示"翻译完成" |
| 在浏览器中打开 ⌘O | 仅 WebUI `running` 可用 |
| 复制服务地址 | 复制 WebUI 地址（`http://127.0.0.1:7860/`） |
| 复制 Zotero 插件地址 | 复制 `http://127.0.0.1:8890`（不带路径，插件要的就是 host:port） |
| 打开输出文件夹 | 不存在则创建后再打开 |
| 打开 WebUI 日志 / 打开 Zotero 服务日志 | 各自无日志时提示 |
| 重新检查 pdf2zh_next | 重新探测路径；未装则弹安装引导 |
| 重启 WebUI ⌘R | stop → 等 0.4s → start（`waitForPortFree`） |
| 重启 Zotero 服务 | 同上；未安装时弹获取方式说明 |
| `pdf2zh_next：<版本>` | 点击显示两个服务的运行环境详情（FR-14） |
| `检查更新` / `有可用更新：<名称 版本>` | 无更新时作手动检查；已知有更新时列出并弹出升级指引（FR-19） |
| 退出并停止全部服务 ⌘Q | `NSApp.terminate` → 两个服务都走清理路径 |

### 7.5 启动序列

1. 取得单实例锁（flock）；失败则提示已有实例并退出。
2. 后台异步执行 `pdf2zh_next --version` 取版本（也充当可执行性检查）。
3. 首次启动时写配置模板。
4. `pdf2zhPath` 为空 → 状态 `missing` + 安装引导；Zotero 服务仍会尝试启动。
5. 创建 `workingDirectory` / `stateDirectory` / `outputDirectory`。
6. 端口已被占用 → `problem("端口 N 已被占用")` + 弹窗，不重复启动。
7. 准备日志文件（轮转 + 权限 0600），记录起始偏移量。
8. `posix_spawn` supervisor，进入 `starting`，启动 0.5s 轮询。
9. 若探测到 `server.py` 且 `zoteroAutoStart` 为真，对 Zotero 服务重复 5–8 步；两个服务各自
   独立判断端口占用与超时，一个失败不影响另一个。轮询在两者都不再 `starting` 时自动停止。

### 7.6 supervisor 脚本模板

两个服务共用同一份模板（`ManagedService.supervisorScript()`），只有 `<可执行文件>` 与参数不同：
WebUI 传 `--gui --server-port N`；Zotero 服务传 `-c "printf 'y\nn\n' | <venv>/bin/python <server.py> --port 8890"`
（理由见 §4.2.1 的交互提示坑）。


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
| `pdf2zh_next --version` 失败 | 空闲态下更新菜单；运行态下不覆盖端口这一更强证据 |
| 两个服务之一启动失败 | 只影响该服务的状态行；另一个照常运行（`ManagedService` 彼此独立） |
| Zotero 服务卡在交互提示 | 已用 `printf 'y\nn\n'` 喂答案；见 §4.2.1 |

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
- [x] FR-18：翻译中图标按总进度变绿，完成后回到常态；多任务取平均
- [x] FR-19：自动检查两个上游的新版本并提醒，只检查不升级
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
- 图标为本项目原创（`scripts/make-icons.swift` 渲染的 ∞ 标识），不含上游美术资源。
- 本项目代码以 [MIT](LICENSE) 许可发布。
