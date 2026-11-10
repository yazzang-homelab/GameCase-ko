//
//  LCSaveDataTransfer.swift
//  LiveContainerSwiftUI
//
//  存档导入 / 导出（每游戏设置页「存档」组）。
//
//  存档落点结论（2026-11-06 源码实证，非猜测）：nxnative 宿主 iOS 前端
//  dm/ios/Sources/main.m 的 boot_env() 对全部客体统一执行
//  setenv("DM_SAVE", <客体 Documents>/save)，启动即建该目录；
//  dm/host/hle_fs.c 的 MountSaveData 与 MountDeviceSaveData 都挂到这
//  同一个目录（单用户、与游戏无关）。事务工作目录是同级兄弟
//  save.work / save.new，挂载时先清残留再从 save 本体重新克隆，所以
//  持久存档就是数据容器 Documents/save 的内容本身，换名替换它安全。
//  结论：落点全客体统一，本功能的可用判据 = 默认容器 Documents/save
//  目录存在（游戏至少启动过一次）；不存在则整组不显示，不按游戏写死
//  名单。非 nxnative 客体若恰有同名目录，其内容同样是它自己的数据，
//  导入导出语义不变。
//
//  导入语义：文件夹 / zip 先归一化内容根（根或唯一 save 子层），整集
//  替换 save；单个文件只覆盖 save 内同名文件。任何导入先把当前 save
//  整夹备份到 Documents/save-backups/save-<时间戳>/（与 save 本体同
//  在数据容器内、文件 App 可达、游戏不会误读），备份失败即中止导入。
//  拷贝复用数据包导入的分块拷贝积木；zip 解包复用既有 libarchive
//  extract()，打包复用 PKZipArchiver（与 IPA 打包同件）。
//

import SwiftUI
import UniformTypeIdentifiers

enum LCSaveDataError: Error {
    case noSaveDirectory
    case invalidContent
    case archiveFailed
    case extractFailed(Int32)
}

enum LCSaveDataStore {
    /// 默认容器 Documents（无容器返回 nil）
    static func documentsURL(for app: LCAppModel) -> URL? {
        guard let container = LCGameLibraryInfo.defaultContainer(for: app) else {
            return nil
        }
        return container.containerURL.appendingPathComponent("Documents")
    }

