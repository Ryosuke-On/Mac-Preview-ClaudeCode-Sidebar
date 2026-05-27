import SwiftUI
import PDFKit
import AppKit

struct PDFViewer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.pageShadowsEnabled = true
        // Native trackpad pinch-to-zoom works automatically.
        // Native text selection enables system Services (translate, lookup) via right-click & menu bar.
        v.document = PDFDocument(url: url)
        // Search support via standard Find toolbar (cmd-F) is provided by PDFView automatically
        // through the responder chain when window's firstResponder is PDFView.
        return v
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}
