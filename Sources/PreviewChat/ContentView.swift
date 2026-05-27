import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let fileURL: URL

    /// Persisted chat sidebar width in points. 0 means "not set yet" → use 1/4 of window.
    @AppStorage("chatPaneWidth") private var storedChatWidth: Double = 0

    private let minViewer: CGFloat = 320
    private let minChat: CGFloat = 220
    private let maxChat: CGFloat = 700

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let defaultChat = max(minChat, min(maxChat, total * 0.25))
            let chatW = clamp(
                storedChatWidth == 0 ? defaultChat : CGFloat(storedChatWidth),
                lower: minChat,
                upper: min(maxChat, max(minChat, total - minViewer))
            )
            HStack(spacing: 0) {
                viewerPane
                    .frame(width: total - chatW - 1)
                SplitterHandle(
                    startWidth: chatW,
                    lower: minChat,
                    upper: min(maxChat, max(minChat, total - minViewer)),
                    onCommit: { newWidth in
                        storedChatWidth = Double(newWidth)
                    }
                )
                .frame(width: 1)
                ChatView(fileURL: fileURL)
                    .frame(width: chatW)
            }
        }
        .navigationTitle(fileURL.lastPathComponent)
    }

    @ViewBuilder
    private var viewerPane: some View {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "pdf" {
            PDFViewer(url: fileURL)
        } else if ["md", "markdown", "txt"].contains(ext) {
            MarkdownViewer(url: fileURL)
        } else if isImageExt(ext) {
            ImageViewer(url: fileURL)
        } else if (try? Data(contentsOf: fileURL)) != nil {
            MarkdownViewer(url: fileURL)
        } else {
            Text("Cannot open \(fileURL.lastPathComponent)").foregroundStyle(.secondary)
        }
    }

    private func isImageExt(_ ext: String) -> Bool {
        ["png","jpg","jpeg","gif","tiff","tif","bmp","heic","heif","webp"].contains(ext)
    }

    private func clamp(_ v: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        max(lower, min(upper, v))
    }
}

/// 1px hairline divider with a wider invisible hit area + resize cursor.
private struct SplitterHandle: View {
    let startWidth: CGFloat
    let lower: CGFloat
    let upper: CGFloat
    var onCommit: (CGFloat) -> Void
    @State private var hovering = false
    @State private var dragStartWidth: CGFloat? = nil

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())
            Rectangle()
                .fill(Color.secondary.opacity(hovering ? 0.5 : 0.25))
                .frame(width: 1)
        }
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let base = dragStartWidth ?? startWidth
                    if dragStartWidth == nil { dragStartWidth = base }
                    // Drag right (+dx) shrinks the right pane; drag left (-dx) grows it.
                    let target = base - value.translation.width
                    onCommit(max(lower, min(upper, target)))
                }
                .onEnded { _ in dragStartWidth = nil }
        )
    }
}
