import AppKit
import SwiftUI

final class CommitPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.animationBehavior = .documentWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
