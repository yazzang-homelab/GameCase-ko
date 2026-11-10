//
//  LCControllersView.swift
//  LiveContainerSwiftUI
//
//  手柄页：复刻 NX2Apple 壳 ControllersView 的结构、视觉与文案（主页手柄胶囊点开，
//  sheet 呈现）。组成：页题 + 关闭钮、已连接手柄卡（玩家号 / 名称 / 电量片）、
//  空状态卡、「按钮」分组（按键测试入口 → 实时按键测试）。
//  未搬入的部分及原因见 PR #5 报告：按键映射（壳侧映射表由客体引擎消费，LC 宿主
//  没有对应落点）、「手柄操作」提示（那是壳内手柄导航的说明，LC 游戏库只有触控）。
//

import SwiftUI
import GameController

struct LCControllersView: View {
    @ObservedObject var monitor: LCControllerMonitor
    /// 横屏侧面板呈现时的关闭回调（Phase 14，主页注入）：面板不是系统
    /// 呈现，dismiss 环境无效，关闭走此回调；nil = sheet 呈现，用
    /// dismiss 关闭，与原来一致。
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    /// 当前是否 floating 侧面板形态（宿主按当前形态现置）：整屏
    /// 形态下本页要自己垫顶部安全区（见 body 的 topContentPad），
    /// 面板形态恒不垫（面板贴右全高、顶部即其物理顶）
    @Environment(\.lcInSidePanel) private var inSidePanel
    @State private var showTest = false
    /// 电量订阅（LCBatteryObserver）：GCDeviceBattery 支持 KVO（苹果
    /// WWDC20 10614 给的机制），batteryLevel 一变就 bump revision 重读；
    /// 30 秒定时器保留作兜底（个别设备不发 KVO、充电等状态变化也不
    /// 一定伴随 level 变化），并周期性重对齐订阅集合。
    @StateObject private var batteryObserver = LCBatteryObserver()
    @State private var batteryTick = 0

