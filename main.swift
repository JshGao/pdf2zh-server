// main.swift
// PDF2ZH Web — a macOS menu bar wrapper that runs `pdf2zh_next --gui` in the background.
//
// This file is the authoritative implementation of VIBE_CODING.md (v1).
//
// Design notes (see VIBE_CODING.md §5 for the evidence behind each one):
//  * The wrapper starts the pdf2zh_next executable that is already installed on this
//    machine (uv tool / pipx / venv / PATH). It never installs anything itself: a
//    Finder-launched app has no shell and no network assumptions, and a silent
//    `uvx` download would turn "start the service" into a multi-minute mystery.
//  * pdf2zh_next's Gradio UI has no token and no auth by default, so a bare
//    http://127.0.0.1:<port>/ is directly usable. Readiness is therefore detected by
//    probing the port, with the Gradio banner parsed from the log when available.
//  * `pdf2zh_next --gui` calls webbrowser.open() on launch, which would steal focus
//    every restart. Gradio routes that through Python's webbrowser module, so
//    BROWSER=/usr/bin/true turns the call into a no-op.
//  * zsh cannot enable job control without a tty (`set -m` fails, `zsh -m` hangs),
//    so the process group is created by posix_spawn(POSIX_SPAWN_SETPGROUP) and the
//    whole tree is reaped with killpg().
//  * applicationWillTerminate does not run on crash/force-quit, so an in-group
//    watchdog shell kills the group once this process disappears.

import Cocoa
import Darwin

// MARK: - C string helpers

private func cStrings(_ values: [String]) -> [UnsafeMutablePointer<CChar>?] {
    var result = values.map { strdup($0) }
    result.append(nil)
    return result
}

private func freeCStrings(_ values: [UnsafeMutablePointer<CChar>?]) {
    for value in values {
        if let value { free(value) }
    }
}

/// Single-quote a value so it is safe to interpolate into a shell script.
private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private struct SpawnFailure: LocalizedError {
    let code: Int32
    var errorDescription: String? {
        "posix_spawn 失败（errno \(code)：\(String(cString: strerror(code))))"
    }
}

// MARK: - Configuration

struct AppConfig {
    /// Absolute path to the pdf2zh_next executable, or "" when not installed.
    var pdf2zhPath: String
    var workingDirectory: String
    var webPort: Int
    var extraArguments: [String]
    var environment: [String: String]
    var envFile: String
    var logPath: String
    var logMaxBytes: UInt64
    var stateDirectory: String
    /// Where translated PDFs land by default (pdf2zh_next writes `*-mono.pdf` next
    /// to the input file, so this is only the folder we hand to the user).
    var outputDirectory: String
    var readTimeoutSeconds: TimeInterval
    var autoOpenBrowser: Bool

    static let defaultPort = 7860
    static let defaultLogMaxBytes: UInt64 = 5 * 1024 * 1024
    static let supportDirectoryName = "PDF2ZHWeb"

    static func load() -> AppConfig {
        let home = NSHomeDirectory()
        let supportDirectory = home + "/Library/Application Support/" + supportDirectoryName
        let processEnvironment = ProcessInfo.processInfo.environment

        var json: [String: Any] = [:]
        let configPath = supportDirectory + "/config.json"
        if let data = FileManager.default.contents(atPath: configPath),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = object
        }

        func stringValue(_ key: String, env: String?, fallback: String) -> String {
            if let env, let value = processEnvironment[env], !value.isEmpty { return value }
            if let value = json[key] as? String, !value.isEmpty { return value }
            return fallback
        }

        func intValue(_ key: String, env: String?, fallback: Int) -> Int {
            if let env, let raw = processEnvironment[env], let value = Int(raw) { return value }
            if let value = json[key] as? Int { return value }
            if let raw = json[key] as? String, let value = Int(raw) { return value }
            return fallback
        }

        func boolValue(_ key: String, env: String?, fallback: Bool) -> Bool {
            if let env, let raw = processEnvironment[env] {
                return ["1", "true", "yes", "on"].contains(raw.lowercased())
            }
            if let value = json[key] as? Bool { return value }
            return fallback
        }

