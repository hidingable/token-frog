import SwiftUI
import VoyageCore

struct SaveRecoveryIssue: Identifiable {
    enum Problem {
        case corrupted(backupPath: String)
        case tooNew(version: Int)
        case unreadable(reason: String)
    }

    let file: SaveFile
    let problem: Problem
    var backups: [SaveBackup] = []
    var id: SaveFile { file }
}

/// Receives display values and actions only; it never reads or writes a save itself.
struct SaveRecoveryView: View {
    @Environment(\.l10n) private var l10n
    let issues: [SaveRecoveryIssue]
    var error: AppError?
    let onRestore: (SaveBackup) -> Void
    let onImport: (SaveFile) -> Void
    let onRestart: (SaveFile) -> Void
    let onRetry: () -> Void
    let onQuit: () -> Void
    @State private var confirmingRestart: SaveFile?

    private var needsUpdate: Bool {
        issues.contains { if case .tooNew = $0.problem { true } else { false } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(l10n("recovery.title")).font(Theme.pixel(24))
                Text(l10n("recovery.paused"))
                    .foregroundStyle(Theme.dusk)
                ForEach(issues) { issue in
                    VStack(alignment: .leading, spacing: 16) {
                        Text(issue.file.rawValue).font(Theme.pixel())
                        switch issue.problem {
                        case .corrupted(let path):
                            Text(l10n("recovery.corrupted"))
                            Text(path).foregroundStyle(Theme.dusk).textSelection(.enabled)
                            if !needsUpdate {
                                if issue.backups.isEmpty {
                                    Text(l10n("recovery.noBackups"))
                                } else {
                                    Text(l10n("recovery.choose")).font(Theme.pixel())
                                    ForEach(issue.backups) { backup in
                                        HStack(alignment: .top, spacing: 12) {
                                            Text(backup.url.lastPathComponent)
                                                .foregroundStyle(Theme.dusk).textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            action(l10n("action.restore")) { onRestore(backup) }
                                        }
                                    }
                                }
                                HStack(spacing: 12) {
                                    action(l10n("action.import")) { onImport(issue.file) }
                                    action(l10n("action.restart")) { confirmingRestart = issue.file }
                                }
                                if confirmingRestart == issue.file {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text(l10n("recovery.confirm", issue.file.rawValue))
                                        HStack(spacing: 12) {
                                            action(l10n("action.confirmRestart")) {
                                                confirmingRestart = nil
                                                onRestart(issue.file)
                                            }
                                            action(l10n("action.cancel")) { confirmingRestart = nil }
                                        }
                                    }
                                    .padding(16).pixelBorder(Theme.dusk)
                                }
                            }
                        case .tooNew(let version):
                            Text(l10n("recovery.tooNew", Format.grouped(version)))
                        case .unreadable(let reason):
                            Text(l10n("recovery.unreadable"))
                            Text(reason).foregroundStyle(Theme.dusk).textSelection(.enabled)
                            if !needsUpdate { action(l10n("action.retry")) { onRetry() } }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20).background(Theme.inkRaised).pixelBorder(Theme.dusk)
                }
                if let error {
                    Text(l10n.error(error)).textSelection(.enabled)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading).pixelBorder(Theme.paper)
                }
                action(l10n("action.quit")) { onQuit() }
            }
            .padding(32).frame(maxWidth: 900, alignment: .leading)
        }
        .font(.system(size: 14))
        .foregroundStyle(Theme.paper)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
        .preferredColorScheme(.dark)
    }

    private func action(_ title: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title).font(Theme.pixel()).foregroundStyle(Theme.paper)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.ink).pixelBorder(Theme.dusk)
        }
        .buttonStyle(.plain)
    }
}