    // NX 壳 ShellPalette 原值；自适应轮改动态色：深色变体与原值逐字
    // 一致，浅色变体与设置页 LCNXColor 同口径（页底 0.96 灰白、卡面
    // 白、奶油金棕、发丝线黑 0.08）。状态色两模式共用、不翻。
    private static let background = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.055, blue: 0.06, alpha: 1)
            : UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
    })
    private static let surface = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1)
            : UIColor(red: 1, green: 1, blue: 1, alpha: 1)
    })
    private static let cream = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0.94, blue: 0.84, alpha: 1)
            : UIColor(red: 0.66, green: 0.47, blue: 0.16, alpha: 1)
    })
    private static let ready = Color(red: 0.25, green: 0.84, blue: 0.47)
    private static let attention = Color(red: 1, green: 0.78, blue: 0.24)
    private static let hairline = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.08)
    })

    private struct RowInfo: Identifiable {
        let id: ObjectIdentifier
        let name: String
        let player: Int
        let batteryPercent: Int?
        let charging: Bool
    }

    private var rows: [RowInfo] {
        _ = batteryTick
        _ = batteryObserver.revision
        return monitor.controllers.enumerated().map { index, controller in
            let battery = Self.battery(of: controller)
            return RowInfo(
                id: ObjectIdentifier(controller),
                name: controller.vendorName ?? "lc.controllers.defaultName".loc,
                player: index + 1,
                batteryPercent: battery.percent,
                charging: battery.charging
            )
        }
    }

    /// 电量读法：state 为 unknown 视为不报告电量；state 已报但 level
    /// 仍为 0 同样视为未报告——苹果文档明示 batteryLevel 默认值就是
    /// 0.0（框架尚未从设备拿到真实电量报告时的占位），旧读法只查
    /// state、把这个占位 0 当真电量渲染成「0%」（还带低电量琥珀色），
    /// Joy-Con 类手柄经 GameController 的 level 长期停在默认值上，
    /// 于是恒显 0%。真实 0% 时手柄已断电断开、不会出现在列表里，
    /// 这一档不会误伤真没电。其余按比例取整（钳到 0–100）。
    /// charging 是 state 能确定的事实，level 未报告时也照实回传。
    private static func battery(of controller: GCController) -> (percent: Int?, charging: Bool) {
        if #available(iOS 17.0, *) {
            guard let battery = controller.battery, battery.batteryState != .unknown else {
                return (nil, false)
            }
            let charging = battery.batteryState == .charging
            guard battery.batteryLevel > 0 else {
                return (nil, charging)
            }
            let percent = Int((min(1, battery.batteryLevel) * 100).rounded())
            return (percent, charging)
        }
        return (nil, false)
    }

    /// 整屏形态的内容顶垫（Phase 26）：页面背景画满到物理顶、内容
    /// （标题行 / X / 按键测试子页的返回钮）在背景内侧下移一个窗
    /// 口顶部安全区，避开灵动岛。Phase 24 曾由宿主在内容外侧垫
    /// （连宿主页底色带与圆角线一起），Phase 26 改由页面自垫：
    /// 垫加在根 Group 上、背景修饰之前——背景按垫后的帧再
    /// ignoresSafeArea 画满整帧，顶部那条是页面自己的底色而非宿
    /// 主的。面板形态（inSidePanel）恒 0，现行面板内排布逐点不
    /// 变；数值取窗口真值、逐次求值现读，旋转后即为新方向的值。
    private var topContentPad: CGFloat {
        inSidePanel ? 0 : LCSidePanelSpec.windowTopSafeInset
    }

    var body: some View {
        Group {
            if showTest {
                LCControllerTestView(onBack: { showTest = false })
            } else {
                listPage
            }
        }
        .padding(.top, topContentPad)
        .background(Self.background.ignoresSafeArea())
        .foregroundStyle(.primary)
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            batteryTick += 1
            batteryObserver.sync()
        }
    }

    // MARK: 列表页（NX ControllersView 本体）

    private var listPage: some View {
        // 横屏定宽与游戏设置页同一层：LCSettingsColumn 把 ScrollView 本体
        // 定宽 640 并居中（PR #10 在内容 VStack 上加 maxWidth、且外层照抄了
        // NX 的 .leading 对齐，真机列宽 ≈668pt 还靠左贴边、右侧留死黑；
        // 视口层定宽后列居中、宽度精确——见 LCSettingsColumn.swift）。
        LCSettingsColumn { _ in
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .center) {
                    Text("lc.controllers.title".loc)
                        .font(.system(size: 26, weight: .heavy))
                        .tracking(-0.6)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 8)
                    Button {
                        if let onClose {
                            onClose()
                        } else {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .modifier { content in
                                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                                    content.glassEffect(.regular.interactive(), in: .circle)
                                } else {
                                    content.background(Color.primary.opacity(0.08), in: Circle())
                                }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("lc.controllers.closeA11y".loc)
                }
                if rows.isEmpty {
                    emptyCard
                } else {
                    controllerCard
                }
                buttonsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lcHideScrollIndicators()
        }
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Self.cream)
                .padding(.bottom, 4)
            Text("lc.controllers.noneConnected".loc)
                .font(.system(size: 19, weight: .bold))
            Text("lc.controllers.noneConnectedDesc".loc)
                .font(.system(size: 14.5))
                .foregroundStyle(.primary.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Self.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Self.hairline))
    }

    private var controllerCard: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                controllerRow(row)
                if row.id != rows.last?.id {
                    Rectangle()
                        .fill(Self.hairline)
                        .frame(height: 1)
                        .padding(.leading, 64)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(Self.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Self.hairline))
    }

    private func controllerRow(_ row: RowInfo) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 20))
                .frame(width: 48, height: 48)
                .background(.primary.opacity(0.07), in: Circle())
                .foregroundStyle(.primary.opacity(0.9))
            VStack(alignment: .leading, spacing: 4) {
                Text("lc.controllers.playerN %lld".localizeWithFormat(row.player))
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Self.cream.opacity(0.8))
                Text(row.name)
                    .font(.system(size: 16, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            batteryChip(row)
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
    }

    /// 电量片（NX BatteryChip）：描边电池形 + 百分比，低电量琥珀、充电绿
    private func batteryChip(_ row: RowInfo) -> some View {
        let low = (row.batteryPercent ?? 100) < 20 && !row.charging
        let tint: Color = low ? Self.attention : row.charging ? Self.ready : .primary.opacity(0.75)
        return HStack(spacing: 7) {
            if let percent = row.batteryPercent {
                batteryShape(fraction: Double(percent) / 100)
                    .foregroundStyle(tint)
                Text("\(percent)%")
                    .monospacedDigit()
                if row.charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10))
                        .accessibilityLabel("lc.controllers.charging".loc)
                }
            } else if row.charging {
                // 百分比没拿到就不编数字；但「在充电」是 state 能确定
                // 的事实，照实显示（与有百分比时的闪电标同语义）
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                Text("lc.controllers.charging".loc)
            } else {
                Text("lc.controllers.noBatteryInfo".loc)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(row.batteryPercent == nil && !row.charging ? .primary.opacity(0.45) : tint)
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .background(.primary.opacity(0.06), in: Capsule())
    }

    private func batteryShape(fraction: Double) -> some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(lineWidth: 1.2)
                    .opacity(0.7)
                RoundedRectangle(cornerRadius: 1.5)
                    .padding(2.5)
                    .frame(width: max(7, 22 * min(1, max(0, fraction))))
            }
            .frame(width: 22, height: 11)
            RoundedRectangle(cornerRadius: 1)
                .frame(width: 1.5, height: 4)
                .opacity(0.7)
        }
    }

    // MARK: 「按钮」分组（NX 同名分组：映射行依赖客体引擎、未搬；只留按键测试）

    private var buttonsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("lc.controllers.buttonsSection".loc)
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(.primary.opacity(0.55))
            Button {
                showTest = true
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("lc.controllers.buttonTest".loc)
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("lc.controllers.buttonTestDesc".loc)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary.opacity(0.55))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.4))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .modifier { content in
                    if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                        content
                            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                    } else {
                        content
                            .background(Self.surface, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Self.hairline))
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 手柄电量观察（KVO 订阅 GCDeviceBattery.batteryLevel）

