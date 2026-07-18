import SwiftUI
import DreamSkinStudioCore

struct ContentView: View {
    @ObservedObject var model: StudioModel
    let controller: StudioAppController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            statusArea
            primaryAction
            Divider()
            secondaryActions
            Divider()
            diagnostics
        }
        .padding(24)
        .frame(minWidth: 500, minHeight: 390, alignment: .topLeading)
        .sheet(isPresented: presentationBinding) {
            if let presentation = model.presentation {
                ConfirmationSheet(
                    presentation: presentation,
                    confirm: { controller.confirmPresentation(deleteUserThemes: $0) },
                    cancel: model.cancelPresentation
                )
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(statusColor)
                .frame(width: 5)
                .accessibilityHidden(true)
            Image(systemName: "paintpalette.fill")
                .font(.title2)
                .foregroundStyle(.teal)
                .accessibilityLabel("Dream Skin")
            VStack(alignment: .leading, spacing: 3) {
                Text("Dream Skin").font(.title2.weight(.semibold))
                Text(statusTitle).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isVerified {
                Label("Verified", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color(red: 0.18, green: 0.49, blue: 0.31))
            }
        }
    }

    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.envelope?.state.themeName ?? "No theme selected")
                .font(.headline)
            Text(statusMessage)
                .foregroundStyle(.secondary)
            if let progress = model.progress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progressText(progress))
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private var primaryAction: some View {
        Button(action: { controller.request(primaryOperation) }) {
            Label(primaryTitle, systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(model.isBusy || !canPerformPrimary)
        .accessibilityLabel(primaryTitle)
        .help(primaryTitle)
    }

    private var secondaryActions: some View {
        HStack(spacing: 12) {
            Button(action: { controller.request(pauseResumeOperation) }) {
                Label(pauseResumeTitle, systemImage: pauseResumeOperation == .pause ? "pause.fill" : "play.fill")
            }
            .disabled(model.isBusy || !canPerform(pauseResumeOperation))
            .accessibilityLabel(pauseResumeTitle)
            .help(pauseResumeTitle)

            Spacer()

            Button(role: .destructive, action: { controller.request(.restore) }) {
                Label("Complete Restore", systemImage: "arrow.counterclockwise")
            }
            .disabled(model.isBusy || !canRestore)
            .accessibilityLabel("Complete Restore")
            .help("Complete Restore")
        }
    }

    private var diagnostics: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Diagnostics").font(.headline)
                Text(model.clientError?.localizedDescription ?? model.envelope?.error?.message ?? "Check the current Dream Skin status.")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button(role: .destructive, action: { controller.request(.uninstall) }) {
                Label("Remove Dream Skin", systemImage: "trash")
            }
            .disabled(model.isBusy || !canPerform(.uninstall))
            .accessibilityLabel("Remove Dream Skin")
            .help("Remove Dream Skin")

            Button(action: controller.diagnostics) {
                Image(systemName: "wrench.and.screwdriver")
            }
            .disabled(model.isBusy)
            .accessibilityLabel("Check diagnostics")
            .help("Check diagnostics")
        }
    }

    private var presentationBinding: Binding<Bool> {
        Binding(
            get: { model.presentation != nil },
            set: { if !$0 { model.cancelPresentation() } }
        )
    }

    private var state: EngineState? { model.envelope?.state }

    private var primaryOperation: EngineOperation {
        if state?.install == .notInstalled { return .install }
        if state?.session == .paused { return .resume }
        return .apply
    }

    private var primaryTitle: String {
        switch primaryOperation {
        case .install: "Install Dream Skin"
        case .resume: "Resume Dream Skin"
        default: "Apply Dream Skin"
        }
    }

    private var pauseResumeOperation: EngineOperation {
        state?.session == .paused ? .resume : .pause
    }

    private var pauseResumeTitle: String {
        pauseResumeOperation == .pause ? "Pause Dream Skin" : "Resume Dream Skin"
    }

    private var canPerformPrimary: Bool { canPerform(primaryOperation) }

    private var canRestore: Bool {
        canPerform(.restore) || model.envelope?.error?.recoveryActions.contains(.restore) == true
    }

    private func canPerform(_ operation: EngineOperation) -> Bool {
        guard let state else { return false }
        return switch operation {
        case .install: state.availableActions.contains(.install)
        case .apply: state.availableActions.contains(.apply)
        case .pause: state.availableActions.contains(.pause)
        case .resume: state.availableActions.contains(.resume)
        case .restore: state.availableActions.contains(.restore)
        case .verify: state.availableActions.contains(.verify)
        case .uninstall: state.availableActions.contains(.uninstall)
        case .preflight, .status: false
        }
    }

    private var statusTitle: String {
        if model.isBusy { return "Working" }
        if model.clientError != nil || model.envelope?.ok == false { return "Needs attention" }
        if model.isVerified { return "Verified" }
        if state?.session == .paused { return "Paused" }
        if state?.session == .active { return "Active" }
        return "Ready"
    }

    private var statusMessage: String {
        if let error = model.clientError { return error.localizedDescription }
        if let message = model.envelope?.error?.message { return message }
        switch state?.session {
        case .active: return model.isVerified ? "Your theme is active and verified." : "Your theme is active."
        case .paused: return "Dream Skin is paused."
        case .stale: return "Dream Skin needs attention before it can continue."
        default: return "Choose an action to get started."
        }
    }

    private var statusColor: Color {
        if model.isBusy { return .teal }
        if model.clientError != nil || model.envelope?.ok == false { return Color(red: 0.71, green: 0.42, blue: 0) }
        if model.isVerified || state?.session == .active { return Color(red: 0.18, green: 0.49, blue: 0.31) }
        if state?.session == .paused { return .secondary }
        return .secondary
    }

    private func progressText(_ progress: EngineProgress) -> String {
        switch progress {
        case .checking: "Checking Dream Skin"
        case .preparing: "Preparing Dream Skin"
        case .installing: "Installing Dream Skin"
        case .launching: "Launching Codex"
        case .connecting: "Connecting"
        case .applying: "Applying Dream Skin"
        case .verifying: "Verifying Dream Skin"
        case .pausing: "Pausing Dream Skin"
        case .restoring: "Restoring Codex"
        case .uninstalling: "Removing Dream Skin"
        }
    }
}

