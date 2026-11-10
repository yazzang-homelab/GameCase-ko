//
//  LCGameCheats.swift
//  LiveContainerSwiftUI
//
//  金手指接线：引擎是 fork 的 hle_cheats.c（Atmosphère dmnt 格式 VM，
//  已随上游同步进 fork main 并真机冒烟通过），GC 只做壳侧两件事——
//  env 维护与设置页管理，引擎与客体零改。
//
//  引擎语义（已实证，直接据此实现，不再另行查证）：
//  - 容器 Documents/env.txt 写一行 DM_CHEATS=cheats（相对路径，客体
//    boot 后按其 Documents 解析，GameCase 内真机已证）即启用：引擎
//    扫 Documents/cheats/ 下与主 NSO build ID 前 16 位大写十六进制
//    同名的 <BUILD16>.txt；
//  - 条目开关靠同夹同名 <BUILD16>.enabled（一行一个条目名、大小写不
//    敏感匹配）；{花括号} 名的段是 master、恒开、不进 .enabled；
//  - 代码补丁型条目在 iOS 上会被引擎逐条自动关停（签名代码页不可
//    写，原因写进客体 log.txt），数据型条目真生效——这是引擎行为，
//    GC 只在组脚注里如实写明一行。
//
//  env 维护与 Mod 共用单一写者：LCGameMods.maintainEnvLine 是 env.txt
//  的唯一行级写者，LCGameMods.refreshEnvOverlay 在同一次维护里顺
//  序处理 DM_ROMFS_OVERLAY、DM_CHEATS、DM_LAUNCHER（他行逐字保
//  留；云存档不经 env、走客体偏好书签同步，只在同一漏斗里删旧残
//  行）：Documents/cheats/ 内存在
//  至少一个文件名合规的 .txt 时写 DM_CHEATS=cheats，否则删行。不写 DM_CHEATS_ON / DM_CHEATS_DEBUG
//  （开关走 .enabled 约定，调试开关留给玩家手写）。
//  与 env 锁定逻辑的关系同 DM_ROMFS_OVERLAY（见 LCGameMods.swift
//  文件头）：LCGameProfile.envLockedValues 会把这行认作 env 固定键
//  在设置页锁定——口径一致、无冲突，这行本来就由 cheats 目录现状
//  决定、GC 独占维护；玩家手写的同名行会在下次启动被维护结果覆盖。
//
//  设置页「金手指」组（本文件下半）：导入 .txt（文件名对 build、内
//  容至少含一个带代码的条目段才收）、逐条开关（读写 .enabled）、
//  删除（连带 .enabled）。解析只取段名、不执行任何内容。金手指文
//  件都是小文件，导入直接整读整写，不走数据包那套分块拷贝。
//

import SwiftUI
import UniformTypeIdentifiers

enum LCGameCheatError: Error {
    /// 文件名不是 16 位十六进制 + .txt（引擎靠文件名对 build）
    case invalidFileName
    /// 内容里解析不到任何带代码的条目段（空文件 / 非金手指文本）
    case invalidContent
}

enum LCGameCheats {
    static let envKey = "DM_CHEATS"
    /// 相对路径值：客体 boot 后按其 Documents 解析（真机已证）
    static let envValue = "cheats"

    /// 一个条目段：[名字] 为普通条目、{名字} 为 master（恒开）
    struct CheatEntry: Identifiable {
        let name: String
        let isMaster: Bool
        var id: String { name }
    }

    /// 一个已装金手指文件 + 其条目与开关现状
    struct CheatFile: Identifiable {
        /// build ID（文件名主干，归一为大写显示）
        let buildID: String
        let fileURL: URL
        let entries: [CheatEntry]
        /// .enabled 里写着的条目名（小写归一集合，匹配大小写不敏感）
        let enabledNames: Set<String>
        var enabledURL: URL {
            fileURL.deletingPathExtension().appendingPathExtension("enabled")
        }
        var id: String { buildID }
        func isOn(_ entry: CheatEntry) -> Bool {
            entry.isMaster || enabledNames.contains(entry.name.lowercased())
        }
    }

    // MARK: 文件名与解析

