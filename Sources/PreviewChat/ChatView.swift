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
    case haiku  = "claude-haiku-4-5"
    case sonnet = "claude-sonnet-4-6"
    case opus   = "claude-opus-4-7"
    var id: String { rawValue }
    var label: String {
        switch self { case .haiku: "Haiku"; case .sonnet: "Sonnet"; case .opus: "Opus" }
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
                    // VStack (not Lazy) avoids the blank-frame flash that LazyVStack
                    // produces when new items are inserted and scrolled into view.
                    VStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty { emptyState }
                        ForEach(messages) { msg in
                            MessageRow(
                                message: msg,
                                isStreaming: streamingIndex != nil,
                                onEdit: msg.role == .user && streamingIndex == nil
                                    ? { editMessage(id: msg.id) } : nil,
                                onRegenerate: msg.role == .assistant && streamingIndex == nil
                                    ? { regenerate(id: msg.id) } : nil
                            )
                            .id(msg.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                // Single scroll handler — no animation during streaming to prevent flicker.
                .onChange(of: messages) { _, _ in
                    if streamingIndex != nil {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    } else {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
            Divider()
            inputBar
        }
        .background(Color(NSColor.textBackgroundColor).opacity(0.4))
        .onAppear {
            if let saved = ChatStore.load(for: fileURL) {
                messages = saved.messages.map {
                    ChatMessage(role: .init(rawValue: $0.role) ?? .system,
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
        input = ""
        messages.append(ChatMessage(role: .user, text: text))
        messages.append(ChatMessage(role: .assistant, text: "", isStreaming: true))
        streamingIndex = messages.count - 1
        agent.send(userMessage: text)
        persist()
    }

    private func editMessage(id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }),
              messages[idx].role == .user else { return }
        let text = messages[idx].text
        messages.removeSubrange(idx...)
        agent.resetSession()
        agent.start()
        input = text
        persist()
    }

    private func regenerate(id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }),
              messages[idx].role == .assistant else { return }
        guard let userText = messages[0..<idx].last(where: { $0.role == .user })?.text else { return }
        messages.removeSubrange(idx...)
        agent.resetSession()
        agent.start()
        messages.append(ChatMessage(role: .assistant, text: "", isStreaming: true))
        streamingIndex = messages.count - 1
        agent.send(userMessage: userText)
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
                messages.append(ChatMessage(role: .assistant, text: t, isStreaming: true))
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
            messages.append(ChatMessage(role: .tool,
                                        text: summarize(toolName: name, input: input),
                                        toolName: name))
            streamingIndex = nil
        case .toolResult: break
        case .systemInfo: break
        case .error(let e):
            messages.append(ChatMessage(role: .system, text: "⚠️ \(e)"))
            persist()
        }
    }

    private func persist() {
        ChatStore.save(.init(
            messages: messages.map { .init(role: $0.role.rawValue, text: $0.text, toolName: $0.toolName) },
            sessionId: agent.sessionId
        ), for: fileURL)
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
        init(_ p: ChatInputField) { self.parent = p }
        func textDidChange(_ n: Notification) {
            (n.object as? NSTextView).map { parent.text = $0.string }
        }
        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSEvent.modifierFlags.contains(.shift) { tv.insertNewlineIgnoringFieldEditor(nil) }
            else { parent.onSubmit() }
            return true
        }
    }
}

// MARK: - Message row

struct MessageRow: View {
    let message: ChatMessage
    var isStreaming: Bool = false   // true when ANY message is streaming
    var onEdit: (() -> Void)? = nil
    var onRegenerate: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        switch message.role {
        case .user:
            // Entire VStack (bubble + action bar) is the hover zone.
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    Spacer(minLength: 30)
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(Color.accentColor.opacity(0.15)))
                }
                // Action bar — always in layout, opacity drives visibility.
                HStack(spacing: 6) {
                    Spacer()
                    actionButton(icon: "doc.on.doc", label: "コピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    }
                    if let onEdit {
                        actionButton(icon: "pencil", label: "編集して再送信", action: onEdit)
                    }
                }
                .opacity(hovering ? 1 : 0)
            }
            .contentShape(Rectangle())   // full-width hover target
            .onHover { hovering = $0 }

        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tint).frame(width: 16).padding(.top, 2)
                    renderedAssistant
                    Spacer(minLength: 0)
                }
                // Action bar
                if !message.isStreaming {
                    HStack(spacing: 6) {
                        Spacer().frame(width: 24)   // align under content
                        actionButton(icon: "doc.on.doc", label: "コピー") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        }
                        if let onRegenerate {
                            actionButton(icon: "arrow.clockwise", label: "再生成", action: onRegenerate)
                        }
                    }
                    .opacity(hovering ? 1 : 0)
                }
            }
            .contentShape(Rectangle())
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

    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.1)))
        }
        .buttonStyle(.borderless)
        .help(label)
    }
}

// MARK: - Markdown theme

extension Theme {
    static let previewChat = Theme()
        .text { FontSize(13); ForegroundColor(.primary) }
        .paragraph { $0.label.relativeLineSpacing(.em(0.18)).padding(.bottom, 6) }
        .heading1 { $0.label.markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.4)) }
            .padding(.top, 8).padding(.bottom, 4) }
        .heading2 { $0.label.markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.2)) }
            .padding(.top, 8).padding(.bottom, 4) }
        .heading3 { $0.label.markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.05)) }
            .padding(.top, 6).padding(.bottom, 2) }
        .strong { FontWeight(.semibold) }
        .code { FontFamilyVariant(.monospaced); FontSize(.em(0.92))
            BackgroundColor(.secondary.opacity(0.15)) }
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
