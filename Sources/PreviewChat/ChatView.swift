import SwiftUI
import AppKit
import MarkdownUI

struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant, tool, system }
    let id = UUID()
    var role: Role
    var text: String
    var toolName: String? = nil
    var isStreaming: Bool = false
}

enum ModelChoice: String, CaseIterable, Identifiable {
    case haiku = "claude-haiku-4-5"
    case sonnet = "claude-sonnet-4-6"
    case opus = "claude-opus-4-7"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .haiku: return "Haiku"
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        }
    }
}

struct ChatView: View {
    let fileURL: URL
    @StateObject private var agent: ClaudeAgent
    @State private var messages: [ChatMessage] = []
    @State private var input: String = ""
    @State private var streamingIndex: Int? = nil
    @AppStorage("preferredModel") private var preferredModelRaw: String = ModelChoice.sonnet.rawValue
    @State private var showClearConfirm = false

    init(fileURL: URL) {
        self.fileURL = fileURL
        let saved = ChatStore.load(for: fileURL)
        let model = UserDefaults.standard.string(forKey: "preferredModel") ?? ModelChoice.sonnet.rawValue
        _agent = StateObject(wrappedValue: ClaudeAgent(
            fileURL: fileURL,
            model: model,
            resumeSessionId: saved?.sessionId
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty { emptyState }
                        ForEach(Array(messages.enumerated()), id: \.element.id) { idx, msg in
                            MessageRow(
                                message: msg,
                                onEdit: msg.role == .user && streamingIndex == nil
                                    ? { editMessage(at: idx) } : nil,
                                onRegenerate: msg.role == .assistant && streamingIndex == nil
                                    ? { regenerate(at: idx) } : nil
                            )
                            .id(msg.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .onChange(of: messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: messages) { _, _ in
                    guard streamingIndex != nil else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            Divider()
            inputBar
        }
        .background(Color(NSColor.textBackgroundColor).opacity(0.4))
        .onAppear {
            if let saved = ChatStore.load(for: fileURL) {
                messages = saved.messages.map {
                    ChatMessage(role: ChatMessage.Role(rawValue: $0.role) ?? .system,
                                text: $0.text, toolName: $0.toolName)
                }
            }
            agent.onEvent = { handleEvent($0) }
            agent.onSessionId = { _ in persist() }
            agent.start()
        }
        .onDisappear { persist(); agent.stop() }
        .confirmationDialog("チャット履歴を消去しますか？", isPresented: $showClearConfirm) {
            Button("消去", role: .destructive) { clearHistory() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このファイルに紐づく会話と Claude セッションを削除します。")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(.tint)
            Text(fileURL.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
            Spacer()
            Picker("", selection: Binding(
                get: { ModelChoice(rawValue: preferredModelRaw) ?? .sonnet },
                set: { preferredModelRaw = $0.rawValue; agent.setModel($0.rawValue) }
            )) {
                ForEach(ModelChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().frame(width: 90)
            Button { showClearConfirm = true } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("チャット履歴を消去")
            Circle().fill(agent.isRunning ? Color.green : Color.gray).frame(width: 8, height: 8)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("このファイルについて質問できます。").font(.subheadline).foregroundStyle(.secondary)
            Text("Enter で送信 / Shift+Enter で改行").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 20)
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ChatInputField(text: $input, onSubmit: send)
                .frame(minHeight: 38, maxHeight: 140)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
            Button(action: send) { Image(systemName: "paperplane.fill").frame(width: 28, height: 28) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
    }

    // MARK: - Actions

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(ChatMessage(role: .user, text: text))
        agent.send(userMessage: text)
        input = ""
        messages.append(ChatMessage(role: .assistant, text: "", isStreaming: true))
        streamingIndex = messages.count - 1
        persist()
    }

    /// Truncate messages from the given user message index, populate the input bar, reset session.
    private func editMessage(at index: Int) {
        guard messages.indices.contains(index), messages[index].role == .user else { return }
        let text = messages[index].text
        messages.removeSubrange(index...)
        agent.resetSession()
        agent.start()
        input = text
        persist()
    }

    /// Remove the assistant message at index and re-send the preceding user message.
    private func regenerate(at index: Int) {
        guard messages.indices.contains(index), messages[index].role == .assistant else { return }
        let userText = messages[0..<index].last(where: { $0.role == .user })?.text
        guard let userText else { return }
        messages.removeSubrange(index...)
        agent.resetSession()
        agent.start()
        agent.send(userMessage: userText)
        messages.append(ChatMessage(role: .assistant, text: "", isStreaming: true))
        streamingIndex = messages.count - 1
        persist()
    }

    private func clearHistory() {
        messages.removeAll()
        streamingIndex = nil
        ChatStore.clear(for: fileURL)
        agent.resetSession()
        agent.start()
    }

    // MARK: - Event handling

    private func handleEvent(_ event: ClaudeAgent.Event) {
        switch event {
        case .assistantText(let t):
            if let i = streamingIndex, messages.indices.contains(i) {
                messages[i].text += t
            } else {
                messages.append(ChatMessage(role: .assistant, text: t))
                streamingIndex = messages.count - 1
            }
        case .assistantTurnEnd:
            if let i = streamingIndex, messages.indices.contains(i) {
                if messages[i].text.isEmpty { messages.remove(at: i) }
                else { messages[i].isStreaming = false }
            }
            streamingIndex = nil
            persist()
        case .toolUse(let name, let input):
            messages.append(ChatMessage(role: .tool, text: summarize(toolName: name, input: input), toolName: name))
            streamingIndex = nil
        case .toolResult: break
        case .systemInfo: break
        case .error(let e):
            messages.append(ChatMessage(role: .system, text: "⚠️ \(e)"))
            persist()
        }
    }

    private func persist() {
        let saved = ChatStore.Saved(
            messages: messages.map { .init(role: $0.role.rawValue, text: $0.text, toolName: $0.toolName) },
            sessionId: agent.sessionId
        )
        ChatStore.save(saved, for: fileURL)
    }

    private func summarize(toolName: String, input: String) -> String {
        if let data = input.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            switch toolName {
            case "Read":  if let p = obj["file_path"] as? String { return "Read \(p)" }
            case "Write": if let p = obj["file_path"] as? String { return "Write \(p)" }
            case "Edit":  if let p = obj["file_path"] as? String { return "Edit \(p)" }
            case "Grep":  if let p = obj["pattern"]   as? String { return "Grep \(p)" }
            case "Glob":  if let p = obj["pattern"]   as? String { return "Glob \(p)" }
            case "Bash":  if let c = obj["command"]   as? String { return "Bash $ \(c)" }
            default: break
            }
        }
        return toolName
    }
}

// MARK: - Chat input

struct ChatInputField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.font = NSFont.systemFont(ofSize: 13)
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 2, height: 4)
        context.coordinator.textView = tv
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: ChatInputField
        weak var textView: NSTextView?
        init(_ parent: ChatInputField) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.shift) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            }
            return false
        }
    }
}

// MARK: - Message row

struct MessageRow: View {
    let message: ChatMessage
    var onEdit: (() -> Void)? = nil
    var onRegenerate: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .top, spacing: 6) {
                Spacer(minLength: 30)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.15)))
                if onEdit != nil {
                    VStack {
                        Spacer()
                        Button { onEdit?() } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .opacity(hovering ? 1 : 0)
                        .help("編集して再送信")
                    }
                }
            }
            .onHover { hovering = $0 }

        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.tint).frame(width: 16).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    renderedAssistant
                    if onRegenerate != nil && !message.isStreaming {
                        Button { onRegenerate?() } label: {
                            Label("再生成", systemImage: "arrow.clockwise")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .opacity(hovering ? 1 : 0)
                        .help("この回答を再生成")
                    }
                }
                Spacer(minLength: 0)
            }
            .onHover { hovering = $0 }

        case .tool:
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver").foregroundStyle(.secondary).font(.caption)
                Text(message.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))

        case .system:
            Text(message.text).font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var renderedAssistant: some View {
        if message.isStreaming {
            Text(message.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Markdown(message.text)
                .markdownTheme(.previewChat)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Markdown theme

extension Theme {
    static let previewChat = Theme()
        .text { FontSize(13); ForegroundColor(.primary) }
        .paragraph { $0.label.relativeLineSpacing(.em(0.18)).padding(.bottom, 6) }
        .heading1 { $0.label.markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.4)) }.padding(.top, 8).padding(.bottom, 4) }
        .heading2 { $0.label.markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.2)) }.padding(.top, 8).padding(.bottom, 4) }
        .heading3 { $0.label.markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.05)) }.padding(.top, 6).padding(.bottom, 2) }
        .strong { FontWeight(.semibold) }
        .code { FontFamilyVariant(.monospaced); FontSize(.em(0.92)); BackgroundColor(.secondary.opacity(0.15)) }
        .codeBlock { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle { FontFamilyVariant(.monospaced); FontSize(.em(0.9)) }
                    .padding(10)
            }
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.vertical, 4)
        }
        .listItem { $0.label.padding(.vertical, 1) }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                configuration.label.padding(.leading, 8).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
}
