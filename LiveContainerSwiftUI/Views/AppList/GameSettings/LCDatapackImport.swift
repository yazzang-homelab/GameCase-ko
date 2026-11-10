//
//  LCDatapackImport.swift
//  LiveContainerSwiftUI
//
//  数据包（romfs.img）导入：选目标游戏（从卡片长按菜单进入时已预选）→ 选 .img 文件
//  → 分块拷贝进该游戏默认容器的 Documents/romfs.img。数据包动辄数 GB：拷贝在后台
//  线程分块进行、带进度与取消，先写临时文件、校验大小一致后才替换正式文件，中途
//  失败不破坏已有数据包。
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LCDatapackRequest: Identifiable {
    let id = UUID()
    let app: LCAppModel? // nil = 从库页按钮进入，先选游戏
}

/// 导入正文（游戏行 + 阶段内容）的实测高：内层 VStack 经背景
/// GeometryReader 上报，供 detent 档（iOS 16/17 全宽 + iOS 18+ 紧凑
/// 宽度）定高用
private struct LCDatapackBodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 呈现瘦身的分工（2026-11-09 预览定版：只收尺寸，内容不动）：
/// regular 宽度（iPad）iOS 18+ 用 presentationSizing——居中表单卡
/// （系统表单宽约 540，封顶口径与预览的约 560 一致）、高度按内容理想
/// 高贴合，状态切换由系统重算并动画；其余情形（iOS 16/17 全部宽度、
/// iOS 18+ 紧凑宽度）用正文实测高拼的 .height detent；iOS 15 不加
/// 修饰，维持现状全高 page sheet。
///
/// #90 曾让 iOS 18+ 无条件走 .form.fitted，实机（iOS 27、iPhone 竖
/// 屏）证明紧凑宽度下完全不生效、sheet 仍全高：.form 是 regular 宽
/// 度的概念——presentationSizing 管的是 regular 宽度下居中卡的占地，
/// 紧凑宽度下 form 与 page 无区别（UIKit 自适应呈现的一贯语义：水
/// 平紧凑环境里 page/form sheet 都按全屏/全高呈现），高度改由
/// detents 决定，fitted(vertical:) 没有机会收高。故 iOS 18+ 按窗口
/// 宽度分流：regular 维持 .form.fitted 逐字不变，紧凑改走与 16/17
/// 同一套实测 detent。
private struct LCDatapackSheetSizingModifier: ViewModifier {
    let detentHeight: CGFloat

    /// 容器尺寸类不参与判定（见 windowHorizontalSizeClass 注），读它
    /// 只为让其变化（旋转 / 窗口形态翻转）触发 body 重算、顺带现读
    /// 一次窗口真值。
    @Environment(\.horizontalSizeClass) private var containerSizeClass

    /// 窗口（场景）横向尺寸类真值（UIKit 现读）：sheet 内容里的
    /// SwiftUI 环境尺寸类是容器局部的——iPad 上 sheet 容器自身即报
    /// .compact，拿它分工会把 iPad 误判去 detent 路。分工只能按呈现
    /// 窗口的 traits 判：iPad 全屏窗口 .regular、iPhone .compact、
    /// iPad 分屏窄窗 .compact（按紧凑宽度同路处理，与其形态相符）。
    /// 与 LCSidePanelSpec.windowTopSafeInset 同一路数（取 keyWindow
    /// 真值、每次现读，旋转后即新值）。读不到窗口时回退 .regular，
    /// 维持 .form 行为、不引入新形态。
    private static var windowHorizontalSizeClass: UIUserInterfaceSizeClass {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        return keyWindow?.traitCollection.horizontalSizeClass ?? .regular
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            if Self.windowHorizontalSizeClass == .regular {
                content.presentationSizing(.form.fitted(horizontal: false, vertical: true))
            } else {
                content.presentationDetents([.height(detentHeight)])
            }
        } else if #available(iOS 16.0, *) {
            content.presentationDetents([.height(detentHeight)])
        } else {
            content
        }
    }
}

/// 选游戏列表定高（iOS 16+）：iOS 18 regular 档 fitted 读 frame 定列表
/// 理想高，detent 档（16/17 全宽 + 18 紧凑宽度）与 sheetDetentHeight
/// 的列表区保持一致；iOS 15 不约束、列表仍占满全高 sheet（现状）。
/// 封顶后列表内部滚动（见 pickerListHeight 的预算说明）。
private struct LCDatapackPickerHeightModifier: ViewModifier {
    let height: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.frame(height: height)
        } else {
            content
        }
    }
}

