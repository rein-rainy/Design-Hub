import AppKit
import SwiftUI

/// Bridges VersionStore.pendingMessage → CommitPanelController.
/// Uses a direct didSet callback instead of Combine/AsyncPublisher to avoid
/// the @Published willSet / RunLoop scheduling issue with Swift Concurrency.
@MainActor
final class AppCoordinator {

    func bind(to store: VersionStore) {
        store.onPendingMessageChanged = { [weak store] message in
            Task { @MainActor [weak store] in
                guard let store else { return }
                if let message {
                    let diff = store.layerDiff(for: message)
                    CommitPanelController.shared.show(
                        rootView: CommitPanelPlaceholder(
                            message: message,
                            layerDiff: diff,
                            onCommit: { msg in
                                Task { @MainActor in store.confirmCommit(commitMessage: msg) }
                            },
                            onCancel: {
                                Task { @MainActor in store.cancelPending() }
                            }
                        )
                    )
                } else {
                    CommitPanelController.shared.hide()
                }
            }
        }
    }
}
