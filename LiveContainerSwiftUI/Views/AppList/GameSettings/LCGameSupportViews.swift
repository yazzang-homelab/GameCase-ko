//
//  LCGameSupportViews.swift
//  LiveContainerSwiftUI
//
//  日志查看器与状态帮助：照 NX2Apple 壳的 LogReader / LogView
//  （ShellHost/LogReader.swift、ShellHost/ShellHostView.swift）与
//  GameStateView / StateHelpView（ShellUI/GameStateView.swift）移植：
//   - 日志只读、只取尾部 256KB（NX2 LogReader.maxBytes 同值），长日志
//     顶部注明只显示末尾；没有日志时给明确空态文案；
//   - 帮助内容 = 状态名 + 一句说明 + 「怎么修」正文 + （损坏时）
//     详情小字（等宽、可选中，方便报障时复制）；动作按状态分：
//     缺数据包 → 导入数据包；已损坏 → 查看日志 / 重新导入数据包。
//  GC 适配点：NX 的帮助页是 sheet、设置页内是 GameStateView 行内块，
//  GC 同构——设置页 detailLead 用行内卡（LCGameStateHelpCard），主页
//  状态行点开 sheet（LCGameStateHelpSheet），两者共用同一份内容
//  （LCGameStateHelpContent）。样式常量（奶油胶囊 / 浅底钮 / 卡面）
//  NX 值在设置页文件里是 file-private，本文件按同值自带一份。
//

import SwiftUI

extension LCGameState {
    /// 状态色（主页口径：LCGameTheme 三色；设置页头部另用本页私有的
    /// LCNXColor 同值映射，两处色值一致）
    var themeColor: Color {
        switch self {
        case .playable, .notRequired: return LCGameTheme.readyGreen
        case .needsDatapack: return LCGameTheme.missingAmber
        case .broken: return LCGameTheme.brokenRed
        }
    }
}

// MARK: - 日志读取（NX2 LogReader 移植）

enum LCGameLogReader {
    static let maxBytes = 256 * 1024

    /// log.txt 的尾部（最多 maxBytes），文件不存在 / 读不到返回 nil。
    /// 整段一次读：日志通常不大，过长时只取末尾并标 truncated。
    static func readTail(of url: URL, maxBytes: Int = LCGameLogReader.maxBytes) -> (text: String, truncated: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else {
            return nil
        }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else {
            return nil
        }
        return (String(decoding: data, as: UTF8.self), start > 0)
    }
}

// MARK: - 日志查看器（NX2 LogView 移植）

struct LCGameLogView: View {
    let app: LCAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var loaded: (text: String, truncated: Bool)?
    @State private var didLoad = false

    private var hasText: Bool {
        !(loaded?.text.isEmpty ?? true)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if hasText, let loaded {
                        if loaded.truncated {
                            Text("lc.gameSettings.logTruncated".loc)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        Text(verbatim: loaded.text)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        Text("lc.gameSettings.logEmpty".loc)
                            .font(.system(size: 14.5))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .navigationTitle(app.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("lc.common.done".loc) { dismiss() }
                }
            }
        }
        .onAppear {
            guard !didLoad else {
                return
            }
            didLoad = true
            if let url = LCGameLibraryInfo.guestLogURL(for: app) {
                loaded = LCGameLogReader.readTail(of: url)
            }
        }
    }
}

// MARK: - 帮助内容（卡与页共用）

/// NX PrimaryPillStyle 同值本地版（可满宽）：奶油底黑字、bold 17、
/// minHeight 50、按下 opacity 0.78 + scale 0.98。
/// iOS 26 + Liquid Glass 可用时底换原生玻璃（无 tint，随外观自适应，
/// 浅色下即浅色玻璃）；玻璃分支的前景改语义色 .primary——原黑字压
/// 无 tint 深色玻璃对比偏弱（#61 装机待验点），primary 深色为白、
/// 浅色为黑，两模式都可读，就不再给玻璃加奶油 tint。按下
/// opacity/scale 两分支共用、逐字保留。否则逐字保留奶油底原实现。
private struct LCStatePillStyle: ButtonStyle {
    var expands = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 26)
            .frame(maxWidth: expands ? .infinity : nil, minHeight: 50)
            .modifier { content in
                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    content
                        .foregroundColor(.primary)
                        .glassEffect(.regular, in: .capsule)
                } else {
                    content
                        .foregroundColor(.black)
                        .background(LCGameTheme.nxCream, in: Capsule())
                }
            }
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// NX ShellButtonStyle(fills: true) 同值本地版：满宽浅底钮。
/// iOS 26 + Liquid Glass 可用时底换原生玻璃（无 tint，随外观自适应；
/// 玻璃无底色深浅差，按下反馈改走 opacity）；否则逐字保留原实现。
private struct LCStateShellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundColor(.primary)
            .modifier { content in
                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    content
                        .glassEffect(.regular, in: .rect(cornerRadius: 9))
                        .opacity(configuration.isPressed ? 0.82 : 1)
                } else {
                    content
                        .background(Color.primary.opacity(configuration.isPressed ? 0.13 : 0.055),
                                    in: RoundedRectangle(cornerRadius: 9))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                        }
                }
            }
    }
}

