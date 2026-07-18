import AppKit
import Combine
import Foundation
import SwiftUI
import DreamSkinStudioCore

@main
@MainActor
struct CodexDreamSkinStudioApp: App {
    @StateObject private var controller = StudioAppController()

    var body: some Scene {
        WindowGroup("Dream Skin") {
            ContentView(model: controller.model, controller: controller)
                .task { await controller.launch() }
        }
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Dream Skin") { controller.quit() }
            }
        }
    }
}

@MainActor
final class StudioAppController: ObservableObject {
    let model: StudioModel

    private var subscriptions = Set<AnyCancellable>()
    private var reopenedWindow: NSWindow?
    private lazy var statusItem = StatusItemController(
        onShow: { [weak self] in self?.showWindow() },
        onApplyResume: { [weak self] in self?.requestPrimaryAction() },
        onPause: { [weak self] in self?.request(.pause) },
        onRestore: { [weak self] in self?.request(.restore) },
        onQuit: { [weak self] in self?.quit() }
    )

    init() {
        let adapterURL = Bundle.main.resourceURL!
            .appendingPathComponent("engine/scripts/studio-adapter-macos.sh")
        model = StudioModel(engine: EngineClient(adapterURL: adapterURL))
        model.$isBusy
            .sink { [weak self] in self?.statusItem.setBusy($0) }
            .store(in: &subscriptions)
    }

    func launch() async {
        _ = statusItem
        await model.launch()
    }

    func request(_ operation: EngineOperation) {
        showWindow()
        Task { await model.request(operation) }
    }

    func requestPrimaryAction() {
        let operation: EngineOperation
        if model.envelope?.state.install == .notInstalled {
            operation = .install
        } else if model.envelope?.state.session == .paused {
            operation = .resume
        } else {
            operation = .apply
        }
        request(operation)
    }

    func confirmPresentation(deleteUserThemes: Bool = false) {
        Task { await model.confirmPresentation(deleteUserThemes: deleteUserThemes) }
    }

    func diagnostics() {
        Task { await model.refresh(.status) }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first ?? makeWindow()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        if let reopenedWindow { return reopenedWindow }
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: ContentView(model: model, controller: self)
        ))
        window.title = "Dream Skin"
        window.minSize = NSSize(width: 500, height: 390)
        window.setContentSize(NSSize(width: 560, height: 440))
        reopenedWindow = window
        return window
    }
}