/// 拷贝分块大小（放文件级常量：拷贝在后台线程跑，不能读主 actor 隔离的静态成员）
private let lcDatapackChunkSize = 4 * 1024 * 1024

/// 分块拷贝被取消（与真实 IO 失败分开报：取消回待选状态、不算导入失败）
enum LCDatapackCopyError: Error {
    case cancelled
}

struct LCDatapackImportView: View {
    let request: LCDatapackRequest
    let apps: [LCAppModel]
    var onFinished: () -> Void = {}

    @Environment(\.presentationMode) private var presentationMode

    @State private var target: LCAppModel?
    @State private var pickingFile = false
    @State private var pickingFolder = false
    @State private var pickedSource: URL?
    @State private var pendingFolderPlan: FolderPlan?
    @State private var confirmFolderImport = false
    @State private var confirmOverwrite = false
    @State private var stage: Stage = .ready
    @State private var progress: Double = 0
    @State private var copiedBytes: Int64 = 0
    @State private var totalBytes: Int64 = 0
    @State private var resultSize: Int64 = 0

    private enum Stage: Equatable {
        case ready
        case copying
        case done
        case failed(String)
    }

    private final class CancelBox { var cancelled = false }
    @State private var cancelBox = CancelBox()

    /// 正文实测高（不含顶/底边距与填充 Spacer）：阶段切换、错误文案
    /// 换行、动态字体都会让它变化，detent 随之跟随（见 body 的挂载点）
    @State private var measuredBodyHeight: CGFloat = 0



