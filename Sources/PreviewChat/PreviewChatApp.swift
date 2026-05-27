import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct PreviewChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup(id: "viewer", for: URL.self) { $url in
            if let url = url {
                ContentView(fileURL: url)
                    .frame(minWidth: 900, minHeight: 600)
            } else {
                WelcomeView()
                    .frame(minWidth: 600, minHeight: 400)
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { openFile() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .image, .plainText,
                                     UTType(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            NSApp.sendAction(#selector(AppDelegate.openURL(_:)), to: nil, from: url as Any)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            openWindow(for: url)
        }
    }

    @objc func openURL(_ sender: Any?) {
        if let url = sender as? URL { openWindow(for: url) }
    }

    private func openWindow(for url: URL) {
        // Use OpenWindowAction via environment is not directly accessible from AppDelegate;
        // instead, post a notification ContentView root listens to. Simpler: open via NSWorkspace
        // is wrong because that re-opens us. Use SwiftUI's openWindow through a helper window.
        let controller = NSWindowController(window: makeWindow(for: url))
        controller.showWindow(nil)
    }

    private func makeWindow(for url: URL) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = false
        window.title = url.lastPathComponent
        window.center()
        let root = ContentView(fileURL: url)
        window.contentView = NSHostingView(rootView: root)
        window.isReleasedWhenClosed = false
        return window
    }
}

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("PreviewChat")
                .font(.title)
            Text("Open a PDF, image, or markdown file (⌘O)")
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }
}
