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
    let issues: [SaveRecoveryIssue]
    var error: String?
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
                Text("存档需要处理").font(Theme.pixel(24))
                Text("旅程已暂停，后台扫描和保存已停止。")
                    .foregroundStyle(Theme.dusk)
                ForEach(issues) { issue in
                    VStack(alignment: .leading, spacing: 16) {
                        Text(issue.file.rawValue).font(Theme.pixel())
                        switch issue.problem {
                        case .corrupted(let path):
                            Text("无法解码旧存档，原文件已完整保留在：")
                            Text(path).foregroundStyle(Theme.dusk).textSelection(.enabled)
                            if !needsUpdate {
                                if issue.backups.isEmpty {
                                    Text("没有可恢复的备份")
                                } else {
                                    Text("选择备份恢复").font(Theme.pixel())
                                    ForEach(issue.backups) { backup in
                                        HStack(alignment: .top, spacing: 12) {
                                            Text(backup.url.lastPathComponent)
                                                .foregroundStyle(Theme.dusk).textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            action("恢复") { onRestore(backup) }
                                        }
                                    }
                                }
                                HStack(spacing: 12) {
                                    action("导入备份…") { onImport(issue.file) }
                                    action("重新开始") { confirmingRestart = issue.file }
                                }
                                if confirmingRestart == issue.file {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("确定重新开始 \(issue.file.rawValue) 吗？旧备份会保留。")
                                        HStack(spacing: 12) {
                                            action("确认重新开始") {
                                                confirmingRestart = nil
                                                onRestart(issue.file)
                                            }
                                            action("取消") { confirmingRestart = nil }
                                        }
                                    }
                                    .padding(16).pixelBorder(Theme.dusk)
                                }
                            }
                        case .tooNew(let version):
                            Text("这是版本 \(version) 的存档，需要更新应用后才能继续。原文件未作任何修改。")
                        case .unreadable(let reason):
                            Text("无法读取或迁移存档：")
                            Text(reason).foregroundStyle(Theme.dusk).textSelection(.enabled)
                            if !needsUpdate { action("重试") { onRetry() } }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20).background(Theme.inkRaised).pixelBorder(Theme.dusk)
                }
                if let error {
                    Text(error).textSelection(.enabled)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading).pixelBorder(Theme.paper)
                }
                action("退出") { onQuit() }
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
