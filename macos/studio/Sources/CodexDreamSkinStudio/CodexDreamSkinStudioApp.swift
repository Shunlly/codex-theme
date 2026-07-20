import AppKit
import Combine
import Foundation
import SwiftUI
import DreamSkinStudioCore

@main
@MainActor
struct CodexDreamSkinStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppController.self) private var controller

    var body: some Scene {
        WindowGroup("Dream Skin") {
            ContentView(model: controller.model, controller: controller)
                .task { await controller.launch() }
        }
        .commands {
            StudioCommands(model: controller.model, onQuit: controller.quit)
        }
    }
}

@MainActor
private struct StudioCommands: Commands {
    @ObservedObject var model: StudioModel
    let onQuit: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .appTermination) {
            Button("Quit Dream Skin", action: onQuit)
                .disabled(!model.menuState.allowsTermination)
        }
    }
}

@MainActor
final class StudioAppController: NSObject, ObservableObject, NSApplicationDelegate {
    let model: StudioModel

    private var subscriptions = Set<AnyCancellable>()
    private var reopenedWindow: NSWindow?
    private lazy var statusItem = StatusItemController(
        onShow: { [weak self] in self?.showWindow() },
        onApplyResume: { [weak self] in self?.requestPrimaryAction() },
        onPauseResume: { [weak self] in self?.requestPauseResumeAction() },
        onRestore: { [weak self] in self?.request(.restore) },
        onQuit: { [weak self] in self?.quit() }
    )

    override init() {
        let adapterURL = Bundle.main.resourceURL!
            .appendingPathComponent("engine/scripts/studio-adapter-macos.sh")
        model = StudioModel(engine: EngineClient(adapterURL: adapterURL))
        super.init()
        Publishers.CombineLatest3(model.$envelope, model.$isBusy, model.$presentation)
            .map(StudioMenuState.init)
            .sink { [weak self] in self?.statusItem.update($0) }
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
        guard let operation = model.primaryOperation else { return }
        request(operation)
    }

    func requestPauseResumeAction() {
        guard let operation = model.pauseResumeOperation else { return }
        request(operation)
    }

    func confirmPresentation(deleteUserThemes: Bool = false) {
        Task { await model.confirmPresentation(deleteUserThemes: deleteUserThemes) }
    }

    func diagnostics() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexDreamSkinStudio", isDirectory: true)
        guard NSWorkspace.shared.open(directory) else {
            let alert = NSAlert()
            alert.messageText = "Diagnostics could not be opened."
            alert.informativeText = "Try again, or reinstall Dream Skin if the problem continues."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.menuState.allowsTermination ? .terminateNow : .terminateCancel
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
