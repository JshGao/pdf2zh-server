// main.swift
// PDF2ZH Web — a macOS menu bar wrapper that runs pdf2zh services in the background.
//
// This file is the authoritative implementation of VIBE_CODING.md.
//
// Two services are managed, because they serve different clients and neither replaces
// the other:
//
//   * pdf2zh_next --gui   the Gradio WebUI a human drives in a browser (default port 7860)
//   * zotero-pdf2zh       the Flask HTTP API the Zotero plugin calls   (default port 8890)
//
// They are distinct upstream projects with distinct protocols; pointing one client at the
// other's port fails with "this address is not a PDF2zh Server". Both are optional and are
// managed independently, so either can be absent without affecting the other.
//
// Design notes (see VIBE_CODING.md for the evidence behind each one):
//  * The wrapper starts executables that are already installed on this machine. It never
//    installs anything itself: a Finder-launched app has no shell and no network
//    assumptions, and a silent download would turn "start the service" into a mystery.
//  * Readiness is detected by probing the port. pdf2zh_next's Gradio UI has no token and no
//    auth by default, so a bare http://127.0.0.1:<port>/ is directly usable; the Gradio
//    banner is parsed from the log when available but is not relied upon (it is suppressed
//    when stdout is not a tty).
//  * `pdf2zh_next --gui` calls webbrowser.open() on launch, which would steal focus every
//    restart. Gradio routes that through Python's webbrowser module, so BROWSER=/usr/bin/true
//    turns the call into a no-op.
//  * zsh cannot enable job control without a tty (`set -m` fails, `zsh -m` hangs), so the
//    process group is created by posix_spawn(POSIX_SPAWN_SETPGROUP) and the whole tree is
//    reaped with killpg().
//  * applicationWillTerminate does not run on crash/force-quit, so an in-group watchdog
//    shell kills the group once this process disappears.

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
    /// Where translated PDFs land by default (pdf2zh_next writes `*-mono.pdf` next to
    /// the input file, so this is only the folder we hand to the user).
    var outputDirectory: String
    var readTimeoutSeconds: TimeInterval
    var autoOpenBrowser: Bool

    // MARK: Zotero service
    /// Path to zotero-pdf2zh's `server.py`, or "" when not installed.
    var zoteroServerPath: String
    /// Interpreter that runs server.py (its own venv), or "" to fall back to `python3`.
    var zoteroPythonPath: String
    var zoteroPort: Int
    var zoteroLogPath: String
    /// Managed together with the WebUI by default; set false to run only the WebUI.
    var zoteroAutoStart: Bool
    /// How often to poll `/api/tasks` while showing progress.
    var zoteroProgressPollSeconds: Double
    /// Whether to look for new releases at launch (manual checking stays available).
    var checkUpdatesOnLaunch: Bool

    static let defaultPort = 7860
    static let defaultZoteroPort = 8890
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
            autoOpenBrowser: boolValue("autoOpenBrowser", env: "PDF2ZH_AUTO_OPEN", fallback: false),
            zoteroServerPath: stringValue(
                "zoteroServerPath", env: "PDF2ZH_ZOTERO_SERVER", fallback: resolveZoteroServer()
            ),
            zoteroPythonPath: stringValue(
                "zoteroPythonPath", env: "PDF2ZH_ZOTERO_PYTHON", fallback: resolveZoteroPython()
            ),
            zoteroPort: intValue("zoteroPort", env: "PDF2ZH_ZOTERO_PORT", fallback: defaultZoteroPort),
            zoteroLogPath: stringValue(
                "zoteroLogPath", env: "PDF2ZH_ZOTERO_LOG",
                fallback: home + "/Library/Logs/pdf2zh-zotero.log"
            ),
            zoteroAutoStart: boolValue("zoteroAutoStart", env: "PDF2ZH_ZOTERO_AUTOSTART", fallback: true),
            zoteroProgressPollSeconds: Double(
                intValue("zoteroProgressPollSeconds", env: nil, fallback: 2)
            ),
            checkUpdatesOnLaunch: boolValue(
                "checkUpdatesOnLaunch", env: "PDF2ZH_CHECK_UPDATES", fallback: true
            )
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

    /// zotero-pdf2zh ships as an unpacked release archive; the documented layout is
    /// `zotero-pdf2zh/server/server.py`. Users put it in a handful of places, so probe
    /// the usual ones rather than making them configure a path by hand.
    static func resolveZoteroServer() -> String {
        let home = NSHomeDirectory()
        let candidates = [
            home + "/zotero-pdf2zh/server/server.py",
            home + "/Documents/zotero-pdf2zh/server/server.py",
            home + "/Downloads/zotero-pdf2zh/server/server.py",
            home + "/Applications/zotero-pdf2zh/server/server.py",
            home + "/.zotero-pdf2zh/server/server.py"
        ]
        for candidate in candidates where FileManager.default.isReadableFile(atPath: candidate) {
            return candidate
        }
        return ""
    }

    /// The interpreter that should run server.py. Its release layout puts a `.venv` next to
    /// `server/`; without one the system python3 may not have Flask, so a wrong guess is
    /// reported at startup rather than failing silently later.
    static func resolveZoteroPython() -> String {
        let home = NSHomeDirectory()
        let serverPath = resolveZoteroServer()
        var candidates: [String] = []
        if !serverPath.isEmpty {
            let root = (serverPath as NSString).deletingLastPathComponent   // .../server
            let parent = (root as NSString).deletingLastPathComponent       // .../zotero-pdf2zh
            candidates.append(parent + "/.venv/bin/python")
            candidates.append(parent + "/venv/bin/python")
        }
        candidates.append(contentsOf: [
            home + "/zotero-pdf2zh/.venv/bin/python",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ])
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "python3"
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

// MARK: - Service lifecycle

/// Everything that differs between the two managed services.
struct ServiceSpec {
    let name: String
    /// Absolute path to the executable to run.
    let executable: String
    /// Arguments appended after the executable.
    let arguments: [String]
    let workingDirectory: String
    let port: Int
    let logPath: String
    let logMaxBytes: UInt64
    /// Name of the pid file inside the state directory.
    let pidFile: String
    let readTimeout: TimeInterval
    /// Extra environment for this service only.
    let environment: [String: String]
    /// Substrings that mark a log line as the cause of a failure.
    let errorMarkers: [String]
}

/// Runs one long-lived child process in its own process group, watches it, and reports a
/// small state machine. Extracted from the app delegate so both services share one
/// implementation of the spawn / watchdog / cleanup logic instead of duplicating it.
final class ManagedService {
    enum State {
        case stopped
        case starting
        case running
        case problem(String)
        case missing

        var isBusy: Bool { if case .starting = self { return true }; return false }
        var isRunning: Bool { if case .running = self { return true }; return false }
    }

    let spec: ServiceSpec
    private(set) var state: State = .stopped
    /// pid of the supervisor shell, which is also the process group id.
    private var supervisorPid: pid_t = 0
    private var supervisorReaped = false
    private var stoppingIntentionally = false
    private var logScanOffset: UInt64 = 0
    private var startAttemptDate: Date?

    /// Called on the main queue whenever the state changes.
    var onStateChange: (() -> Void)?

    init(spec: ServiceSpec, installed: Bool) {
        self.spec = spec
        if !installed { state = .missing }
    }

    var isInstalled: Bool { if case .missing = state { return false }; return true }
    var supervisor: pid_t { supervisorPid }

    // MARK: Starting

    /// Returns nil on success, or a human-readable reason for failure.
    func start(waitForPortFree: Bool) -> String? {
        guard supervisorPid == 0 else { return nil }
        guard isInstalled else { return "未安装" }

        if waitForPortFree { _ = waitUntilPortFree(seconds: 3) }

        if PortProbe.isInUse(spec.port) {
            state = .problem("端口 \(spec.port) 已被占用")
            onStateChange?()
            return "port-in-use"
        }

        prepareLogFile()
        logScanOffset = LogFile.size(atPath: spec.logPath)
        startAttemptDate = Date()

        do {
            let pid = try spawnSupervisor()
            supervisorPid = pid
            supervisorReaped = false
            state = .starting
            onStateChange?()
            return nil
        } catch {
            state = .problem("启动失败")
            onStateChange?()
            return error.localizedDescription
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
        posix_spawn_file_actions_addopen(&actions, 1, spec.logPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
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

    /// The supervisor shell keeps the group alive, runs the service in the background,
    /// and owns the crash watchdog. It deliberately does NOT use `set -m`: zsh cannot
    /// enable job control without a tty, and the process group already comes from
    /// POSIX_SPAWN_SETPGROUP.
    private func supervisorScript() -> String {
        let workingDirectory = shellQuote(spec.workingDirectory)
        let executable = shellQuote(spec.executable)
        let pidFile = shellQuote(
            NSHomeDirectory() + "/Library/Application Support/PDF2ZHWeb/" + spec.pidFile
        )
        let arguments = spec.arguments.map(shellQuote).joined(separator: " ")
        let argumentSuffix = arguments.isEmpty ? "" : " " + arguments
        let wrapperPid = String(getpid())
        let label = spec.name

        return """
        cd \(workingDirectory) || { print -r -- "\(label): cannot cd to" \(workingDirectory); exit 1; }

        pgid=$$
        wrapper=\(wrapperPid)

        ( trap '' TERM
          while kill -0 "$wrapper" 2>/dev/null && kill -0 "$pgid" 2>/dev/null; do sleep 1; done
          kill -TERM -"$pgid" 2>/dev/null
          sleep 3
          kill -KILL -"$pgid" 2>/dev/null ) &
        watchdog_pid=$!

        \(executable)\(argumentSuffix) &
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

        environment["PATH"] = Self.extendedPath(adding: spec.executable)
        environment["HOME"] = NSHomeDirectory()
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        if environment["LC_CTYPE"] == nil { environment["LC_CTYPE"] = "UTF-8" }

        // `pdf2zh_next --gui` calls webbrowser.open() while launching Gradio; point the
        // BROWSER override at /usr/bin/true so the call succeeds as a no-op instead of
        // stealing focus on every restart.
        environment["BROWSER"] = "/usr/bin/true"

        for (key, value) in spec.environment { environment[key] = value }
        return environment
    }

    /// Finder-launched apps inherit a minimal PATH; both services shell out to helper
    /// binaries, so widen it rather than hoping the shell profile is read (it is not).
    static func extendedPath(adding executablePath: String) -> String {
        let home = NSHomeDirectory()
        var components: [String] = []
        if !executablePath.isEmpty {
            components.append((executablePath as NSString).deletingLastPathComponent)
        }
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

    // MARK: Stopping

    func stop() {
        guard supervisorPid != 0 else {
            if case .problem = state {} else if case .missing = state {} else { state = .stopped }
            onStateChange?()
            return
        }

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

        if case .problem = state {} else if case .missing = state {} else { state = .stopped }
        onStateChange?()
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

    // MARK: Polling

    /// One polling step. Returns true when the caller should present a failure alert.
    @discardableResult
    func poll() -> String? {
        reapIfNeeded()
        guard case .starting = state, let started = startAttemptDate else { return nil }

        // A listening socket is the readiness signal we can always trust: both services
        // bind only after they are actually able to answer.
        if PortProbe.isInUse(spec.port) {
            state = .running
            onStateChange?()
            startAttemptDate = nil
            return nil
        }

        if Date().timeIntervalSince(started) > spec.readTimeout {
            state = .problem("启动超时")
            startAttemptDate = nil
            onStateChange?()
            return "timeout"
        }
        return nil
    }

    private func reapIfNeeded() {
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
        state = .problem(logTailSummary() ?? "\(spec.name) 进程已退出")
        onStateChange?()
    }

    /// Summarise the tail of the log for the status line: prefer a line that looks like a
    /// cause, otherwise the last non-empty line.
    private func logTailSummary() -> String? {
        guard let handle = FileHandle(forReadingAtPath: spec.logPath) else { return nil }
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
        let interesting = lines.last { line in
            spec.errorMarkers.contains { line.contains($0) }
        }
        guard let line = interesting ?? lines.last else { return nil }
        return "异常 — " + String(line.suffix(110))
    }

    // MARK: Files and ports

    private func prepareLogFile() {
        let manager = FileManager.default
        let directory = (spec.logPath as NSString).deletingLastPathComponent
        try? manager.createDirectory(atPath: directory, withIntermediateDirectories: true)

        if let attributes = try? manager.attributesOfItem(atPath: spec.logPath),
           let size = attributes[.size] as? NSNumber, size.uint64Value > spec.logMaxBytes {
            let rotated = spec.logPath + ".1"
            try? manager.removeItem(atPath: rotated)
            try? manager.moveItem(atPath: spec.logPath, toPath: rotated)
        }

        if !manager.fileExists(atPath: spec.logPath) {
            manager.createFile(atPath: spec.logPath, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        // The log can carry the user's engine settings, so keep it private.
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: spec.logPath)
    }

    private func waitUntilPortFree(seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !PortProbe.isInUse(spec.port) { return true }
            usleep(120_000)
        }
        return !PortProbe.isInUse(spec.port)
    }
}

// MARK: - Small shared helpers

enum PortProbe {
    static func isInUse(_ port: Int) -> Bool {
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
}

enum LogFile {
    static func size(atPath path: String) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.uint64Value
    }
}

/// `pdf2zh_next --version` prints a rich banner whose last line is
/// `pdf2zh-next version: 2.9.0`; be tolerant and accept any `x.y.z`.
func extractVersion(from output: String) -> String? {
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


// MARK: - Update checking

/// One "an update exists" fact, ready for the menu.
struct AvailableUpdate {
    let name: String
    let current: String
    let latest: String
    let url: String
}

/// Checks the two upstreams for newer releases. It **only checks** — nothing is downloaded
/// or installed. Upgrading pdf2zh_next can pull a new BabelDOC and re-download assets, and
/// upgrading zotero-pdf2zh replaces a server the user may have customised, so those stay
/// explicit user actions; this just surfaces that they are available.
///
/// Sources, deliberately the ones each project itself documents:
///   * pdf2zh_next  -> PyPI JSON API (the package is installed by `uv tool install`)
///   * zotero-pdf2zh -> its GitHub releases (the docs point users at releases, not PyPI)
enum UpdateChecker {

    static func check(completion: @escaping ([AvailableUpdate]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [AvailableUpdate] = []

        func add(_ update: AvailableUpdate?) {
            guard let update else { return }
            lock.lock(); found.append(update); lock.unlock()
        }

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            add(checkPDF2ZH())
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            add(checkZoteroPDF2ZH())
            group.leave()
        }

        group.notify(queue: .main) {
            completion(found.sorted { $0.name < $1.name })
        }
    }

    /// PyPI's per-release JSON. `releases` is keyed by version, so the newest key is the
    /// newest version — cheaper and more reliable than parsing the HTML page.
    private static func checkPDF2ZH() -> AvailableUpdate? {
        guard let current = installedPDF2ZHVersion() else { return nil }
        guard let json = fetchJSON("https://pypi.org/pypi/pdf2zh-next/json") else { return nil }
        guard let releases = json["releases"] as? [String: Any] else { return nil }

        let versions = releases.keys.filter { !$0.contains("-") }   // skip pre-releases
        guard let latest = versions.max(by: { compareVersions($0, $1) == .orderedAscending }) else {
            return nil
        }
        guard compareVersions(latest, current) == .orderedDescending else { return nil }
        return AvailableUpdate(
            name: "pdf2zh_next",
            current: current,
            latest: latest,
            url: "https://pypi.org/project/pdf2zh-next/"
        )
    }

    /// Reads the installed version out of the package on disk. `pdf2zh_next --version` would
    /// work too but starts a whole interpreter for one string, so read the module's own
    /// `__version__` instead.
    ///
    /// Note the shape of this: it checks a short list of *exact* file paths rather than
    /// enumerating site-packages. A depth-first walk finds thousands of unrelated packages
    /// before reaching pdf2zh_next, so any traversal budget either truncates before the hit
    /// or costs hundreds of milliseconds; every supported install layout has a known path.
    private static func installedPDF2ZHVersion() -> String? {
        let home = NSHomeDirectory()
        var candidates: [String] = []

        // uv tool and pipx layouts, whose site-packages version directory varies.
        let versionedRoots = [
            home + "/.local/share/uv/tools/pdf2zh-next/lib",
            home + "/.local/pipx/venvs/pdf2zh-next/lib"
        ]
        for root in versionedRoots {
            guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for version in versions {
                candidates.append(root + "/" + version + "/site-packages/pdf2zh_next/__init__.py")
            }
        }
        // Plain virtualenvs and the uv-tool variant that uses the default python.
        candidates.append(contentsOf: [
            home + "/.local/share/uv/tools/pdf2zh-next/lib/site-packages/pdf2zh_next/__init__.py",
            home + "/.venv/lib/python3.12/site-packages/pdf2zh_next/__init__.py",
            home + "/venv/lib/python3.12/site-packages/pdf2zh_next/__init__.py"
        ])

        for path in candidates {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if let version = firstMatch(in: text, pattern: "__version__\\s*=\\s*[\"']([0-9][0-9.]*)[\"']") {
                return version
            }
        }

        // Last resort: the metadata directory is named "<package>-<version>.dist-info".
        for root in versionedRoots {
            guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for version in versions {
                let sitePackages = root + "/" + version + "/site-packages"
                guard let entries = try? FileManager.default.contentsOfDirectory(atPath: sitePackages) else { continue }
                for entry in entries where entry.hasSuffix(".dist-info") {
                    let lower = entry.lowercased()
                    guard lower.hasPrefix("pdf2zh_next-") || lower.hasPrefix("pdf2zh-next-") else { continue }
                    let stem = entry.replacingOccurrences(of: ".dist-info", with: "")
                    if let dash = stem.range(of: "-", options: .backwards) {
                        return String(stem[dash.upperBound...])
                    }
                }
            }
        }
        return nil
    }

    /// First capture group of `pattern`, or nil.
    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { return nil }
        return (text as NSString).substring(with: match.range(at: 1))
    }

    /// zotero-pdf2zh publishes its server as release assets, so the tag is the version.
    private static func checkZoteroPDF2ZH() -> AvailableUpdate? {
        guard let current = installedZoteroVersion() else { return nil }
        guard let json = fetchJSON("https://api.github.com/repos/guaguastandup/zotero-pdf2zh/releases/latest"),
              let tag = json["tag_name"] as? String else { return nil }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard compareVersions(latest, current) == .orderedDescending else { return nil }
        return AvailableUpdate(
            name: "zotero-pdf2zh",
            current: current,
            latest: latest,
            url: "https://github.com/guaguastandup/zotero-pdf2zh/releases/latest"
        )
    }

    /// server.py declares its version as a module-level `__version__` (it prints the same
    /// value on startup). Reading the source is more direct than scraping the log, and the
    /// leading `## server.py v4.1.7` comment is accepted as a fallback.
    private static func installedZoteroVersion() -> String? {
        let path = AppConfig.resolveZoteroServer()
        guard !path.isEmpty,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let patterns = [
            "__version__\\s*=\\s*[\"']([0-9][0-9.]*)[\"']",
            "SERVER_VERSION\\s*=\\s*[\"']([0-9][0-9.]*)[\"']",
            "^##\\s*server\\.py\\s*v([0-9][0-9.]*)"
        ]
        for pattern in patterns {
            if let version = firstMatch(in: text, pattern: pattern) { return version }
        }
        return nil
    }

    private static func fetchJSON(_ urlString: String) -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("PDF2ZHWeb-MenuBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result = object
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 12)
        return result
    }

    /// Numeric component-wise comparison, so "2.10.0" sorts above "2.9.0" (a string compare
    /// would get that backwards, which is exactly the kind of bug that hides releases).
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}


// MARK: - Translation progress

/// Polls zotero-pdf2zh's `/api/tasks` and reports aggregate progress.
///
/// That endpoint is the only place either service exposes per-task progress: it returns the
/// active task list with a 0–100 `progress` field, updated by the server as it drives
/// pdf2zh_next. The Gradio WebUI has no equivalent, so progress tracking is available only
/// when the Zotero service is installed and translating.
///
/// "Overall progress" across several concurrent tasks is the mean of their percentages —
/// the tasks are independent and roughly equal in cost, so an average is the honest summary
/// and matches what a user means by "how far along am I".
final class ProgressTracker {
    private let port: Int
    private let interval: TimeInterval
    private var timer: Timer?
    private var inFlight = false

    /// Aggregate 0...1, or nil when nothing is running.
    private(set) var fraction: Double?
    /// How many tasks the current figure covers.
    private(set) var taskCount: Int = 0
    /// Set briefly when work finishes, so the icon can show a completed state.
    private var completedAt: Date?
    /// True once any task has actually been observed; distinguishes "idle so far" (keep
    /// polling — work may start at any time) from "finished" (stop after the banner).
    private var hasSeenTasks = false

    /// Called on the main queue when the reported progress changes.
    var onChange: (() -> Void)?
    /// Optional sink for a short diagnostic line whenever the reported progress changes.
    /// Without this, a user reporting "the icon never turns green" cannot be told apart from
    /// "nothing was translating yet", because the app otherwise keeps no record of what it saw.
    var onDiagnostic: ((String) -> Void)?

    init(port: Int, interval: TimeInterval) {
        self.port = port
        self.interval = max(1, interval)
    }

    var isTranslating: Bool { fraction != nil }

    /// True for a couple of seconds after the last task finished: the menu shows a
    /// "completed" note and the icon stays green, then everything returns to normal.
    var justCompleted: Bool {
        guard let completedAt else { return false }
        return Date().timeIntervalSince(completedAt) < 4
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        // A future start() must again begin from "nothing observed yet".
        hasSeenTasks = false
        completedAt = nil
    }

    private func poll() {
        guard !inFlight else { return }

        // Once a run has been *seen* and then finished, keep polling until the completion
        // banner expires — the icon holds full green during that window and needs one more
        // tick to return to normal — and only then stop.
        //
        // The guard must key on `hasSeenTasks`, not on `fraction == nil`: at launch nothing
        // has been observed yet, so a nil fraction means "idle so far", not "finished".
        // Testing `fraction == nil` alone stopped the tracker on its first tick, which is why
        // a translation started later never showed up in the menu bar.
        if timer != nil, hasSeenTasks, !justCompleted {
            stop()
            return
        }

        inFlight = true

        let url = URL(string: "http://127.0.0.1:\(port)/api/tasks")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 4

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            // A refused connection is the normal case whenever the service is not running;
            // treat any failure as "no tasks" rather than as an error to report.
            var percentages: [Double] = []
            if let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tasks = object["tasks"] as? [[String: Any]] {
                for task in tasks {
                    if let progress = task["progress"] as? Double {
                        percentages.append(progress)
                    } else if let progress = task["progress"] as? Int {
                        percentages.append(Double(progress))
                    }
                }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                self.apply(percentages: percentages)
            }
        }.resume()
    }

    private func apply(percentages: [Double]) {
        let previous = fraction
        let previousCount = taskCount

        if percentages.isEmpty {
            if previous != nil { completedAt = Date() }
            fraction = nil
            taskCount = 0
        } else if justCompleted, let held = fraction {
            // Tasks reappeared within the completion window: the batch is still going, so
            // keep the completed banner off and resume live progress from here.
            completedAt = nil
            fraction = min(1.0, max(0.0, percentages.reduce(0, +) / Double(percentages.count) / 100.0))
            taskCount = percentages.count
            hasSeenTasks = true
            _ = held
        } else {
            fraction = min(1.0, max(0.0, percentages.reduce(0, +) / Double(percentages.count) / 100.0))
            taskCount = percentages.count
            hasSeenTasks = true
        }

        if fraction != previous || taskCount != previousCount {
            if let fraction {
                let percent = Int((fraction * 100).rounded())
                onDiagnostic?("进度 \(percent)%（\(taskCount) 个任务）")
            } else {
                onDiagnostic?("翻译任务结束")
            }
            onChange?()
        } else if previous == nil, justCompleted {
            // Keep refreshing while the "completed" note is on screen so it expires.
            onChange?()
        }
    }
}

// MARK: - Progress icon

/// Renders the menu bar mark with a progress overlay.
///
/// The mark is normally a template image, which macOS tints itself — that is why it adapts
/// to light and dark menu bars for free, but it also means a template image can never be
/// green. Progress therefore switches to a coloured bitmap drawn here instead.
///
/// The progress reads as a fill sweeping left to right: the finished portion is green, the
/// rest stays close to the menu bar's own colour so the mark keeps its shape. The artwork is
/// the same vector source as the template icon, so only the colouring differs.
enum ProgressIcon {
    private static var cachedPath: CGPath?

    /// The mark's geometry, transcribed from assets/download.svg exactly as make-icons.swift
    /// does (SVG y-down flipped to CoreGraphics y-up).
    private static func markPath() -> CGPath {
        if let cachedPath { return cachedPath }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 296, y: 9))
        path.addCurve(to: CGPoint(x: 254, y: -3), control1: CGPoint(x: 284, y: 1), control2: CGPoint(x: 269, y: -3))
        path.addCurve(to: CGPoint(x: 169, y: 79), control1: CGPoint(x: 207, y: -3), control2: CGPoint(x: 169, y: 33))
        path.addCurve(to: CGPoint(x: 254, y: 162), control1: CGPoint(x: 169, y: 125), control2: CGPoint(x: 207, y: 162))
        path.addCurve(to: CGPoint(x: 305, y: 145), control1: CGPoint(x: 273, y: 162), control2: CGPoint(x: 289, y: 156))
        path.addLine(to: CGPoint(x: 387, y: 89))
        path.addCurve(to: CGPoint(x: 389, y: 57), control1: CGPoint(x: 399, y: 81), control2: CGPoint(x: 400, y: 67))
        path.addCurve(to: CGPoint(x: 358, y: 56), control1: CGPoint(x: 381, y: 49), control2: CGPoint(x: 369, y: 49))
        path.addLine(to: CGPoint(x: 278, y: 111))
        path.addCurve(to: CGPoint(x: 254, y: 120), control1: CGPoint(x: 270, y: 117), control2: CGPoint(x: 262, y: 120))
        path.addCurve(to: CGPoint(x: 214, y: 79), control1: CGPoint(x: 231, y: 120), control2: CGPoint(x: 214, y: 102))
        path.addCurve(to: CGPoint(x: 257, y: 35), control1: CGPoint(x: 214, y: 55), control2: CGPoint(x: 232, y: 36))
        path.closeSubpath()
        path.move(to: CGPoint(x: 328, y: 149))
        path.addCurve(to: CGPoint(x: 378, y: 163), control1: CGPoint(x: 343, y: 158), control2: CGPoint(x: 360, y: 163))
        path.addCurve(to: CGPoint(x: 470, y: 80), control1: CGPoint(x: 429, y: 163), control2: CGPoint(x: 470, y: 127))
        path.addCurve(to: CGPoint(x: 380, y: -3), control1: CGPoint(x: 470, y: 33), control2: CGPoint(x: 432, y: -3))
        path.addCurve(to: CGPoint(x: 306, y: 20), control1: CGPoint(x: 352, y: -4), control2: CGPoint(x: 328, y: 4))
        path.addLine(to: CGPoint(x: 242, y: 66))
        path.addCurve(to: CGPoint(x: 239, y: 96), control1: CGPoint(x: 231, y: 74), control2: CGPoint(x: 229, y: 86))
        path.addCurve(to: CGPoint(x: 268, y: 98), control1: CGPoint(x: 247, y: 105), control2: CGPoint(x: 258, y: 105))
        path.addLine(to: CGPoint(x: 344, y: 44))
        path.addCurve(to: CGPoint(x: 410, y: 49), control1: CGPoint(x: 365, y: 29), control2: CGPoint(x: 392, y: 32))
        path.addCurve(to: CGPoint(x: 414, y: 107), control1: CGPoint(x: 430, y: 67), control2: CGPoint(x: 430, y: 91))
        path.addCurve(to: CGPoint(x: 373, y: 118), control1: CGPoint(x: 404, y: 118), control2: CGPoint(x: 390, y: 122))
        path.closeSubpath()
        cachedPath = path
        return path
    }

    /// Draw the mark at `size`, with the leftmost `fraction` of its width in `progressColor`
    /// and the remainder in `restColor`.
    static func image(size: NSSize, fraction: Double, restColor: NSColor) -> NSImage {
        let width = max(1, Int((size.width * 2).rounded()))
        let height = max(1, Int((size.height * 2).rounded()))

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(size: size)
        }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        // Fit the ink box into the canvas, exactly like the generator does, so the coloured
        // icon lines up with the template one it replaces.
        let source = markPath()
        let ink = source.boundingBoxOfPath
        let canvasW = CGFloat(width), canvasH = CGFloat(height)
        let scale = min(canvasW / ink.width, canvasH / ink.height)
        var transform = CGAffineTransform(translationX: canvasW / 2, y: canvasH / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -ink.midX, y: -ink.midY)
        let fitted = source.copy(using: &transform) ?? source

        // Everything in `restColor` first…
        context.saveGState()
        context.addPath(fitted)
        context.setFillColor(restColor.cgColor)
        context.fillPath()
        context.restoreGState()

        // …then the finished portion in green, clipped to the leftmost `fraction`.
        let clamped = min(1.0, max(0.0, fraction))
        if clamped > 0 {
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: 0, width: canvasW * CGFloat(clamped), height: canvasH))
            context.addPath(fitted)
            context.setFillColor(NSColor.systemGreen.cgColor)
            context.fillPath()
            context.restoreGState()
        }

        guard let cgImage = context.makeImage() else { return NSImage(size: size) }
        let image = NSImage(cgImage: cgImage, size: size)
        image.isTemplate = false   // a coloured image must not be tinted by the system
        return image
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let config = AppConfig.load()

    /// The Gradio WebUI a human drives in a browser.
    private var webService: ManagedService!
    /// The Flask HTTP API the Zotero plugin calls. Optional: absent installs are fine.
    private var zoteroService: ManagedService?

    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var openItem: NSMenuItem?
    private var copyItem: NSMenuItem?
    private var zoteroItem: NSMenuItem?
    private var zoteroOpenItem: NSMenuItem?
    private var versionItem: NSMenuItem?
    private var progressItem: NSMenuItem?
    private var updateItem: NSMenuItem?

    private var progressTracker: ProgressTracker?
    private var updateCheckTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?
    private var availableUpdates: [AvailableUpdate] = []
    /// The template (adaptive) icon, kept so it can be restored after a progress run.
    private var templateIcon: NSImage?
    private var lastIconSignature = ""

    /// Lock file descriptor held for the lifetime of the process (flock).
    private var lockFileDescriptor: Int32 = -1
    private var pollTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var versionText: String?
    private var zoteroNote: String?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        webService = ManagedService(
            spec: ServiceSpec(
                name: "pdf2zh-web",
                executable: config.pdf2zhPath,
                arguments: webArguments(),
                workingDirectory: config.workingDirectory,
                port: config.webPort,
                logPath: config.logPath,
                logMaxBytes: config.logMaxBytes,
                pidFile: "pdf2zh-web.pid",
                readTimeout: config.readTimeoutSeconds,
                environment: zoteroAwareEnvironment(),
                errorMarkers: ["EADDRINUSE", "error", "Traceback", "Address already in use"]
            ),
            installed: !config.pdf2zhPath.isEmpty
        )
        webService.onStateChange = { [weak self] in self?.updateMenu() }

        // The Zotero service is only managed when its server.py is actually present. An
        // install that only wants the WebUI keeps the old single-service behaviour.
        if !config.zoteroServerPath.isEmpty {
            let spec = ServiceSpec(
                name: "zotero-pdf2zh",
                executable: "/bin/zsh",
                arguments: ["-c", zoteroCommandLine()],
                workingDirectory: (config.zoteroServerPath as NSString).deletingLastPathComponent,
                port: config.zoteroPort,
                logPath: config.zoteroLogPath,
                logMaxBytes: config.logMaxBytes,
                pidFile: "zotero-server.pid",
                // First launch may create/repair a translation environment, which is slow;
                // later launches bind in a couple of seconds. Stay generous.
                readTimeout: max(config.readTimeoutSeconds, 120),
                environment: zoteroAwareEnvironment(),
                errorMarkers: ["Traceback", "Address already in use", "Errno", "PermissionError"]
            )
            zoteroService = ManagedService(spec: spec, installed: true)
            zoteroService?.onStateChange = { [weak self] in self?.updateMenu() }
        }

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
        startProgressTracking()
        if config.checkUpdatesOnLaunch {
            checkForUpdates(userInitiated: false)
        }

        // Re-check periodically so a long-running session still learns about releases. A day
        // is plenty: these are tools the user updates deliberately, not a security feed.
        let updateTimer = Timer(timeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            self?.checkForUpdates(userInitiated: false)
        }
        RunLoop.main.add(updateTimer, forMode: .common)
        updateCheckTimer = updateTimer

        // The coloured progress icon draws its own background-matched colour, so it has to be
        // redrawn when the system switches between light and dark.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            self?.lastIconSignature = ""
            self?.updateStatusIcon()
        }

        guard webService.isInstalled else {
            updateMenu()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.presentInstallGuide()
            }
            startZoteroIfNeeded()
            return
        }

        startWeb(waitForPortFree: false)
        startZoteroIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        webService?.stop()
        zoteroService?.stop()
        releaseSingleInstanceLock()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Logout, shutdown and `kill` deliver SIGTERM rather than an Apple Event.
    /// Without this, those paths would skip applicationWillTerminate and leave the
    /// services running (SIGKILL and crashes are still covered by the watchdog).
    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Service arguments

    /// `--server-port` is the flattened name of gui_settings.server_port; it wins over
    /// ~/.config/pdf2zh/config.v3.toml and is never written back to it.
    private func webArguments() -> [String] {
        ["--gui", "--server-port", "\(config.webPort)"] + config.extraArguments
    }

    /// zotero-pdf2zh's server.py runs an interactive environment check and, when it finds
    /// anything to fix or update, waits for a y/n answer before continuing. The wrapper
    /// gives the child /dev/null on stdin, so that prompt would raise EOFError and the
    /// server would exit — which is exactly what an unattended launch must avoid.
    ///
    /// Answering "y" to *start anyway* is what matters: the check is advisory and the server
    /// runs fine past it. Answering "n" to the second prompt (offer to update the translation
    /// environment) keeps an already-provisioned environment untouched — a service that
    /// silently reinstalls packages on every launch would be far worse than one that does
    /// not. Users who want updates run `update_packages.py`, as zotero-pdf2zh's docs say.
    private func zoteroCommandLine() -> String {
        let python = shellQuote(config.zoteroPythonPath)
        let script = shellQuote(config.zoteroServerPath)
        return "printf 'y\\nn\\n' | \(python) \(script) --port \(config.zoteroPort)"
    }

    private func zoteroAwareEnvironment() -> [String: String] {
        var environment = AppConfig.parseEnvFile(config.envFile)
        for (key, value) in config.environment { environment[key] = value }
        return environment
    }

    private func startZoteroIfNeeded() {
        guard zoteroService != nil, config.zoteroAutoStart else { return }
        startZotero(waitForPortFree: false)
    }

    // MARK: Progress and updates

    private func startProgressTracking() {
        let tracker = ProgressTracker(port: config.zoteroPort, interval: config.zoteroProgressPollSeconds)
        tracker.onChange = { [weak self] in self?.updateMenu() }
        tracker.onDiagnostic = { [weak self] message in
            self?.appendDiagnostic(message)
        }
        tracker.start()
        progressTracker = tracker
    }

    /// Append an app-level note to the WebUI log. The file is already 0600 and is the place
    /// users are told to look, so app events go there too, prefixed so they are easy to pick
    /// out from the service's own output.
    private func appendDiagnostic(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "pdf2zh-web[app]: \(stamp) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: config.logPath) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: config.logPath))
        }
    }

    /// Ask both upstreams whether newer releases exist. Nothing is installed; the menu
    /// surfaces the result and the user decides (see UpdateChecker for why).
    private func checkForUpdates(userInitiated: Bool) {
        if userInitiated { updateItem?.title = "检查更新：检查中…" }
        UpdateChecker.check { [weak self] updates in
            guard let self else { return }
            self.availableUpdates = updates
            self.updateMenu()
            if userInitiated, updates.isEmpty {
                self.presentAlert(
                    title: "已是最新版本",
                    message: "pdf2zh_next 与 zotero-pdf2zh 都没有可用更新。",
                    style: .informational
                )
            }
        }
    }

    /// Icon reflects translation progress when there is any, and the plain template mark
    /// otherwise. Rebuilt only when something it depends on actually changed, because
    /// drawing costs far more than the comparison.
    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }

        // While the completion banner is up, hold the icon at full green so "finished" is
        // visible before the mark returns to its normal colour.
        let fraction: Double?
        if let live = progressTracker?.fraction {
            fraction = live
        } else if progressTracker?.justCompleted == true {
            fraction = 1.0
        } else {
            fraction = nil
        }

        // Resting state: the template image, which macOS tints for light/dark menu bars.
        guard let fraction else {
            let signature = "template"
            guard signature != lastIconSignature else { return }
            lastIconSignature = signature
            if let templateIcon { button.image = templateIcon }
            return
        }

        // Colour cannot come from a template image, so draw a coloured bitmap instead. The
        // unfinished remainder is drawn in the colour the template would have been tinted
        // to, detected from the button's effective appearance.
        let isDark = button.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let signature = String(format: "%.3f-%@", fraction, isDark ? "dark" : "light")
        guard signature != lastIconSignature else { return }
        lastIconSignature = signature

        let size = templateIcon?.size ?? NSSize(width: 23.5, height: 13)
        let rest: NSColor = isDark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.92)
            : NSColor(calibratedWhite: 0.0, alpha: 0.92)
        button.image = ProgressIcon.image(size: size, fraction: fraction, restColor: rest)
    }

    private func progressSummary() -> String? {
        guard let tracker = progressTracker else { return nil }
        if let fraction = tracker.fraction {
            let percent = Int((fraction * 100).rounded())
            let tasks = tracker.taskCount
            return tasks > 1
                ? "翻译中：\(percent)%（\(tasks) 个任务）"
                : "翻译中：\(percent)%"
        }
        if tracker.justCompleted { return "翻译完成" }
        return nil
    }

    // MARK: Update actions

    /// One item doubles as "check now" and "show what was found", which keeps the menu
    /// short: with updates known it reports them, otherwise it runs a check.
    @objc private func updateItemClicked() {
        if availableUpdates.isEmpty {
            checkForUpdates(userInitiated: true)
        } else {
            showPendingUpdates()
        }
    }

    @objc private func showPendingUpdates() {
        guard !availableUpdates.isEmpty else {
            checkForUpdates(userInitiated: true)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let lines = availableUpdates
            .map { "\($0.name)  \($0.current) → \($0.latest)" }
            .joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "有可用更新"
        alert.informativeText = """
        \(lines)

        本 App 只负责检查与提醒，不会自动升级：

        • pdf2zh_next 由 uv tool 安装，在终端执行
          uv tool upgrade pdf2zh-next
          升级后点菜单“重启 WebUI”生效。升级可能带来新的 BabelDOC，首次翻译会重新下载资产。

        • zotero-pdf2zh 的 server 是解压目录，按上游 release 替换：
          https://github.com/guaguastandup/zotero-pdf2zh/releases/latest
          升级后点菜单“重启 Zotero 服务”。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "打开项目页")
        if alert.runModal() == .alertSecondButtonReturn,
           let first = availableUpdates.first,
           let url = URL(string: first.url) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Menu

    private func makeItem(
_ title: String, action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if action != nil { item.target = self }
        return item
    }

    private func buildMenu() {
        // variableLength, not squareLength: the mark is wider than it is tall (roughly
        // 1.8:1), so a square status item would force it into a square box and shrink it.
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            // The bundled template image (black mark on transparent) is the primary icon:
            // macOS tints it automatically for light/dark menu bars.
            var image: NSImage?
            if let path = Bundle.main.path(forResource: "pdf2zh-status", ofType: "png"),
               let bundled = NSImage(contentsOfFile: path) {
                // The PNG is cropped tight to the artwork and rendered at 2x the size it is
                // shown at, so the bitmap's aspect ratio is already correct: scale it to the
                // target height and let the width follow. Setting a square size here would
                // squash a 1.8:1 mark into a square and make it look small.
                let targetHeight: CGFloat = bundled.size.height / 2
                let aspect = bundled.size.width / max(bundled.size.height, 1)
                bundled.size = NSSize(width: targetHeight * aspect, height: targetHeight)
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
                templateIcon = image
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

        // A dedicated line for the Zotero service, because "which port do I give the
        // plugin" is the question this app exists to answer for Zotero users.
        let zotero = makeItem("Zotero 服务：未安装", action: nil)
        zotero.isEnabled = false
        zoteroItem = zotero
        menu.addItem(zotero)

        // Only meaningful while a translation is running, so it hides itself otherwise.
        let progress = makeItem("翻译中", action: nil)
        progress.isEnabled = false
        progress.isHidden = true
        progressItem = progress
        menu.addItem(progress)
        menu.addItem(.separator())

        let open = makeItem("在浏览器中打开", action: #selector(openInBrowser), key: "o")
        openItem = open
        menu.addItem(open)

        let copy = makeItem("复制服务地址", action: #selector(copyServiceURL))
        copyItem = copy
        menu.addItem(copy)

        let zoteroOpen = makeItem("复制 Zotero 插件地址", action: #selector(copyZoteroURL))
        zoteroOpenItem = zoteroOpen
        menu.addItem(zoteroOpen)

        menu.addItem(makeItem("打开输出文件夹", action: #selector(openOutputDirectory)))
        menu.addItem(.separator())
        menu.addItem(makeItem("打开 WebUI 日志", action: #selector(openLog)))
        menu.addItem(makeItem("打开 Zotero 服务日志", action: #selector(openZoteroLog)))
        menu.addItem(.separator())
        menu.addItem(makeItem("重新检查 pdf2zh_next", action: #selector(recheckDependency)))
        menu.addItem(makeItem("重启 WebUI", action: #selector(restartWeb), key: "r"))
        menu.addItem(makeItem("重启 Zotero 服务", action: #selector(restartZotero)))
        menu.addItem(.separator())

        let version = makeItem("pdf2zh_next：检测中…", action: #selector(showEnvironment))
        versionItem = version
        menu.addItem(version)

        let update = makeItem("检查更新", action: #selector(updateItemClicked))
        updateItem = update
        menu.addItem(update)

        menu.addItem(.separator())
        menu.addItem(makeItem("退出并停止全部服务", action: #selector(quitApp), key: "q"))

        statusItem.menu = menu
    }

    private func updateMenu() {
        guard let statusMenuItem, let openItem, let copyItem else { return }

        let webTitle: String
        switch webService.state {
        case .starting: webTitle = "PDF2ZH Web：启动中…（端口 \(config.webPort)）"
        case .running: webTitle = "PDF2ZH Web：运行中（端口 \(config.webPort)）"
        case .stopped: webTitle = "PDF2ZH Web：已停止"
        case .problem(let reason): webTitle = "PDF2ZH Web：\(reason)"
        case .missing: webTitle = "PDF2ZH Web：未找到 pdf2zh_next"
        }
        statusMenuItem.title = webTitle
        statusItem?.button?.toolTip = webTitle

        let webUsable = webService.state.isRunning
        openItem.isEnabled = webUsable
        copyItem.isEnabled = webUsable

        updateStatusIcon()

        if let progressItem {
            if let summary = progressSummary() {
                progressItem.title = summary
                progressItem.isHidden = false
            } else {
                progressItem.isHidden = true
            }
        }

        if let updateItem {
            if availableUpdates.isEmpty {
                updateItem.title = "检查更新"
            } else {
                let names = availableUpdates.map { "\($0.name) \($0.latest)" }.joined(separator: "、")
                updateItem.title = "有可用更新：\(names)"
            }
        }

        if let zoteroItem {
            if let zoteroService {
                let title: String
                switch zoteroService.state {
                case .starting: title = "Zotero 服务：启动中…（端口 \(config.zoteroPort)）"
                case .running: title = "Zotero 服务：运行中（端口 \(config.zoteroPort)）"
                case .stopped: title = "Zotero 服务：已停止"
                case .problem(let reason): title = "Zotero 服务：\(reason)"
                case .missing: title = "Zotero 服务：未安装"
                }
                zoteroItem.title = title
                zoteroOpenItem?.isEnabled = zoteroService.state.isRunning
            } else {
                zoteroItem.title = "Zotero 服务：未安装（点击查看获取方式）"
            }
        }
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
        guard webService.state.isRunning else { return }
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(config.webPort)/")!)
    }

    @objc private func copyServiceURL() {
        guard webService.state.isRunning else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("http://127.0.0.1:\(config.webPort)/", forType: .string)
    }

    /// The Zotero plugin wants the bare host:port of the API server, not a URL with a path.
    @objc private func copyZoteroURL() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("http://127.0.0.1:\(config.zoteroPort)", forType: .string)
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
        openLogFile(config.logPath, label: "WebUI")
    }

    @objc private func openZoteroLog() {
        openLogFile(config.zoteroLogPath, label: "Zotero 服务")
    }

    private func openLogFile(_ path: String, label: String) {
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            presentAlert(
                title: "暂无\(label)日志",
                message: path + " 尚未创建。",
                style: .informational
            )
        }
    }

    @objc private func showEnvironment() {
        if !webService.isInstalled {
            presentInstallGuide()
            return
        }
        let version = versionText ?? "未知（可点“重新检查 pdf2zh_next”）"
        let zoteroLines: String
        if let zoteroService {
            let stateText: String
            switch zoteroService.state {
            case .running: stateText = "运行中"
            case .starting: stateText = "启动中"
            case .stopped: stateText = "已停止"
            case .problem(let reason): stateText = reason
            case .missing: stateText = "未安装"
            }
            zoteroLines = """
            Zotero 服务：\(stateText)（端口 \(config.zoteroPort)）
            Zotero 插件地址：http://127.0.0.1:\(config.zoteroPort)
            server.py：
            \(config.zoteroServerPath)
            解释器：
            \(config.zoteroPythonPath)
            日志：
            \(config.zoteroLogPath)
            """
        } else {
            zoteroLines = "Zotero 服务：未安装（未找到 server.py）"
        }

        presentAlert(
            title: "运行环境",
            message: """
            pdf2zh_next 版本：\(version)

            可执行文件：
            \(config.pdf2zhPath.isEmpty ? "（未找到）" : config.pdf2zhPath)

            WebUI 端口：\(config.webPort)
            工作目录：
            \(config.workingDirectory)

            \(zoteroLines)

            修改配置文件后，用菜单里的“重启”项即可生效：
            \(config.stateDirectory)/config.json
            """,
            style: .informational
        )
    }

    @objc private func recheckDependency() {
        let resolved = AppConfig.resolvePDF2ZHPath()
        guard !resolved.isEmpty else {
            presentInstallGuide()
            return
        }
        if resolved == config.pdf2zhPath {
            presentAlert(title: "已找到 pdf2zh_next", message: resolved, style: .informational)
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

    @objc private func restartWeb() {
        webService.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.startWeb(waitForPortFree: true)
        }
    }

    @objc private func restartZotero() {
        startZotero(waitForPortFree: true, restart: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: Starting / stopping

    private func startWeb(waitForPortFree: Bool) {
        guard webService.isInstalled else {
            updateMenu()
            return
        }
        if let failure = webService.start(waitForPortFree: waitForPortFree) {
            updateMenu()
            if failure == "port-in-use" {
                presentAlert(
                    title: "端口 \(config.webPort) 已被占用",
                    message: "另一个进程正在监听 127.0.0.1:\(config.webPort)，PDF2ZH Web 未启动。\n\n"
                        + "可用 `lsof -nP -iTCP:\(config.webPort) -sTCP:LISTEN` 查看占用者；"
                        + "若确认是残留进程，先 `kill -TERM <pid>`，必要时再 `kill -9 <pid>`。\n\n"
                        + "如果那是你自己在终端里跑的 pdf2zh_next，直接用那个就行，无需本 App。",
                    style: .warning
                )
            } else if failure != "未安装" {
                presentAlert(
                    title: "PDF2ZH Web 启动失败",
                    message: failure,
                    style: .warning
                )
            }
            return
        }
        updateMenu()
        startPolling()
    }

    private func startZotero(waitForPortFree: Bool, restart: Bool = false) {
        guard let zoteroService else {
            if restart {
                presentAlert(
                    title: "未安装 Zotero 服务",
                    message: zoteroInstallHint(),
                    style: .informational
                )
            }
            return
        }
        if restart { zoteroService.stop() }
        if let failure = zoteroService.start(waitForPortFree: waitForPortFree) {
            updateMenu()
            if failure == "port-in-use" {
                presentAlert(
                    title: "端口 \(config.zoteroPort) 已被占用",
                    message: "另一个进程正在监听 127.0.0.1:\(config.zoteroPort)，Zotero 服务未启动。\n\n"
                        + "若那是你自己在终端里跑的 server.py，直接用那个即可。",
                    style: .warning
                )
            } else {
                presentAlert(title: "Zotero 服务启动失败", message: failure, style: .warning)
            }
            return
        }
        updateMenu()
        startPolling()
    }

    private func zoteroInstallHint() -> String {
        """
        本 App 只托管 zotero-pdf2zh 的 server.py，不包含它。获取方式：

        1. 下载 Server
           https://github.com/guaguastandup/zotero-pdf2zh/releases/latest/download/server.zip

        2. 解压到 ~/zotero-pdf2zh（本 App 会在这个位置自动探测）

        3. 装 Server 自身依赖（Flask 等），已在同一目录建好 venv 时：
           cd ~/zotero-pdf2zh && ./.venv/bin/pip install -r server/requirements.txt

        完成后点菜单里的“重启 Zotero 服务”，或重新打开本 App。

        也可以直接指定路径：
        \(config.stateDirectory)/config.json
        { "zoteroServerPath": "/绝对路径/server.py" }
        """
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
            "_readme": "可选配置。优先级：环境变量 > 本文件 > 默认值。改完在菜单里点“重启”生效。",
            "_keys": [
                "pdf2zhPath": "pdf2zh_next 可执行文件的绝对路径，留空则自动探测",
                "workingDirectory": "服务的工作目录，不存在会自动创建",
                "webPort": "WebUI 端口，传给 pdf2zh_next --server-port",
                "outputDirectory": "菜单里“打开输出文件夹”指向的目录",
                "extraArguments": "追加到 pdf2zh_next 之后的参数，例如 [\"--debug\"]",
                "environment": "追加给服务的环境变量",
                "envFile": "KEY=VALUE 文件路径，不存在则忽略",
                "logPath": "WebUI 日志路径，追加写入，权限 0600",
                "logMaxBytes": "日志超过该字节数后轮转为 .log.1",
                "startupTimeoutSeconds": "等端口就绪的超时秒数",
                "autoOpenBrowser": "true 时服务就绪后自动打开浏览器（默认 false）",
                "zoteroServerPath": "zotero-pdf2zh 的 server.py 路径，留空则自动探测（默认 ~/zotero-pdf2zh/server/server.py）",
                "zoteroPythonPath": "运行 server.py 的解释器，通常是其同目录的 .venv/bin/python",
                "zoteroPort": "Zotero 插件要填的端口（默认 8890）",
                "zoteroLogPath": "Zotero 服务日志路径",
                "zoteroAutoStart": "true 时随 WebUI 一起启动 Zotero 服务（默认 true）",
                "zoteroProgressPollSeconds": "轮询 /api/tasks 的间隔秒数，用于图标进度（默认 2）",
                "checkUpdatesOnLaunch": "false 时不在启动时检查更新，仍可从菜单手动检查（默认 true）"
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
            "autoOpenBrowser": config.autoOpenBrowser,
            "zoteroServerPath": config.zoteroServerPath,
            "zoteroPythonPath": config.zoteroPythonPath,
            "zoteroPort": config.zoteroPort,
            "zoteroLogPath": config.zoteroLogPath,
            "zoteroAutoStart": config.zoteroAutoStart,
            "zoteroProgressPollSeconds": Int(config.zoteroProgressPollSeconds),
            "checkUpdatesOnLaunch": config.checkUpdatesOnLaunch
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
            environment["PATH"] = ManagedService.extendedPath(adding: path)
            process.environment = environment

            var text: String?
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                text = extractVersion(from: String(decoding: data, as: UTF8.self))
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
                switch self.webService.state {
                case .stopped, .missing: idle = true
                default: idle = false
                }
                if text == nil, idle, !self.config.pdf2zhPath.isEmpty {
                    self.updateMenu()
                }
            }
        }
    }

    // MARK: Polling

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        let webFailure = webService.poll()
        let zoteroFailure = zoteroService?.poll()

        if webFailure == "timeout" {
            presentAlert(
                title: "WebUI 启动超时",
                message: "等待 \(Int(config.readTimeoutSeconds)) 秒后端口 \(config.webPort) 仍未监听。\n\n"
                    + "常见原因：首次运行要下载 babeldoc 资产、代理干扰、pdf2zh_next 报错。\n"
                    + "日志：\(config.logPath)",
                style: .warning
            )
        }
        if zoteroFailure == "timeout" {
            presentAlert(
                title: "Zotero 服务启动超时",
                message: "等待 \(Int(zoteroService?.spec.readTimeout ?? 120)) 秒后端口 \(config.zoteroPort) 仍未监听。\n\n"
                    + "首次启动可能要创建翻译环境，会慢一些；也可能是 server.py 报错。\n"
                    + "日志：\(config.zoteroLogPath)",
                style: .warning
            )
        }

        let anyBusy = webService.state.isBusy || (zoteroService?.state.isBusy ?? false)
        if !anyBusy { stopPolling() }
    }

    // MARK: Locking

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
