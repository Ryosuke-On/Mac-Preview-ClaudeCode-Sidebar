import Foundation

/// Wraps the `claude` CLI in stream-json mode as a long-lived subprocess.
/// Sends user messages on stdin (one JSON per line), parses stream events on stdout.
@MainActor
final class ClaudeAgent: ObservableObject {
    enum Event {
        case assistantText(String)         // streaming text delta from assistant
        case assistantTurnEnd               // assistant message complete
        case toolUse(name: String, input: String)
        case toolResult(String)
        case systemInfo(String)
        case error(String)
    }

    @Published var isRunning: Bool = false
    @Published var lastError: String?
    @Published private(set) var sessionId: String?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()

    private let workingDir: URL
    private let initialContext: String
    private(set) var model: String
    private var resumeSessionId: String?
    var onEvent: ((Event) -> Void)?
    var onSessionId: ((String) -> Void)?

    init(fileURL: URL, model: String, resumeSessionId: String? = nil) {
        self.workingDir = fileURL.deletingLastPathComponent()
        self.model = model
        self.resumeSessionId = resumeSessionId
        self.sessionId = resumeSessionId
        self.initialContext = """
        You are helping the user understand a specific file they are currently viewing.
        File path: \(fileURL.path)
        Working directory: \(fileURL.deletingLastPathComponent().path)
        When asked about "this file" or "the document", refer to that file.
        You can read other files in the working directory, run searches, and write markdown summary files when asked.

        Formatting rules — VERY IMPORTANT, the UI renders your replies as Markdown:
        - Respond in the same language as the user.
        - Separate paragraphs with a blank line.
        - Use `## ` for section headings when the answer has multiple parts.
        - Use `- ` bullet lists for enumerations; never inline a list as a long sentence.
        - Use `**bold**` sparingly for key terms only, not whole sentences.
        - Use fenced code blocks ``` for code, formulas, and file paths longer than a few words.
        - Use inline `code` for short identifiers, file names, math symbols.
        - Keep paragraphs short (2–4 sentences max).
        """
    }

    func start() {
        guard process == nil else { return }
        let p = Process()
        let claudePath = findClaudeBinary()
        p.executableURL = URL(fileURLWithPath: claudePath)
        var args: [String] = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--append-system-prompt", initialContext,
            "--permission-mode", "acceptEdits",
            "--model", model,
        ]
        if let resume = resumeSessionId {
            args.append(contentsOf: ["--resume", resume])
        }
        p.arguments = args
        p.currentDirectoryURL = workingDir
        // Build environment: start from the GUI process env, ensure PATH includes
        // common locations for `node` / `claude`, then layer optional user config.
        var env = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
        env["PATH"] = (env["PATH"].map { "\(extraPath):\($0)" }) ?? extraPath
        env["FORCE_COLOR"] = "0"
        // Strip variables that might leak from a parent Claude Code session and
        // cause auth confusion. We want claude to use ~/.claude.json OAuth creds
        // (or our config file's API key) — not whatever happens to be in env.
        for k in ["CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID",
                  "CLAUDE_CODE_EXECPATH", "CLAUDECODE",
                  "CLAUDE_AGENT_SDK_VERSION"] {
            env.removeValue(forKey: k)
        }
        if let cfg = loadUserConfig() {
            if let key = cfg.anthropicApiKey { env["ANTHROPIC_API_KEY"] = key }
            if let url = cfg.anthropicBaseUrl { env["ANTHROPIC_BASE_URL"] = url }
        }
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.handleStdout(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let s = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    self?.lastError = s
                    self?.onEvent?(.error(s))
                }
            }
        }

        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isRunning = false
                self?.process = nil
            }
        }

        do {
            try p.run()
            self.process = p
            self.isRunning = true
            onEvent?(.systemInfo("Claude session started in \(workingDir.path)"))
        } catch {
            onEvent?(.error("Failed to launch claude: \(error.localizedDescription)"))
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        isRunning = false
    }

    /// Restart the underlying claude subprocess with a new model, preserving the
    /// session id so context is retained via `--resume`.
    func setModel(_ newModel: String) {
        guard newModel != model else { return }
        self.model = newModel
        self.resumeSessionId = sessionId
        stop()
        start()
    }

    /// Forget the current session; next start() spawns a fresh conversation.
    func resetSession() {
        stop()
        self.resumeSessionId = nil
        self.sessionId = nil
    }

    func send(userMessage: String) {
        if process == nil { start() }
        guard let stdin = stdinPipe?.fileHandleForWriting else { return }
        let payload: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": userMessage
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
        var line = data
        line.append(0x0A)  // newline
        try? stdin.write(contentsOf: line)
    }

    // MARK: - stdout parsing

    private func handleStdout(_ chunk: Data) {
        stdoutBuffer.append(chunk)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: 0..<nl)
            stdoutBuffer.removeSubrange(0...nl)
            if lineData.isEmpty { continue }
            parseEventLine(lineData)
        }
    }

    private func parseEventLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard let type = obj["type"] as? String else { return }

        switch type {
        case "system":
            if let sub = obj["subtype"] as? String, sub == "init" {
                if let sid = obj["session_id"] as? String {
                    self.sessionId = sid
                    onSessionId?(sid)
                }
                onEvent?(.systemInfo("ready"))
            }
        case "assistant":
            if let msg = obj["message"] as? [String: Any],
               let content = msg["content"] as? [[String: Any]] {
                for block in content {
                    if let btype = block["type"] as? String {
                        if btype == "text", let t = block["text"] as? String {
                            onEvent?(.assistantText(t))
                        } else if btype == "tool_use" {
                            let name = block["name"] as? String ?? "tool"
                            let inputStr: String
                            if let input = block["input"] {
                                let d = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted])
                                inputStr = d.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                            } else { inputStr = "" }
                            onEvent?(.toolUse(name: name, input: inputStr))
                        }
                    }
                }
                onEvent?(.assistantTurnEnd)
            }
        case "user":
            // tool_result echoed back as user message containing tool_result blocks
            if let msg = obj["message"] as? [String: Any],
               let content = msg["content"] as? [[String: Any]] {
                for block in content {
                    if (block["type"] as? String) == "tool_result" {
                        let c = block["content"]
                        let s: String
                        if let str = c as? String { s = str }
                        else if let arr = c as? [[String: Any]] {
                            s = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                        } else { s = "" }
                        onEvent?(.toolResult(s))
                    }
                }
            }
        case "result":
            if (obj["is_error"] as? Bool) == true,
               let msg = obj["result"] as? String {
                let lower = msg.lowercased()
                if lower.contains("not logged in") || lower.contains("authentication") || lower.contains("401") {
                    onEvent?(.error("認証されていません。ターミナルで `claude /login` を一度実行するか、 ~/.config/previewchat/config.json に `{\"anthropicApiKey\": \"sk-ant-...\"}` を置いてください。"))
                } else {
                    onEvent?(.error(msg))
                }
            }
        default:
            break
        }
    }

    private struct UserConfig: Decodable {
        let anthropicApiKey: String?
        let anthropicBaseUrl: String?
    }

    private func loadUserConfig() -> UserConfig? {
        let path = "\(NSHomeDirectory())/.config/previewchat/config.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(UserConfig.self, from: data)
    }

    private func findClaudeBinary() -> String {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        // Last resort: rely on PATH lookup via /usr/bin/env
        return "/usr/bin/env"
    }
}