private struct ConfirmationSheet: View {
    let presentation: StudioPresentation
    let confirm: (Bool) -> Void
    let cancel: () -> Void
    @State private var deleteUserThemes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title2.weight(.semibold))
            Text(message).foregroundStyle(.secondary)
            if case .uninstallConfirmation = presentation {
                Toggle("同时删除我的主题", isOn: $deleteUserThemes)
                    .toggleStyle(.checkbox)
                Text("删除主题后无法恢复。")
                    .font(.footnote)
                    .foregroundStyle(Color(red: 0.73, green: 0.23, blue: 0.23))
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button(confirmTitle, role: isDestructive ? .destructive : nil) {
                    confirm(deleteUserThemes)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var title: String {
        switch presentation {
        case .restartConfirmation: "Restart Codex?"
        case .forceStopConfirmation: "Force quit Codex?"
        case .restoreConfirmation: "Complete restore?"
        case .uninstallConfirmation: "Remove Dream Skin?"
        }
    }

    private var message: String {
        switch presentation {
        case .restartConfirmation: "Codex needs to restart before Dream Skin can continue."
        case .forceStopConfirmation: "Codex did not close normally. Continuing will force quit it."
        case .restoreConfirmation: "This restores Codex to its standard appearance."
        case .uninstallConfirmation: "This restores Codex and removes Dream Skin from this Mac."
        }
    }

    private var confirmTitle: String {
        switch presentation {
        case .restartConfirmation: "Restart and Continue"
        case .forceStopConfirmation: "Force Quit and Continue"
        case .restoreConfirmation: "Restore"
        case .uninstallConfirmation: "Remove"
        }
    }

    private var isDestructive: Bool {
        switch presentation {
        case .forceStopConfirmation, .restoreConfirmation, .uninstallConfirmation: true
        case .restartConfirmation: false
        }
    }
}
