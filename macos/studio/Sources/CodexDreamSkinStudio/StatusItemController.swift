import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let onShow: () -> Void
    private let onApplyResume: () -> Void
    private let onPause: () -> Void
    private let onRestore: () -> Void
    private let onQuit: () -> Void
    private var isBusy = false

    init(
        onShow: @escaping () -> Void,
        onApplyResume: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onRestore: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onShow = onShow
        self.onApplyResume = onApplyResume
        self.onPause = onPause
        self.onRestore = onRestore
        self.onQuit = onQuit
        super.init()

        statusItem.button?.image = NSImage(systemSymbolName: "paintpalette.fill", accessibilityDescription: "Dream Skin")
        rebuildMenu()
    }

    func setBusy(_ isBusy: Bool) {
        guard self.isBusy != isBusy else { return }
        self.isBusy = isBusy
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("Show Dream Skin", #selector(show), enabled: true))
        menu.addItem(.separator())
        menu.addItem(item("Apply / Resume", #selector(applyResume), enabled: !isBusy))
        menu.addItem(item("Pause", #selector(pause), enabled: !isBusy))
        menu.addItem(item("Complete Restore", #selector(restore), enabled: !isBusy))
        menu.addItem(.separator())
        menu.addItem(item("Quit Dream Skin", #selector(quit), enabled: true))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc private func show() { onShow() }
    @objc private func applyResume() { onApplyResume() }
    @objc private func pause() { onPause() }
    @objc private func restore() { onRestore() }
    @objc private func quit() { onQuit() }
}