    /// 文件名合规：主干恰 16 位十六进制（大小写不论）、扩展名 .txt
    static func isCheatFileName(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: name)
        guard url.pathExtension.lowercased() == "txt" else { return false }
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.count == 16 && stem.allSatisfy(\.isHexDigit)
    }

    /// 归一文件名：主干大写 + .txt（引擎按大写 build ID 找文件）
    static func normalizedFileName(_ name: String) -> String {
        URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent.uppercased() + ".txt"
    }

    /// 解析条目段：只取段名——[名字] 为普通条目、{名字} 为 master；
    /// 段后至少跟一行内容（代码行）才算一条：只有段头没有内容的
    /// （文件标题行、分组行）不是条目，与引擎计数同口径（冒烟样本
    /// 14 个段头里 11 个带代码，引擎汇总正是 11 条）。同名段只认
    /// 首个。不执行、不校验任何代码内容。
    static func parseEntries(text: String) -> [CheatEntry] {
        var entries: [CheatEntry] = []
        var seen = Set<String>()
        var pending: (name: String, isMaster: Bool)?
        var pendingHasContent = false
        func flush() {
            guard let pending, pendingHasContent else { return }
            if seen.insert(pending.name.lowercased()).inserted {
                entries.append(CheatEntry(name: pending.name, isMaster: pending.isMaster))
            }
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let isBracket = line.hasPrefix("[")
            let isBrace = line.hasPrefix("{")
            if isBracket || isBrace,
               let close = line.firstIndex(of: isBracket ? "]" : "}"),
               close > line.index(after: line.startIndex) {
                flush()
                pending = (String(line[line.index(after: line.startIndex)..<close]), isBrace)
                pendingHasContent = false
            } else if !line.isEmpty {
                pendingHasContent = true
            }
        }
        flush()
        return entries
    }

    /// 读 .enabled：每行一个条目名，去空白、跳空行（原始顺序与写法）
    static func readEnabledNames(enabledURL: URL) -> [String] {
        guard let text = try? String(contentsOf: enabledURL, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// cheats 夹现状：全部文件名合规的文件（按文件名序），各带解析
    /// 出的条目与 .enabled 现状。读不出内容的文件按 0 条目列出（引
    /// 擎同样读不动它），不隐藏。
    static func installedFiles(in cheatsDir: URL, _ fm: FileManager = .default) -> [CheatFile] {
        let names = ((try? fm.contentsOfDirectory(atPath: cheatsDir.path)) ?? [])
            .filter { isCheatFileName($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return names.map { name in
            let url = cheatsDir.appendingPathComponent(name)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let enabledURL = url.deletingPathExtension().appendingPathExtension("enabled")
            return CheatFile(
                buildID: url.deletingPathExtension().lastPathComponent.uppercased(),
                fileURL: url,
                entries: parseEntries(text: text),
                enabledNames: Set(readEnabledNames(enabledURL: enabledURL).map { $0.lowercased() })
            )
        }
    }

    /// env 维护判据：cheats 夹内存在至少一个文件名合规的 .txt 时
    /// 返回要写入的值，否则 nil（删行）。只看文件名、不解析内容——
    /// 与引擎「按名找文件」的行为一致。
    static func cheatsEnvValue(in documents: URL, _ fm: FileManager = .default) -> String? {
        let cheatsDir = documents.appendingPathComponent("cheats", isDirectory: true)
        let names = (try? fm.contentsOfDirectory(atPath: cheatsDir.path)) ?? []
        return names.contains(where: { isCheatFileName($0) }) ? envValue : nil
    }

    // MARK: 开关 / 导入 / 删除

    /// 开关一个条目：重写该文件的 .enabled——只写当前文件里真实存
    /// 在的普通条目名、按其在文件中的出现顺序、一行一名、用条目名
    /// 的原文写法（master 不写、恒开）；名单为空则删掉 .enabled
    /// （无此文件 = 全关，与引擎约定同义）。
    static func setEntry(_ entry: CheatEntry, on: Bool, file: CheatFile, _ fm: FileManager = .default) throws {
        guard !entry.isMaster else { return }
        var onNames = file.enabledNames
        if on {
            onNames.insert(entry.name.lowercased())
        } else {
            onNames.remove(entry.name.lowercased())
        }
        let lines = file.entries
            .filter { !$0.isMaster && onNames.contains($0.name.lowercased()) }
            .map(\.name)
        if lines.isEmpty {
            if fm.fileExists(atPath: file.enabledURL.path) {
                try fm.removeItem(at: file.enabledURL)
            }
        } else {
            try (lines.joined(separator: "\n") + "\n")
                .write(to: file.enabledURL, atomically: true, encoding: .utf8)
        }
    }

    /// 导入一个金手指文件（数据已由调用方在安全作用域内读好）：先
    /// 校验文件名（不合规 invalidFileName）、再校验内容（UTF-8 且
    /// 解析得到至少一个带代码的条目段，否则 invalidContent），都
    /// 过才以归一名落位 cheats 夹。覆盖同名文件时保留其 .enabled
    /// （同名条目的开关选择延续，新文件独有的条目默认关）。返回
    /// build ID。
    static func importCheatFile(fileName: String, data: Data, into cheatsDir: URL, _ fm: FileManager = .default) throws -> String {
        guard isCheatFileName(fileName) else {
            throw LCGameCheatError.invalidFileName
        }
        guard let text = String(data: data, encoding: .utf8),
              !parseEntries(text: text).isEmpty else {
            throw LCGameCheatError.invalidContent
        }
        try fm.createDirectory(at: cheatsDir, withIntermediateDirectories: true)
        let normalized = normalizedFileName(fileName)
        try data.write(to: cheatsDir.appendingPathComponent(normalized), options: .atomic)
        return String(normalized.dropLast(4))
    }

    /// 删除金手指文件并连带其 .enabled
    static func delete(file: CheatFile, _ fm: FileManager = .default) throws {
        try fm.removeItem(at: file.fileURL)
        try? fm.removeItem(at: file.enabledURL)
    }

    /// 设置页「金手指」组的上下文：默认容器 + cheats 夹（取不到
    /// titleID 也无妨——文件名自带 build ID）。无容器返回 nil。
    static func cheatsContext(for app: LCAppModel) -> (container: LCContainer, cheatsDir: URL)? {
        guard let container = LCGameLibraryInfo.defaultContainer(for: app) else {
            return nil
        }
        let cheatsDir = container.containerURL.appendingPathComponent("Documents/cheats", isDirectory: true)
        return (container, cheatsDir)
    }
}

// MARK: - 设置页「金手指」组（导入 + 条目开关 + 删除）

/// 每个已装文件一行（build ID + 条目数），点开逐条开关：普通条目
/// 的开关读写同名 .enabled，master 条目只显示「恒开」。底部「导入
/// 金手指…」可多选 .txt。全组只动 Documents/cheats 本层，env.txt
/// 的 DM_CHEATS 行由启动前维护按现状重算，本组不直接碰 env.txt。
/// 排版与 LCGameModsSectionView 同语言（自带同值常量）。金手指文
/// 件很小，导入在本线程整读整写，不设进度与取消。
struct LCGameCheatsSectionView: View {
    let app: LCAppModel
    /// 宿主页面的状态刷新计数：其他组动作后 bump，本组随之重算
    var refreshToken: Int = 0

    @State private var files: [LCGameCheats.CheatFile] = []
    @State private var hasContainer = false
    @State private var expandedBuildID: String?
    @State private var picking = false
    @State private var pendingPayloads: [PendingCheat] = []
    @State private var pendingProblems: [String] = []
    @State private var overwriteNames = ""
    @State private var confirmImportOverwrite = false
    @State private var pendingDelete: LCGameCheats.CheatFile?
    @State private var confirmDelete = false
    @State private var resultTitle: String?
    @State private var resultMessage: String?

    /// 已校验待落位的导入内容（数据在选择器回调的安全作用域内读好）
    private struct PendingCheat {
        let fileName: String
        let data: Data
    }

    // 与 LCGameModsSectionView / LCGameSettingsView 的 LCNXColor 同值，深浅动态变体亦同
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
        // Group 透明包裹：无容器时整组缺席，与 Mod 组自隐同效
        Group {
            if hasContainer {
                section
            }
        }
        .onAppear { reload() }
        .onChange(of: refreshToken) { _ in reload() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.plainText], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                pickedCheatFiles(urls)
            }
        }
        .confirmationDialog("lc.cheats.importOverwriteTitle".loc, isPresented: $confirmImportOverwrite, titleVisibility: .visible) {
            Button("lc.cheats.replace".loc, role: .destructive) {
                writePending()
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                pendingPayloads = []
                pendingProblems = []
            }
        } message: {
            Text("lc.cheats.importOverwriteMessage".loc.localizeWithFormat(overwriteNames))
        }
        .confirmationDialog("lc.cheats.deleteConfirmTitle".loc, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("lc.cheats.delete".loc, role: .destructive) {
                if let file = pendingDelete {
                    runDelete(file)
                }
                pendingDelete = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("lc.cheats.deleteConfirmMessage".loc.localizeWithFormat(pendingDelete?.buildID ?? ""))
        }
        .alert(resultTitle ?? "", isPresented: resultPresented) {
            Button("lc.common.ok".loc, role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
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
            Text("lc.cheats.section".loc.uppercased())
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(1.6)
                .foregroundColor(Self.cream.opacity(0.72))
            VStack(alignment: .leading, spacing: 14) {
                if files.isEmpty {
                    Text("lc.cheats.none".loc)
                        .font(.system(size: 14))
                        .foregroundColor(.primary.opacity(0.72))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.06))
                                .frame(height: 1)
                        }
                        fileBlock(file)
                    }
                }
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)
                Button {
                    picking = true
                } label: {
                    HStack(spacing: 8) {
                        Text("lc.cheats.import".loc)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.primary)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.primary.opacity(0.4))
                    }
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("lc.cheats.note".loc)
                    .font(.system(size: 12.5))
                    .foregroundColor(.primary.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Self.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Self.hairline, lineWidth: 1)
            }
        }
    }

    /// 一个文件块：头行（build ID + 条目数 + 删除）点按展开 / 收起，
    /// 展开后逐条列条目开关。
    private func fileBlock(_ file: LCGameCheats.CheatFile) -> some View {
        let expanded = expandedBuildID == file.buildID
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    expandedBuildID = expanded ? nil : file.buildID
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.buildID)
                                .font(.system(size: 15, weight: .semibold).monospaced())
                                .foregroundColor(.primary)
                            Text("lc.cheats.entries".loc.localizeWithFormat(String(file.entries.count)))
                                .font(.system(size: 12.5))
                                .foregroundColor(.primary.opacity(0.45))
                        }
                        Spacer(minLength: 8)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.primary.opacity(0.4))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    pendingDelete = file
                    confirmDelete = true
                } label: {
                    Text("lc.cheats.delete".loc)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(.red.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(file.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.05))
                                .frame(height: 1)
                        }
                        entryRow(file: file, entry: entry)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 一行条目：名字 + 开关；master 显示「恒开」不可关
    private func entryRow(file: LCGameCheats.CheatFile, entry: LCGameCheats.CheatEntry) -> some View {
        HStack(spacing: 10) {
            Text(entry.name)
                .font(.system(size: 14))
                .foregroundColor(.primary.opacity(0.88))
                .lineLimit(2)
            Spacer(minLength: 8)
            if entry.isMaster {
                Text("lc.cheats.alwaysOn".loc)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.4))
            } else {
                Toggle("", isOn: entryBinding(file: file, entry: entry))
                    .labelsHidden()
                    .tint(Self.cream)
                    .gcGlassToggleStyle()
            }
        }
        .frame(minHeight: 44)
    }

    private func entryBinding(file: LCGameCheats.CheatFile, entry: LCGameCheats.CheatEntry) -> Binding<Bool> {
        Binding(
            get: { file.isOn(entry) },
            set: { newValue in runToggle(file: file, entry: entry, on: newValue) }
        )
    }

    // MARK: 动作

    private func reload() {
        if let context = LCGameCheats.cheatsContext(for: app) {
            hasContainer = true
            files = LCGameCheats.installedFiles(in: context.cheatsDir)
        } else {
            hasContainer = false
            files = []
        }
        // 只有一个文件时默认展开（最常见情形，省一次点按）
        if files.count == 1 {
            expandedBuildID = files[0].buildID
        } else if let expandedBuildID, !files.contains(where: { $0.buildID == expandedBuildID }) {
            self.expandedBuildID = nil
        }
    }

    private func runToggle(file: LCGameCheats.CheatFile, entry: LCGameCheats.CheatEntry, on: Bool) {
        do {
            try LCGameCheats.setEntry(entry, on: on, file: file)
            reload()
        } catch {
            reload()
            resultTitle = "lc.cheats.section".loc
            resultMessage = "lc.cheats.failed".loc.localizeWithFormat(error.localizedDescription)
        }
    }

    private func runDelete(_ file: LCGameCheats.CheatFile) {
        do {
            try LCGameCheats.delete(file: file)
            reload()
        } catch {
            resultTitle = "lc.cheats.section".loc
            resultMessage = "lc.cheats.failed".loc.localizeWithFormat(error.localizedDescription)
        }
    }

    /// 选入一批 .txt：逐个在安全作用域内读好并先校验（文件名 → 内
    /// 容），合规的攒成待落位清单；与已装文件同名的先攒着弹覆盖确
    /// 认（确认 = 全部落位、取消 = 全部不落位），不合规的逐条记进
    /// 结果说明。
    private func pickedCheatFiles(_ urls: [URL]) {
        var payloads: [PendingCheat] = []
        var problems: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            let scoped = url.startAccessingSecurityScopedResource()
            let data = try? Data(contentsOf: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
            guard let data else {
                problems.append("lc.cheats.failed".loc.localizeWithFormat(name))
                continue
            }
            guard LCGameCheats.isCheatFileName(name) else {
                problems.append("lc.cheats.importInvalidName".loc.localizeWithFormat(name))
                continue
            }
            guard let text = String(data: data, encoding: .utf8),
                  !LCGameCheats.parseEntries(text: text).isEmpty else {
                problems.append("lc.cheats.importInvalidContent".loc.localizeWithFormat(name))
                continue
            }
            payloads.append(PendingCheat(fileName: name, data: data))
        }
        guard !payloads.isEmpty else {
            if !problems.isEmpty {
                resultTitle = "lc.cheats.import".loc
                resultMessage = problems.joined(separator: "\n")
            }
            return
        }
        let existing = Set(files.map { $0.fileURL.lastPathComponent.lowercased() })
        let conflicts = payloads
            .map { LCGameCheats.normalizedFileName($0.fileName) }
            .filter { existing.contains($0.lowercased()) }
        if conflicts.isEmpty {
            pendingPayloads = payloads
            pendingProblems = problems
            writePending()
        } else {
            pendingPayloads = payloads
            pendingProblems = problems
            overwriteNames = conflicts.joined(separator: ", ")
            confirmImportOverwrite = true
        }
    }

    /// 落位全部待导入文件并汇报（成功数 + 逐条跳过原因）
    private func writePending() {
        guard let context = LCGameCheats.cheatsContext(for: app) else { return }
        var imported = 0
        var problems = pendingProblems
        for payload in pendingPayloads {
            do {
                _ = try LCGameCheats.importCheatFile(fileName: payload.fileName, data: payload.data, into: context.cheatsDir)
                imported += 1
            } catch LCGameCheatError.invalidFileName {
                problems.append("lc.cheats.importInvalidName".loc.localizeWithFormat(payload.fileName))
            } catch LCGameCheatError.invalidContent {
                problems.append("lc.cheats.importInvalidContent".loc.localizeWithFormat(payload.fileName))
            } catch {
                problems.append("lc.cheats.failed".loc.localizeWithFormat(error.localizedDescription))
            }
        }
        pendingPayloads = []
        pendingProblems = []
        reload()
        var lines: [String] = []
        if imported > 0 {
            lines.append("lc.cheats.importDone".loc)
        }
        lines.append(contentsOf: problems)
        if !lines.isEmpty {
            resultTitle = "lc.cheats.import".loc
            resultMessage = lines.joined(separator: "\n")
        }
    }
}