/// 订阅每个已连接手柄的 batteryLevel：苹果在 WWDC20 10614 明确给了
/// KVO 这条路——level 一变就 bump revision 让手柄页重读，取代旧的
/// 「只靠进页面快照 + 定时器重读」。手柄集合变化（连接/断开通知）
/// 与页面定时器都会触发 sync() 重新对齐订阅：新到手柄补订、
/// 断开的手柄退订、battery 对象晚到也能补上。只订阅 level；
/// charging 等 state 变化由页面 30 秒定时器兜底重读。
private final class LCBatteryObserver: ObservableObject {
    @Published private(set) var revision = 0

    private var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var centerObservers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        centerObservers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.sync()
        })
        centerObservers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.sync()
        })
        sync()
    }

    deinit {
        centerObservers.forEach { NotificationCenter.default.removeObserver($0) }
        observations.values.forEach { $0.invalidate() }
    }

    /// 与当前已连接手柄的 battery 对象对齐订阅（幂等）
    func sync() {
        guard #available(iOS 17.0, *) else { return }
        var live = Set<ObjectIdentifier>()
        for controller in GCController.controllers() {
            guard let battery = controller.battery else { continue }
            let id = ObjectIdentifier(battery)
            live.insert(id)
            if observations[id] == nil {
                observations[id] = battery.observe(\.batteryLevel, options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async {
                        self?.revision += 1
                    }
                }
            }
        }
        for id in Array(observations.keys) where !live.contains(id) {
            observations[id]?.invalidate()
            observations[id] = nil
        }
    }
}

// MARK: - 按键测试（NX ButtonTestView 的行为复刻：按键亮起、摇杆移动、扳机填充）

private struct LCControllerTestView: View {
    let onBack: () -> Void

    private struct Snapshot {
        var name: String = ""
        var a = false, b = false, x = false, y = false
        var up = false, down = false, left = false, right = false
        var l1 = false, r1 = false
        var l2: Float = 0, r2: Float = 0
        var menu = false, options = false, home = false
        var l3 = false, r3 = false
        var ls = CGPoint.zero, rs = CGPoint.zero
    }

