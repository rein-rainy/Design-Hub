import AppKit
import SwiftUI

@MainActor
final class CommitPanelController {
    static let shared = CommitPanelController()

    private var panel: CommitPanel?

    private init() {}

    func show(rootView: some View) {
        if panel == nil {
            panel = CommitPanel()
        }
        guard let panel else { return }

        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting

        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens[0]
        let sf = screen.frame
        let pf = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: sf.midX - pf.width / 2,
            y: sf.midY - pf.height / 2
        ))

        panel.alphaValue = 0
        panel.orderFront(nil)
        panel.makeKey()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }
}
