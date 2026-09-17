# PDF2ZH Web（macOS 菜单栏应用）

[English](README.en.md) | 中文

一个只有状态栏图标、不占程序坞的轻量启动器：双击即把
[PDFMathTranslate-next](https://github.com/PDFMathTranslate-next/PDFMathTranslate-next)（`pdf2zh_next`）
的 WebUI 跑在后台，省掉每次手敲 `pdf2zh_next --gui`。

<img src="assets/icon-preview.png" width="112" alt="PDF2ZH Web 图标">

概念与工程结构参考 [DSH-desktop-server](https://github.com/JshGao/DSH-desktop-server)。实现规格见
`VIBE_CODING.md`，源码是单文件 `main.swift`。

**环境要求**

- macOS 11+（已在 macOS 26.7 / Apple Silicon 上验证）
- 构建：`swiftc`（Xcode，或 `xcode-select --install`）
- 运行：本机已安装 `pdf2zh_next`（已在 2.9.0 上验证）

> 本 App 只是启动器，**不包含也不会自动安装** `pdf2zh_next`。没装的话状态行会写明，并弹窗给出安装命令。
> 上游官方推荐的安装方式（先装 [uv](https://docs.astral.sh/uv/)）：
>
> ```bash
> uv tool install --python 3.12 pdf2zh-next   # 官方推荐
> pipx install pdf2zh-next                    # 或者 pipx
> ```

---

## 从源码构建

```bash
./build.sh                        # 生成 build/PDF2ZH Web.app
open "build/PDF2ZH Web.app"       # 启动
./scripts/package.sh 1.0.0        # 可选：打包 .dmg / .zip 到 build/dist/
```

其他开关：

```bash
PDF2ZH_VERSION=1.2.3 ./build.sh   # 指定版本号（默认 1.0.0）
PDF2ZH_REGEN_ICONS=1 ./build.sh   # 改了 scripts/make-icons.swift 后重新渲染图标
```

构建只需要 `swiftc`，不需要 Xcode 工程；模块缓存固定写在 `build/.swift-module-cache`，所以构建是自包含的，
沙箱和 CI 里都能跑。图标产物已提交在 `assets/`，是构建时的真源，正常构建不会再渲染一次。

也可以直接下载 Releases 里现成的产物：`PDF2ZH Web-<版本>.dmg`（内含 App 和指向 `/Applications` 的快捷方式）
或 `PDF2ZH Web-<版本>.zip`。推一个 `v*` 标签，CI 会在 macOS runner 上构建、验收并打包发布。

启动后右上角状态栏出现一个**加粗的 ∞**：这是一张黑字 + 透明底的模板图，
浅色菜单栏显示为黑色，深色菜单栏自动变白。程序坞和 Cmd-Tab 里都不会出现它（`LSUIElement=true`）。
Finder 里看到的 App 图标是圆角蓝色渐变底板 + 居中的白色 ∞。

### 菜单

| 菜单项 | 说明 |
|---|---|
| `PDF2ZH Web：运行中（端口 7860）` | 状态行（禁用）：启动中…（端口 N）/ 运行中（端口 N）/ 已停止 / 异常原因 / 未找到 pdf2zh_next |
| 在浏览器中打开 ⌘O | 打开 `http://127.0.0.1:<端口>/`，仅"运行中"可用 |
| 复制服务地址 | 把同一个地址写入剪贴板，仅"运行中"可用 |
| 打开输出文件夹 | 打开 `outputDirectory`，不存在则先创建再打开 |
| 打开日志 | 打开 `~/Library/Logs/pdf2zh-web.log`，还没有日志时给提示 |
| 重新检查 pdf2zh_next | 重新探测可执行文件；没装就弹安装引导 |
| 重启 PDF2ZH Web ⌘R | 停掉当前服务再重新拉起（改完 `config.json` 用它生效） |
| `pdf2zh_next：2.9.0` | 版本行；点击查看运行环境（版本、可执行文件、工作目录、端口、日志、配置路径） |
| 退出并停止 PDF2ZH Web ⌘Q | 退出 App，同时终止服务及其全部子进程 |

默认地址：<http://127.0.0.1:7860/>

> **没有 token，但服务默认监听 `0.0.0.0`，同局域网可访问。** 这一点与参考项目 DSH Web 正好相反：
> DSH 有进程级 token 保护，而 pdf2zh_next 的 Gradio 界面默认既没有 token 也没有认证，所以裸地址
> `http://127.0.0.1:7860/` 直接就能用。也正因如此，上游默认绑定 `0.0.0.0`——**同一局域网内的其他设备
> 也能打开这个界面、提交翻译任务**。介意的话二选一：
>
> - 用 macOS 防火墙限制该进程的入站连接（系统设置 → 网络 → 防火墙）；
> - 或修改上游配置文件 `~/.config/pdf2zh/config.v3.toml` 里的绑定地址（本 App 不覆盖 `server_name`，
>   以免与上游行为打架）。

### 首次打开被 Gatekeeper 拦下

> 本 App 是 ad-hoc 签名、未做 Apple 公证，首次双击会提示"Apple 无法检查其是否包含恶意软件"。任选一种：
>
> - 在 Finder 里**右键（或 Control-点击）图标 → 打开 → 再点"打开"**，之后即可正常双击；
> - 或终端执行 `xattr -dr com.apple.quarantine "/Applications/PDF2ZH Web.app"`。
>
> 想彻底消除这个提示需要 Apple Developer ID 签名 + 公证，本项目不做。

### 想常驻使用

1. 把 `PDF2ZH Web.app` 拖到 `/Applications`；
2. 系统设置 → 通用 → 登录项，把它加入"打开时启动"。

---

## 配置

配置文件（首次启动自动生成带说明的模板，权限 0600）：

```text
~/Library/Application Support/PDF2ZHWeb/config.json
```

优先级：**环境变量 > config.json > 默认值**。

| 键 | 环境变量 | 默认值 | 说明 |
|---|---|---|---|
| `pdf2zhPath` | `PDF2ZH_PATH` | 自动探测 | `pdf2zh_next` 可执行文件绝对路径，探测不到则为空并进入"未找到 pdf2zh_next" |
| `workingDirectory` | `PDF2ZH_WORKDIR` | `~/PDF2ZH Workspace` | 服务工作目录，不存在会自动创建 |
| `webPort` | `PDF2ZH_WEB_PORT` | `7860` | 传给 `pdf2zh_next --server-port` |
| `outputDirectory` | `PDF2ZH_OUTPUT_DIR` | 同 `workingDirectory` | "打开输出文件夹"指向的目录 |
| `extraArguments` | — | `[]` | 追加到 `pdf2zh_next` 之后的参数，例如 `["--debug"]` |
| `environment` | — | `{}` | 追加给服务的环境变量（PATH、API key 等） |
| `envFile` | `PDF2ZH_ENV_FILE` | `~/Library/Application Support/PDF2ZHWeb/env` | `KEY=VALUE` 行，`#` 注释，不存在则忽略 |
| `logPath` | `PDF2ZH_LOG_PATH` | `~/Library/Logs/pdf2zh-web.log` | 追加写入，权限固定 0600 |
| `logMaxBytes` | — | `5242880` | 超过则在下次启动时轮转为 `.log.1` |
| `startupTimeoutSeconds` | — | `60` | 等端口就绪的超时秒数 |
| `autoOpenBrowser` | `PDF2ZH_AUTO_OPEN` | `false` | true 时端口就绪后由 App 打开浏览器 |

示例：

```json
{
  "webPort": 7860,
  "workingDirectory": "/Users/me/PDF2ZH Workspace",
  "environment": { "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" },
  "autoOpenBrowser": true
}
```

改完在菜单点"重启 PDF2ZH Web"即可生效，不用重新构建。

**关于环境变量**：从 Finder 双击启动的 App 不读 `~/.zshrc`，所以写在那里的 `PATH`、API key 等不会自动生效，
请写进 `config.json` 的 `environment` 或 `envFile`。App 会自己补一条 PATH（可执行文件所在目录 +
`~/.local/bin` + `/opt/homebrew/bin` + `/usr/local/bin` + 系统目录 + 继承的 PATH，去重），
因为 `pdf2zh_next` 会调用外部程序。

`autoOpenBrowser` 的判定：`PDF2ZH_AUTO_OPEN` 取值为 `1` / `true` / `yes` / `on`（不区分大小写）时视为 true，
其他任何值都视为 false。

---

## 关于翻译引擎

本 App **不接管**翻译引擎配置。引擎选型、API key、源/目标语言都由 pdf2zh_next 自己管理：

- `~/.config/pdf2zh/config.v3.toml`（本机已配好 DeepSeek）；
- WebUI 界面里也可以改。

App 只做一件事：启动时加 `--gui --server-port <端口>` 覆盖端口。**启动不会回写你的 pdf2zh 配置文件**——
实测以 `--server-port 7861` 启动后，`config.v3.toml` 的内容和 mtime 都没有变化，端口覆盖只在本次运行有效
（回写只发生在你在 GUI 里点保存时）。

---

## 工作原理（简述）

- 用 `posix_spawn` 的 `POSIX_SPAWN_SETPGROUP` 让 supervisor 成为新进程组组长，把
  `zsh → pdf2zh_next → python` 整棵树放进同一个进程组，退出时用 `killpg` 一次性清理；
  SIGTERM 4 秒不退就升级 SIGKILL。
- 就绪信号以 **TCP 端口探测**为准（`connect` 到 `127.0.0.1:<端口>`）：pdf2zh_next 的 Gradio 界面没有
  "带 token 的就绪 URL"可解析，而 Gradio 只在应用构建完成、真正开始服务之后才 bind。
  日志里的 Gradio banner（`* Running on local URL:`）也会尽力解析，但只是补充——
  stdout 不是 tty 时上游根本不打印它。
- 组内有一个看门狗子 shell：App 崩溃或被 `kill -9` 后，它会在 1 秒内杀掉整个进程组
  （实测 `kill -9` 后 1 秒端口即释放）。
- 注销 / 关机 / `kill -TERM` 会转到正常退出路径，做同样的清理。
- 子进程环境里设 `BROWSER=/usr/bin/true`，把 `pdf2zh_next --gui` 自带的 `webbrowser.open()` 变成空操作，
  免得每次重启都弹浏览器抢焦点；想自动打开就设 `autoOpenBrowser`。
- 同时只允许一个 App 实例（`flock` 锁文件 `~/Library/Application Support/PDF2ZHWeb/pdf2zh-web.lock`）；
  启动前探测端口，被占用时提示而不重复启动。

源码里有更详细的注释，实现规格见 `VIBE_CODING.md`。

---

## 排错

**未找到 pdf2zh_next**：状态行显示"未找到 pdf2zh_next"，App 会弹窗给出安装命令（可一键复制
`uv tool install --python 3.12 pdf2zh-next`）。装好后点菜单里的"重新检查 pdf2zh_next"。如果它装在别处，
直接在 `config.json` 里写 `pdf2zhPath` 绝对路径。注意：探测到的路径与当前不同时，菜单会提示你退出 App
再重新打开才能用上新安装。

**端口被占用**：菜单显示"端口 7860 已被占用"并弹窗，App 不会重复启动。

```bash
lsof -nP -iTCP:7860 -sTCP:LISTEN     # 看占用者
kill -TERM <pid>                     # 确认是残留进程后再杀，必要时 kill -9 <pid>
```

如果那就是你自己在终端里跑的 `pdf2zh_next`，直接用那个服务就好，不需要本 App。

**一直卡在"启动中…"**：首次运行要下载 babeldoc 资产（模型/字体），可能几十秒到几分钟；超过
`startupTimeoutSeconds`（默认 60）会弹窗提示。看日志：

```bash
tail -50 ~/Library/Logs/pdf2zh-web.log
```

**状态行显示异常**：日志尾部会给出原因摘要，优先摘出含 `EADDRINUSE`、`error`、`Traceback`、
`Address already in use` 的最后一行。

**日志安全**：日志里含翻译引擎设置，权限固定 0600，不要外发。怀疑泄露就
`rm ~/Library/Logs/pdf2zh-web.log` 后重启 App。

---

## 项目结构

```text
pdf2zh-server/
├── main.swift                  # 菜单栏 App 全部源码（配置、状态机、posix_spawn、就绪探测、清理）
├── build.sh                    # 构建 .app：编译 + 图标 + Info.plist + ad-hoc 签名
├── assets/
│   ├── AppIcon.icns            # 提交的 App 图标产物（构建时的真源）
│   ├── pdf2zh-status.png       # 提交的状态栏图标产物（加粗 ∞，黑字 + 透明底，可作模板图）
│   └── icon-preview.png        # README 预览图
├── scripts/
│   ├── make-icons.swift        # CoreGraphics/CoreText 渲染图标（原创 ∞ 标识）
│   ├── package.sh              # 打包 .dmg / .zip
│   └── verify.sh               # 验收：静态检查 + 运行期检查 + 退出清理检查
├── .github/workflows/build.yml # CI：构建 + 验收；打标签时发布 Release
├── VIBE_CODING.md              # 实现规格
├── README.md                   # 中文 README（本文件）
├── README.en.md                # 英文 README
├── LICENSE                     # MIT
└── .gitignore
```

`build/` 是构建产物目录，已在 `.gitignore` 中忽略。

---

## 已知限制

- 与上游的耦合点只有三处：`--gui` 与 `--server-port` 两个 flag、可执行文件名 `pdf2zh_next`、
  以及"就绪靠端口"这个判定方式。上游**改名**才需要改 `main.swift` 重新构建；
  **上游发新版本不需要重新构建**（App 只调用 CLI，不加任何版本约束）。
- 状态栏图标受菜单栏高度限制：`NSStatusItem.squareLength` 是个正方形，约 22pt 已接近上限，
  再调大不会有变化。
- 服务默认监听 `0.0.0.0`（上游行为），WebUI 无认证，同局域网可访问，注意安全（见上文）。
- 本 App 是**非官方**启动器，与 PDFMathTranslate-next 项目无隶属关系。
- 不自动安装依赖，也不做公证签名。
- 同一时间只应跑一个实例：多个 `pdf2zh_next` 实例共享 `~/.config/pdf2zh`，还会争抢端口。

---

## 来源与许可

- 本项目是 [PDFMathTranslate-next](https://github.com/PDFMathTranslate-next/PDFMathTranslate-next) 的
  **非官方**启动器，不修改上游源码，只调用其 CLI（`pdf2zh_next --gui`）。
- 概念与工程结构参考 [DSH-desktop-server](https://github.com/JshGao/DSH-desktop-server)（MIT）。
- 图标为本项目原创：`scripts/make-icons.swift` 用 CoreGraphics/CoreText 直接渲染的 ∞ 标识
  （描边无限符号 / 圆角渐变底板），**不含**上游 PDFMathTranslate 的任何美术资源。
- 本项目的代码以 [MIT](LICENSE) 许可发布。

---

## 重新构建 / 验收 / 卸载

```bash
./build.sh              # 重新构建（改了 main.swift 之后）
./scripts/verify.sh     # 验收
rm -rf "build/PDF2ZH Web.app"                        # 卸载 App
rm -rf ~/Library/Application\ Support/PDF2ZHWeb      # 卸载配置与状态
rm -f  ~/Library/Logs/pdf2zh-web.log                 # 卸载日志
```

`./scripts/verify.sh` 会检查 bundle 结构、`LSUIElement`、签名、状态栏图标 alpha 通道、运行期端口监听、
WebUI 是否返回 HTTP 200、日志权限 0600、配置模板是否生成，以及退出后有没有残留进程和端口占用
（脚本会自己启动 App，并在结束时把它停掉）。
