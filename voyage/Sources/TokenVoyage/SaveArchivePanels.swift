import AppKit
import UniformTypeIdentifiers
import VoyageCore

@MainActor
enum SaveArchivePanels {
    static func exportSave(model: AppModel) {
        let panel = NSSavePanel()
        panel.title = model.l10n("settings.export")
        panel.nameFieldStringValue = SaveStore.suggestedArchiveFilename()
        panel.allowedContentTypes = [.json]
        panel.message = model.l10n("settings.exportHint")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.exportSave(to: url) }
    }

    static func importSave(model: AppModel, legacyFile: SaveFile? = nil) {
        let panel = NSOpenPanel()
        panel.title = legacyFile.map { model.l10n("backup.choose", $0.rawValue) } ?? model.l10n("settings.import")
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let candidate = try model.validateImport(at: url)
            let alert = NSAlert()
            alert.messageText = model.l10n("archive.confirmTitle")
            alert.informativeText = model.l10n("archive.confirmBody")
            alert.addButton(withTitle: model.l10n("settings.import"))
            alert.addButton(withTitle: model.l10n("action.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Task { await model.importSave(candidate) }
        } catch {
            // The recovery page also accepts the original individual-file backups.
            if let legacyFile, error as? SaveArchiveError == .invalidArchive {
                model.restoreSave(SaveBackup(file: legacyFile, url: url))
            } else {
                model.reportImportError(error)
            }
        }
    }
}

extension L10n {
    func archiveError(_ error: any Error) -> String {
        guard let error = error as? SaveArchiveError else { return self("archive.writeFailed") }
        switch error {
        case .tooLarge: return self("archive.tooLarge")
        case .unreadable: return self("archive.unreadable")
        case .invalidArchive: return self("archive.invalid")
        case .unsupportedFormat: return self("archive.unsupportedFormat")
        case .newerSave: return self("archive.newerSave")
        case .invalidSave(let file): return self("archive.invalidSave", file.rawValue)
        case .unavailable: return self("archive.unavailable")
        case .writeFailed: return self("archive.writeFailed")
        case .recoveryRequired: return self("archive.recoveryRequired")
        }
    }
}