    var body: some View {
        NavigationView {
            Group {
                if let target {
                    targetBody(target)
                } else {
                    gamePickerBody
                }
            }
            .navigationTitle("lc.datapack.importTitle".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".loc) {
                        cancelBox.cancelled = true
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onPreferenceChange(LCDatapackBodyHeightKey.self) { newHeight in
            // 带动画赋值：切阶段时 detent 档的高度平滑跟随、不跳变；
            // 阈值挡住同值重复上报，避免布局回路
            guard newHeight > 0, abs(newHeight - measuredBodyHeight) > 0.5 else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                measuredBodyHeight = newHeight
            }
        }
        .modifier(LCDatapackSheetSizingModifier(detentHeight: sheetDetentHeight))
        .onAppear {
            // 本页的写侧解析（existingDatapackSize / startCopy / 文件夹
            // 导入）与读侧复核共用 defaultContainer 的同一份快照：出现
            // 先按记录对齐全部候选游戏，免得快照脱钩时包写进与启动、
            // 状态读数不一致的容器
            for app in apps {
                app.refreshContainerSelection()
            }
            if target == nil {
                target = request.app
            }
        }
        // 允许任意文件：.img 没有注册 UTI，用 [.data] 过滤会在文件选择器里把它置灰选不了
        // （IPA 能选是因为宿主为 ipa/tipa 声明了专用类型）。选到后仍由 pickedFile 按
        // 扩展名 == img 把关、startCopy 按大小校验，类型放宽不降低校验强度。
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    pickedFile(url)
                }
            case .failure(let error):
                stage = .failed(error.localizedDescription)
            }
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    pickedFolder(url)
                }
            case .failure(let error):
                stage = .failed(error.localizedDescription)
            }
        }
        .confirmationDialog("lc.datapack.folderOverwriteTitle".loc, isPresented: $confirmFolderImport, titleVisibility: .visible) {
            Button("lc.datapack.folderOverwriteButton".loc, role: .destructive) {
                if let plan = pendingFolderPlan {
                    startFolderImport(plan: plan)
                }
                pendingFolderPlan = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                pendingFolderPlan = nil
            }
        } message: {
            Text("lc.datapack.folderOverwriteMessage".loc.localizeWithFormat(Self.sizeText(existingDatapackSize)))
        }
        .confirmationDialog("lc.datapack.folderOverwriteTitle".loc, isPresented: $confirmOverwrite, titleVisibility: .visible) {
            Button("lc.datapack.overwriteButton".loc, role: .destructive) {
                if let source = pickedSource {
                    startCopy(source: source)
                }
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                pickedSource = nil
            }
        } message: {
            Text("lc.datapack.overwriteMessage %@".localizeWithFormat(Self.sizeText(existingDatapackSize)))
        }
    }

    // MARK: 呈现尺寸（瘦身）

    /// 选游戏列表的高度预算：表头约 50 + 每行约 62（44 图标 + 上下行距）
    /// + 底 8，封顶 560——游戏再多，列表在封顶高内滚动，不把 sheet 顶出
    /// 屏幕。极端大字体下单行可能高于预算，超出部分同样靠列表内滚动
    /// 消化、不会截断内容。
    private var pickerListHeight: CGFloat {
        min(50 + 62 * CGFloat(apps.count) + 8, 560)
    }

    /// detent 档（iOS 16/17 全宽 + iOS 18+ 紧凑宽度）的总高。选游戏：
    /// 导航栏 44 + 列表高 + 余量 20；
    /// 已选游戏：正文实测高 + 92（导航栏 44 + 顶边距 20 + 底边距 20 +
    /// 余量 8）。实测到达前（首帧）用选文件前状态的正文预算 284 兜底，
    /// 测值一到即接管。预选进入（设置页 / 长按菜单）时 request.app 已定，
    /// 直接按已选游戏算，不闪一帧选游戏高。
    private var sheetDetentHeight: CGFloat {
        if target == nil, request.app == nil {
            return 44 + pickerListHeight + 20
        }
        return (measuredBodyHeight > 0 ? measuredBodyHeight : 284) + 92
    }

    // MARK: 选游戏

    private var gamePickerBody: some View {
        List {
            Section {
                ForEach(apps, id: \.self) { app in
                    Button {
                        target = app
                    } label: {
                        HStack(spacing: 12) {
                            gameIcon(app)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.displayName)
                                    .foregroundColor(.primary)
                                Text("lc.datapack.versionN %@".localizeWithFormat(app.version))
                                    .font(.footnote)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            datapackStatusText(for: app)
                        }
                    }
                }
            } header: {
                Text("lc.datapack.pickGameHeader".loc)
            }
        }
        .modifier(LCDatapackPickerHeightModifier(height: pickerListHeight))
    }

    // MARK: 已选游戏

    @ViewBuilder
    private func targetBody(_ app: LCAppModel) -> some View {
        // 外层 VStack 只管「被测内容 + 填充位」：内层是游戏行与阶段内容
        // （原 spacing 20 与各元素逐字不变），背景量其真实高度供 detent
        // 定高；Spacer(minLength: 0) 只为全高回退（iOS 15）把内容顶到
        // 顶部，贴合呈现时收为 0、且不计入实测高（测的是内层）。
        // 底边距 20 为新增：全高时由 Spacer 等量吸收、视觉不变；贴合时
        // 它就是卡片的底部留白（预览的贴合高含此项）。
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                HStack(spacing: 12) {
                    gameIcon(app)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.displayName)
                            .font(.headline)
                        Text("lc.datapack.versionN %@".localizeWithFormat(app.version))
                            .font(.footnote)
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    datapackStatusText(for: app)
                }
                .padding(.horizontal)

                switch stage {
                case .ready:
                    Text("lc.datapack.writeHint".loc)
                        .font(.footnote)
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                    Button {
                        pickingFile = true
                    } label: {
                        Text("lc.datapack.chooseFile".loc)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .gcGlassProminentButtonStyle()
                    .tint(LCGameTheme.accentColor)
                    .padding(.horizontal)
                    Button {
                        pickingFolder = true
                    } label: {
                        Text("lc.datapack.chooseFolder".loc)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .gcGlassButtonStyle()
                    .tint(LCGameTheme.accentColor)
                    .padding(.horizontal)
                    Text("lc.datapack.folderHint".loc)
                        .font(.footnote)
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                    if request.app == nil {
                        Button("lc.datapack.changeGame".loc) {
                            target = nil
                            pickedSource = nil
                        }
                        .foregroundColor(.gray)
                    }
                case .copying:
                    VStack(spacing: 10) {
                        ProgressView(value: progress)
                        Text("lc.datapack.copying %@ %@".localizeWithFormat(Self.sizeText(copiedBytes), Self.sizeText(totalBytes)))
                            .font(.footnote)
                            .foregroundColor(.gray)
                        Button("lc.datapack.cancelCopy".loc) {
                            cancelBox.cancelled = true
                        }
                        .foregroundColor(.red)
                    }
                    .padding(.horizontal)
                case .done:
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.green)
                        Text("lc.datapack.imported %@".localizeWithFormat(Self.sizeText(resultSize)))
                            .font(.headline)
                        Button {
                            presentationMode.wrappedValue.dismiss()
                            onFinished()
                        } label: {
                            Text("lc.common.done".loc)
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .gcGlassProminentButtonStyle()
                        .tint(LCGameTheme.accentColor)
                    }
                    .padding(.horizontal)
                case .failed(let message):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.orange)
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                        Button("lc.datapack.chooseAgain".loc) {
                            stage = .ready
                            pickingFile = true
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .background(GeometryReader { proxy in
                Color.clear.preference(key: LCDatapackBodyHeightKey.self, value: proxy.size.height)
            })
            Spacer(minLength: 0)
        }
        .padding(.top, 20)
        .padding(.bottom, 20)
    }

    // MARK: 拷贝

    private var existingDatapackSize: Int64 {
        guard let target, let container = LCGameLibraryInfo.defaultContainer(for: target) else { return 0 }
        // 走统一探测：现存镜像可能是任意大小写（RomFS.img 等），
        // 拼写死小写路径会漏认、跳过覆盖确认
        guard let url = LCGameLibraryInfo.probeDatapack(container: container).imageFile else { return 0 }
        return Self.fileSize(url)
    }

    private func pickedFile(_ url: URL) {
        guard url.pathExtension.lowercased() == "img" else {
            stage = .failed("lc.datapack.notImgFile %@".localizeWithFormat(url.lastPathComponent))
            return
        }
        pickedSource = url
        if existingDatapackSize > 0 {
            confirmOverwrite = true
        } else {
            startCopy(source: url)
        }
    }

    private func startCopy(source: URL) {
        guard let target, let container = LCGameLibraryInfo.defaultContainer(for: target) else {
            stage = .failed("lc.datapack.noContainer".loc)
            return
        }
        let documents = container.containerURL.appendingPathComponent("Documents")
        let dest = documents.appendingPathComponent("romfs.img")
        let tmp = documents.appendingPathComponent("romfs.img.importing")
        let box = CancelBox()
        cancelBox = box
        stage = .copying
        progress = 0
        copiedBytes = 0
        totalBytes = 0

        Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: documents, withIntermediateDirectories: true)
                let expected = Self.fileSize(source)
                await MainActor.run { totalBytes = expected }
                guard expected > 0 else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let written = try await Self.chunkedCopyFile(from: source, to: tmp, isCancelled: { box.cancelled }) { done in
                    await MainActor.run {
                        copiedBytes = done
                        if expected > 0 { progress = Double(done) / Double(expected) }
                    }
                }
                // 校验：拷贝结果与源文件大小一致才替换正式文件
                guard written == expected, Self.fileSize(tmp) == expected else {
                    try? fm.removeItem(at: tmp)
                    throw CocoaError(.fileWriteUnknown)
                }
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.moveItem(at: tmp, to: dest)
                await MainActor.run {
                    resultSize = expected
                    stage = .done
                }
            } catch LCDatapackCopyError.cancelled {
                try? FileManager.default.removeItem(at: tmp)
                await MainActor.run { stage = .ready }
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                await MainActor.run {
                    stage = .failed("lc.datapack.copyFailed %@".localizeWithFormat(error.localizedDescription))
                }
            }
        }
    }

    /// 分块拷贝单个文件（数据包导入的既有机制，文件夹导入与存档导入共用）：
    /// 每块 4MB，块前查取消，写完同步落盘，返回写入字节数。本函数只负责把
    /// 字节完整写到 dest（先清同名残留），大小校验与替换由调用方做。
    nonisolated static func chunkedCopyFile(from source: URL, to dest: URL, isCancelled: () -> Bool, onProgress: (Int64) async -> Void) async throws -> Int64 {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        guard fm.createFile(atPath: dest.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let reader = try FileHandle(forReadingFrom: source)
        let writer = try FileHandle(forWritingTo: dest)
        defer {
            try? reader.close()
            try? writer.close()
        }
        var written: Int64 = 0
        while true {
            if isCancelled() {
                throw LCDatapackCopyError.cancelled
            }
            let chunk = reader.readData(ofLength: lcDatapackChunkSize)
            if chunk.isEmpty { break }
            writer.write(chunk)
            written += Int64(chunk.count)
            await onProgress(written)
        }
        try writer.synchronize()
        return written
    }

    // MARK: 文件夹数据包导入

    /// 文件夹包的解析结果：包根 + 三个落点（romfs.img 走单文件同路替换、
    /// aoc 整夹替换、其余顶层文件原样进 Documents）
    struct FolderPlan {
        let root: URL
        let romfs: URL?
        let aocDirectory: URL?
        let extraFiles: [URL]
    }

    /// 解析所选文件夹为包：顶层有 romfs.img 或 aoc/ 即认；都没有时若顶层
    /// 恰有一个子文件夹且其内有包，按该子文件夹为包根（解压多套一层的常见
    /// 形态，只下钻一层）；仍无 → nil，调用方明确拒绝（散装 romfs 文件夹
    /// 引擎挂载不了，不静默拷一堆文件进去）。
    nonisolated static func resolveFolderPlan(at folder: URL) -> FolderPlan? {
        if let plan = folderPlan(at: folder) {
            return plan
        }
        let directories = topEntries(of: folder).directories
        if directories.count == 1, let plan = folderPlan(at: directories[0]) {
            return plan
        }
        return nil
    }

    nonisolated static func folderPlan(at folder: URL) -> FolderPlan? {
        let entries = topEntries(of: folder)
        let romfs = entries.files.first { $0.lastPathComponent.lowercased() == "romfs.img" }
        let aoc = entries.directories.first { $0.lastPathComponent.lowercased() == "aoc" }
        guard romfs != nil || aoc != nil else {
            return nil
        }
        let extras = entries.files.filter { $0 != romfs }
        return FolderPlan(root: folder, romfs: romfs, aocDirectory: aoc, extraFiles: extras)
    }

    /// 顶层条目（跳过 __MACOSX / .DS_Store / 点开头隐藏项，免得系统杂物进容器）
    nonisolated static func topEntries(of folder: URL) -> (files: [URL], directories: [URL]) {
        var files: [URL] = []
        var directories: [URL] = []
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: []) else {
            return (files, directories)
        }
        for item in items {
            let name = item.lastPathComponent
            if name == "__MACOSX" || name == ".DS_Store" || name.hasPrefix(".") {
                continue
            }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                directories.append(item)
            } else if values?.isRegularFile == true {
                files.append(item)
            }
        }
        return (files, directories)
    }

    /// 目录内普通文件总字节（aoc 这种整夹计进度用）
    nonisolated static func treeSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    /// 目录内全部普通文件（相对路径升序，拷贝顺序稳定；跳过系统杂物）
    nonisolated static func treeFiles(_ url: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var files: [URL] = []
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let components = item.pathComponents
            if components.contains("__MACOSX") || components.contains(".DS_Store") {
                continue
            }
            files.append(item)
        }
        return files.sorted { $0.path < $1.path }
    }

    nonisolated static func relativePath(of url: URL, under base: URL) -> String {
        let path = url.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path
        if path.hasPrefix(basePath + "/") {
            return String(path.dropFirst(basePath.count + 1))
        }
        return url.lastPathComponent
    }

    private func pickedFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        let plan = Self.resolveFolderPlan(at: url)
        if scoped { url.stopAccessingSecurityScopedResource() }
        guard let plan else {
            stage = .failed("lc.datapack.folderRejected".loc)
            return
        }
        pendingFolderPlan = plan
        if folderPlanConflicts(plan) {
            confirmFolderImport = true
        } else {
            pendingFolderPlan = nil
            startFolderImport(plan: plan)
        }
    }

    /// 将被替换的现存内容：带 romfs 时已有数据包、或带 aoc 时已有 aoc 目录
    private func folderPlanConflicts(_ plan: FolderPlan) -> Bool {
        guard let target, let container = LCGameLibraryInfo.defaultContainer(for: target) else { return false }
        let documents = container.containerURL.appendingPathComponent("Documents")
        let fm = FileManager.default
        if plan.romfs != nil, LCGameLibraryInfo.probeDatapack(container: container).imageEntry != nil {
            return true
        }
        if plan.aocDirectory != nil, fm.fileExists(atPath: documents.appendingPathComponent("aoc").path) {
            return true
        }
        return false
    }

    /// 文件夹导入执行：全部内容先分块拷进 Documents/.folder-import-staging
    /// （与目标同卷），逐项过大小校验；全成才逐项替换落点（romfs.img 删旧
    /// 换新、aoc 整夹换、顶层文件同名换），任一步拷贝失败只删 staging、
    /// 现有数据包与 aoc 原样不动。进度/取消/分块与单文件导入共用一套。
    private func startFolderImport(plan: FolderPlan) {
        guard let target, let container = LCGameLibraryInfo.defaultContainer(for: target) else {
            stage = .failed("lc.datapack.noContainer".loc)
            return
        }
        let documents = container.containerURL.appendingPathComponent("Documents")
        let staging = documents.appendingPathComponent(".folder-import-staging", isDirectory: true)
        let box = CancelBox()
        cancelBox = box
        stage = .copying
        progress = 0
        copiedBytes = 0
        totalBytes = 0

        Task.detached(priority: .userInitiated) {
            let scoped = plan.root.startAccessingSecurityScopedResource()
            defer { if scoped { plan.root.stopAccessingSecurityScopedResource() } }
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: documents, withIntermediateDirectories: true)
                if fm.fileExists(atPath: staging.path) {
                    try fm.removeItem(at: staging)
                }
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)

                var totalAcc: Int64 = 0
                if let romfs = plan.romfs { totalAcc += Self.fileSize(romfs) }
                if let aoc = plan.aocDirectory { totalAcc += Self.treeSize(aoc) }
                for file in plan.extraFiles { totalAcc += Self.fileSize(file) }
                guard totalAcc > 0 else {
                    throw CocoaError(.fileNoSuchFile)
                }
                // 定格为 let 再进各闭包捕获（var 捕获在并发闭包里会触发 Swift 6 模式诊断）
                let total = totalAcc
                await MainActor.run { totalBytes = total }

                var base: Int64 = 0
                func copyOne(_ source: URL, to dest: URL) async throws {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let start = base
                    let written = try await Self.chunkedCopyFile(from: source, to: dest, isCancelled: { box.cancelled }) { done in
                        let acc = start + done
                        await MainActor.run {
                            copiedBytes = acc
                            if total > 0 { progress = Double(acc) / Double(total) }
                        }
                    }
                    guard written == Self.fileSize(source) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    base += written
                }

                if let romfs = plan.romfs {
                    try await copyOne(romfs, to: staging.appendingPathComponent("romfs.img"))
                }
                if let aoc = plan.aocDirectory {
                    for file in Self.treeFiles(aoc) {
                        let relative = Self.relativePath(of: file, under: aoc)
                        try await copyOne(file, to: staging.appendingPathComponent("aoc").appendingPathComponent(relative))
                    }
                }
                for file in plan.extraFiles {
                    try await copyOne(file, to: staging.appendingPathComponent(file.lastPathComponent))
                }

                // 提交：staging 与目标同卷，逐项删旧换新（rename 级操作）
                func commit(_ staged: URL, to dest: URL) throws {
                    guard fm.fileExists(atPath: staged.path) else { return }
                    if fm.fileExists(atPath: dest.path) {
                        try fm.removeItem(at: dest)
                    }
                    try fm.moveItem(at: staged, to: dest)
                }
                if plan.romfs != nil {
                    try commit(staging.appendingPathComponent("romfs.img"), to: documents.appendingPathComponent("romfs.img"))
                }
                if plan.aocDirectory != nil {
                    try commit(staging.appendingPathComponent("aoc"), to: documents.appendingPathComponent("aoc"))
                }
                for file in plan.extraFiles {
                    try commit(staging.appendingPathComponent(file.lastPathComponent), to: documents.appendingPathComponent(file.lastPathComponent))
                }
                try? fm.removeItem(at: staging)

                let result = plan.romfs.map { Self.fileSize($0) } ?? total
                await MainActor.run {
                    resultSize = result
                    stage = .done
                }
            } catch LCDatapackCopyError.cancelled {
                try? FileManager.default.removeItem(at: staging)
                await MainActor.run { stage = .ready }
            } catch {
                try? FileManager.default.removeItem(at: staging)
                await MainActor.run {
                    stage = .failed("lc.datapack.folderFailed %@".localizeWithFormat(error.localizedDescription))
                }
            }
        }
    }

    // MARK: 小件

    private func gameIcon(_ app: LCAppModel) -> some View {
        Group {
            if let icon = app.appInfo.iconIsDarkIcon(false) {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.fill")
                    .font(.title)
                    .foregroundColor(.gray)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func datapackStatusText(for app: LCAppModel) -> some View {
        // 走共用求值入口（先对齐快照再解析容器），与库主页同一口径
        let ready = LCGameLibraryInfo.datapackReady(for: app)
        return HStack(spacing: 6) {
            Circle()
                .fill(ready ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(ready ? "lc.datapack.statusReady".loc : "lc.datapack.statusMissing".loc)
                .font(.footnote)
                .foregroundColor(.gray)
        }
    }

    nonisolated static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize { return Int64(size) }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    nonisolated static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