    @State private var snapshot: Snapshot?
    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private static let card = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.075, green: 0.075, blue: 0.082, alpha: 1)
            : UIColor(red: 1, green: 1, blue: 1, alpha: 1)
    })
    private static let cream = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0.94, blue: 0.84, alpha: 1)
            : UIColor(red: 0.66, green: 0.47, blue: 0.16, alpha: 1)
    })
    private static let hairline = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.08)
    })

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("lc.controllers.buttonTest".loc)
                            .font(.system(size: 20, weight: .bold))
                            .lineLimit(1)
                        Text(headerName)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary.opacity(0.5))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .modifier { content in
                                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                                    content.glassEffect(.regular.interactive(), in: .circle)
                                } else {
                                    content.background(.primary.opacity(0.08), in: Circle())
                                }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("lc.controllers.backA11y".loc)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 8)
                Rectangle()
                    .fill(Self.hairline)
                    .frame(height: 1)
                diagram
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 10)
                Text(pressedText)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Self.cream)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                Text("lc.controllers.testHint".loc)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 18)
                    .padding(.top, 4)
            }
            .frame(maxWidth: 620)
            .modifier { content in
                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    // 测试页主卡换玻璃面（描边保留，压在页面底色上仍有边界）
                    content
                        .glassEffect(.regular, in: .rect(cornerRadius: 26))
                        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.primary.opacity(0.10)))
                } else {
                    content
                        .background(Self.card, in: RoundedRectangle(cornerRadius: 26))
                        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.primary.opacity(0.10)))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .lcHideScrollIndicators()
        .onReceive(tick) { _ in
            refresh()
        }
        .onAppear {
            refresh()
        }
    }

    private var headerName: String {
        if let name = snapshot?.name, !name.isEmpty {
            return name
        }
        return "lc.controllers.pressAnyButton".loc
    }

    // MARK: 简图（面键菱形 + 十字键 + 双摇杆 + 肩键/扳机条）

    private var diagram: some View {
        let s = snapshot ?? Snapshot()
        return VStack(spacing: 16) {
            HStack(spacing: 14) {
                triggerBar(label: "L2", value: s.l2)
                triggerBar(label: "R2", value: s.r2)
            }
            HStack {
                shoulderChip(label: "L1", pressed: s.l1)
                Spacer()
                shoulderChip(label: "R1", pressed: s.r1)
            }
            HStack(alignment: .center, spacing: 10) {
                stickView(point: s.ls, pressed: s.l3, label: "lc.controllers.leftStick".loc)
                dpadView(s)
                centerChips(s)
                faceButtons(s)
                stickView(point: s.rs, pressed: s.r3, label: "lc.controllers.rightStick".loc)
            }
        }
    }

    private func triggerBar(label: String, value: Float) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(value > 0.02 ? Self.cream : .primary.opacity(0.55))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Self.cream)
                        .frame(width: geo.size.width * CGFloat(min(1, max(0, value))))
                }
            }
            .frame(height: 8)
        }
        .frame(maxWidth: .infinity)
    }

    /// 指示件底（肩键/中键片/面键/十字键/摇杆点共用口径）：按下态恒
    /// 实色填充（亮起反馈优先，不玻璃化）；未按态在玻璃分支换玻璃，
    /// 非玻璃保留原浅底。
    private func shoulderChip(label: String, pressed: Bool) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(pressed ? .black : .primary.opacity(0.7))
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background {
                if pressed {
                    Capsule().fill(Self.cream)
                } else if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    Capsule().fill(.clear).glassEffect(.regular, in: .capsule)
                } else {
                    Capsule().fill(Color.primary.opacity(0.08))
                }
            }
    }

    private func stickView(point: CGPoint, pressed: Bool, label: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.18), lineWidth: 1.5)
                    .frame(width: 56, height: 56)
                Group {
                    if pressed {
                        Circle().fill(Self.cream)
                    } else if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                        Circle().fill(.clear).glassEffect(.regular, in: .circle)
                    } else {
                        Circle().fill(Color.primary.opacity(0.35))
                    }
                }
                .frame(width: 14, height: 14)
                .offset(x: point.x * 18, y: point.y * 18)
            }
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.primary.opacity(0.5))
        }
    }

    private func dpadView(_ s: Snapshot) -> some View {
        let cell: CGFloat = 17
        func piece(_ pressed: Bool) -> some View {
            ZStack {
                if pressed {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Self.cream)
                } else if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.clear)
                        .glassEffect(.regular, in: .rect(cornerRadius: 3))
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.14))
                }
            }
            .frame(width: cell, height: cell)
        }
        return VStack(spacing: 2) {
            HStack(spacing: 2) {
                Color.clear.frame(width: cell, height: cell)
                piece(s.up)
                Color.clear.frame(width: cell, height: cell)
            }
            HStack(spacing: 2) {
                piece(s.left)
                piece(s.up || s.down || s.left || s.right)
                piece(s.right)
            }
            HStack(spacing: 2) {
                Color.clear.frame(width: cell, height: cell)
                piece(s.down)
                Color.clear.frame(width: cell, height: cell)
            }
        }
    }

    private func centerChips(_ s: Snapshot) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                miniChip(label: "lc.controllers.menu".loc, pressed: s.menu)
                miniChip(label: "lc.controllers.options".loc, pressed: s.options)
            }
            HStack(spacing: 8) {
                miniChip(label: "lc.controllers.home".loc, pressed: s.home)
            }
        }
    }

    private func miniChip(label: String, pressed: Bool) -> some View {
        Text(label)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(pressed ? .black : .primary.opacity(0.6))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                if pressed {
                    Capsule().fill(Self.cream)
                } else if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    Capsule().fill(.clear).glassEffect(.regular, in: .capsule)
                } else {
                    Capsule().fill(Color.primary.opacity(0.08))
                }
            }
    }

    private func faceButtons(_ s: Snapshot) -> some View {
        let d: CGFloat = 33
        func button(_ label: String, _ color: Color, _ pressed: Bool) -> some View {
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(pressed ? .black : color)
                .frame(width: d, height: d)
                .background {
                    if pressed {
                        Circle().fill(color)
                    } else if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                        Circle().fill(.clear).glassEffect(.regular, in: .circle)
                    } else {
                        Circle().fill(Color.primary.opacity(0.07))
                    }
                }
                .overlay(Circle().strokeBorder(color.opacity(0.55), lineWidth: 1))
        }
        let yellow = Color(red: 0.95, green: 0.78, blue: 0.25)
        let blue = Color(red: 0.35, green: 0.58, blue: 0.95)
        let red = Color(red: 0.92, green: 0.36, blue: 0.31)
        let green = Color(red: 0.36, green: 0.80, blue: 0.46)
        return VStack(spacing: 3) {
            button("Y", yellow, s.y)
            HStack(spacing: 14) {
                button("X", blue, s.x)
                button("B", red, s.b)
            }
            button("A", green, s.a)
        }
    }

    // MARK: 快照读取（第一个已连接手柄；扩展手柄优先，微型手柄取其子集）

    private var pressedText: String {
        guard let s = snapshot else {
            return "lc.controllers.nothingPressed".loc
        }
        var names: [String] = []
        if s.y { names.append("Y") }
        if s.x { names.append("X") }
        if s.b { names.append("B") }
        if s.a { names.append("A") }
        if s.up { names.append("lc.controllers.dpadUp".loc) }
        if s.down { names.append("lc.controllers.dpadDown".loc) }
        if s.left { names.append("lc.controllers.dpadLeft".loc) }
        if s.right { names.append("lc.controllers.dpadRight".loc) }
        if s.l1 { names.append("L1") }
        if s.r1 { names.append("R1") }
        if s.l2 > 0.02 { names.append("L2") }
        if s.r2 > 0.02 { names.append("R2") }
        if s.l3 { names.append("lc.controllers.leftStickPress".loc) }
        if s.r3 { names.append("lc.controllers.rightStickPress".loc) }
        if hypot(s.ls.x, s.ls.y) > 0.35 { names.append("lc.controllers.leftStick".loc) }
        if hypot(s.rs.x, s.rs.y) > 0.35 { names.append("lc.controllers.rightStick".loc) }
        if s.menu { names.append("lc.controllers.menu".loc) }
        if s.options { names.append("lc.controllers.options".loc) }
        if s.home { names.append("lc.controllers.home".loc) }
        return names.isEmpty ? "lc.controllers.nothingPressed".loc : names.joined(separator: " + ")
    }

    private func refresh() {
        guard let controller = GCController.controllers().first else {
            snapshot = nil
            return
        }
        var s = Snapshot()
        s.name = controller.vendorName ?? ""
        if let pad = controller.extendedGamepad {
            s.a = pad.buttonA.isPressed
            s.b = pad.buttonB.isPressed
            s.x = pad.buttonX.isPressed
            s.y = pad.buttonY.isPressed
            s.up = pad.dpad.up.isPressed
            s.down = pad.dpad.down.isPressed
            s.left = pad.dpad.left.isPressed
            s.right = pad.dpad.right.isPressed
            s.l1 = pad.leftShoulder.isPressed
            s.r1 = pad.rightShoulder.isPressed
            s.l2 = pad.leftTrigger.value
            s.r2 = pad.rightTrigger.value
            s.menu = pad.buttonMenu.isPressed
            s.options = pad.buttonOptions?.isPressed ?? false
            s.home = pad.buttonHome?.isPressed ?? false
            s.l3 = pad.leftThumbstickButton?.isPressed ?? false
            s.r3 = pad.rightThumbstickButton?.isPressed ?? false
            s.ls = CGPoint(x: CGFloat(pad.leftThumbstick.xAxis.value), y: CGFloat(-pad.leftThumbstick.yAxis.value))
            s.rs = CGPoint(x: CGFloat(pad.rightThumbstick.xAxis.value), y: CGFloat(-pad.rightThumbstick.yAxis.value))
        } else if let micro = controller.microGamepad {
            s.a = micro.buttonA.isPressed
            s.x = micro.buttonX.isPressed
            s.menu = micro.buttonMenu.isPressed
            s.up = micro.dpad.up.isPressed
            s.down = micro.dpad.down.isPressed
            s.left = micro.dpad.left.isPressed
            s.right = micro.dpad.right.isPressed
        } else {
            snapshot = nil
            return
        }
        snapshot = s
    }
}

private extension View {
    /// scrollIndicators 是 iOS 16 API，工程部署目标 15，分开守卫
    @ViewBuilder func lcHideScrollIndicators() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollIndicators(.hidden)
        } else {
            self
        }
    }
}