    /// 存档目录：存在且为目录才返回（本功能的可用判据，见文件头）
    static func saveDirectoryURL(for app: LCAppModel) -> URL? {
        guard let documents = documentsURL(for: app) else {
            return nil
        }
        let save = documents.appendingPathComponent("save", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: save.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return save
    }

    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: 导出

    /// 把 save 目录打成 zip 放进宿主临时目录，返回文件 URL 供分享。
    /// 文件名：<消毒后的游戏名>-save-<时间戳>.zip（与容器夹名同一消毒规则）
    static func exportSaveZip(for app: LCAppModel) async throws -> URL {
        guard let saveDir = saveDirectoryURL(for: app) else {
            throw LCSaveDataError.noSaveDirectory
        }
        let base = LCContainer.sanitizedFolderBase(app.displayName, fallback: app.bundleIdentifier)
        let fileName = "\(base)-save-\(stamp()).zip"
        return try await Task.detached(priority: .userInitiated) {
            // PKZipArchiver 在 PassKitCore 私有框架里、不可直链，经 LCUtils 封装运行时取
            guard let data = LCUtils.zipData(forDirectory: saveDir), !data.isEmpty else {
                throw LCSaveDataError.archiveFailed
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try data.write(to: url, options: .atomic)
            return url
        }.value
    }

    // MARK: 导入

    /// 导入存档（来源：文件夹 / zip / 单个存档文件）。返回备份目录
    /// （导入前 save 为空时无备份，返回 nil）。流程见文件头。
    static func importSave(from source: URL, for app: LCAppModel) async throws -> URL? {
        guard let documents = documentsURL(for: app), let saveDir = saveDirectoryURL(for: app) else {
            throw LCSaveDataError.noSaveDirectory
        }
        return try await Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let fm = FileManager.default
            let staging = fm.temporaryDirectory.appendingPathComponent("LCSaveImport-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }

            var isDirectory: ObjCBool = false
            let sourceIsDirectory = fm.fileExists(atPath: source.path, isDirectory: &isDirectory) && isDirectory.boolValue

            // 1) 归一化：得到「整集内容根」或「单个文件」
            var contentRoot: URL?
            var singleFile: URL?
            if sourceIsDirectory {
                contentRoot = normalizedContentRoot(of: source)
            } else if source.pathExtension.lowercased() == "zip" {
                let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
                try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
                let rc = extract(source.path, extracted.path, Progress(totalUnitCount: 100))
                guard rc == 0 else {
                    throw LCSaveDataError.extractFailed(rc)
                }
                contentRoot = normalizedContentRoot(of: extracted)
            } else {
                singleFile = source
            }
            if let root = contentRoot, LCDatapackImportView.treeFiles(root).isEmpty {
                throw LCSaveDataError.invalidContent
            }

            // 2) 备份当前存档（硬前置：失败即中止，save 原样不动）
            let backup = try await makeBackup(of: saveDir, in: documents, fm: fm)

            // 3) 落地
            if let file = singleFile {
                let dest = saveDir.appendingPathComponent(file.lastPathComponent)
                let tmp = saveDir.appendingPathComponent(file.lastPathComponent + ".importing")
                let written = try await LCDatapackImportView.chunkedCopyFile(from: file, to: tmp, isCancelled: { false }) { _ in }
                guard written == LCDatapackImportView.fileSize(file) else {
                    try? fm.removeItem(at: tmp)
                    throw CocoaError(.fileWriteUnknown)
                }
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.moveItem(at: tmp, to: dest)
            } else if let root = contentRoot {
                // 先整集拷到同卷临时夹，再三步换名（旧 save 先挪开、新集就位、删旧集）
                let incoming = documents.appendingPathComponent("save.importing", isDirectory: true)
                if fm.fileExists(atPath: incoming.path) {
                    try fm.removeItem(at: incoming)
                }
                try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
                for file in LCDatapackImportView.treeFiles(root) {
                    let relative = LCDatapackImportView.relativePath(of: file, under: root)
                    let dest = incoming.appendingPathComponent(relative)
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let written = try await LCDatapackImportView.chunkedCopyFile(from: file, to: dest, isCancelled: { false }) { _ in }
                    guard written == LCDatapackImportView.fileSize(file) else {
                        try? fm.removeItem(at: incoming)
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                let swappedOut = documents.appendingPathComponent("save.swapped-out", isDirectory: true)
                if fm.fileExists(atPath: swappedOut.path) {
                    try fm.removeItem(at: swappedOut)
                }
                try fm.moveItem(at: saveDir, to: swappedOut)
                do {
                    try fm.moveItem(at: incoming, to: saveDir)
                } catch {
                    try? fm.moveItem(at: swappedOut, to: saveDir)
                    throw error
                }
                try? fm.removeItem(at: swappedOut)
            }
            return backup
        }.value
    }

    /// 内容根归一化：根自身名为 save → 就是它；根下恰有一个子目录且
    /// 名为 save → 下钻一层（把整个 save 文件夹打包的常见形态）；其余
    /// 情形根自身即内容根（导出 zip 解开的形态）。
    static func normalizedContentRoot(of directory: URL) -> URL {
        if directory.lastPathComponent.lowercased() == "save" {
            return directory
        }
        let entries = LCDatapackImportView.topEntries(of: directory)
        if entries.directories.count == 1, entries.directories[0].lastPathComponent.lowercased() == "save" {
            return entries.directories[0]
        }
        return directory
    }

    /// 把当前 save 整夹备份到 Documents/save-backups/save-<时间戳>/；
    /// save 内无任何文件时跳过（无可备份），返回 nil。逐文件分块拷贝
    /// 并校验大小，任一失败抛错（调用方据此中止导入）。
    static func makeBackup(of saveDir: URL, in documents: URL, fm: FileManager) async throws -> URL? {
        let files = LCDatapackImportView.treeFiles(saveDir)
        guard !files.isEmpty else {
            return nil
        }
        let backupsRoot = documents.appendingPathComponent("save-backups", isDirectory: true)
        try fm.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
        let stamp = stamp()
        var backupDir = backupsRoot.appendingPathComponent("save-\(stamp)", isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: backupDir.path) {
            backupDir = backupsRoot.appendingPathComponent("save-\(stamp)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        for file in files {
            let relative = LCDatapackImportView.relativePath(of: file, under: saveDir)
            let dest = backupDir.appendingPathComponent(relative)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let written = try await LCDatapackImportView.chunkedCopyFile(from: file, to: dest, isCancelled: { false }) { _ in }
            guard written == LCDatapackImportView.fileSize(file) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        return backupDir
    }
}

/// 每游戏设置页「存档」组（NX 行语言：与 LCGameSettingsView 的分组卡 /
/// 导航行同规格，本文件自备同值样式常量）。存档目录不存在时整组不显示。
struct LCSaveDataSectionView: View {
    let app: LCAppModel

    @State private var sizeText: String?
    @State private var busy = false
    @State private var picking = false
    @State private var pendingSource: URL?
    @State private var confirmImport = false
    @State private var shareItem: LCShareItem?
    @State private var resultTitle: String?
    @State private var resultMessage: String?

    private struct LCShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    // 与 LCGameSettingsView 的 LCNXColor 同值，深浅动态变体亦同（那组常量是其文件私有）
    private static let cream = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0.94, blue: 0.84, alpha: 1)
            : UIColor(red: 0.66, green: 0.47, blue: 0.16, alpha: 1)
    })
    private static let surface = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1)
            : UIColor(red: 1, green: 1, blue: 1, alpha: 1)
    })
    private static let hairline = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.08)
    })

    var body: some View {
        if LCSaveDataStore.saveDirectoryURL(for: app) != nil {
            section
                .onAppear { refreshSize() }
                .fileImporter(isPresented: $picking, allowedContentTypes: [.item, .folder], allowsMultipleSelection: false) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        pendingSource = url
                        confirmImport = true
                    }
                }
                .confirmationDialog("lc.save.importConfirmTitle".loc, isPresented: $confirmImport, titleVisibility: .visible) {
                    Button("lc.save.import".loc, role: .destructive) {
                        if let source = pendingSource {
                            runImport(source: source)
                        }
                        pendingSource = nil
                    }
                    Button("lc.common.cancel".loc, role: .cancel) {
                        pendingSource = nil
                    }
                } message: {
                    Text("lc.save.importConfirmMessage".loc)
                }
                .sheet(item: $shareItem) { item in
                    ActivityViewController(activityItems: [item.url])
                }
                .alert(resultTitle ?? "", isPresented: resultPresented) {
                    Button("lc.common.ok".loc, role: .cancel) {}
                } message: {
                    Text(resultMessage ?? "")
                }
        }
    }

    private var resultPresented: Binding<Bool> {
        Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil; resultTitle = nil } }
        )
    }

    private var section: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("lc.save.section".loc.uppercased())
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(1.6)
                .foregroundColor(Self.cream.opacity(0.72))
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    runExport()
                } label: {
                    row(label: "lc.save.export".loc, value: sizeText)
                }
                .buttonStyle(.plain)
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)
                Button {
                    picking = true
                } label: {
                    row(label: "lc.save.import".loc, value: nil)
                }
                .buttonStyle(.plain)
                if busy {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("lc.save.working".loc)
                            .font(.system(size: 12.5))
                            .foregroundColor(.primary.opacity(0.5))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Self.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Self.hairline, lineWidth: 1)
            }
        }
        .disabled(busy)
    }

    /// NX 导航行同语言：标签 15 medium 白、值 14.5 semibold 奶油、
    /// chevron 13 bold 白 0.4、行 minHeight 48
    private func row(label: String, value: String?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.primary)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(Self.cream)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.primary.opacity(0.4))
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    private func refreshSize() {
        guard let saveDir = LCSaveDataStore.saveDirectoryURL(for: app) else {
            return
        }
        let bytes = LCDatapackImportView.treeSize(saveDir)
        sizeText = bytes > 0 ? LCDatapackImportView.sizeText(bytes) : nil
    }

    private func runExport() {
        busy = true
        Task {
            do {
                let url = try await LCSaveDataStore.exportSaveZip(for: app)
                shareItem = LCShareItem(url: url)
            } catch {
                resultTitle = "lc.save.export".loc
                resultMessage = "lc.save.failed %@".localizeWithFormat(error.localizedDescription)
            }
            busy = false
        }
    }

    private func runImport(source: URL) {
        busy = true
        Task {
            do {
                _ = try await LCSaveDataStore.importSave(from: source, for: app)
                resultTitle = "lc.save.import".loc
                resultMessage = "lc.save.imported".loc
                refreshSize()
            } catch LCSaveDataError.invalidContent {
                resultTitle = "lc.save.import".loc
                resultMessage = "lc.save.invalidContent".loc
            } catch {
                resultTitle = "lc.save.import".loc
                resultMessage = "lc.save.failed %@".localizeWithFormat(error.localizedDescription)
            }
            busy = false
        }
    }
}
