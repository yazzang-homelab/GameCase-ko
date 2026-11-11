//
//  LCSettingsColumn.swift
//  LiveContainerSwiftUI
//
//  设置类页面横屏定宽列（NX2Apple 壳通则：ShellSettingsView / ControllersView /
//  TouchLayoutEditorView 的设置类页面内容列统一 640pt）。
//
//  约束必须加在决定内容宽度的容器本体上：PR #10 把 .frame(maxWidth: 640)
//  加在 ScrollView 的内容 VStack 上，真机落点不精确——用户截图实测（956pt
//  横屏）：游戏设置页列宽 ≈669pt（居中但宽于规格），手柄页列宽 ≈668pt 且
//  靠左贴边（照抄 NX 时连 .leading 对齐一起抄了）。滚动内容的帧不治理滚动
//  视口的宽度，视口多宽、行与卡片就多宽。本容器在页面根层用 GeometryReader
//  读页面自身尺寸：横向（宽 > 高）时给内容容器（ScrollView / Form 本体）
//  显式定宽 min(640, 可用宽) 并居中；竖向时宽 = 可用全宽、高 = 可用全高，
//  与不加约束时逐点一致（竖屏零变化）。闭包参数 isLandscape 仍向页内
//  报告横竖屏判定（Phase 14 起游戏设置页头部已全形态统一为图标头、
//  不再读它，其余页可按需取用）。
//
//  横屏侧面板内（Phase 14，环境 lcInSidePanel = true）：640 在 NX 里
//  本就是面板内部内容列的上限、面板宽（≤520）恒小于它——本容器必须
//  退化为全宽填充，不得再叠一层收窄或居中偏移；同时 isLandscape 恒
//  置 true：面板内页自身宽 < 高是常态（手机横屏面板约 410×430），
//  若按页自身宽高判横竖，游戏设置页头部会误落竖屏图标头。横屏语义
//  由呈现形态决定。sheet 呈现（不带此环境）行为与原来逐点一致。
//
//  面板内右侧死空（Phase 16）：Phase 14 只退化了列宽，没退化安全区
//  消费。面板贴在屏幕右缘，窗口的横向 safe inset 是位置性的——面板
//  区域只压在尾部不安全带上（灵动岛侧 ≈59pt），页内的 NavigationView
//  内容区与 ScrollView 的自动内容安全区调整便把这 59pt 单侧计入，
//  叠在内容自己的 padding 之上：真机丝之歌面板内分组卡左距 ≈30、
//  右距 ≈120。NX2 壳在提交 d38ed0b8（「Landscape panels narrower
//  again, with even margins」）修过同病：设置类页面的 ScrollView 不
//  再吃横向 safe inset（.ignoresSafeArea(edges: [.leading,
//  .trailing])），每游戏页删掉第二次叠加的尾部 inset，边距只由内容
//  自己的 padding 决定。本容器照此：面板内时整页根层忽略横向安全
//  区，GeometryReader 量到的就是面板全宽、列按全宽落位，左右边距
//  对称（各页自己的 padding，面板内按 NX 口径 24）。非面板形态
//  （竖屏整屏横向 inset 本为 0、横屏居中列形态）不加此忽略，
//  与 Phase 12/14 行为逐点一致。
//
//  Phase 22 起 lcInSidePanel 由自适应宿主按「当前形态」现置：
//  floating 面板形态为 true、整屏形态为 false，旋转时随形态翻转，
//  本容器的列宽 / 安全区语义跟着原地切换（页面实例不重建）。
//
//  灵动岛右侧留白（搬运 S2Arm 上游 PR #452 的合并形态，上游提交
//  026bff15「灵动岛转到右边时，设置浮窗和设置页右侧照扣安全区」，
//  用户 2026-11-11 在 S2Arm 线拍板保留、再令搬入 GC）：面板贴屏幕
//  右缘、整页忽略横向 safe inset 时，行尾的开关 / 分段条直达物理
//  右缘；iPhone 横屏时系统给左右两边同样的安全区（灵动岛机型
//  59pt），但灵动岛只在一边——转到右边时右侧控件会被它盖住。故
//  判定与 S2Arm 的 SensorEdge 逐字同构：手机且界面朝向为
//  landscapeLeft（设备顶部、即传感器那一端在右）时，面板内只忽
//  略 leading 一边、trailing 照常计入（行右缘退回安全区内，内容
//  自己的 padding 之外再留 59pt）；其余情形（竖屏、朝向相反、
//  无岛 / iPad）维持现行两侧全忽略的全宽布局。S2Arm 把该判定做
//  成独立的 TrailingOverlaySafeArea 修饰器逐页挂（壳设置页 / 手
//  柄页），另在库页浮窗用 padding 内联现算；GC 的三页（游戏设
//  置 / 宿主设置 / 手柄）共用本容器一处根层，等价映射为把朝向
//  状态收进本容器：出现在面板内时读一次、每次设备转向时刷新
//  （面板常驻、旋转时输入不变，页面不一定重画——与 S2Arm 把朝
//  向放进状态的理由相同）。整屏形态不经此路：640 居中列在横屏
//  左右各留 ≥117pt，行不达右缘，与岛无关，逐点不变。
//

import SwiftUI
import UIKit

/// 横屏时灵动岛 / 刘海在不在界面的右侧（trailing）：S2Arm
/// SensorEdge 的等价搬运（出处见文件头注）。竖屏、iPad 恒 false。
enum GCSensorEdge {
    @MainActor static var onTrailing: Bool {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }.first
        return UIDevice.current.userInterfaceIdiom == .phone
            && scene?.interfaceOrientation == .landscapeLeft
    }
}

struct LCSettingsColumn<Content: View>: View {
    @ViewBuilder var content: (_ isLandscape: Bool) -> Content
    @Environment(\.lcInSidePanel) private var inSidePanel
    /// 灵动岛当前是否在界面右侧（仅面板形态用，见文件头注）：出现
    /// 时与每次设备转向时刷新，语义与 S2Arm TrailingOverlaySafeArea
    /// 的同名状态一致。
    @State private var sensorOnTrailing = false

    var body: some View {
        if inSidePanel {
            reader
                .ignoresSafeArea(edges: sensorOnTrailing ? [.leading] : [.leading, .trailing])
                .onAppear { sensorOnTrailing = GCSensorEdge.onTrailing }
                .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                    sensorOnTrailing = GCSensorEdge.onTrailing
                }
        } else {
            reader
        }
    }

    private var reader: some View {
        GeometryReader { geo in
            let isLandscape = inSidePanel || geo.size.width > geo.size.height
            let columnWidth = inSidePanel ? geo.size.width
                : (isLandscape ? min(640, geo.size.width) : geo.size.width)
            content(isLandscape)
                .frame(width: columnWidth, height: geo.size.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}