/// 状态帮助正文：状态行（点 + 状态名）/ 说明 / 怎么修 / 损坏详情 /
/// 状态动作。与 NX2 GameStateView + StateHelpView 的信息层级一致。
struct LCGameStateHelpContent: View {
    let state: LCGameState
    var onImportDatapack: () -> Void
    var onShowLog: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.themeColor)
                    .frame(width: 7, height: 7)
                Text(state.title)
                    .font(.system(size: 11.5, weight: .bold))
                    .tracking(1.3)
                    .foregroundColor(state.themeColor)
            }
            if !state.explanation.isEmpty {
                Text(state.explanation)
                    .font(.system(size: 14.5))
                    .foregroundColor(.primary.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !state.fixText.isEmpty {
                Text(state.fixText)
                    .font(.system(size: 15))
                    .foregroundColor(.primary.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .broken(_, _, let technical) = state, !technical.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("lc.gameSettings.details".loc)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.5))
                    Text(verbatim: technical)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            switch state {
            case .playable, .notRequired:
                EmptyView()
            case .needsDatapack:
                Button {
                    onImportDatapack()
                } label: {
                    Label("lc.gameSettings.importDatapack".loc, systemImage: "folder")
                }
                .buttonStyle(LCStatePillStyle())
                .padding(.top, 4)
            case .broken:
                VStack(spacing: 10) {
                    Button("lc.gameSettings.viewLog".loc) { onShowLog() }
                        .buttonStyle(LCStateShellButtonStyle())
                    Button("lc.gameSettings.reimportDatapack".loc) { onImportDatapack() }
                        .buttonStyle(LCStateShellButtonStyle())
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 设置页行内帮助卡：卡面与设置页 sectionCard 同值（0.10 灰、圆角
/// 16、白 0.08 发丝线），内容即 LCGameStateHelpContent。
struct LCGameStateHelpCard: View {
    let state: LCGameState
    var onImportDatapack: () -> Void
    var onShowLog: () -> Void

    var body: some View {
        LCGameStateHelpContent(state: state, onImportDatapack: onImportDatapack, onShowLog: onShowLog)
            .padding(18)
            // 卡面随外观翻转（深色值与原硬编码逐字一致、浅色纯白）：内容
            // 文字已改 primary 自适应，卡面不翻的话浅色下黑字压深卡不可读
            .background(Color(UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1)
                    : UIColor(red: 1, green: 1, blue: 1, alpha: 1)
            }), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

/// 主页帮助页（sheet）：NX2 StateHelpView 排布——内容在上、「完成」
/// 奶油胶囊满宽在下；损坏态的「查看日志」在内容里，点了在本页之上
/// 再叠一层日志页。导入动作先关本页再走主页既有导入流（两层 sheet
/// 不叠呈现，与设置页相册选图的延后手法同理）。
struct LCGameStateHelpSheet: View {
    let app: LCAppModel
    let state: LCGameState
    var onImportDatapack: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var logPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LCGameStateHelpContent(state: state, onImportDatapack: {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    onImportDatapack()
                }
            }, onShowLog: {
                logPresented = true
            })
            Button {
                dismiss()
            } label: {
                Text("lc.common.done".loc)
            }
            .buttonStyle(LCStatePillStyle(expands: true))
            .padding(.top, 8)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LCGameTheme.pageBackground.ignoresSafeArea())
        .sheet(isPresented: $logPresented) {
            LCGameLogView(app: app)
        }
    }
}