        var extraArguments: [String] = []
        if let values = json["extraArguments"] as? [String] {
            extraArguments = values
        }

        var environment: [String: String] = [:]
        if let values = json["environment"] as? [String: String] {
            environment = values
        }

        let workingDirectory = stringValue(
            "workingDirectory", env: "PDF2ZH_WORKDIR", fallback: home + "/PDF2ZH Workspace"
        )

        return AppConfig(
            pdf2zhPath: stringValue(
                "pdf2zhPath", env: "PDF2ZH_PATH", fallback: resolvePDF2ZHPath()
            ),
            workingDirectory: workingDirectory,
            webPort: intValue("webPort", env: "PDF2ZH_WEB_PORT", fallback: defaultPort),
            extraArguments: extraArguments,
            environment: environment,
            envFile: stringValue(
                "envFile", env: "PDF2ZH_ENV_FILE", fallback: supportDirectory + "/env"
            ),
            logPath: stringValue(
                "logPath", env: "PDF2ZH_LOG_PATH", fallback: home + "/Library/Logs/pdf2zh-web.log"
            ),
            logMaxBytes: UInt64(intValue("logMaxBytes", env: nil, fallback: Int(defaultLogMaxBytes))),
            stateDirectory: supportDirectory,
            outputDirectory: stringValue(
                "outputDirectory", env: "PDF2ZH_OUTPUT_DIR", fallback: workingDirectory
            ),
            readTimeoutSeconds: TimeInterval(
                intValue("startupTimeoutSeconds", env: nil, fallback: 60)
            ),
            autoOpenBrowser: boolValue("autoOpenBrowser", env: "PDF2ZH_AUTO_OPEN", fallback: false)
        )
    }

    /// Probe the places a `pdf2zh_next` install actually lands, newest-first where
    /// the layout allows ordering. Mirrors what the official docs tell users to run
    /// (`uv tool install --python 3.12 pdf2zh-next`) plus the other common installs.
    static func resolvePDF2ZHPath() -> String {
        let home = NSHomeDirectory()
        var candidates = [
            // uv tool install (the officially documented install)
            home + "/.local/share/uv/tools/pdf2zh-next/bin/pdf2zh_next",
            // uv tool with a custom UV_TOOL_DIR is handled by the PATH probe below
            home + "/.local/bin/pdf2zh_next",
            // pipx
            home + "/.local/pipx/venvs/pdf2zh-next/bin/pdf2zh_next",
            // Homebrew / system-wide pip
            "/opt/homebrew/bin/pdf2zh_next",
            "/usr/local/bin/pdf2zh_next",
            // Common hand-made venvs
            home + "/.venv/bin/pdf2zh_next",
            home + "/venv/bin/pdf2zh_next"
        ]

        // pyenv-managed interpreters, newest version first.
        let pyenvRoot = home + "/.pyenv/versions"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: pyenvRoot) {
            for version in versions.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }).reversed() {
                candidates.append(pyenvRoot + "/" + version + "/bin/pdf2zh_next")
            }
        }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        // Last resort: whatever PATH the app inherited (Finder launch has a minimal
        // PATH, but a terminal launch carries the user's shell PATH).
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for directory in pathDirectories where !directory.isEmpty {
            let candidate = directory + "/pdf2zh_next"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }

        return ""
    }

    /// Parse an optional `KEY=VALUE` file. Blank lines and `#` comments are ignored;
    /// a leading `export ` and surrounding quotes are tolerated.
    static func parseEnvFile(_ path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private enum State {
        case starting
        case running(URL)
        case stopped
        case problem(String)
        case missingDependency
    }

    private let config = AppConfig.load()
    private var state: State = .stopped

    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var openItem: NSMenuItem?
    private var copyItem: NSMenuItem?
    private var versionItem: NSMenuItem?

    /// Lock file descriptor held for the lifetime of the process (flock).
    private var lockFileDescriptor: Int32 = -1
    /// pid of the supervisor shell, which is also the process group id.
    private var supervisorPid: pid_t = 0
    private var supervisorReaped = false
    private var stoppingIntentionally = false

    private var logScanOffset: UInt64 = 0
    private var logScanBuffer = ""
    private var pollTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var startAttemptDate: Date?
    private var probedURL: URL?
    private var versionText: String?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installSignalHandlers()
        buildMenu()
        updateMenu()

        guard acquireSingleInstanceLock() else {
            presentAlert(
                title: "PDF2ZH Web 已在运行",
                message: "另一个 PDF2ZH Web 菜单栏实例已经启动，请使用状态栏中的图标。",
                style: .informational
            )
            NSApp.terminate(nil)
            return
        }

        queryVersion()

        writeConfigTemplateIfNeeded()

        guard !config.pdf2zhPath.isEmpty else {
            state = .missingDependency
            updateMenu()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.presentInstallGuide()
            }
            return
        }

        startServer(waitForPortFree: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopServer()
        releaseSingleInstanceLock()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Logout, shutdown and `kill` deliver SIGTERM rather than an Apple Event.
    /// Without this, those paths would skip applicationWillTerminate and leave the
    /// service running (SIGKILL and crashes are still covered by the watchdog).
    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Menu

    private func makeItem(_ title: String, action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if action != nil { item.target = self }
        return item
    }

    private func buildMenu() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            // The bundled template image (black glyph on transparent) is the primary
            // icon: macOS tints it automatically for light/dark menu bars, and it is the
            // same 译 mark the app uses in the Dock. SF Symbols are the fallback for a
            // bundle that was built without the icon artefacts.
            var image: NSImage?
            if let path = Bundle.main.path(forResource: "pdf2zh-status", ofType: "png"),
               let bundled = NSImage(contentsOfFile: path) {
                bundled.size = NSSize(width: 20, height: 20)
                bundled.isTemplate = true
                image = bundled
            } else {
                for name in ["translate", "character.book.closed", "doc.text.magnifyingglass", "doc.text"] {
                    if let candidate = NSImage(systemSymbolName: name, accessibilityDescription: "PDF2ZH Web") {
                        candidate.isTemplate = true
                        image = candidate
                        break
                    }
                }
            }
            if let image {
                button.image = image
            } else {
                button.title = "译"
            }
            button.toolTip = "PDF2ZH Web"
        }

        let menu = NSMenu()
        let status = makeItem("PDF2ZH Web：已停止", action: nil)
        status.isEnabled = false
        statusMenuItem = status
        menu.addItem(status)
        menu.addItem(.separator())

        let open = makeItem("在浏览器中打开", action: #selector(openInBrowser), key: "o")
        openItem = open
        menu.addItem(open)

        let copy = makeItem("复制服务地址", action: #selector(copyServiceURL))
        copyItem = copy
        menu.addItem(copy)

        menu.addItem(makeItem("打开输出文件夹", action: #selector(openOutputDirectory)))
        menu.addItem(makeItem("打开日志", action: #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(makeItem("重新检查 pdf2zh_next", action: #selector(recheckDependency)))
        menu.addItem(makeItem("重启 PDF2ZH Web", action: #selector(restartServer), key: "r"))
        menu.addItem(.separator())

        let version = makeItem("pdf2zh_next：检测中…", action: #selector(showEnvironment))
        versionItem = version
        menu.addItem(version)

        menu.addItem(.separator())
        menu.addItem(makeItem("退出并停止 PDF2ZH Web", action: #selector(quitApp), key: "q"))

        statusItem.menu = menu
    }

    private func updateMenu() {
        guard let statusMenuItem, let openItem, let copyItem else { return }

        let title: String
        switch state {
        case .starting:
            title = "PDF2ZH Web：启动中…（端口 \(config.webPort)）"
        case .running:
            title = "PDF2ZH Web：运行中（端口 \(config.webPort)）"
        case .stopped:
            title = "PDF2ZH Web：已停止"
        case .problem(let reason):
            title = "PDF2ZH Web：\(reason)"
        case .missingDependency:
            title = "PDF2ZH Web：未找到 pdf2zh_next"
        }
        statusMenuItem.title = title
        statusItem?.button?.toolTip = title

        var usable = false
        if case .running = state { usable = true }
        openItem.isEnabled = usable
        copyItem.isEnabled = usable
    }

    private func updateVersionItem() {
        guard let versionItem else { return }
        if config.pdf2zhPath.isEmpty {
            versionItem.title = "pdf2zh_next：未安装（点击查看安装方法）"
        } else if let versionText {
            versionItem.title = "pdf2zh_next：\(versionText)"
        } else {
            versionItem.title = "pdf2zh_next：已就绪（点击查看详情）"
        }
    }

    // MARK: Menu actions

    @objc private func openInBrowser() {
        guard case .running(let url) = state else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyServiceURL() {
        guard case .running(let url) = state else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    @objc private func openOutputDirectory() {
        let path = config.outputDirectory
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: path) else {
            presentAlert(
                title: "无法打开输出文件夹",
                message: "目录不存在且无法创建：\n\(path)",
                style: .warning
            )
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func openLog() {
        if FileManager.default.fileExists(atPath: config.logPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: config.logPath))
        } else {
            presentAlert(title: "暂无日志", message: config.logPath + " 尚未创建。", style: .informational)
        }
    }

    @objc private func showEnvironment() {
        if case .missingDependency = state {
            presentInstallGuide()
            return
        }
        let version = versionText ?? "未知（可点“重新检查 pdf2zh_next”）"
        presentAlert(
            title: "运行环境",
            message: """
            pdf2zh_next 版本：\(version)

            可执行文件：
            \(config.pdf2zhPath.isEmpty ? "（未找到）" : config.pdf2zhPath)

            工作目录：
            \(config.workingDirectory)

            服务端口：\(config.webPort)

            日志：
            \(config.logPath)

            修改配置文件后，用菜单里的“重启 PDF2ZH Web”即可生效：
            \(config.stateDirectory)/config.json
            """,
            style: .informational
        )
    }

    @objc private func recheckDependency() {
        let previous = config.pdf2zhPath
        let resolved = AppConfig.resolvePDF2ZHPath()
        guard !resolved.isEmpty else {
            state = .missingDependency
            updateMenu()
            presentInstallGuide()
            return
        }
        if resolved == previous {
            presentAlert(
                title: "已找到 pdf2zh_next",
                message: resolved,
                style: .informational
            )
            return
        }
        // The path only changes when pdf2zh_next was (re)installed while we ran, which
        // needs the app itself to restart to pick up (AppConfig is immutable by design).
        presentAlert(
            title: "发现新的 pdf2zh_next",
            message: "路径已变更：\n\(resolved)\n\n请退出本 App 再重新打开，以使用这个新安装。",
            style: .informational
        )
    }

    @objc private func restartServer() {
        stopServer()
        state = .starting
        updateMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.startServer(waitForPortFree: true)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: Dependency

    /// Drop a self-documenting config template on first launch. Without it the
    /// "restart to apply your config.json" advice in the menus points at a file the
    /// user has never seen. JSON has no comments, so the hints ride along as extra
    /// keys that AppConfig ignores.
    private func writeConfigTemplateIfNeeded() {
        let manager = FileManager.default
        try? manager.createDirectory(atPath: config.stateDirectory, withIntermediateDirectories: true)
        let path = config.stateDirectory + "/config.json"
        guard !manager.fileExists(atPath: path) else { return }

        let template: [String: Any] = [
            "_readme": "可选配置。优先级：环境变量 > 本文件 > 默认值。改完在菜单里点“重启 PDF2ZH Web”生效。",
            "_keys": [
                "pdf2zhPath": "pdf2zh_next 可执行文件的绝对路径，留空则自动探测",
                "workingDirectory": "服务的工作目录，不存在会自动创建",
                "webPort": "WebUI 端口，传给 pdf2zh_next --server-port",
                "outputDirectory": "菜单里“打开输出文件夹”指向的目录",
                "extraArguments": "追加到 pdf2zh_next 之后的参数，例如 [\"--debug\"]",
                "environment": "追加给服务的环境变量",
                "envFile": "KEY=VALUE 文件路径，不存在则忽略",
                "logPath": "日志路径，追加写入，权限 0600",
                "logMaxBytes": "日志超过该字节数后轮转为 .log.1",
                "startupTimeoutSeconds": "等端口就绪的超时秒数",
                "autoOpenBrowser": "true 时服务就绪后自动打开浏览器（默认 false）"
            ],
            "pdf2zhPath": config.pdf2zhPath,
            "workingDirectory": config.workingDirectory,
            "webPort": config.webPort,
            "outputDirectory": config.outputDirectory,
            "extraArguments": config.extraArguments,
            "environment": config.environment,
            "envFile": config.envFile,
            "logPath": config.logPath,
            "logMaxBytes": Int(config.logMaxBytes),
            "startupTimeoutSeconds": Int(config.readTimeoutSeconds),
            "autoOpenBrowser": config.autoOpenBrowser
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: template,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        manager.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    private func presentInstallGuide() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "未找到 pdf2zh_next"
        alert.informativeText = """
        本 App 只是启动器，本身不包含 pdf2zh_next。请先安装它，任选一种方式：

        • uv（官方推荐）
          uv tool install --python 3.12 pdf2zh-next

        • pipx
          pipx install pdf2zh-next

        安装完成后点菜单里的“重新检查 pdf2zh_next”，或重新打开本 App。

        如果它装在别处，也可以直接指定路径：
        \(config.stateDirectory)/config.json
        { "pdf2zhPath": "/绝对路径/pdf2zh_next" }
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "复制 uv 安装命令")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString("uv tool install --python 3.12 pdf2zh-next", forType: .string)
        }
    }

    /// Ask the installed executable for its version, off the main thread. Also serves
    /// as a liveness check: a path that exists but cannot run is reported as a problem.
    private func queryVersion() {
        guard !config.pdf2zhPath.isEmpty else {
            updateVersionItem()
            return
        }
        let path = config.pdf2zhPath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = Self.extendedPath(adding: path)
            process.environment = environment

            var text: String?
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(decoding: data, as: UTF8.self)
                text = Self.extractVersion(from: output)
            } catch {
                text = nil
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.versionText = text
                self.updateVersionItem()
                // A failed query is only surfaced while we are idle. If the server is
                // starting or already running, the live port is better evidence than a
                // one-off subprocess that may have tripped over a minimal PATH.
                let idle: Bool
                switch self.state {
                case .stopped, .missingDependency: idle = true
                default: idle = false
                }
                if text == nil, idle, !self.config.pdf2zhPath.isEmpty {
                    self.state = .problem("pdf2zh_next 无法执行")
                    self.updateMenu()
                }
            }
        }
    }

    /// `pdf2zh_next --version` prints a rich banner whose last line is
    /// `pdf2zh-next version: 2.9.0`; be tolerant and accept any `x.y.z`.
    static func extractVersion(from output: String) -> String? {
        if let range = output.range(of: "version:", options: .backwards) {
            let tail = output[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").first.map(String.init) ?? ""
            let trimmed = tail.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .decimalDigits) != nil {
                return trimmed
            }
        }
        let pattern = try? NSRegularExpression(pattern: "\\d+\\.\\d+\\.\\d+(?:[-+][0-9A-Za-z.\\-]+)?")
        let text = output as NSString
        if let match = pattern?.firstMatch(in: output, range: NSRange(location: 0, length: text.length)) {
            return text.substring(with: match.range)
        }
        return nil
    }

    /// Finder-launched apps inherit a minimal PATH; pdf2zh_next shells out to
    /// helper binaries (libreoffice, fonts, ...) so widen it the same way the
    /// child environment does.
    static func extendedPath(adding executablePath: String) -> String {
        let home = NSHomeDirectory()
        var components = [(executablePath as NSString).deletingLastPathComponent]
        components.append(contentsOf: [
            home + "/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ])
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        components.append(contentsOf: inherited.split(separator: ":").map(String.init))
        var seen = Set<String>()
        return components
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    // MARK: Starting

    private func startServer(waitForPortFree: Bool) {
        guard supervisorPid == 0 else { return }
        ensureDirectories()

        if config.pdf2zhPath.isEmpty {
            state = .missingDependency
            updateMenu()
            return
        }

        if waitForPortFree { _ = waitUntilPortFree(seconds: 3) }

        if isPortInUse(config.webPort) {
            state = .problem("端口 \(config.webPort) 已被占用")
            updateMenu()
            presentAlert(
                title: "端口 \(config.webPort) 已被占用",
                message: "另一个进程正在监听 127.0.0.1:\(config.webPort)，PDF2ZH Web 未启动。\n\n"
                    + "可用 `lsof -nP -iTCP:\(config.webPort) -sTCP:LISTEN` 查看占用者；"
                    + "若确认是残留进程，先 `kill -TERM <pid>`，必要时再 `kill -9 <pid>`。\n\n"
                    + "如果那是你自己在终端里跑的 pdf2zh_next，直接用那个就行，无需本 App。",
                style: .warning
            )
            return
        }

        prepareLogFile()
        logScanOffset = fileSize(atPath: config.logPath)
        logScanBuffer = ""
        probedURL = nil
        startAttemptDate = Date()

        do {
            let pid = try spawnSupervisor()
            supervisorPid = pid
            supervisorReaped = false
            state = .starting
            updateMenu()
            startPolling()
        } catch {
            state = .problem("启动失败")
            updateMenu()
            presentAlert(title: "PDF2ZH Web 启动失败", message: error.localizedDescription, style: .warning)
        }
    }

    private func spawnSupervisor() throws -> pid_t {
        var pid: pid_t = 0

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0) // 0 => the child becomes its own group leader

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, config.logPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        let argv = cStrings(["/bin/zsh", "-c", supervisorScript()])
        let envp = cStrings(childEnvironment().map { "\($0.key)=\($0.value)" }.sorted())
        defer {
            freeCStrings(argv)
            freeCStrings(envp)
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }

        let result = posix_spawn(&pid, "/bin/zsh", &actions, &attributes, argv, envp)
        guard result == 0 else { throw SpawnFailure(code: result) }
        return pid
    }

    /// The supervisor shell keeps the group alive, runs the server in the background,
    /// and owns the crash watchdog. It deliberately does NOT use `set -m`: zsh cannot
    /// enable job control without a tty, and the process group already comes from
    /// POSIX_SPAWN_SETPGROUP.
    private func supervisorScript() -> String {
        let workingDirectory = shellQuote(config.workingDirectory)
        let executable = shellQuote(config.pdf2zhPath)
        let pidFile = shellQuote(config.stateDirectory + "/pdf2zh-web.pid")
        let extraArguments = config.extraArguments.map(shellQuote).joined(separator: " ")
        let extraSuffix = extraArguments.isEmpty ? "" : " " + extraArguments
        let wrapperPid = String(getpid())

        return """
        cd \(workingDirectory) || { print -r -- "pdf2zh-web: cannot cd to" \(workingDirectory); exit 1; }

        pgid=$$
        wrapper=\(wrapperPid)

        ( trap '' TERM
          while kill -0 "$wrapper" 2>/dev/null && kill -0 "$pgid" 2>/dev/null; do sleep 1; done
          kill -TERM -"$pgid" 2>/dev/null
          sleep 3
          kill -KILL -"$pgid" 2>/dev/null ) &
        watchdog_pid=$!

        # --server-port is the flattened name of gui_settings.server_port; it wins over
        # ~/.config/pdf2zh/config.v3.toml and is never written back to it.
        \(executable) --gui --server-port \(config.webPort)\(extraSuffix) &
        server_pid=$!
        print -r -- "$pgid $server_pid" > \(pidFile)

        trap 'kill -TERM -"$pgid" 2>/dev/null; kill -TERM "$watchdog_pid" 2>/dev/null; exit 0' TERM INT HUP
        wait "$server_pid"
        rc=$?
        kill -TERM "$watchdog_pid" 2>/dev/null
        exit $rc
        """
    }

    private func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        environment["PATH"] = Self.extendedPath(adding: config.pdf2zhPath)
        environment["HOME"] = NSHomeDirectory()
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        if environment["LC_CTYPE"] == nil { environment["LC_CTYPE"] = "UTF-8" }

        // `pdf2zh_next --gui` calls webbrowser.open() while launching Gradio; point the
        // BROWSER override at /usr/bin/true so the call succeeds as a no-op instead of
        // stealing focus on every restart. Users who want the old behaviour set
        // autoOpenBrowser, which opens the page from here once the port is live.
        environment["BROWSER"] = "/usr/bin/true"

        // A Finder-launched app reads no shell profile, so pdf2zh variables must come
        // from config.json / envFile instead of ~/.zshrc.
        for (key, value) in AppConfig.parseEnvFile(config.envFile) { environment[key] = value }
        for (key, value) in config.environment { environment[key] = value }
        return environment
    }

    // MARK: Stopping

    private func stopServer() {
        stopPolling()
        guard supervisorPid != 0 else { return }

        stoppingIntentionally = true
        let pgid = supervisorPid

        if !supervisorReaped {
            _ = killpg(pgid, SIGTERM)
            if !waitForSupervisorExit(timeout: 4) {
                _ = killpg(pgid, SIGKILL)
                _ = waitForSupervisorExit(timeout: 2)
            }
        }

        var status: Int32 = 0
        while waitpid(pgid, &status, WNOHANG) > 0 {}

        supervisorReaped = true
        supervisorPid = 0
        stoppingIntentionally = false
        startAttemptDate = nil
        probedURL = nil

        if case .problem = state {} else if case .missingDependency = state {} else { state = .stopped }
        updateMenu()
    }

    /// Wait for the supervisor (group leader) itself to exit. We deliberately do not
    /// wait for the whole group here: the TERM-immune watchdog stays in the group for
    /// up to three seconds and would otherwise make every quit take the full grace period.
    private func waitForSupervisorExit(timeout: TimeInterval) -> Bool {
        guard supervisorPid != 0 else { return true }
        if supervisorReaped { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var status: Int32 = 0
            if waitpid(supervisorPid, &status, WNOHANG) == supervisorPid {
                supervisorReaped = true
                return true
            }
            usleep(80_000)
        }
        return false
    }

    // MARK: Readiness

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        reapSupervisorIfNeeded()
        guard case .starting = state else { return }

        scanLogForURL()

        if probedURL == nil, isPortInUse(config.webPort) {
            // A listening socket is the readiness signal we can always trust: Gradio
            // only binds after the app finished building. The banner is nice-to-have.
            probedURL = localURL()
        }

        if let url = probedURL {
            state = .running(url)
            updateMenu()
            stopPolling()
            if config.autoOpenBrowser { NSWorkspace.shared.open(url) }
            return
        }

        if let started = startAttemptDate, Date().timeIntervalSince(started) > config.readTimeoutSeconds {
            state = .problem("启动超时")
            updateMenu()
            stopPolling()
            presentAlert(
                title: "启动超时",
                message: "等待 \(Int(config.readTimeoutSeconds)) 秒后端口 \(config.webPort) 仍未监听。\n\n"
                    + "常见原因：首次运行要下载 babeldoc 资产、代理干扰、pdf2zh_next 报错。\n"
                    + "日志：\(config.logPath)",
                style: .warning
            )
        }
    }

    private func reapSupervisorIfNeeded() {
        guard supervisorPid != 0, !supervisorReaped else { return }

        var status: Int32 = 0
        guard waitpid(supervisorPid, &status, WNOHANG) == supervisorPid else { return }
        supervisorReaped = true

        // Sweep any straggler left in the group; the watchdog finishes the job.
        if killpg(supervisorPid, 0) == 0 { _ = killpg(supervisorPid, SIGTERM) }

        guard !stoppingIntentionally else { return }

        supervisorPid = 0
        supervisorReaped = false
        startAttemptDate = nil
        probedURL = nil
        state = .problem(logTailSummary() ?? "pdf2zh_next 进程已退出")
        stopPolling()
        updateMenu()
    }

    /// Gradio announces readiness with `* Running on local URL:  http://127.0.0.1:7860`.
    /// pdf2zh_next does not always reach that print (Gradio suppresses the banner when
    /// stdout is not a tty), so this is an enhancement, not the primary signal.
    private func scanLogForURL() {
        guard let handle = FileHandle(forReadingAtPath: config.logPath) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        guard size > logScanOffset else { return }
        try? handle.seek(toOffset: logScanOffset)
        let data = handle.readData(ofLength: 262_144)
        logScanOffset += UInt64(data.count)
        guard let chunk = String(data: data, encoding: .utf8) else { return }

        logScanBuffer += chunk
        if logScanBuffer.count > 262_144 {
            logScanBuffer = String(logScanBuffer.suffix(131_072))
        }
        guard probedURL == nil, let url = extractWebURL(from: logScanBuffer) else { return }
        probedURL = url
    }

    private func extractWebURL(from text: String) -> URL? {
        let markers = ["Running on local URL:", "Running on public URL:"]
        for marker in markers {
            guard let range = text.range(of: marker, options: .backwards) else { continue }
            let candidate = text[range.upperBound...].prefix { !$0.isWhitespace }
            guard candidate.hasPrefix("http://") || candidate.hasPrefix("https://"),
                  var url = URL(string: String(candidate)) else { continue }
            // Gradio prints the bind address; 0.0.0.0 is not dialable from a browser.
            if url.host == "0.0.0.0" || url.host == "::" {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                components?.host = "127.0.0.1"
                if let rewritten = components?.url { url = rewritten }
            }
            return url
        }
        return nil
    }

    private func localURL() -> URL {
        URL(string: "http://127.0.0.1:\(config.webPort)/")!
    }

    private func logTailSummary() -> String? {
        guard let handle = FileHandle(forReadingAtPath: config.logPath) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return nil }
        let readSize = min(size, 8_192)
        try? handle.seek(toOffset: size - readSize)
        let data = handle.readData(ofLength: Int(readSize))
        guard !data.isEmpty else { return nil }

        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let interesting = lines.last {
            $0.contains("EADDRINUSE")
                || $0.lowercased().contains("error")
                || $0.contains("Traceback")
                || $0.contains("Address already in use")
        }
        guard let line = interesting ?? lines.last else { return nil }
        return "异常 — " + String(line.suffix(110))
    }

    // MARK: Files, ports, locking

    private func ensureDirectories() {
        let manager = FileManager.default
        try? manager.createDirectory(atPath: config.workingDirectory, withIntermediateDirectories: true)
        try? manager.createDirectory(atPath: config.stateDirectory, withIntermediateDirectories: true)
        try? manager.createDirectory(atPath: config.outputDirectory, withIntermediateDirectories: true)
    }

    private func prepareLogFile() {
        let manager = FileManager.default
        let directory = (config.logPath as NSString).deletingLastPathComponent
        try? manager.createDirectory(atPath: directory, withIntermediateDirectories: true)

        if let attributes = try? manager.attributesOfItem(atPath: config.logPath),
           let size = attributes[.size] as? NSNumber, size.uint64Value > config.logMaxBytes {
            let rotated = config.logPath + ".1"
            try? manager.removeItem(atPath: rotated)
            try? manager.moveItem(atPath: config.logPath, toPath: rotated)
        }

        if !manager.fileExists(atPath: config.logPath) {
            manager.createFile(atPath: config.logPath, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        // The log carries the user's translation-engine settings, so keep it private.
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.logPath)
    }

    private func fileSize(atPath path: String) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.uint64Value
    }

    private func isPortInUse(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private func waitUntilPortFree(seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !isPortInUse(config.webPort) { return true }
            usleep(120_000)
        }
        return !isPortInUse(config.webPort)
    }

    private func acquireSingleInstanceLock() -> Bool {
        try? FileManager.default.createDirectory(atPath: config.stateDirectory, withIntermediateDirectories: true)
        let path = config.stateDirectory + "/pdf2zh-web.lock"
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return true }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        if ftruncate(descriptor, 0) == 0 {
            let text = "\(getpid())\n"
            _ = text.withCString { write(descriptor, $0, strlen($0)) }
        }
        lockFileDescriptor = descriptor
        return true
    }

    private func releaseSingleInstanceLock() {
        guard lockFileDescriptor >= 0 else { return }
        flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
    }

    // MARK: Alerts

    private func presentAlert(title: String, message: String, style: NSAlert.Style) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

// MARK: - Entry point

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
