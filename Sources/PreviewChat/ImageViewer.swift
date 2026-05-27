import SwiftUI
import AppKit

/// Image viewer with trackpad pinch-to-zoom and pan.
struct ImageViewer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 20.0
        scroll.magnification = 1.0
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = .windowBackgroundColor

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = NSImage(contentsOf: url)
        imageView.frame = NSRect(origin: .zero, size: imageView.image?.size ?? NSSize(width: 400, height: 300))
        scroll.documentView = imageView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let iv = scroll.documentView as? NSImageView {
            iv.image = NSImage(contentsOf: url)
            iv.frame = NSRect(origin: .zero, size: iv.image?.size ?? NSSize(width: 400, height: 300))
        }
    }
}
