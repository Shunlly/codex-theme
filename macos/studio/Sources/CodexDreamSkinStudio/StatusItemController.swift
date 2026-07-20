import AppKit
import DreamSkinStudioCore

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let onShow: () -> Void
    private let onStatus: () -> Void
    private let onApplyResume: () -> Void
    private let onPauseResume: () -> Void
    private let onRestore: () -> Void
    private let onQuit: () -> Void
    private var menuState = StudioMenuState(envelope: nil, isBusy: false, presentation: nil)

    init(
        onShow: @escaping () -> Void,
        onStatus: @escaping () -> Void,
        onApplyResume: @escaping () -> Void,
        onPauseResume: @escaping () -> Void,
        onRestore: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onShow = onShow
        self.onStatus = onStatus
        self.onApplyResume = onApplyResume
        self.onPauseResume = onPauseResume
        self.onRestore = onRestore
        self.onQuit = onQuit
        super.init()

        statusItem.button?.image = NSImage(systemSymbolName: "paintpalette.fill", accessibilityDescription: "Dream Skin")
        rebuildMenu()
    }

    func update(_ menuState: StudioMenuState) {
        guard self.menuState != menuState else { return }
        self.menuState = menuState
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("Show Dream Skin", #selector(show), enabled: true))
        menu.addItem(item("Check Status", #selector(status), enabled: menuState.statusEnabled))
        menu.addItem(.separator())
        menu.addItem(item(actionTitle(menuState.primaryOperation, fallback: "Apply / Resume"), #selector(applyResume), enabled: menuState.primaryEnabled))
        menu.addItem(item(actionTitle(menuState.pauseResumeOperation, fallback: "Pause / Resume"), #selector(pauseResume), enabled: menuState.pauseResumeEnabled))
        menu.addItem(item("Complete Restore", #selector(restore), enabled: menuState.restoreEnabled))
        menu.addItem(.separator())
        menu.addItem(item("Quit Dream Skin", #selector(quit), enabled: menuState.allowsTermination))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc private func show() { onShow() }
    @objc private func status() { onStatus() }
    @objc private func applyResume() { onApplyResume() }
    @objc private func pauseResume() { onPauseResume() }
    @objc private func restore() { onRestore() }
    @objc private func quit() { onQuit() }

    private func actionTitle(_ operation: EngineOperation?, fallback: String) -> String {
        switch operation {
        case .install: "Install Dream Skin"
        case .apply: "Apply Dream Skin"
        case .pause: "Pause Dream Skin"
        case .resume: "Resume Dream Skin"
        default: fallback
        }
    }
}
