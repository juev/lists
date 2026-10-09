import AppKit
import SwiftUI

/// The backups of this Mac in the settings (R88–R90): the schedule, the number
/// to keep, the backups themselves and restoring from one of them or from a file.
struct BackupsSection: View {
    @Environment(AppModel.self) private var model

    /// What is to be restored: a backup of the list, or a file picked outside the app.
    private struct Restore { let path: String; let label: String }

    @State private var settings = BackupSettings(everyHours: 24, keep: 5)
    @State private var backups: [Backup] = []
    @State private var restoring: Restore?
    @State private var busy = false
    @State private var message: String?

    private static let sizes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var synced: Bool {
        guard let config = try? model.store?.syncConfig() else { return false }
        return config != .off
    }

    var body: some View {
        Section(L("Backups")) {
            Picker(L("Create backups"), selection: Binding(
                get: { settings.everyHours },
                set: { save(BackupSettings(everyHours: $0, keep: settings.keep)) })) {
                Text(L("Do not create")).tag(UInt32(0))
                Text(L("Every 24 hours")).tag(UInt32(24))
                Text(L("Every 48 hours")).tag(UInt32(48))
            }
            Picker(L("Keep at most"), selection: Binding(
                get: { settings.keep },
                set: { save(BackupSettings(everyHours: settings.everyHours, keep: $0)) })) {
                ForEach([UInt32(5), 10, 20, 30], id: \.self) { Text("\($0)").tag($0) }
            }
            Text(L("A backup holds the tasks, the lists and the attachments that are on this Mac. Backups are kept in the data folder of the app: save a copy elsewhere from time to time."))
                .font(AppFont.style(.caption)).foregroundStyle(.secondary)
            HStack {
                Button(L("Create Backup Now")) { run { _ = try $0.createBackup() } }
                Button(L("Restore from File…"), action: chooseFile)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            .disabled(busy)
            if let message {
                Text(message).font(AppFont.style(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if backups.isEmpty {
                Text(L("No backups yet.")).foregroundStyle(.secondary)
            }
            ForEach(backups, id: \.name) { backup in
                HStack {
                    Text(Moment.label(backup.created))
                    Spacer()
                    Text(Self.sizes.string(fromByteCount: Int64(backup.size))).foregroundStyle(.secondary)
                    Menu {
                        Button(L("Restore…")) { restoring = Restore(path: backup.path, label: Moment.label(backup.created)) }
                        Button(L("Save a Copy…")) { saveCopy(backup) }
                        Button(L("Delete"), role: .destructive) { run { try $0.deleteBackup(name: backup.name) } }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(busy)
                    .accessibilityLabel(L("Actions for the backup"))
                }
            }
        }
        .onAppear(perform: load)
        .confirmationDialog(
            L("Replace everything with the backup?"),
            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
            titleVisibility: .visible,
            presenting: restoring
        ) { what in
            // S40: with sync on, what the storage holds has to be settled in the same step.
            if synced {
                Button(L("Restore and merge with the storage"), role: .destructive) { restore(what, overStorage: false) }
                Button(L("Restore and replace the data of the storage"), role: .destructive) { restore(what, overStorage: true) }
            } else {
                Button(L("Restore"), role: .destructive) { restore(what, overStorage: false) }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: { what in
            Text(L("All tasks, lists and filters on this Mac are replaced with what the backup %@ holds. The present state is saved as a backup first.", what.label))
        }
    }

    private func load() {
        guard let store = model.store else { return }
        settings = (try? store.backupSettings()) ?? settings
        backups = (try? store.backups()) ?? []
    }

    private func save(_ changed: BackupSettings) {
        do {
            try model.store?.setBackupSettings(settings: changed)
            settings = changed
        } catch {
            message = describe(error)
        }
    }

    /// Runs `work` off the main thread, then shows the backups as they are and `done` or the error.
    private func run(done: String? = nil, then: @escaping () -> Void = {}, _ work: @escaping @Sendable (Store) throws -> Void) {
        guard let store = model.store else { return }
        busy = true
        Task {
            let result = await Task.detached { Result { try work(store) } }.value
            busy = false
            switch result {
            case .success:
                message = done
                then()
            case .failure(let error): message = describe(error)
            }
            load()
        }
    }

    private func restore(_ what: Restore, overStorage: Bool) {
        let path = what.path
        run(done: L("Restored from %@.", what.label), then: {
            // The lists and the next sync start from the restored data.
            model.reload()
            model.syncNow()
        }) { try $0.restoreBackup(path: path, overStorage: overStorage) }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        restoring = Restore(path: picked.path, label: picked.lastPathComponent)
    }

    private func saveCopy(_ backup: Backup) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = backup.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let source = URL(fileURLWithPath: backup.path)
        run(done: L("The copy is saved.")) { _ in
            // The panel has asked about replacing a file that is there.
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
        }
    }
}
