//
//  LCGameHomeView.swift
//  LiveContainerSwiftUI
//
//  游戏库主页（NX2Apple 壳式界面，按已批准预览 lc-nxstyle-port/land-v1 实现）：
//  竖屏 = 封面大图 + 你的游戏双列 + 最近游玩 + 底部开始大胶囊；
//  横屏 = 封面色调模糊背景 + 卡片轮播 + 右上按钮排。
//  本视图只负责呈现与聚焦状态，启动 / 设置 / 导入 / 卸载等动作全部走
//  LCAppListView 的既有机制（回调注入），JIT sheet 与错误 alert 仍锚在列表层。
//

import SwiftUI
import GameController
import QuartzCore

// MARK: - 游戏库配色（自旧 LCGameCardView 抽出的共享常量，设置页 / 导入页也在用）

enum LCGameTheme {
    /// 奶油强调色（文字 / 描边 / 选中态）：动态色——深色值与原硬编码
    /// 逐字一致；浅色改深金棕，保证在浅底上作文字可读。恒深色面专用
    /// 的静态版见 creamOnDark（按键布局编辑器的黑底 chip 在用）。
    static let creamColor = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.965, green: 0.929, blue: 0.839, alpha: 1)
            : UIColor(red: 0.55, green: 0.40, blue: 0.16, alpha: 1)
    })
    /// 奶油色静态版（= creamColor 的深色值）：只给恒深色底的面用
    static let creamOnDark = Color(red: 0.965, green: 0.929, blue: 0.839)
    static let accentColor = Color(red: 0.788, green: 0.373, blue: 0.263)
    // 压在页面/卡片底上的诸项随外观翻转（UIColor trait 动态色）：深色值
    // 与原硬编码逐字一致，浅色值见各行后段。只压在封面图 / 固定深色罩
    // 上的浮层色（chipBackground、chipIconOnDark 等）不翻，两模式共用。
    static let cardBackground = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.118, green: 0.118, blue: 0.129, alpha: 1)
            : UIColor(red: 1, green: 1, blue: 1, alpha: 1)
    })

    // NX 预览取值。UIColor 本体单独存一份，供 hero 融合渐变按混合
    // 因子逐 trait 构造采样色（heroBlendColor）；pageBackground 的
    // 取值与此前逐字一致。
    static let pageBackgroundUIColor = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 10 / 255, green: 10 / 255, blue: 11 / 255, alpha: 1)
            : UIColor(red: 242 / 255, green: 242 / 255, blue: 247 / 255, alpha: 1)
    }
    static let pageBackground = Color(pageBackgroundUIColor)
    /// 浅色封面头深罩的锚点（P1 的主页版形状，Phase 42 按设
    /// 置页 Phase 41 的语法重塑，见下）：峰值 0.47 在标题带，
    /// 爬升拉平、峰顶改缓穹顶、下降多锚分摊、尾段贴地收零。
    /// 本表原是两处深罩的共同锚点源：主页 hero（heroScrimStops）
    /// 与设置页头（settingsScrimStops）分别自 Phase 32 / 33 起
    /// 按单调三次密采样使用（见下），锚点原样作 stops 的分段
    /// 形态已退役——分段拐点压在低频图面上成台阶（用户实测）。
    /// Phase 40 起设置页改用自有锚点（settingsScrimAnchors，
    /// 两栈构成不同、峰值平台在设置页栈里正是断层共犯，见彼
    /// 处注释），本表回归 hero 专用。几何（罩总高 / 下探量）
    /// 见调用点注释：主页 hero 的几何是 #69 形态（下探 12，
    /// Phase 31 定版，本轮逐字不动）。
    ///
    /// Phase 42（主页同步设置页定版处理，用户实测设置页「很
    /// 完美」后令主页同办）：旧形 = 0.42@0.52 → 0.47@0.68 的
    /// 宽平台 + 峰点切线归零，与设置页 Phase 41 定案的病灶
    /// 同构——曲率压进峰顶两缘的少数采样段。以仓库同一采样
    /// 函数复刻数值模型（画布 = 罩高 0.62h+24、h≈363 时约
    /// 249pt；断点步 = 相邻采样段 alpha 斜率差的最大值，下
    /// 同）：旧形 @17 采样断点步 0.0065/pt、只加密到 129 仍
    /// 0.0016/pt（真曲率尖峰、加密压不下去，与 Phase 41 对
    /// 设置页旧形的结论一致）；设置页定版形同口径 @129 为
    /// 0.0005/pt。本表按 Phase 41 三段语法重塑：爬升以三锚
    /// 拉平割线、平顶改缓穹顶（峰 0.472@0.65，有限斜率进
    /// 出）、下降以 0.72 / 0.78 / 0.84 / 0.89 四锚分摊、尾
    /// 段贴地（0.94 → 0.07、0.975 → 0.026）。新形 @129 断
    /// 点步 0.0007/pt（旧形 @17 的约九分之一）。峰值与文字
    /// 带不回退：数值模型全带扫描，文字带 loc 0.45–0.88 内
    /// 新曲线逐点 ≥ 旧曲线（最大亏空 0.000）；行位读数（同
    /// 模型）状态行 0.444 → 0.450、标题 0.457 → 0.463、版
    /// 本行 0.152 → 0.228（下降分摊的必然结果，只强不
    /// 弱）。采样数同步设置页口径 17 → 129（见
    /// heroScrimStops）。本层仅浅色渲染，深色逐字零影响；
    /// 设置页锚点（峰 0.58、按其三层相乘栈与行位地板定）
    /// 不照搬——两栈构成与几何不同，照搬会改掉 hero 已定
    /// 版的峰值与行位取值。
    ///
    /// Phase 44（底缘台阶定案与尾段着陆重塑）：#95 装机后
    /// 用户报 hero 底缘仍有台阶感（标注图红箭头指「你的游
    /// 戏」上方一带）。对标注图干净列逐行采样：合成亮度以
    /// 约 +1.1–1.4 lum/pt 一路爬升、到 y ≈ 1105px（368pt）
    /// 精确到达页底 241.6 后斜率归零——368pt 正是本罩画布
    /// 的底边行（hero 高 355.7 + 下探 12）。逐层归因：①本
    /// 罩是元凶——zeroEndTangents=false 时采样函数把末端切
    /// 线钉为末段割线，旧尾 (0.975, 0.026) → (1, 0) 的割
    /// 线 −1.04/loc、画布仅 244.5pt，合成在画布底边处仍以
    /// 1.03 lum/pt 爬升、下一行被画布硬切成 0，斜率断崖即
    /// 台阶本体；②噪点层同框同底边，其纹理均值 127.5 在
    /// 0.015 不透明度下给亮尾区垫了约 −1.73 lum 的直流偏
    /// 移、也在同一行戛然而止（实测边缘上方窄带均值 239.3
    /// vs 纯罩模型 241.4，差约 2 lum 与此吻合），修法见
    /// heroNoiseTailMaskStops；③mask 无罪：(1, 0) 锚点 +
    /// 两端切线归零使图像项在图底行取值与斜率同为零、任
    /// 意封面亮度下图框切断处无台阶（模型验算）；④页底色
    /// 无色差带：边缘下方实测 241.6 与页底逐点相等。设置
    /// 页无此边：其罩画布 532（2.2 倍长）+ 尾锚 0.008，末
    /// 段割线仅 −0.32/loc、终端斜率约 0.15 lum/pt，且 mask
    /// 与栈同终点、无线噪点层、无下探。修法只动本表尾段
    /// （0.94 起，0.94 锚点值与此前全部锚点逐字不动）：按
    /// 幂律着陆曲线 (1−loc)^2.5 的形态布点 (0.952, 0.0507)
    /// / (0.964, 0.0319) / (0.976, 0.0157) / (0.984,
    /// 0.0060)，末锚 (0.992, 0.0009) 使末段割线与 FC 限幅
    /// 后的末端切线同降至约 −0.10/loc。数值模型（采样函数
    /// 逐字复刻、Swift 工具链交叉核对）：画布底边处解析斜
    /// 率 1.031 → 0.096 lum/pt、合成在底边前约 2pt 已收敛
    /// 到距页底 0.3 lum 内；状态行 / 标题 / 版本行罩 alpha
    /// 0.4718 / 0.3854 / 0.2579 逐点不变（新锚全在行位所
    /// 在段之后、切线联动只及 0.89–0.94 段、该段无文字行
    /// 且合成偏差 ≤0.3 lum）；有对比带（alpha ≥ 0.02）的
    /// 采样断点步 0.143 / 0.150 与旧形 0.176 / 0.150 同级
    /// 或更优；alpha < 0.02 深尾的断点步升至 0.571，但该
    /// 处合成距页底总余量 ≤1.4 lum、弯折淹没在 1 LSB 量
    /// 级内——旧形在此无弯折只是因为它根本不着陆（斜率
    /// 1.03 撞画布边 + 噪点直流跳变 1.73，即本轮定案的
    /// 边）。短基线（±2pt）斜率估计器在底边 ±30pt 窗口内
    /// 最大步：0.431（旧、峰值正在底边行）→ 0.148（新、
    /// 位于着陆缓弯区、非断点）。
    static let coverScrimAnchors: [(location: Double, alpha: Double)] = [
        (0, 0), (0.18, 0.142), (0.34, 0.272), (0.47, 0.392),
        (0.57, 0.452), (0.65, 0.472), (0.72, 0.453), (0.78, 0.38),
        (0.84, 0.27), (0.89, 0.163), (0.94, 0.07), (0.952, 0.0507),
        (0.964, 0.0319), (0.976, 0.0157), (0.984, 0.0060),
        (0.992, 0.0009), (1, 0),
    ]
    /// 单调三次（Fritsch–Carlson）密采样：过全部锚点、每段单调、
    /// C1 连续（斜率无跳变）。相邻割线异号的锚点是局部极值、切线
    /// 归零，否则三次曲线会在极值前冲过锚点值；切线比 a²+b²>9 时
    /// 等比收缩保单调。渐变构造专用：把少数锚点的分段线性曲线换
    /// 成同一条平滑曲线的密采样，消掉每个 stop 处的斜率拐点——
    /// 验收口径「过渡是平滑的色值和透明度的转变」：色值与 alpha
    /// 两通道都必须是单条连续平滑函数，不许分段拐点与平台段。
    private static func monotoneCubicSamples(
        anchors: [(x: Double, y: Double)],
        samples: Int,
        zeroEndTangents: Bool
    ) -> [(x: Double, y: Double)] {
        let n = anchors.count
        var secants = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            secants[i] = (anchors[i + 1].y - anchors[i].y) / (anchors[i + 1].x - anchors[i].x)
        }
        var tangents = [Double](repeating: 0, count: n)
        tangents[0] = secants[0]
        tangents[n - 1] = secants[n - 2]
        for i in 1..<(n - 1) {
            if secants[i - 1] * secants[i] <= 0 {
                tangents[i] = 0
            } else {
                tangents[i] = (secants[i - 1] + secants[i]) / 2
            }
        }
        if zeroEndTangents {
            tangents[0] = 0
            tangents[n - 1] = 0
        }
        for i in 0..<(n - 1) {
            if secants[i] == 0 {
                tangents[i] = 0
                tangents[i + 1] = 0
            } else {
                let a = tangents[i] / secants[i]
                let b = tangents[i + 1] / secants[i]
                let s = a * a + b * b
                if s > 9 {
                    let tau = 3 / s.squareRoot()
                    tangents[i] = tau * a * secants[i]
                    tangents[i + 1] = tau * b * secants[i]
                }
            }
        }
        return (0..<samples).map { j in
            let x = Double(j) / Double(samples - 1)
            var i = 0
            while i < n - 2, x > anchors[i + 1].x { i += 1 }
            let dx = anchors[i + 1].x - anchors[i].x
            let s = (x - anchors[i].x) / dx
            let s2 = s * s
            let s3 = s2 * s
            let h00 = 2 * s3 - 3 * s2 + 1
            let h10 = s3 - 2 * s2 + s
            let h01 = -2 * s3 + 3 * s2
            let h11 = s3 - s2
            let y = h00 * anchors[i].y + h10 * dx * tangents[i]
                + h01 * anchors[i + 1].y + h11 * dx * tangents[i + 1]
            return (x: x, y: y)
        }
    }

    /// 密采样 stops 的共用入口（Phase 33）：锚点 → 单调三次密
    /// 采样 → 按 color 闭包逐点着色成 stops。主页 heroScrimStops
    /// / heroFusionStops 与设置页 settingsScrimStops /
    /// settingsBackdropMaskStops 同调本入口，采样逻辑全仓一份，
    /// 不许各处复制近似实现。
    private static func denseSampledStops(
        anchors: [(x: Double, y: Double)],
        samples: Int,
        zeroEndTangents: Bool,
        color: (Double) -> Color
    ) -> [Gradient.Stop] {
        monotoneCubicSamples(
            anchors: anchors, samples: samples, zeroEndTangents: zeroEndTangents
        ).map { Gradient.Stop(color: color($0.y), location: $0.x) }
    }

    /// 主页 hero 专用深罩 stops（Phase 32）：当时与设置页
    /// settingsScrimStops 同一组锚点、同一强度口径、同一采样
    /// （Phase 40 起两页锚点分家、Phase 42 起 hero 采样数再
    /// 与设置页对齐 129，见下），但不用锚点原样作 stops——
    /// 锚点间的分段线性每段都是斜率
    /// 拐点，压在深色低频图面（无横图兜底的放大模糊图标面）
    /// 上，拐点连成一级级横向台阶（用户实测「过渡有阶梯
    /// 感」），再叠 8-bit 量化更显。这里按单调三次密采样作
    /// stops：过全部锚点、采样后 alpha 严格落在 [0, 0.472]
    /// 无过冲；三处文本高度的 alpha 与旧分段值同级（h≈363
    /// 换算：状态行 0.435→0.446、标题 0.414→0.446、版本行
    /// 0.168→0.162，合成亮度差 −0.005 / −0.021 / +0.005，
    /// 深色参考图口径）。
    /// Phase 42：锚点已按 Phase 41 语法重塑（见
    /// coverScrimAnchors 注释），采样数同步设置页定版口径
    /// 17 → 129——断点步 ≈ 曲率 × 采样步长，曲线定形后只
    /// 能靠步长压（设置页 settingsScrimStops 同为 129）。
    static let heroScrimStops: [Gradient.Stop] = denseSampledStops(
        anchors: coverScrimAnchors.map { (x: $0.location, y: $0.alpha) },
        samples: 129,
        zeroEndTangents: false
    ) { .black.opacity($0) }

    /// 设置页页头深罩的锚点（Phase 40 起自有，不再与主页 hero
    /// 共用 coverScrimAnchors）：两栈构成不同——hero 是融合层
    /// × 罩，设置页是 mask 淡出 × 横图压暗 × 罩三层相乘。共
    /// 用锚点的峰值平台（0.42@0.52 → 0.47@0.68、峰顶切线归
    /// 零）正压在文字带上：mask 在该带放进的页底亮度被罩的持
    /// 续爬升与压暗渐变的同步加深吃掉，合成亮度在 loc
    /// 0.50–0.68 几乎不涨（均匀亮图 190 输入、设置页几何下
    /// 96pt 仅 +2.6），带后三层又同时释放、陡升成墙——平台
    /// 上下各成一条可见台阶（用户实测红圈圈住整带）。Phase
    /// 40 改成「状态行前爬满、标题带平顶、眉题后匀速落下」：
    /// 平顶 0.52（loc 0.52–0.69），文字行取值（罩画布坐标）
    /// 状态行 0.409 → 0.513、标题 0.443 → 0.520、副行
    /// 0.463 → 0.520、眉题 0.468 → 0.520，只强不弱；尾段
    /// （0.83 → 0.18、0.93 → 0.05、1 → 0）与旧形同级。罩几
    /// 何（532 / 下探 160、与图同终点）逐字不动（Phase 30
    /// 定版）；主页 hero 的罩仍走 coverScrimAnchors、逐字不
    /// 变。
    ///
    /// Phase 41（残余三线定案与全平滑化）：Phase 40 的包上
    /// 用户在 S2Arm 兜底页头（平滑中灰、显形条件最苛刻）报
    /// 状态行 / 眉题行 / 说明行三行背后各一条深色线。对截
    /// 图右带逐行采样：折点在 246 / 346 / 381 / 413pt，斜
    /// 率步 +0.48 / +0.64 / +0.45 / −0.50 lum/pt；以现行栈
    /// 数值模型（采样函数与仓库逐字一致、Swift 工具链交叉
    /// 核对）复刻合成剖面，与实测 RMSE 0.33 lum，逐层归
    /// 因定案：四折点逐一落在**本罩 17 点密采样的采样断
    /// 点** loc 0.5 / 0.6875 / 0.75 / 0.8125（几何拟合误
    /// 差 ≤1pt），解析斜率步 +0.50 / +0.78 / +0.64 /
    /// −0.62——平顶两缘的切线归零与陡尾中段把曲率压进少
    /// 数采样段，折线渲染在断点处成台阶；413pt 无文字故
    /// 未被圈、机理相同。mask 同口径斜率步 ≤0.011（兜底
    /// 有效底图与页底接近、权重近零）、横图压暗不在兜底
    /// 路上，均无罪；loc 1 落地处另有收尾步约 −0.31（尾
    /// 切线 −0.69/unit 未归零、罩在画布底缘消失）。光加密
    /// 无用：旧形 @129 采样最坏步仍 0.31（平顶切线鞭打是
    /// 真曲率尖峰）。本表改三段：爬升线性化（三锚点把割线
    /// 拉平、消 0.31/0.44 两断点的曲率堆积）、平顶改缓穹
    /// 顶（峰 0.58@0.605、两缘以有限斜率进出）、下降走廊
    /// 以 0.69 / 0.72 / 0.76 / 0.80 四锚点分摊（眉题
    /// ≥0.52 → 说明 ≤0.42 → 分组题 ≤0.31 的行位地板把
    /// 走廊曲率下限钉死，只能摊开不能绕开）、尾段贴地
    /// （0.95 → 0.029、0.975 → 0.008，末段割线 −0.32、
    /// 落地收尾步降至约 0.12）。行位取值（三次曲线，修前
    /// → 修后）状态行 0.517 → 0.533、标题带 [0.53, 0.65]
    /// 最低 0.520 → 0.551、眉题 0.520 → 0.521、说明行
    /// 0.417 → 0.396（罩更轻、深字底更亮）、分组题
    /// 0.311 → 0.313，均不回退。本层仅浅色渲染，深色逐
    /// 字零影响。
    static let settingsScrimAnchors: [(location: Double, alpha: Double)] = [
        (0, 0), (0.15, 0.135), (0.30, 0.26), (0.38, 0.335),
        (0.46, 0.479), (0.52, 0.544), (0.605, 0.58), (0.69, 0.516),
        (0.72, 0.466), (0.76, 0.368), (0.80, 0.268), (0.85, 0.152),
        (0.90, 0.076), (0.95, 0.029), (0.975, 0.008), (1, 0),
    ]

    /// 设置页页头深罩 stops：锚点见 settingsScrimAnchors，同
    /// denseSampledStops 入口密采样、采样逻辑仍全仓一份。
    /// Phase 33 时与 hero 同锚点同采样、两页曲线逐点相等
    /// （见该版注释史）；Phase 40 因栈构成不同改用自有锚
    /// 点（见上）。Phase 41 起采样数 17 → 129：折线台阶幅
    /// ≈ 曲率 × 采样步长，走廊段曲率下限被文字行地板钉死
    /// （见锚点注释），只能靠步长压——新形 @17 仍约
    /// 0.5、@129 降至 0.12（解析断点步，回退底图权重）；
    /// 同口径短基线折点估计器在新模型全剖面 [130, 510]
    /// 内 ≤0.10（修前模型 +0.39 / +0.59 / +0.49 / −0.48）。
    static let settingsScrimStops: [Gradient.Stop] = denseSampledStops(
        anchors: settingsScrimAnchors.map { (x: $0.location, y: $0.alpha) },
        samples: 129,
        zeroEndTangents: false
    ) { .black.opacity($0) }

    /// 设置页页头 backdrop 淡出 mask 的锚点（NX 原规格）：loc
    /// 0.45 前满显，其后衰减、loc 1 归零——loc 1 正落在图绘制
    /// 的最后一行像素上（绘制总高 = 帧高 + topInset + 160，
    /// Phase 28 / 30），终点位置是同终点结论的一部分、不许移。
    static let settingsBackdropMaskAnchors: [(location: Double, alpha: Double)] = [
        (0, 1), (0.45, 1), (0.66, 0.55), (0.85, 0.13), (1, 0),
    ]

    /// 设置页页头 backdrop 淡出 mask stops（Phase 33）：锚点同
    /// 上，改走单调三次密采样 17 点、两端切线归零——离开满显
    /// 平台与落到 clear 都无斜率突变。Phase 40 锚点两处微调
    /// （断层窄修，见 settingsScrimAnchors 注释）：中锚略前提
    /// （0.68 → 0.66、同值 0.55）、尾锚降低（0.85 处 0.18 →
    /// 0.13），让页底涌入在文字带内提前到位、并把眉题→说明
    /// 行之间的合成爬升提早起步；满显段终点 0.45 与 loc 1
    /// 归零逐字不动。锚点逐点过：0 / 0.45 → 1、0.66 → 0.55、
    /// 0.85 → 0.13、1 → 0；段内中点等效值 loc 0.565 处
    /// 0.834 → 0.805、0.765 处 0.357 → 0.303、0.925 处
    /// 0.058 → 0.039，衰减段全程单调、无过冲。
    static let settingsBackdropMaskStops: [Gradient.Stop] = denseSampledStops(
        anchors: settingsBackdropMaskAnchors.map { (x: $0.location, y: $0.alpha) },
        samples: 17,
        zeroEndTangents: true
    ) { .black.opacity($0) }

    /// 设置页页头状态栏 scrim 的锚点（NX 原规格）：黑 0.5 起、
    /// 落到 0。原构造是这两点的一条两段线性渐变（LinearGradient
    /// colors 直连），本表只记锚点、stops 走密采样（见下）。
    static let settingsStatusScrimAnchors: [(location: Double, alpha: Double)] = [
        (0, 0.5), (1, 0),
    ]

    /// 设置页页头状态栏 scrim stops（Phase 35）：锚点同上，改走
    /// 单调三次密采样 13 点、两端切线归零。定案过程（用户装
    /// Phase 33 的 nightly 后回图「上部还有线」）：对截图右带
    /// （x 950–1240 纯 backdrop 列）逐行采样，全图唯一系统性
    /// 斜率突变在 y≈354px = 物理顶下 118pt，亮度斜率由 +4.4/
    /// 10px 翻到 −1.1/10px；旧图（Phase 33 之前）同一行同亮度
    /// （≈198）同突变——线不在 Phase 33 动过的层里。118pt 正
    /// 是本 scrim 的下缘（topInset 68 + 高 50，锚图顶）：线性
    /// 渐变 alpha 在下缘归零、但斜率从恒定值一步跳到 0，压在
    /// 平坦灰面上就是这条线。其余候选逐项排除：两实例出血交
    /// 界在安全线 68pt（204px），采样曲线直穿无突变；backdrop
    /// mask 离开满显平台在约 277pt，Phase 33 密采样后无突变；
    /// 设置页深罩顶边 alpha 自 0 平滑起、无突变；兜底黑 0.38
    /// 平叠与 y 无关。平滑后强度对照（s = 带内相对位置）：顶
    /// 点 0.5 逐点不变（锚点必过）；s 0.25 处 0.375 → 0.422、
    /// s 0.5 处 0.25 → 0.25、s 0.75 处 0.125 → 0.078——时钟 /
    /// 电量所在的上半带只强不弱，下半带贴地缓收、斜率归零，
    /// 线消除。深色模式共用本层：锚点与上半带强度不变，深色
    /// 合成形态不变。
    static let settingsStatusScrimStops: [Gradient.Stop] = denseSampledStops(
        anchors: settingsStatusScrimAnchors.map { (x: $0.location, y: $0.alpha) },
        samples: 13,
        zeroEndTangents: true
    ) { .black.opacity($0) }

    /// 设置页页头有横图路径压暗渐变的锚点（NX 原规格为三
    /// 点：clear@0.3 → 黑 0.4@0.6 → 黑 0.55@1，loc 0.3 之
    /// 前恒 clear，补 (0, 0) 锚点把平段钉住）。Phase 40 改
    /// 五点（断层窄修，见 settingsScrimAnchors 注释）：爬升
    /// 提前到状态行之前完成（0.48 到 0.45），文字带内不再
    /// 持续加深、吃掉 mask 的页底涌入；尾段（0.70 → 0.50、
    /// 1 → 0.55）与旧密采样值贴齐（loc 0.767：0.504 →
    /// 0.511、0.862：0.535 → 0.531），说明行 / 分组题与深
    /// 色模式不回退。stops 见下。
    static let settingsBannerShadeAnchors: [(location: Double, alpha: Double)] = [
        (0, 0), (0.30, 0), (0.48, 0.45), (0.70, 0.50), (1, 0.55),
    ]

    /// 设置页页头有横图压暗 stops：锚点同上，单调三次密采
    /// 样 17 点、两端切线归零（Phase 35 起；原三点分段线性
    /// 压在图面上留斜率拐点，属同类预防性平滑）。锚点逐点
    /// 过：0.3 → 0、0.48 → 0.45、0.70 → 0.50、1 → 0.55；
    /// 段内中点 loc 0.45 处 0.168 → 0.388（爬升前移的必然
    /// 结果，位于状态行上方的图面区、无文字）、loc 0.80 处
    /// 0.518 → 0.518，全程单调无过冲。深浅共用本层：深色
    /// 侧文字行取值不低于旧值（Phase 40 验证口径），合成形
    /// 态仍是单条向下融化曲线。
    static let settingsBannerShadeStops: [Gradient.Stop] = denseSampledStops(
        anchors: settingsBannerShadeAnchors.map { (x: $0.location, y: $0.alpha) },
        samples: 17,
        zeroEndTangents: true
    ) { .black.opacity($0) }

    /// hero 融合渐变的采样色：透明黑 → 页底色、混合因子 f。与原
    /// 两段线性渐变的分量模型逐字一致（RGB = 页底 RGB × f、
    /// alpha = f），只是混合因子从位置线性换成 heroFusionStops
    /// 的平滑曲线值。
    private static func heroBlendColor(_ f: Double) -> Color {
        Color(UIColor { trait in
            let bg = pageBackgroundUIColor.resolvedColor(with: trait)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            _ = bg.getRed(&r, green: &g, blue: &b, alpha: &a)
            let k = CGFloat(f)
            return UIColor(red: r * k, green: g * k, blue: b * k, alpha: k)
        })
    }

    /// 主页 hero 融合渐变 stops（Phase 32）：原构造是透明黑 →
    /// 页底色的两段线性渐变，长缓坡在 8-bit 下量化成带，且斜率
    /// 在融合带上界（与原图衔接处）与下界（与页底衔接处）突变、
    /// 各留一条折线。改按单调三次密采样 13 点：锚点取三处文本
    /// 行在融合带内的现行 blend 值——hero 高 h≈363（0.39 ×
    /// 932pt 屏高）时融合带 0.48h ≈ 174pt，状态行 / 标题 / 版
    /// 本行中心距 hero 底约 95 / 60 / 24pt，u = 1 − d ÷ 174 ≈
    /// 0.453 / 0.657 / 0.861，锚点落在对角线上即 blend 在该三
    /// 处与旧线性逐点相等；两端切线归零，融合带上下界的斜率连
    /// 续。偏离只在 u<0.453 的图像主导段（最大约 −0.067，坡度
    /// 渐入）与 u>0.861 的收尾段（约 +0.013）。深色模式共用此
    /// 层：本轮对深色只换 stops 曲线，端点 / 中点 / 形态不动。
    /// Phase 42：采样数 13 → 129（与深罩同轮，Phase 41 口
    /// 径）——锚点与曲线逐点不变，只压采样断点步（同模型：
    /// 两端切线归零的曲率堆积在带上下界，@13 断点步
    /// 0.0031/pt → @129 约 0.0012/pt，画布 0.48h≈174pt 口
    /// 径）；深色模式同理只密采样、形态与强度逐点不变。
    static let heroFusionStops: [Gradient.Stop] = denseSampledStops(
        anchors: [(0, 0), (0.453, 0.453), (0.657, 0.657), (0.861, 0.861), (1, 1)],
        samples: 129,
        zeroEndTangents: true,
        color: heroBlendColor
    )

    /// 主页 hero 底图熔化 mask 的锚点（Phase 43）：语法照设置
    /// 页 settingsBackdropMaskAnchors（满显段 → 长尾渐隐 →
    /// 末端归零），落点按主页几何与行位换算、未照搬数值——
    /// 设置页行位在其图高 0.45–0.64 深处、满显到 0.45；主
    /// 页行位在图高 0.73–0.93，照搬则标题处 mask 只剩约
    /// 0.175（数值模型：合成亮度 +34、白字对比 6.9 → 4.2，
    /// 否决）。本表满显到 0.48、行位取值 状态行 0.734 / 标
    /// 题 0.542 / 版本行 0.130、图底归零。定案与对照见
    /// heroBackdropMaskStops 注释。
    static let heroBackdropMaskAnchors: [(location: Double, alpha: Double)] = [
        (0, 1), (0.48, 1), (0.68, 0.80), (0.80, 0.62),
        (0.88, 0.38), (0.93, 0.14), (1, 0),
    ]

    /// 主页 hero 底图熔化 mask stops（Phase 43）：锚点同上，
    /// 走 denseSampledStops 密采样 129 点、两端切线归零
    /// （采样数与 #94 的罩 / 融合对齐；采样值经 Swift 工具
    /// 链复算与数值模型逐值一致、值域 [0, 1] 无过冲）。仅
    /// 浅色挂载（调用点），深色逐字零影响。
    ///
    /// Phase 43 定案（用户装 #94 后实测「只是白色变高了，
    /// 没有设置页这种平滑渐变的效果」）：以仓库同一采样函
    /// 数复刻两栈数值模型（主页 h≈356、设置页图高 591），
    /// 把图像权重 w（图像在合成中的系数）分解——设置页
    /// w = mask × (1 − 压暗)：满显 0.45 之后由图像自身
    /// alpha 主导衰减（mask 0.55@0.66 → 0.13@0.85 → 0@1，
    /// w 过 0.5 / 0.25 / 0.02 在图高 0.51 / 0.68 /
    /// 0.92）；主页 #94 的 w = 1 − 融合 f，100% 由叠加
    /// 层承担：图像恒不透明、被页底色预乘叠加按 f 逐行替
    /// 换，f 爬到可见强度处即读作一条上爬的白色带。#94 只
    /// 把同一形状密采样——真机同列差分：#94 前后带内仅
    /// −3…−16 lum、白边（lum ≥ 220）位置 354pt 未动，模
    /// 型差分与真机逐点 ±2 内吻合，形状未变、观感未变。
    /// 截图同列（x 0.86–0.985）另证：主页饱和度在 240–
    /// 276pt 先塌完、亮度到约 354pt 才爬满（颜色先死、
    /// 白随后爬 = 叠加替换签名）；设置页亮度尾程（60 →
    /// 209）拉开约 200pt、与饱和同步衰减（图像原地溶
    /// 解）。
    ///
    /// 修法（机制级移植）：浅色下底图挂本 mask 原地熔
    /// 化、融合层浅色退役（深色逐字保留——深色融合是向近
    /// 黑页底的淡出、机制不同且已定版），#94 深罩逐字不
    /// 动（罩形未动、行位读数与 #94 逐点相等）。同形核
    /// 对（均匀 190 / 130 输入）：w 带 frac 0.61 →
    /// 0.98（带长受 hero 图高 356 的物理上限约束；设置
    /// 页 336pt / frac 0.35 → 0.92 @591）；均匀 130 的
    /// 带内平台 31.5 → 7pt、斜率步 0.195 → 0.191（不
    /// 劣）；行位合成（丝之歌 / 哈迪斯横图 strip 口径）
    /// 状态行 73.7 / 75.8 → 54.5 / 57.4、标题 90.1 /
    /// 88.7 → 68.4 / 66.2（白字 WCAG 6.9 / 7.0 → 9.7 /
    /// 10.0，只强不弱）、版本行 160.1 / 159.6 → 161.6 /
    /// 161.1（深字对比 2.29 / 2.27 → 2.33 / 2.31，持
    /// 平）；hero 底缘合成 229.1 逐点不变（罩下探 12 的
    /// 收尾与 #94 同位）。无横图兜底（图标糊化底 + 中央
    /// 清晰图标）整幅同 mask 熔化：图标中心 loc 0.5 处
    /// mask 0.997 近全显、下缘 loc 0.775 处 0.670 随底
    /// 同溶、无硬边；兜底行位合成（有效底 lum ≈ 43）
    /// 53.0 / 72.5 / 163.6 vs #94 的 72.6 / 92.8 /
    /// 162.2，同向不回退。横屏浅色已核对为同构：封面权
    /// 重 0.75 起经径向 / 纵向 / 底部融合三道乘性衰减
    /// （0.5@frac 0.62、0.02@0.94）、帧内 y ≈ 385–395
    /// 已收满页底、底半斜率步 ≤ 0.17，本轮不动。
    static let heroBackdropMaskStops: [Gradient.Stop] = denseSampledStops(
        anchors: heroBackdropMaskAnchors.map { (x: $0.location, y: $0.alpha) },
        samples: 129,
        zeroEndTangents: true
    ) { .black.opacity($0) }

    /// 横屏浅色专用底部融合 stops（Phase 34）：曲线口径同
    /// heroFusionStops（单调三次密采样、两端切线归零），着色
    /// 模型走竖屏融合的页底色 alpha 直 ramp（pageBackground
    /// .opacity(f)）——横屏底部要收进的是已被洗浅的晕染面，
    /// 不需要 hero 那条过黑的预乘 ramp。锚点把 f 在 0.80 处
    /// 提前推到 1 并平台到 1：调用点把融合带下探出 backdrop
    /// 帧底 40pt，f=1 的平台段正盖住下探区，屏内底边处已是
    /// 纯页底色、洗色在屏上没有任何边界（见 landscapeBackdrop
    /// 注释）。深色不用本 stops（横屏深色收尾逐字不变）。
    /// Phase 42：采样数 17 → 129（与竖屏同轮，Phase 41 口
    /// 径）——锚点与曲线逐点不变（含 0.80 起 f=1 平台，定
    /// 版形态不动），只压爬升段的采样断点步（同模型 @17
    /// 0.0077/pt → @129 约 0.0030/pt，画布约 255pt 口径）。
    static let landscapeLightMeltStops: [Gradient.Stop] = denseSampledStops(
        anchors: [(0, 0), (0.36, 0.36), (0.53, 0.53), (0.69, 0.69), (0.80, 1), (1, 1)],
        samples: 129,
        zeroEndTangents: true
    ) { pageBackground.opacity($0) }

    /// hero 过渡带噪点不透明度（Phase 32）：置 0 即关闭噪点层。
    static let heroDitherOpacity: Double = 0.015
    /// 静态噪点纹理（Phase 32）：256×256 灰阶随机（固定种子
    /// LCG，跨启动一致、无动画），拉伸铺满 hero 过渡带、以
    /// heroDitherOpacity 盖在融合 + 深罩之上、浮钮与文字之下。
    /// 密采样消掉斜率拐点后，深色平坦面上仍可能残余 8-bit 量
    /// 化色带；约 ±2 LSB 的静态扰动把带打散到不可见。噪点不参
    /// 与渐变构造，两通道的平滑性仍由曲线本身保证。
    static let heroNoiseImage: UIImage = {
        let side = 256
        var state: UInt32 = 0x9E37_79B9
        var data = Data(count: side * side * 4)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for p in 0..<(side * side) {
                state = state &* 1_664_525 &+ 1_013_904_223
                let v = UInt8(truncatingIfNeeded: state >> 24)
                bytes[p * 4] = v
                bytes[p * 4 + 1] = v
                bytes[p * 4 + 2] = v
                bytes[p * 4 + 3] = 255
            }
        }
        let provider = CGDataProvider(data: data as CFData)!
        let cgImage = CGImage(
            width: side, height: side,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return UIImage(cgImage: cgImage)
    }()
    /// 噪点层尾部收尾 mask 的 stops（Phase 44）：噪点画布与
    /// 深罩同框（0.62h+24、下探 12），其纹理均值 127.5 在
    /// heroDitherOpacity 下给亮区垫约 −1.73 lum 的直流偏移
    /// （均值 ≠ 页底亮度所致）、纹理本身也带静态颗粒——两
    /// 者在画布底边行同时硬切，与深罩的终端斜率断崖叠在同
    /// 一行成边（定案见 coverScrimAnchors 的 Phase 44 注
    /// 释）。本 mask 让噪点在画布 loc 0.94 前满幅（标题带等
    /// 抗色带主力区逐点不变）、其后平滑收尾到 0：loc 0.94
    /// 换算页坐标约在图底行上方 2.5pt 处，该处底图 mask 已
    /// 溶掉约 97%、无色带可打；收尾段两端切线归零、与栈体
    /// （Phase 44 着陆后的深罩）在同一底边前一同收敛到页
    /// 底。数值模型：底边行处的直流跳变 +1.73 → +0.002
    /// lum。仅噪点调用点（浅色）使用。
    static let heroNoiseTailMaskStops: [Gradient.Stop] = denseSampledStops(
        anchors: [(0, 1), (0.94, 1), (1, 0)],
        samples: 129,
        zeroEndTangents: true
    ) { .black.opacity($0) }
    /// 主操作奶油色（开始按钮 / 聚焦选中线）：动态色——深色值与原硬
    /// 编码逐字一致；浅色略加深饱和，白底上作填充 / 玻璃 tint 不发飘
    static let nxCream = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 240 / 255, blue: 214 / 255, alpha: 1)
            : UIColor(red: 0.96, green: 0.83, blue: 0.55, alpha: 1)
    })
    static let mutedText = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 158 / 255, green: 158 / 255, blue: 164 / 255, alpha: 1)
            : UIColor(red: 99 / 255, green: 99 / 255, blue: 104 / 255, alpha: 1)
    })
    static let sectionText = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 228 / 255, green: 224 / 255, blue: 218 / 255, alpha: 1)
            : UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
    })
    static let readyGreen = Color(red: 64 / 255, green: 214 / 255, blue: 120 / 255)
    static let missingAmber = Color(red: 1.0, green: 176 / 255, blue: 66 / 255)
    /// 已损坏（状态机三态新增，与设置页 LCNXColor.broken 同值）
    static let brokenRed = Color(red: 1.0, green: 0.42, blue: 0.38)
    static let chipBackground = Color(red: 30 / 255, green: 28 / 255, blue: 29 / 255).opacity(0.92)
    /// chip 描边（压封面图上，两模式共用）
    static let chipBorder = Color.white.opacity(0.18)
    /// chip 描边（压页面 / 卡片自适应面上）：深色 = chipBorder 原值，
    /// 浅色改黑 0.12
    static let chipBorderOnSurface = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.18)
            : UIColor.black.withAlphaComponent(0.12)
    })
    /// chip 图标色（玻璃 / 自适应面用）：动态色——深色值与原硬编码逐字
    /// 一致；浅色改深暖灰。固定深底（非玻璃回退的 chipBackground）上
    /// 用 chipIconOnDark 静态浅色，分工见 gcChipIconForeground。
    static let chipIcon = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 232 / 255, green: 230 / 255, blue: 228 / 255, alpha: 1)
            : UIColor(red: 0.16, green: 0.15, blue: 0.14, alpha: 1)
    })
    /// chip 图标静态浅色（= chipIcon 深色值）：只给固定深底用
    static let chipIconOnDark = Color(red: 232 / 255, green: 230 / 255, blue: 228 / 255)
}

extension View {
    /// 图面 chip 的图标 / 文字前景：玻璃分支（玻璃本身随外观自适应）
    /// 用动态 chipIcon；非玻璃回退分支底是固定深色 chipBackground，
    /// 用静态浅色 chipIconOnDark。两分支各自可读、深色逐字不变。
    func gcChipIconForeground() -> some View {
        self.modifier { view in
            if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                view.foregroundColor(LCGameTheme.chipIcon)
            } else {
                view.foregroundColor(LCGameTheme.chipIconOnDark)
            }
        }
    }

    /// 底部开始按钮的底：玻璃开时原生 Liquid Glass（regular + 主操作
    /// nxCream tint + interactive；苹果规范里 tint 只给主操作）；非玻璃
    /// 回退逐字保留实心 nxCream 胶囊。
    func gcStartButtonBackground() -> some View {
        self.modifier { view in
            if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                view.glassEffect(.regular.tint(LCGameTheme.nxCream).interactive(), in: .capsule)
            } else {
                view.background(LCGameTheme.nxCream).clipShape(Capsule())
            }
        }
    }
}

// MARK: - 封面图（横版封面 → 图标兜底，与旧卡片 coverView 同语义）

struct LCGameCoverView: View {
    let app: LCAppModel
    let darkModeIcon: Bool
    /// 库内容刷新令牌（列表层在设置页 / 导入页关闭后 bump）：封面是 body 里
    /// 现读磁盘算出来的，本视图不观察任何状态，令牌不变 body 就不重跑、
    /// 换完封面仍显示旧图。令牌作为入参变化即触发重解析。
    let refreshToken: Int
    /// 无横图兜底美化（Phase 19）：解析落到图标时不把图标拉伸充数，
    /// 改 NX 无横图同款语言（与设置页头部 Phase 17 的无横图路同源）。
    /// 打开的面：竖屏 hero、横屏牌组卡、竖屏网格卡与最近游玩缩略图
    /// （网格/最近两处 2026-11-08 按 Tiao 要求对齐横屏处理）；仅横屏
    /// 背景晕染保持旧兜底（整幅糊化是其本职）。
    var beautifiedFallback: Bool = false

    var body: some View {
        let _ = refreshToken
        if let bannerImage = LCGameLibraryInfo.bannerImage(for: app.appInfo) {
            Image(uiImage: bannerImage)
                .resizable()
                .scaledToFill()
        } else if let iconImage = app.appInfo.iconIsDarkIcon(darkModeIcon) {
            if beautifiedFallback {
                beautifiedIconFallback(iconImage: iconImage)
            } else {
                ZStack {
                    Image(uiImage: iconImage)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 24)
                        .opacity(0.75)
                    Image(uiImage: iconImage)
                        .resizable()
                        .scaledToFit()
                        .padding(18)
                }
            }
        } else {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
        }
    }

    /// 美化兜底：图标自体放大 1.4 + blur 40 + saturation 1.2 铺满卡面、
    /// 黑 0.38 叠压（NX PaneBanner 无横图底原值），中央叠一张清晰图标，
    /// 边长 = 卡高 55%，圆角 / 描边 / 阴影按 NX CoverThumbnail 规格
    /// （圆角比 0.2、白 0.14 描边、阴影 black 0.4 / r16 / y6）。
    private func beautifiedIconFallback(iconImage: UIImage) -> some View {
        GeometryReader { geo in
            let side = geo.size.height * 0.55
            ZStack {
                Image(uiImage: iconImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(1.4)
                    .blur(radius: 40)
                    .saturation(1.2)
                    .clipped()
                Color.black.opacity(0.38)
                Image(uiImage: iconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.2, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: side * 0.2, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 6)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }
}

// MARK: - 游戏库主页

struct LCGameHomeView: View {
    let apps: [LCAppModel]
    let hiddenAppsCount: Int
    let multiLCStatus: Int
    let installProgressVisible: Bool
    let installProgress: Float
    /// 真实安全区：由 LCAppListView 从不忽略安全区的层级读出后注入。
    /// 本视图内部 GeometryReader 带 .ignoresSafeArea()，它读到的
    /// geo.safeAreaInsets 恒为 0，不能直接用作浮钮排的定位依据。
    let safeAreaInsets: EdgeInsets
    /// 安全区尺寸：同一个列表层 GeometryReader 的 size。NX CoverFlow 的
    /// 度量参考系就是安全区 geometry（LibraryView 把 geometry.size 与
    /// safeAreaInsets 一起传给 CoverFlowView），横屏度量按它算。
    let safeSize: CGSize
    /// 库内容刷新令牌：变化即本视图 body 重跑，封面与数据包状态点按磁盘重算
    let refreshToken: Int
    /// 列表层是否有任何弹层 / 面板盖在主页之上（设置面板、隐藏游戏页、
    /// 数据包导入、卸载确认、JIT 流程等）：手柄导航的让位判据，列表层注入
    let overlayPresented: Bool

    var onRun: (LCAppModel) -> Void
    var onSettings: (LCAppModel) -> Void
    var onOpenDataFolder: (LCAppModel) -> Void
    var onImportDatapack: (LCAppModel) -> Void
    var onUninstall: (LCAppModel) -> Void
    var onImportIPA: () -> Void
    var onImportDatapackGeneric: () -> Void
    var onOpenHiddenApps: () -> Void
    var onOpenContainerSettings: () -> Void

    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false
    /// 游玩时长快照（Phase 18）：磁盘现读，本视图不观察统计文件，靠出现 /
    /// 刷新令牌两个时点重读（见 body 的 onAppear / onChange）。
    @State private var playStats: [String: LCPlayStats.Entry] = [:]
    @State private var focusKey: String?
    @StateObject private var controllerMonitor = LCControllerMonitor()
    /// 主页手柄导航输入层（十字键 / 左摇杆移选、A 开始）：handler 的
    /// 装卸由 gamepadGateOpen 判据驱动，见 body 的 onChange
    @StateObject private var gamepadNav = LCGamepadNavHandler()
    /// 横屏布局标志（手柄移动语义分岔：横屏只左右切卡、竖屏走网格
    /// 步进），由 safeSize 方向维护（与 body 的布局判据同向）
    @State private var isLandscapeLayout = false
    /// 手柄移动后的滚动请求令牌：竖屏 ScrollViewReader 观察它把选中
    /// 卡滚入可见区；触摸切换聚焦不 bump、滚动位置不被抢
    @State private var gamepadScrollToken = 0
    @Environment(\.scenePhase) private var scenePhase
    /// 手柄页呈现状态（Phase 22 起统一走 LCSidePanelContainer 自适应
    /// 宿主：横屏 = 右侧面板、竖屏 = 整屏，形态随当前尺寸跟随、旋转
    /// 原地变形；Phase 14 的 sheet / 面板打开时二选一已废除）
    @State private var controllerPanelPresented = false

    @State private var stateHelpTarget: LCGameStateTarget?

    // 库顺序快照（竖屏网格与横屏牌组共用）：Phase 30 起冻结并持久
    // 化——快照落 UserDefaults（LCGameLibraryOrderStore），视图初值
    // 直接读回，主页存活期间与回库（进程重启重建视图）都不再按
    // 「最近游玩」重排；只有游戏集合变化（装 / 卸）时才收敛一次
    // （幸存者相对次序不变、新游戏追加末尾，见 maintainLibraryOrder），
    // 全新安装无快照时才按 LCGameLibraryInfo.libraryOrder（最近
    // 游玩 → 可玩 → 缺数据包 → 已损坏）定序一次。冻结的动因是横屏
    // 回库失同步，查实结论见 snapCarouselToFocus 的 Phase 30 复盘。
    // 竖屏下方的「最近游玩」区是分组第 0 组（玩过的游戏）的独立
    // 呈现，仍走 recentApps，不受本快照影响；聚焦与 hero 也不读
    // 顺序。状态点颜色是现算的、会变，位置不变。
    // carouselOffsetCards 是横屏牌组手势轮播的滚动量（Phase 39 起
    // 全卡数共用，旧制仅 >3 张），单位 = 卡位
    // （1.0 = 一张卡的 stride），静止时恒等于聚焦序号本身；存活期内
    // 顺序变化（装 / 卸收敛）时由 snapCarouselToFocus 无动画重算
    // （Phase 28 安全网，Phase 30 保留）。
    // carouselDragLogicalCards 是拖动中的未钳制逻辑偏移（手指原始
    // 位移在手势边界换算成卡位）：显示偏移在两端橡皮筋化，落点投影
    // 按逻辑偏移算，两者只在越界拖动时不同。
    //
    // Phase 31（单位改制）：旧模型按点存储、静止值 = 序号 × stride，
    // 而 stride 随布局宽派生。回库是进程重启重建，出现级联里 metrics
    // 可能还是过渡宽：任何一次写入（snap 或 focusKey 的 sync 动画）
    // 用过渡 stride 算出的点值落盘后，最终 stride 下 place = 序号 −
    // offset/stride ≠ 0 就此定格（倾角、压暗都由 place 驱动，偏
    // 0.2–0.3 肉眼可见），且 settled 为真、无后续路径纠正——用户点
    // 它还会被 deckTap 当「已停稳的聚焦卡」直接启动（Phase 31 的
    // 正面门是另一道结构兜底，见 deckTap）。卡位单位下写值与 stride
    // 无关：序号是整数、静止值精确，过渡宽度在结构上不可能污染；
    // 点值只在画卡 position 时按当帧 stride 现算。宽度变化时静止
    // place 恒精确，onChange(w) 的 snap 退化为纯安全网、保留。
    @State private var libraryOrderKeys: [String] = LCGameLibraryOrderStore.load()
    @State private var carouselOffsetCards: CGFloat = 0
    @State private var carouselDragStartCards: CGFloat = 0
    @State private var carouselDragLogicalCards: CGFloat = 0
    // 拖动末段采样（Phase 38）：(时刻, 逻辑偏移) 序列，松手时取末
    // 120ms 窗口估真实末速——DragGesture 的 value.velocity 是全程
    // 阻尼平均、快甩时系统性低估末速，见 deckReleaseVelocityPerSecond。
    @State private var carouselDragSamples: [(time: Date, logical: CGFloat)] = []
    @State private var carouselDragging = false
    @State private var carouselSettled = true
    @State private var carouselScrollEpoch = 0
    // Cover Flow 式自由动量（Phase 37）：高速多卡松手后不预定目标，
    // 由 LCDeckMomentumDriver 逐帧把摩擦衰减积分直接写进偏移状态；
    // 速度是卡/s、随积分逐帧衰减。滚动中抓停 / 点卡 / 外部落位都先
    // 停驱动，见 stopDeckMomentum。
    @State private var carouselMomentumActive = false
    @State private var deckMomentumVelocity: CGFloat = 0
    @State private var deckMomentumDriver = LCDeckMomentumDriver()
    // 横屏牌组点击裁决（Phase 27）：上次裁决时刻（同一触摸被重复投递
    // 时的时间窗去重）——见 deckTap 注释。Phase 39 前另有
    // deckLastSwitchAt（最近一次牌组切换时刻：shelf 没有 carousel
    // 的 settled 机制、其时间制停稳 deckSettled 读它判停稳，
    // setFocusFromDeck 写它），随小库统一与 deckSettled 一并删除：
    // 停稳判定自此全卡数走 carouselSettled。
    @State private var deckTapAdjudicatedAt: Date = .distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    // MARK: 聚焦与状态推导

    private func key(of app: LCAppModel) -> String {
        app.appInfo.relativeBundlePath as String
    }

    private var focusedApp: LCAppModel? {
        if let focusKey, let app = apps.first(where: { key(of: $0) == focusKey }) {
            return app
        }
        return defaultFocus
    }

    /// 默认聚焦：最近启动过的一款（lastLaunched 由 LCAppModel.runApp 真实写入），否则列表第一款
    private var defaultFocus: LCAppModel? {
        apps.max { a, b in
            (a.appInfo.lastLaunched ?? .distantPast) < (b.appInfo.lastLaunched ?? .distantPast)
        } ?? apps.first
    }

    private var focusIndex: Int {
        guard let focusedApp, let idx = apps.firstIndex(of: focusedApp) else {
            return 0
        }
        return idx
    }

    private func setFocus(_ app: LCAppModel) {
        withAnimation(.easeInOut(duration: 0.35)) {
            focusKey = key(of: app)
        }
    }

    private func stepFocus(_ delta: Int) {
        let target = focusIndex + delta
        guard apps.indices.contains(target) else {
            return
        }
        setFocus(apps[target])
    }

    private func ensureFocus() {
        if focusedApp == nil, let fallback = defaultFocus {
            focusKey = key(of: fallback)
        }
    }

    // MARK: 手柄导航（主页版）

    /// 手柄导航的让位判据：库非空、列表层无弹层 / 面板盖着、主页
    /// 自身的手柄面板与状态帮助页都没开、App 在前台。任一不成立时
    /// 输入层摘掉 handler，手柄事件不落到主页。
    private var gamepadGateOpen: Bool {
        !apps.isEmpty && !overlayPresented && !controllerPanelPresented
            && stateHelpTarget == nil && scenePhase == .active
    }

    private func wireGamepadNav() {
        gamepadNav.onMove = { direction in gamepadMove(direction) }
        gamepadNav.onConfirm = { gamepadConfirm() }
    }

    /// 移动一格：复用现成聚焦状态（focusKey / focusedApp，不另建
    /// 焦点模型），顺序走 orderedApps（竖屏网格与横屏牌组的共同
    /// 视觉序）。横屏单列：左右切卡、上下不接；竖屏双列网格：
    /// 左右 ±1、上下 ±2（列数），到边停住不绕圈。横屏切换走
    /// setFocusFromDeck（牌组动画与停稳计时同触摸口径，轮播偏移
    /// 由其 onChange(focusKey) 自行同步）；竖屏切换后 bump 滚动
    /// 令牌，让 ScrollViewReader 把选中卡滚进可见区。
    private func gamepadMove(_ direction: LCGamepadNavDirection) {
        let list = orderedApps
        guard let current = focusedApp, let idx = list.firstIndex(of: current) else {
            ensureFocus()
            return
        }
        let delta: Int
        if isLandscapeLayout {
            switch direction {
            case .left: delta = -1
            case .right: delta = 1
            case .up, .down: return
            }
        } else {
            switch direction {
            case .left: delta = -1
            case .right: delta = 1
            case .up: delta = -2
            case .down: delta = 2
            }
        }
        let target = idx + delta
        guard list.indices.contains(target) else {
            return
        }
        if isLandscapeLayout {
            setFocusFromDeck(list[target])
        } else {
            setFocus(list[target])
            gamepadScrollToken += 1
        }
    }

    /// A 键 = 开始：与竖屏底部开始按钮同一入口（onRun，列表层
    /// wired 到 runGame）、同一可用条件（有聚焦且没有游戏在跑）；
    /// 横屏侧等价于点已停稳的聚焦卡（deckTap 的启动路）。
    private func gamepadConfirm() {
        guard let app = focusedApp, !app.isAppRunning else {
            return
        }
        onRun(app)
    }

    // MARK: 横屏轮播的顺序与聚焦（NX2 CoverFlow 移植辅助）

    /// 全主页共用的有序数据源（横屏牌组与竖屏「你的游戏」网格同读）：
    /// 顺序快照 ∩ 现有游戏，新游戏追加末尾；快照为空（全新安装、尚未
    /// 定序）时退回入参次序。Phase 30 起快照持久化且冻结：onAppear
    /// 只做集合收敛（maintainLibraryOrder），不再按最近游玩重排。
    private var orderedApps: [LCAppModel] {
        let byKey = Dictionary(uniqueKeysWithValues: apps.map { (key(of: $0), $0) })
        var result = libraryOrderKeys.compactMap { byKey[$0] }
        let known = Set(libraryOrderKeys)
        result += apps.filter { !known.contains(key(of: $0)) }
        return result.isEmpty ? apps : result
    }

    /// 横屏牌组数据源 = 全主页有序口径（旧名保留，横屏内部读法不变）
    private var landscapeApps: [LCAppModel] {
        orderedApps
    }

    /// 顺序快照维护（Phase 30 冻结）：root onAppear 调用。
    /// - 无快照（全新安装）：按 libraryOrder 定序一次并落盘——这是
    ///   唯一按最近游玩排序的时点，此刻视图刚建、没有活着的偏移量，
    ///   不会失同步。
    /// - 有快照、集合变了（装 / 卸）：收敛为生效次序（幸存者相对
    ///   次序不变、新游戏追加末尾，即 orderedApps 的推导结果）并
    ///   落盘；变序发生在存活视图上，偏移由顺序签名 snap 兜底。
    /// - 有快照、集合没变（普通出现 / 回库）：什么都不做——次序
    ///   冻结，刚玩的游戏不换位置；焦点由 focusedApp 的缺省推导
    ///   （最近启动款）跟随，牌组 onAppear 的 snap 按冻结序号落位
    ///   （回库有淡入遮罩盖住接缝，落位无动画不可见）。
    private func maintainLibraryOrder() {
        guard !apps.isEmpty else {
            return
        }
        if libraryOrderKeys.isEmpty {
            let seeded = LCGameLibraryInfo.libraryOrder(of: apps).map { key(of: $0) }
            libraryOrderKeys = seeded
            LCGameLibraryOrderStore.save(seeded)
            return
        }
        let effective = orderedApps.map { key(of: $0) }
        if effective != libraryOrderKeys {
            libraryOrderKeys = effective
            LCGameLibraryOrderStore.save(effective)
        }
    }

    private func landscapeFocusIndex(in list: [LCAppModel]) -> Int {
        guard let focusedApp, let idx = list.firstIndex(of: focusedApp) else {
            return 0
        }
        return idx
    }

    /// NX 的切换动画是 .smooth(duration: 0.3)，部署目标 15 没有该曲线，
    /// 用等价时长的 timingCurve 近似；减弱动态时按 NX 同口径降为 0.2 线性。
    private var deckAnimation: Animation {
        reduceMotion ? .linear(duration: 0.2) : .timingCurve(0.22, 0.61, 0.36, 1, duration: 0.3)
    }

    /// 手柄焦点缩放的弹簧：短 response + 略欠阻尼，与 deck 的短促
    /// 切换同风格、放大落定带一点回弹；减弱动态时同口径降为线性。
    private var gamepadFocusAnimation: Animation {
        reduceMotion ? .linear(duration: 0.2) : .spring(response: 0.32, dampingFraction: 0.72)
    }

    private func setFocusFromDeck(_ app: LCAppModel) {
        withAnimation(deckAnimation) {
            focusKey = key(of: app)
        }
    }

    /// 牌组落点规则（Phase 27，取代 NX CardSnap 的一手势一卡钳制）：
    /// 落点 = 逻辑偏移 + 速度投影后最近的卡。velocity 是朝后一张卡
    /// 方向的速度（卡位/ms），投影时长 220ms：慢拖时速度近零、落最
    /// 近卡（不足半张回原位）；快甩时投影把落点推过多张、一次滑多
    /// 卡。只钳列表两端，不再钳手势起始卡的邻位。Phase 31 起偏移全
    /// 线改卡位单位（见 carouselOffsetCards 注释），本函数入参随之
    /// 改卡位：公式与旧点值版逐项等价（旧式 projected/stride ≡ 新式
    /// projected 本身）。
    private static func cardSnap(logicalCards: CGFloat, velocityCards: CGFloat, count: Int) -> Int {
        let projected = logicalCards + velocityCards * 220
        let card = Int(projected.rounded())
        return min(count - 1, max(0, card))
    }

    /// 牌组停稳动画（Phase 27）：与 deckAnimation 同一曲线，时长按
    /// 行程（以卡位计）放大——一卡内仍是 0.3 的原手感，远行程至
    /// 多 0.55，避免多卡跳变套一卡时长显得硬切。减弱动态时按
    /// deckAnimation 同口径降为 0.2 线性。
    ///
    /// Phase 30（仅拖动松手、且行程 > 1 卡时）：0.55 的定时曲线在
    /// 多卡行程上读作拖尾（用户实测：小幅好评、大幅有延迟感），
    /// 改走插值弹簧——interpolatingSpring(质量 1、刚度 150、阻尼
    /// 24)，阻尼比 ≈0.98 近临界、无过冲；弹簧时标与行程无关
    /// （包络衰减 ζω₀ ≈ 12/s，收敛到 1% 约 0.38s），多卡总时长
    /// 天然次线性、落在约 0.38–0.45s。初速与松手速度连续：把
    /// 「朝落点方向的松手速度（卡位/s）÷ 行程（卡位）」折算为弹簧
    /// 的相对初速（单位 = 全行程/秒，钳 0–5），不从零速起步。一卡
    /// 内（含小幅慢拖就近落点）与点卡、外部同步（不传速度）仍走
    /// 下面的定时曲线原式，逐字未动。（本段弹簧在 Phase 35 被匀
    /// 速曲线取代，见下。）
    ///
    /// Phase 35（仅拖动松手、且行程 > 1 卡时，取代 Phase 30 的弹
    /// 簧）：用户实测快速多卡滑动时「正面图先显示、背后的封面才
    /// 滚过去」——弹簧的速度剖面是指数衰减（包络 ζω₀ ≈ 12/s）：
    /// 以 3 卡、松手 4 卡/s 为例，前两卡各约 0.09s 就过完，最后
    /// 一卡却要约 0.35s 爬行（行程到 99% 约 0.53s）；而中心卡的
    /// 缩放（1 − |near|×0.22）/ 压暗（−|near|×0.25）/ 角度在
    /// place 过 0 附近最敏感，高速前段里最先「看起来到位」；外
    /// 侧卡又有远退压缩（far×0.55）与角度封顶（|place| ≥ 1.5 后
    /// 45°），单位偏移的表观位移更小——迟到感被双重放大。多卡
    /// 段要的不是弹簧而是近匀速剖面，改走自定义贝塞尔
    /// .timingCurve(0.40, 0.46, 0.80, 1)：起步斜率 1.15（初速 =
    /// 均速的 1.15 倍，3 卡 / 0.55s 时约 6 卡/s；能进本分支必有
    /// |松手速度| > 约 2.3 卡/s——落点投影须先越过半卡，故同量
    /// 级、不从零起步）；时间 15%–75% 段斜率 0.92–1.19（巡航约
    /// 均速 1.05 倍、波动 ±13%，逐卡匀速通过）；c2y = 1 令末斜
    /// 率恰为 0，且进入最后半卡时斜率仍约 0.95——减速集中在最
    /// 后半卡内，总时长有限、恰好到达，无渐近尾巴；曲线单调、
    /// 无过冲回弹。总时长改为按行程近线性：min(0.85, 0.10 +
    /// 0.15 × 行程)——2 / 3 / 4 / 5 卡 = 0.40 / 0.55 / 0.70 /
    /// 0.85s（每卡均时 0.20 / 0.183 / 0.175 / 0.17s，5 卡触顶
    /// 封顶）。逐卡通过时间（曲线数值求积）：2 卡 0.169 /
    /// 0.231，3 卡 0.155 / 0.158 / 0.237，4 卡 0.149 / 0.148 /
    /// 0.157 / 0.247，5 卡 0.145 / 0.143 / 0.146 / 0.158 /
    /// 0.258——中段各卡约 0.15s 近乎相等，末卡多出的约 0.09s
    /// 全部来自最后半卡的收速。一卡内与点卡、外部同步（不传速
    /// 度）仍走下面的定时曲线原式，逐字未动。
    ///
    /// Phase 31：入参随偏移改卡位单位。相对初速是「速度 ÷ 行程」
    /// 的无量纲比，单位换算中不变；定时曲线的行程阈值（>1 卡）与
    /// 时长公式同为卡位口径，与旧点值版（÷stride 后）数值逐项相等。
    ///
    /// Phase 37：高速多卡松手的发布段改走 Cover Flow 式自由动量
    /// （startDeckMomentum），不再经本函数的多卡匀速分支；该分支
    /// 自此只服务低速松手（投影行程 > 1 卡但 |初速| 未过动量阈
    /// 值）一路径，点卡 / 外部同步 / 动量末段吸附（均不传速度、
    /// 行程 ≤ 1 卡或低速）走原式逐字未动。
    private func deckSettleAnimation(distanceCards: CGFloat, releaseVelocityCards: CGFloat? = nil) -> Animation {
        if reduceMotion {
            return .linear(duration: 0.2)
        }
        let strides = Double(abs(distanceCards))
        if strides > 1, releaseVelocityCards != nil {
            // Phase 35：多卡松手落点走匀速主导的贝塞尔曲线（剖面
            // 与时长公式见上 Phase 35 注释）；releaseVelocityCards
            // 在此只作分支判据——只有拖动松手传入速度，点卡与外
            // 部同步不传、恒走下面的原式。
            let duration = min(0.85, 0.10 + 0.15 * strides)
            return .timingCurve(0.40, 0.46, 0.80, 1, duration: duration)
        }
        let duration = min(0.55, 0.3 + 0.09 * max(0, strides - 1))
        return .timingCurve(0.22, 0.61, 0.36, 1, duration: duration)
    }

    /// 游戏状态求值（主页全部状态呈现的单一入口）：读 refreshToken
    /// 把依赖写明，令牌变化时状态随 body 按磁盘重算。求值走
    /// LCGameLibraryInfo.gameState：先按记录对齐容器快照再查
    /// romfs.img——手动经「文件」App 放的包没有任何 App 内事件来
    /// 对齐快照，直查快照会停在错误容器上长期报缺失（玩家实证）。
    /// 三态与旧二态（LCGameLibraryInfo.datapackReady，导入链复核
    /// 仍在用）的差异只在损坏态：二态把异常文件也算「在」，三态
    /// 把异常单列已损坏。
    private func gameState(_ app: LCAppModel) -> LCGameState {
        _ = refreshToken
        return LCGameLibraryInfo.gameState(for: app)
    }

    /// 横屏信息区状态文案色：深色沿用旧浅色值（比状态点色浅，
    /// 是横屏信息区原有的排法）；浅色改深色版（Phase 34）——
    /// 旧浅色值压在浅色晕染上几乎无对比，改与竖屏同口径的
    /// 深绿 / 深琥珀。损坏两模式共用 brokenRed（设置页浅色面
    /// 同值在用）。
    private func stateTextColor(_ state: LCGameState) -> Color {
        if colorScheme == .light {
            switch state {
            case .playable: return Color(red: 10 / 255, green: 125 / 255, blue: 55 / 255)
            case .needsDatapack: return Color(red: 166 / 255, green: 96 / 255, blue: 0 / 255)
            case .broken: return LCGameTheme.brokenRed
            }
        }
        switch state {
        case .playable: return Color(red: 196 / 255, green: 232 / 255, blue: 204 / 255)
        case .needsDatapack: return Color(red: 1.0, green: 196 / 255, blue: 110 / 255)
        case .broken: return LCGameTheme.brokenRed
        }
    }

    /// 横屏非聚焦卡左下状态胶囊的底色：缺包沿用旧暗琥珀，损坏用暗红
    private func capsuleBackground(_ state: LCGameState) -> Color {
        switch state {
        case .needsDatapack: return Color(red: 24 / 255, green: 18 / 255, blue: 8 / 255).opacity(0.85)
        case .broken: return Color(red: 30 / 255, green: 12 / 255, blue: 10 / 255).opacity(0.85)
        case .playable: return Color.clear
        }
    }

    /// 「最近游玩」排序：lastLaunched 倒序，从未启动过的排后面
    private var recentApps: [LCAppModel] {
        apps.sorted { a, b in
            let da = a.appInfo.lastLaunched ?? .distantPast
            let db = b.appInfo.lastLaunched ?? .distantPast
            if da != db {
                return da > db
            }
            return a.displayName < b.displayName
        }
    }

    /// 游玩时间文案只来自真实的 lastLaunched，没有记录就不显示
    private func playedText(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "lc.gameHome.playedToday".loc
        }
        if calendar.isDateInYesterday(date) {
            return "lc.gameHome.playedYesterday".loc
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day ?? 0
        if days > 1 && days <= 7 {
            return "lc.gameHome.playedDaysAgo %lld".localizeWithFormat(days)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return "lc.gameHome.playedOnDate %@".localizeWithFormat(formatter.string(from: date))
    }

    private func metaText(for app: LCAppModel) -> String {
        var text = "lc.gameHome.version %@".localizeWithFormat(app.version)
        if let lastLaunched = app.appInfo.lastLaunched {
            text += " · \(playedText(for: lastLaunched))"
        }
        return text
    }

    // MARK: 主体

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                LCGameTheme.pageBackground
                    .ignoresSafeArea()
                if apps.isEmpty {
                    emptyState(size: size, safeTop: safeAreaInsets.top, safeBottom: safeAreaInsets.bottom)
                } else if size.width > size.height {
                    landscape(size: size, safe: safeAreaInsets)
                } else {
                    portrait(size: size, safe: safeAreaInsets)
                }
                if installProgressVisible {
                    installPill(safeTop: safeAreaInsets.top)
                }
                if gamepadNav.hasController && !apps.isEmpty {
                    gamepadHintBar
                }
                // 手柄页自适应宿主（Phase 22）：横屏 = 右侧抽屉面板
                // （主页留在下层被压暗）、竖屏 = 整屏，形态随旋转跟随，
                // 语义与容器设置 / 游戏设置同轨
                // 顶部（Phase 26）：手柄页无 NavigationView，整屏形态的
                // 内容下移由页面自己在背景内侧垫（见 LCControllersView），
                // 宿主不外垫、不裁圆角
                LCSidePanelContainer(isPresented: controllerPanelPresented, onClose: { controllerPanelPresented = false }) {
                    LCControllersView(monitor: controllerMonitor, onClose: { controllerPanelPresented = false })
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        // 状态帮助页：竖屏 hero / 横屏信息区的状态行点开（非可玩态），
        // 内容与导入动作见 LCGameStateHelpSheet；导入走主页既有回调
        .sheet(item: $stateHelpTarget) { target in
            LCGameStateHelpSheet(app: target.app, state: target.state, onImportDatapack: {
                onImportDatapack(target.app)
            })
        }
        .onAppear {
            // 页面出现先把全部游戏的容器快照按记录对齐：主页的状态点
            // 求值虽走共用入口（内含对齐），这里先行一步让封面 / 时长等
            // 其余读快照的面与状态点同口径
            for app in apps {
                app.refreshContainerSelection()
            }
            ensureFocus()
            maintainLibraryOrder()
            // 游玩时长补结（Phase 18）：主页出现 = 此刻没有客体在本进程跑，
            // 统计文件里还挂着的 openSession 必是闪退/被划掉没结清的局，
            // 按心跳补结后再读快照（回库路径已由客体侧结清，这里是空转）。
            LCPlayStats.reconcileOpenSession()
            playStats = LCPlayStats.allEntries()
            sweepCoverFetches()
            // 手柄导航接线：回调注入 + 按当前判据决定是否装 handler
            wireGamepadNav()
            isLandscapeLayout = safeSize.width > safeSize.height
            gamepadNav.setActive(gamepadGateOpen)
        }
        .onDisappear {
            gamepadNav.setActive(false)
        }
        .onChange(of: refreshToken) { _ in
            playStats = LCPlayStats.allEntries()
            sweepCoverFetches()
        }
        .onChange(of: apps.map { key(of: $0) }) { _ in
            ensureFocus()
            // 库增删后重注回调，闭包捕获的 apps 快照不许过期
            wireGamepadNav()
        }
        .onChange(of: gamepadGateOpen) { open in
            gamepadNav.setActive(open)
        }
        .onChange(of: safeSize) { newSize in
            isLandscapeLayout = newSize.width > newSize.height
        }
    }

    /// 手柄提示条（手柄连着时才出现）：底部安全区上方的小胶囊，
    /// 竖屏避开底部开始栏（浮在其上方）、横屏贴底。样式照安装
    /// 胶囊的两分支（iOS 26 玻璃 / 半透明黑回退）。
    private var gamepadHintBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "dpad")
                    .font(.system(size: 13))
                Text("lc.gameHome.gamepadHint".loc)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .modifier { view in
                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    view
                        .foregroundColor(.primary)
                        .glassEffect(.regular, in: .capsule)
                } else {
                    view
                        .foregroundColor(.white)
                        .background(Capsule().fill(Color.black.opacity(0.72)))
                        .overlay(Capsule().strokeBorder(LCGameTheme.chipBorder, lineWidth: 1))
                }
            }
            .padding(.bottom, isLandscapeLayout ? safeAreaInsets.bottom + 10 : safeAreaInsets.bottom + 76)
        }
        .allowsHitTesting(false)
    }

    /// 联网封面懒抓（Phase 19）：主页出现 / 库刷新时逐个过一遍去重入口——
    /// 已有更高优先封面、已有抓取缓存、负缓存新鲜的游戏都在入口内直接
    /// 返回，不发请求；抓取成功后服务回调 bump libraryRefresh，封面随
    /// 令牌变化重解析（本 onChange 会再扫一遍，但那时缓存已落盘、空转）。
    private func sweepCoverFetches() {
        for app in apps {
            LCCoverFetchService.shared.ensureFetched(appInfo: app.appInfo)
        }
    }

    /// 水平边距对齐 NX2 壳真机截图实测：竖屏 ≈ 屏宽 5.9%（393pt 宽 ≈ 23pt），
    /// 横屏顶排左距 ≈ 屏宽 10.2%。旧值 9.3% 是竖屏留白过多的来源。
    private func margin(for size: CGSize) -> CGFloat {
        if size.width > size.height {
            return min(max(size.width * 0.102, 24), 120)
        }
        return min(max(size.width * 0.059, 18), 40)
    }

    // MARK: 通用小件

    private func statusDot(color: Color, radius: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.45))
                .frame(width: (radius + 2.5) * 2, height: (radius + 2.5) * 2)
            Circle()
                .fill(color)
                .frame(width: radius * 2, height: radius * 2)
        }
    }

    /// 圆形图面浮钮底：两个调用方（chromeButton、＋导入菜单）都是可点
    /// 控件；iOS 26 + Liquid Glass 可用时换原生玻璃（无 tint——regular
    /// 玻璃本身随外观自适应、interactive 按压反馈，形态照 App Store
    /// 浮动栏），否则逐字保留 chip 填充+描边。
    private func circleChrome(diameter: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        ZStack {
            content()
        }
        .frame(width: diameter, height: diameter)
        .modifier { view in
            if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                view
                    .glassEffect(.regular.interactive(), in: .circle)
            } else {
                view
                    .background {
                        ZStack {
                            Circle()
                                .fill(LCGameTheme.chipBackground)
                            Circle()
                                .strokeBorder(LCGameTheme.chipBorder, lineWidth: 1)
                        }
                    }
            }
        }
    }

    private func chromeButton(diameter: CGFloat, systemImage: String, fontSize: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            circleChrome(diameter: diameter) {
                Image(systemName: systemImage)
                    .font(.system(size: fontSize))
                    .gcChipIconForeground()
            }
        }
        .buttonStyle(.plain)
    }

    /// 手柄胶囊（对齐 NX 壳语义）：数字 = 当前已连接手柄数（GameController 实时
    /// 监听连接/断开刷新），点击打开手柄页（LCControllersView，复刻 NX 壳
    /// ControllersView 的结构与视觉）：自适应宿主呈现——横屏右侧抽屉
    /// 面板、竖屏整屏，旋转跟随（Phase 22）。尺寸与位置沿用原常量，只接行为。
    private func gamepadCapsule(height: CGFloat) -> some View {
        Button {
            controllerPanelPresented = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gamecontroller")
                    .font(.system(size: height * 0.42))
                Text("\(controllerMonitor.controllers.count)")
                    .font(.system(size: height * 0.4, weight: .bold))
            }
            .gcChipIconForeground()
            .padding(.horizontal, height * 0.32)
            .frame(height: height)
            .fixedSize(horizontal: true, vertical: false)
            .modifier { view in
                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    view
                        .glassEffect(.regular.interactive(), in: .capsule)
                } else {
                    view
                        .background {
                            ZStack {
                                Capsule()
                                    .fill(LCGameTheme.chipBackground)
                                Capsule()
                                    .strokeBorder(LCGameTheme.chipBorder, lineWidth: 1)
                            }
                        }
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// ＋导入菜单：导入 IPA / 导入数据包（现有两条导入实现），外加隐藏游戏恢复入口
    private func importMenu(diameter: CGFloat) -> some View {
        Menu {
            Button {
                onImportIPA()
            } label: {
                Label("lc.gameHome.importIpa".loc, systemImage: "doc.badge.plus")
            }
            Button {
                onImportDatapackGeneric()
            } label: {
                Label("lc.gameHome.importDataPack".loc, systemImage: "square.and.arrow.down")
            }
            if hiddenAppsCount > 0 {
                Divider()
                Button {
                    onOpenHiddenApps()
                } label: {
                    Label("lc.gameHome.hiddenGamesCount %lld".localizeWithFormat(hiddenAppsCount), systemImage: "eye.slash")
                }
            }
        } label: {
            circleChrome(diameter: diameter) {
                Image(systemName: "plus")
                    .font(.system(size: diameter * 0.4, weight: .semibold))
                    .gcChipIconForeground()
            }
        }
    }

    /// 右上按钮排：横屏 ＋/滑杆/手柄/齿轮；竖屏封面排 ＋/手柄/齿轮（滑杆在底部开始键旁）
    private func chromeRow(diameter: CGFloat, includeSliders: Bool) -> some View {
        HStack(spacing: 12) {
            if multiLCStatus != 2 {
                importMenu(diameter: diameter)
            }
            if includeSliders {
                chromeButton(diameter: diameter, systemImage: "slider.horizontal.3", fontSize: diameter * 0.44) {
                    if let focusedApp {
                        onSettings(focusedApp)
                    }
                }
            }
            gamepadCapsule(height: diameter)
            chromeButton(diameter: diameter, systemImage: "gearshape", fontSize: diameter * 0.46) {
                onOpenContainerSettings()
            }
        }
    }

    /// 长按动作：与旧卡片 contextMenu 逐项同语义
    @ViewBuilder
    private func gameContextMenu(for app: LCAppModel) -> some View {
        if !app.uiIsShared, app.uiSelectedContainer != nil {
            Button {
                onOpenDataFolder(app)
            } label: {
                Label("lc.appBanner.openDataFolder".loc, systemImage: "folder")
            }
        }
        Button {
            onSettings(app)
        } label: {
            Label("lc.gameHome.gameSettings".loc, systemImage: "gear")
        }
        if !app.uiIsShared {
            Button {
                onImportDatapack(app)
            } label: {
                Label("lc.gameHome.importDataPack".loc, systemImage: "square.and.arrow.down")
            }
        }
        if !app.uiIsShared {
            Button(role: .destructive) {
                onUninstall(app)
            } label: {
                Label("lc.appBanner.uninstall".loc, systemImage: "trash")
            }
        }
    }

    private func installPill(safeTop: CGFloat) -> some View {
        VStack {
            HStack(spacing: 8) {
                ProgressView()
                Text("lc.gameHome.installingPercent %lld".localizeWithFormat(Int(installProgress * 100)))
                    .font(.footnote.bold())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .modifier { view in
                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    // 纯展示胶囊（安装进度）：玻璃不加 interactive、不加
                    // tint（随外观自适应），前景走语义色两模式都可读
                    view
                        .foregroundColor(.primary)
                        .tint(.primary)
                        .glassEffect(.regular, in: .capsule)
                } else {
                    view
                        .foregroundColor(.white)
                        .tint(.white)
                        .background(Capsule().fill(Color.black.opacity(0.72)))
                        .overlay(Capsule().strokeBorder(LCGameTheme.chipBorder, lineWidth: 1))
                }
            }
            .padding(.top, safeTop + 8)
            Spacer()
        }
    }

    // MARK: 空库

    private func emptyState(size: CGSize, safeTop: CGFloat, safeBottom: CGFloat) -> some View {
        ZStack {
            VStack {
                HStack {
                    Spacer()
                    chromeRow(diameter: 40, includeSliders: false)
                }
                Spacer()
            }
            .padding(.top, safeTop + 6)
            .padding(.horizontal, margin(for: size))

            VStack(spacing: 18) {
                Image(systemName: "gamecontroller")
                    .font(.system(size: 54))
                    .foregroundColor(.gray)
                Text("lc.gameHome.noGamesYet".loc)
                    .font(.system(.title3, design: .rounded).bold())
                    .foregroundColor(LCGameTheme.creamColor)
                if multiLCStatus == 2 {
                    Text("lc.appList.manageInPrimaryTip".loc)
                        .font(.footnote)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                } else {
                    VStack(spacing: 12) {
                        Button {
                            onImportIPA()
                        } label: {
                            Text("lc.gameHome.importIpaPlus".loc)
                                .font(.headline)
                                .foregroundColor(.black)
                                .frame(width: 240, height: 50)
                                .background(LCGameTheme.nxCream)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        Button {
                            onImportDatapackGeneric()
                        } label: {
                            Text("lc.gameHome.importDataPackPlus".loc)
                                .font(.headline)
                                .foregroundColor(LCGameTheme.chipIcon)
                                .frame(width: 240, height: 50)
                                .overlay(Capsule().strokeBorder(LCGameTheme.chipBorderOnSurface, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        if hiddenAppsCount > 0 {
                            Button {
                                onOpenHiddenApps()
                            } label: {
                                Text("lc.gameHome.hiddenGamesCount %lld".localizeWithFormat(hiddenAppsCount))
                                    .font(.footnote)
                                    .foregroundColor(.gray)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, margin(for: size))
        }
    }

    // MARK: 竖屏

    private func portrait(size: CGSize, safe: EdgeInsets) -> some View {
        let w = size.width
        let m = margin(for: size)
        let heroH = max(size.height * 0.39, 280)
        return ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        portraitHero(width: w, height: heroH, safeTop: safe.top, margin: m)
                        portraitGames(margin: m, width: w)
                        portraitRecent(margin: m, width: w)
                        if multiLCStatus == 2 {
                            Text("lc.appList.manageInPrimaryTip".loc)
                                .font(.footnote)
                                .foregroundColor(.gray)
                                .padding(.horizontal, m)
                                .padding(.top, 20)
                        }
                        // 给底部浮动开始栏让位
                        Color.clear.frame(height: 118)
                    }
                }
                .ignoresSafeArea(edges: .top)
                // 手柄移动后把选中卡滚入可见区：仅手柄路径 bump 令牌，
                // 触摸点选切聚焦不触发、滚动位置不被抢。锚点是网格卡
                // 的 id（portraitGames 给每张卡打了同名 id）
                .onChange(of: gamepadScrollToken) { _ in
                    if let app = focusedApp {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(key(of: app), anchor: .center)
                        }
                    }
                }
            }
            portraitBottomBar(margin: m, safeBottom: safe.bottom)
        }
    }

    private func portraitHero(width: CGFloat, height: CGFloat, safeTop: CGFloat, margin m: CGFloat) -> some View {
        ZStack {
            if let app = focusedApp {
                // Phase 43：浅色下底图挂熔化 mask（heroBackdrop
                // MaskStops）原地溶入页底——机制级移植设置页定
                // 版的主力层（图像自身 alpha 长尾渐隐），取代
                // 融合叠加的「白色带」读法（定案见主题注
                // 释）。无横图兜底整幅同熔（糊化底与中央清晰
                // 图标一并渐隐、无硬边）。深色不挂 mask、底图
                // 逐字不变。
                Group {
                    if colorScheme == .light {
                        LCGameCoverView(app: app, darkModeIcon: darkModeIcon, refreshToken: refreshToken, beautifiedFallback: true)
                            .frame(width: width, height: height)
                            .clipped()
                            .mask {
                                LinearGradient(
                                    gradient: Gradient(stops: LCGameTheme.heroBackdropMaskStops),
                                    startPoint: .top, endPoint: .bottom
                                )
                            }
                    } else {
                        LCGameCoverView(app: app, darkModeIcon: darkModeIcon, refreshToken: refreshToken, beautifiedFallback: true)
                            .frame(width: width, height: height)
                            .clipped()
                    }
                }
            }
            // 底部渐隐到黑、顶部压暗保状态栏可读（照预览 vgrad 取值）
            VStack {
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color.black.opacity(0.43), location: 0),
                        .init(color: Color.black.opacity(0), location: 1)
                    ]),
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: height * 0.12)
                Spacer()
            }
            // 融合渐变（图 → 页底）：stops 走 LCGameTheme
            // .heroFusionStops 的平滑曲线（Phase 32：色值与 alpha
            // 两通道同为单条连续平滑函数），几何（带高 0.48h、底
            // 锚定）与端点逐字不变；深浅两模式共用此层，深色模式
            // 本轮只换 stops 曲线、不动形态与强度。
            // Phase 43：本层浅色退役——浅色的图 → 页底过渡改由
            // 底图 mask 原地熔化承担（见上与主题 heroBackdrop
            // MaskStops 注释），本层只在深色渲染（深色融合是向
            // 近黑页底的淡出、形态与强度逐字不变）。
            if colorScheme == .dark {
                VStack {
                    Spacer()
                    LinearGradient(
                        gradient: Gradient(stops: LCGameTheme.heroFusionStops),
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: height * 0.48)
                }
            }
            // 浅色专用深罩（用户看预览拍板 P1）：浅色下融合渐变把封面
            // 下部洗成近白页底、白色大标题糊在亮底上。标题文字层之下
            // 加一层深色渐变罩：stops 与 LCGameTheme.coverScrimAnchors
            // 同锚点（峰值 0.47 对准标题带，向下经版本行渐弱、
            // 在 hero 下缘外 12pt 处收零，不留硬界），
            // Phase 32 起改走密采样版 heroScrimStops（见下注）；
            // 深色模式不加、逐字保持现状（原渐变已是深色融合）。
            // 几何 = #69 形态：罩高 0.62h+24、下探 12。Phase 30 曾把
            // 本罩改成与图同终点（高 0.58h、下探 0）想消图缘折角，
            // 用户装机实测裁决「主页深罩过渡不如原来的自然」——渐变
            // 被压缩变陡、图下缘雾感反而更重，Phase 31 按裁决回退
            // 本处几何至 #69 值（罩与上方融合渐变回 #69 的共存形
            // 态）；Phase 30 的同终点对齐只保留在设置页页头（罩高
            // 532 / 下探 160 与图最后一行齐平，本轮不动）。
            // Phase 32：本罩 stops 改走 heroScrimStops（同锚点单调
            // 三次密采样）+ 其下噪点层，治深色兜底图面上的阶梯感；
            // 本处几何（0.62h+24 / 下探 12）逐字不动，丝之歌等明亮
            // 图面认可的 #69 形态不改陡、不改短。
            // Phase 42：锚点按设置页 Phase 41 语法重塑 + 采样
            // 17 → 129（峰值与文字带取值只强不弱、几何逐字不
            // 动，定案与数值见主题 coverScrimAnchors 注释）；同
            // 轮融合 stops 13 → 129、横屏浅色融合 17 → 129
            // （曲线逐点不变、只加密）。
            if colorScheme == .light {
                VStack {
                    Spacer()
                    LinearGradient(
                        gradient: Gradient(stops: LCGameTheme.heroScrimStops),
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: height * 0.62 + 24)
                    .offset(y: 12)
                }
                .allowsHitTesting(false)
            }
            // 静态噪点（Phase 32）：盖在融合 + 深罩之上、浮钮与文
            // 字之下，几何与深罩同带（0.62h+24、下探 12，完整覆
            // 盖融合带），打散密采样后残余的 8-bit 量化色带；只
            // 在浅色加——深色模式本轮只平滑融合 stops、不加层。
            // 开关与纹理见 LCGameTheme.heroDitherOpacity。
            // Phase 44：噪点另挂尾部收尾 mask（heroNoiseTail
            // MaskStops）——其直流偏移与颗粒原与深罩同在画布
            // 底边行硬切、是底缘台阶的共犯；mask 在 loc 0.94
            // 前满幅、其后平滑收零，覆盖范围与栈体收尾对齐。
            if colorScheme == .light, LCGameTheme.heroDitherOpacity > 0 {
                VStack {
                    Spacer()
                    Image(uiImage: LCGameTheme.heroNoiseImage)
                        .resizable()
                        .frame(height: height * 0.62 + 24)
                        .mask {
                            LinearGradient(
                                gradient: Gradient(stops: LCGameTheme.heroNoiseTailMaskStops),
                                startPoint: .top, endPoint: .bottom
                            )
                        }
                        .offset(y: 12)
                }
                .opacity(LCGameTheme.heroDitherOpacity)
                .allowsHitTesting(false)
            }
            // 右上浮钮排
            VStack {
                HStack {
                    Spacer()
                    chromeRow(diameter: 40, includeSliders: false)
                }
                // 浮钮排落在真实安全区之下（safeTop 由列表层注入，不再是被
                // .ignoresSafeArea() 归零的值），+6 后约在屏高 7% 处，不碰灵动岛
                .padding(.top, safeTop + 6)
                .padding(.trailing, m)
                Spacer()
            }
            // 左下状态 + 标题 + 版本
            VStack {
                Spacer()
                if let app = focusedApp {
                    VStack(alignment: .leading, spacing: 8) {
                        // 状态行三态呈现（照 NX GameStateView 口径）：非
                        // 可玩时整行可点，打开状态帮助页（怎么修 + 动作）
                        Button {
                            let state = gameState(app)
                            if !state.isPlayable {
                                stateHelpTarget = LCGameStateTarget(app: app, state: state)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                statusDot(color: gameState(app).themeColor, radius: 5)
                                Text(gameState(app).title)
                                    .font(.system(size: 13.5, weight: .bold))
                                    .foregroundColor(gameState(app).themeColor)
                            }
                        }
                        .buttonStyle(.plain)
                        Text(app.displayName)
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(metaText(for: app))
                            .font(.system(size: 13.5))
                            .foregroundColor(LCGameTheme.mutedText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, m)
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(width: width, height: height)
    }

    private func portraitGames(margin m: CGFloat, width: CGFloat) -> some View {
        let spacing: CGFloat = 15
        let columnWidth = (width - m * 2 - spacing) / 2
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("lc.gameHome.yourGames".loc)
                    .font(.system(size: 14))
                    .foregroundColor(LCGameTheme.sectionText)
                Spacer()
                Text("\(apps.count)")
                    .font(.system(size: 14))
                    .foregroundColor(LCGameTheme.mutedText)
            }
            .padding(.horizontal, m)
            .padding(.top, 20)
            .padding(.bottom, 14)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: spacing), GridItem(.flexible(), spacing: spacing)], spacing: 18) {
                ForEach(orderedApps, id: \.self) { app in
                    VStack(alignment: .leading, spacing: 8) {
                        LCGameCoverView(app: app, darkModeIcon: darkModeIcon, refreshToken: refreshToken, beautifiedFallback: true)
                            .frame(width: columnWidth, height: columnWidth * 9 / 16)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(alignment: .topLeading) {
                                statusDot(color: gameState(app).themeColor, radius: 5)
                                    .padding(10)
                            }
                            // 手柄焦点表现：手柄连着时聚焦卡整体放大
                            // 1.07 + 柔和投影（tvOS 式焦点）；无手柄时
                            // scale 恒 1、无投影，与现行界面逐字一致。
                            // 防裁剪：缩放施加在封面自身 clipShape 之外
                            // （圆角裁剪随图一起放大），本 cell、LazyVGrid、
                            // 外层 VStack 均无任何裁剪；手柄路径又先把
                            // 聚焦卡滚到视口中央，1.07 的增量（卡宽每侧
                            // 约 6pt）小于网格 15pt 间距，放大边缘完整露出
                            .scaleEffect(gamepadNav.hasController && focusedApp == app ? 1.07 : 1)
                            .shadow(color: .black.opacity(gamepadNav.hasController && focusedApp == app ? 0.35 : 0), radius: 12, x: 0, y: 6)
                            .animation(gamepadFocusAnimation, value: gamepadNav.hasController && focusedApp == app)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                setFocus(app)
                            }
                            .contextMenu {
                                gameContextMenu(for: app)
                            }
                        Text(app.displayName)
                            .font(.system(size: 14))
                            .foregroundColor(LCGameTheme.sectionText)
                            .lineLimit(1)
                        // 聚焦项名下米色线（照预览）
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(focusedApp == app ? LCGameTheme.nxCream : Color.clear)
                            .frame(width: columnWidth, height: 3)
                    }
                    // 手柄滚动锚点（ScrollViewReader.scrollTo 的目标 id）
                    .id(key(of: app))
                    // 聚焦卡放大后抬升绘制层级，压住相邻卡而不是被压
                    .zIndex(gamepadNav.hasController && focusedApp == app ? 1 : 0)
                }
            }
            .padding(.horizontal, m)
        }
    }

    private func portraitRecent(margin m: CGFloat, width: CGFloat) -> some View {
        let rows = Array(recentApps.prefix(6))
        return VStack(alignment: .leading, spacing: 0) {
            Text("lc.gameHome.recentlyPlayed".loc)
                .font(.system(size: 14))
                .foregroundColor(LCGameTheme.sectionText)
                .padding(.horizontal, m)
                .padding(.top, 26)
                .padding(.bottom, 6)

            ForEach(rows.indices, id: \.self) { idx in
                let app = rows[idx]
                HStack(spacing: 12) {
                    LCGameCoverView(app: app, darkModeIcon: darkModeIcon, refreshToken: refreshToken, beautifiedFallback: true)
                        .frame(width: 73, height: 41)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        // 手柄焦点表现（与网格卡同口径）：聚焦游戏在
                        // 最近行里出现时缩略图整体放大 1.08（元素小、
                        // 幅度略大）+ 投影，并抬升层级。防裁剪：缩放
                        // 施加在缩略图自身 clipShape 之外，行内 HStack、
                        // 外层 VStack 均无裁剪；1.08 的增量（宽每侧约
                        // 2.9pt、高每侧约 1.6pt）远小于行上下 10pt
                        // 留白与 12pt 横向间距，完整露出
                        .scaleEffect(gamepadNav.hasController && focusedApp == app ? 1.08 : 1)
                        .shadow(color: .black.opacity(gamepadNav.hasController && focusedApp == app ? 0.35 : 0), radius: 8, x: 0, y: 4)
                        .animation(gamepadFocusAnimation, value: gamepadNav.hasController && focusedApp == app)
                        .zIndex(gamepadNav.hasController && focusedApp == app ? 1 : 0)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.displayName)
                            .font(.system(size: 15))
                            .foregroundColor(LCGameTheme.sectionText)
                            .lineLimit(1)
                        recentSubtitle(for: app)
                        // 游玩时长行（Phase 18，用户指定只上「最近游玩」）：
                        // 有累计记录才出，文案如「累计 2 小时 5 分钟 · 上次 32 分钟」
                        if let statsText = LCPlayStats.summaryText(for: playStats[app.bundleIdentifier]) {
                            Text(statsText)
                                .font(.system(size: 12.5))
                                .foregroundColor(LCGameTheme.mutedText)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button {
                        onRun(app)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 15))
                            .foregroundColor(Color(UIColor { trait in
                                trait.userInterfaceStyle == .dark
                                    ? UIColor(red: 168 / 255, green: 168 / 255, blue: 172 / 255, alpha: 1)
                                    : UIColor(red: 110 / 255, green: 110 / 255, blue: 115 / 255, alpha: 1)
                            }))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    setFocus(app)
                }
                .contextMenu {
                    gameContextMenu(for: app)
                }
                .padding(.horizontal, m)
                .padding(.vertical, 10)

                if idx < rows.count - 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(height: 0.5)
                        .padding(.leading, m + 73 + 12)
                        .padding(.trailing, m)
                }
            }
        }
    }

    @ViewBuilder
    private func recentSubtitle(for app: LCAppModel) -> some View {
        if !gameState(app).isPlayable {
            HStack(spacing: 6) {
                statusDot(color: gameState(app).themeColor, radius: 3.5)
                Text(gameState(app).title)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(gameState(app).themeColor)
            }
        } else if let lastLaunched = app.appInfo.lastLaunched {
            Text(playedText(for: lastLaunched))
                .font(.system(size: 13))
                .foregroundColor(LCGameTheme.mutedText)
        } else {
            Text("lc.gameHome.version %@".localizeWithFormat(app.version))
                .font(.system(size: 13))
                .foregroundColor(LCGameTheme.mutedText)
        }
    }

    private func portraitBottomBar(margin m: CGFloat, safeBottom: CGFloat) -> some View {
        VStack {
            Spacer()
            ZStack(alignment: .bottom) {
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: LCGameTheme.pageBackground.opacity(0), location: 0),
                        .init(color: LCGameTheme.pageBackground.opacity(0.92), location: 0.45),
                        .init(color: LCGameTheme.pageBackground, location: 1)
                    ]),
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 108)
                HStack(spacing: 14) {
                    Button {
                        if let focusedApp {
                            onRun(focusedApp)
                        }
                    } label: {
                        HStack(spacing: 9) {
                            if let focusedApp, focusedApp.isSigningInProgress {
                                ProgressView()
                                    .tint(.black)
                            } else {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 17))
                                Text("lc.gameHome.start".loc)
                                    .font(.system(size: 19, weight: .bold))
                            }
                        }
                        .foregroundColor(Color(red: 18 / 255, green: 18 / 255, blue: 18 / 255))
                        .frame(height: 56)
                        .frame(maxWidth: .infinity)
                        .gcStartButtonBackground()
                        // 命中区 = 整颗可见胶囊：label 无 contentShape 时
                        // 命中回落到 HStack 内容本身（图标 + 文字），玻璃
                        // 分支下胶囊面又是 glassEffect 渲染层而非实体视图，
                        // 点胶囊空白处无反应（用户实报只有「开始」文字块
                        // 能点）。胶囊形与两分支的胶囊底同帧内切、逐点
                        // 一致——只定命中区，不大不小，外观零变化。
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    // 手柄焦点表现：手柄连着时开始钮整体放大 1.03 +
                    // 投影，明示 A 键的目标就是它；无手柄时 scale 恒 1、
                    // 无投影，逐字原样。防裁剪：底栏 ZStack、HStack 到
                    // portraitBottomBar 根视图全程无任何裁剪修饰，1.03
                    // 的增量（高每侧约 0.9pt、宽每侧约 5pt）小于与滑杆
                    // 钮的 14pt 间距、上方又有 108pt 渐变区兜底，完整露出
                    .scaleEffect(gamepadNav.hasController ? 1.03 : 1)
                    .shadow(color: .black.opacity(gamepadNav.hasController ? 0.25 : 0), radius: 10, x: 0, y: 4)
                    .animation(gamepadFocusAnimation, value: gamepadNav.hasController)
                    .zIndex(gamepadNav.hasController ? 1 : 0)
                    .disabled(focusedApp == nil || (focusedApp?.isAppRunning ?? false))

                    chromeButton(diameter: 56, systemImage: "slider.horizontal.3", fontSize: 24) {
                        if let focusedApp {
                            onSettings(focusedApp)
                        }
                    }
                }
                // NX 竖屏实测：开始胶囊下缘距屏底 ≈ 42pt ≈ 安全区 34 + 8
                .padding(.horizontal, m)
                .padding(.bottom, safeBottom + 8)
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: 横屏（NX2 CoverFlow 移植：几何与吸附规则照 DmShell CoverFlowView）

    /// 横屏度量：与 NX CoverFlowView 同一度量参考系——全部量在安全区
    /// geometry 内原样计算（safeSize + safeAreaInsets，正是 NX
    /// LibraryView 传给 CoverFlowView 的 geometry.size + screenInsets），
    /// 不再用全屏尺寸做「等值换算」：旧换算的两处宽度封顶（0.54 cap 与
    /// shelf cap）误用全屏宽，卡区锚点也脱离了 NX 的 middle 定义，
    /// 安全区左右留边越大的机型偏得越多（Phase 13）。
    /// 卡高由上下两头反推（下：卡底要给信息区让位；上：卡顶不进顶栏
    /// 区），再被安全区宽 54% 的 16:9 封顶，最后 /1.06 给倾斜留头寸。
    /// short = 安全区高 < 520（手机横屏）。
    private struct LCLandscapeMetrics {
        let short: Bool
        let cover: CGFloat
        let stride: CGFloat
        let cardAreaHeight: CGFloat
        let cardAreaTop: CGFloat
        let gap: CGFloat
        let titleSize: CGFloat

        init(safeSize: CGSize, safe: EdgeInsets) {
            let width = safeSize.width
            let height = safeSize.height
            short = height < 520
            titleSize = short ? 18 : 28
            let words = titleSize * 1.3 * 2 + 8 + 34
            gap = short ? 10 : 24
            let below: CGFloat = short ? 4 : 56
            let barTop: CGFloat = short ? 12 : 16
            // 整屏中点在安全区坐标系里的位置（NX middle 定义原式）
            let middle = (height + safe.top + safe.bottom) / 2 - safe.top
            let byBottom = 2 * (height - middle - gap - words - below)
            let byTop = 2 * (middle - barTop - 44 - (short ? 6 : 16))
            let cardHeight = max(90, min(byBottom, byTop, width * 0.54 * 9 / 16) / 1.06)
            cover = cardHeight * 16 / 9
            stride = cover + cover * 0.04
            cardAreaHeight = cardHeight * 1.06
            // 卡区顶换算回本视图（全屏出血）坐标：安全区原点 + middle
            cardAreaTop = safe.top + middle - cardAreaHeight / 2
        }
    }

    private func landscape(size: CGSize, safe: EdgeInsets) -> some View {
        let w = size.width
        let metrics = LCLandscapeMetrics(safeSize: safeSize, safe: safe)
        let list = landscapeApps
        let focusIdx = landscapeFocusIndex(in: list)
        return ZStack(alignment: .top) {
            landscapeBackdrop(size: size)

            // 卡区 + 信息区：卡区顶按整屏中点定位，信息区跟在卡区下方 gap 处
            VStack(spacing: 0) {
                // Phase 39：≤3 张不再分流 shelf，全卡数同一套
                // carousel 列车（差异对照与推论见 landscapeCarousel
                // 头注释的 Phase 39 段）。
                landscapeCarousel(list: list, metrics: metrics, size: size)
                    .frame(height: metrics.cardAreaHeight)

                if let app = focusedApp {
                    landscapeInfo(app: app, metrics: metrics, width: w)
                        .padding(.top, metrics.gap)
                        .padding(.horizontal, 24)
                }
            }
            .padding(.top, metrics.cardAreaTop)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // 顶部行：左位置字、右按钮排（LC 现行，位置口径不动）
            VStack {
                HStack(alignment: .center) {
                    HStack(spacing: 12) {
                        // 计数行文字色（Phase 34）：深色沿用原固定
                        // 浅色值；浅色改语义色（sectionText /
                        // mutedText，与竖屏浅色同口径）——原固定
                        // 值压在浅色晕染上几乎看不见（用户实测）。
                        Text("lc.gameHome.yourGames".loc)
                            .font(.system(size: 14))
                            .foregroundColor(colorScheme == .light ? LCGameTheme.sectionText : Color(red: 206 / 255, green: 200 / 255, blue: 194 / 255))
                        Text("lc.gameHome.focusPosition %lld %lld".localizeWithFormat(focusIdx + 1, list.count))
                            .font(.system(size: 14))
                            .foregroundColor(colorScheme == .light ? LCGameTheme.mutedText : Color(red: 172 / 255, green: 164 / 255, blue: 158 / 255))
                    }
                    Spacer()
                    chromeRow(diameter: 41, includeSliders: true)
                }
                // 顶排对齐 NX 横屏：钮面约在屏高 4% 处起（图标中心 ≈ 7%）
                .padding(.top, safe.top + size.height * 0.04)
                .padding(.horizontal, margin(for: size))
                Spacer()
            }
        }
    }

    /// 背景：聚焦游戏封面的色调晕染（NX CoverFlowBackdrop 常量）：原图
    /// 放大 1.3、模糊 60、饱和 1.25、不透明 0.75，切换时 0.45 交叉淡化；
    /// 上面再压径向（中心 0.5/0.4、80→900）与纵向两道渐变收边。
    /// 浅色另在最上补一层底部融合（Phase 34，见 ZStack 内注
    /// 释）：把帧底外出血的封面收进页底色、消底边硬带；深色
    /// 不加、收尾逐字不变。
    private func landscapeBackdrop(size: CGSize) -> some View {
        ZStack {
            LCGameTheme.pageBackground
            if let app = focusedApp {
                LCGameCoverView(app: app, darkModeIcon: darkModeIcon, refreshToken: refreshToken)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .scaleEffect(1.3)
                    .blur(radius: 60)
                    .saturation(1.25)
                    .opacity(0.75)
                    .id(key(of: app))
                    .transition(.opacity)
            }
            RadialGradient(
                colors: [.clear, LCGameTheme.pageBackground.opacity(0.75)],
                center: UnitPoint(x: 0.5, y: 0.4),
                startRadius: 80,
                endRadius: 900
            )
            LinearGradient(
                colors: [.black.opacity(0.25), .clear, LCGameTheme.pageBackground.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
            // 浅色专用底部融合（Phase 34，用户实测）：浅色下屏
            // 幕最底边有一条未被洗色的封面原色直边带——封面层
            // 放大 1.3、出血越过 backdrop 帧底，而洗色层（页底
            // 色打底 + 两道渐变）都止于帧内、且纵向渐变底止只
            // 到页底色 0.85 永不收满，出血的那截封面在底边露
            // 出原色（深色下封面底本身近黑、看不见）。补一层
            // 与竖屏融合同思路的底部收尾：带从屏高 50% 起、
            // 下探出帧底 40pt，f 在带内 0.80 处已到 1 并平台
            // （landscapeLightMeltStops），帧底处已是纯页底
            // 色、屏上不存在洗色的边界，硬带消除。深色不加
            // 本层、收尾逐字不变。
            if colorScheme == .light {
                LinearGradient(
                    stops: LCGameTheme.landscapeLightMeltStops,
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: size.width, height: size.height * 0.5 + 40)
                .offset(y: size.height * 0.25 + 20)
                .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(reduceMotion ? .linear(duration: 0.2) : .easeInOut(duration: 0.45), value: focusKey)
    }

    /// 聚焦卡下方信息区（NX 布局、LC 语义）：游戏名（字号随 short 取
    /// 18/28、两行预留、切换只交叉淡化不跳高），其下 34pt 定高行放 LC
    /// 自己的数据包状态；开始入口仍是点聚焦卡本身，不搬 NX 的状态文案。
    private func landscapeInfo(app: LCAppModel, metrics: LCLandscapeMetrics, width w: CGFloat) -> some View {
        let state = gameState(app)
        return ZStack(alignment: .top) {
            // 浅色对比方案（Phase 34 定版，用户实测后改判）：旧
            // 法在此垫一块模糊深色斑（黑 0.36 + blur 30）给白
            // 字撑对比——0.36 的黑模糊后只剩中灰，白字压上去
            // 仍发飘，且斑本身在浅底上读作一团灰黑污渍（与卡
            // 投影叠在中心卡下方）。改走语义色单选：标题 /
            // 状态 / 计数在浅色下改深色语义值（见下与
            // stateTextColor、landscape 计数行），斑整块移除、
            // 不与语义色叠加。取舍理由：横屏信息区落在
            // backdrop 纵向渐变的收尾段、底色已被洗向页底
            // （与竖屏 hero 压原始封面不同），深色字在各封面
            // 下均可读；深罩路线则要按封面明暗逐个调斑的强
            // 度、且污渍感无解。深色模式本就无斑、逐字不变。
            // 隐藏占位先量好两行标题 + 34 状态行，切换时只有文字淡换
            VStack(spacing: 8) {
                Text("M\nM")
                    .font(.system(size: metrics.titleSize, weight: .bold))
                Color.clear.frame(height: 34)
            }
            .hidden()
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(app.displayName)
                    .font(.system(size: metrics.titleSize, weight: .bold))
                    .tracking(-metrics.titleSize * 0.04)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
                    .foregroundColor(colorScheme == .light ? LCGameTheme.sectionText : .white)
                    .shadow(color: colorScheme == .light ? .clear : .black.opacity(0.35), radius: 10)
                // 状态行三态呈现：文案/色随状态（可玩与缺包沿用旧
                // 文案与浅色值，损坏新增红色「已损坏」）；非可玩时
                // 可点开状态帮助页，与竖屏 hero 同一入口
                Button {
                    if !state.isPlayable {
                        stateHelpTarget = LCGameStateTarget(app: app, state: state)
                    }
                } label: {
                    HStack(spacing: 7) {
                        statusDot(color: state.themeColor, radius: 4)
                        Text(state.isPlayable ? "lc.gameHome.readyToPlay".loc : state.title)
                            .font(.system(size: 12))
                            .foregroundColor(stateTextColor(state))
                    }
                    .frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .id(key(of: app))
            .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: focusKey)
        .frame(maxWidth: min(560, w - 48))
        .frame(maxWidth: .infinity)
    }

    /// 一张 16:9 卡（NX CoverView 常量）：圆角 = 卡宽 3%、白色 0.10 描边、
    /// 阴影黑 0.5（浅色 0.16，Phase 34）/ 半径卡宽 5% / y 卡宽 3%；左上状态点直径钳在
    /// 8…14（卡宽 3.4%）、内距 = 点径 0.9。非聚焦卡缺数据包时左下加
    /// LC 自己的琥珀胶囊（LC 语义，NX 无此件）。
    /// transformScale：调用方此前靠外层 scaleEffect 呈现的缩放比（shelf
    /// 邻卡 0.8、聚焦与 carousel 恒 1）。按 cardW 成比例的部件（圆角 /
    /// 阴影）折进渲染尺寸后自动等值，但状态点（带钳制）与琥珀胶囊
    /// （固定字号 / 内距）不成比例，须按缩放比还原旧的有效尺寸；
    /// 默认 1 时与旧口径逐点一致。
    private func landscapeCard(app: LCAppModel, cardW: CGFloat, isFocused: Bool, transformScale: CGFloat = 1) -> some View {
        let state = gameState(app)
        let dot = max(8, min(14, (cardW / transformScale) * 0.034)) * transformScale
        return LCGameCoverView(app: app, darkModeIcon: darkModeIcon, refreshToken: refreshToken, beautifiedFallback: true)
            .frame(width: cardW, height: cardW * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: cardW * 0.03, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cardW * 0.03, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                statusDot(color: state.themeColor, radius: dot / 2)
                    .padding(dot * 0.9)
            }
            .overlay(alignment: .bottomLeading) {
                if !isFocused && !state.isPlayable {
                    HStack(spacing: 6 * transformScale) {
                        Circle()
                            .fill(state.themeColor)
                            .frame(width: 8 * transformScale, height: 8 * transformScale)
                        Text(state.title)
                            .font(.system(size: 10.5 * transformScale, weight: .bold))
                            .foregroundColor(state.themeColor)
                    }
                    .padding(.horizontal, 10 * transformScale)
                    .padding(.vertical, 5 * transformScale)
                    .background(Capsule().fill(capsuleBackground(state)))
                    .padding(10 * transformScale)
                }
            }
            // 投影（Phase 34）：深色沿用黑 0.5；浅色降到 0.16
            // ——为深底调的浓影压在浅色晕染上成一团灰黑（用户
            // 实测，中心卡下方尤甚），半径 / 偏移是几何、两模
            // 式共用不动。
            .shadow(color: .black.opacity(colorScheme == .light ? 0.16 : 0.5), radius: cardW * 0.05, y: cardW * 0.03)
    }

    /// 全部卡数（Phase 39 起；旧制 4 张起，NX carousel 的手势移植）：部署目标 15 用不了 NX 的
    /// ScrollView 吸附 API，改手势驱动同一套几何——place = 序号 - 偏移
    /// （Phase 31 起偏移以卡位存储，见 carouselOffsetCards 注释；点值
    /// 只在下方 position 按当帧 stride 现算），每卡按 FlowTilt 变形：
    /// 缩放 1 - |near|×0.22（near = place 钳 ±1）、内收 near×卡宽 0.28、
    /// 压暗 |near|×0.25；远处再多退 far×卡宽 0.55、压暗至多 0.1；
    /// zIndex = -|place|，近卡恒在上。构造范围：Phase 31–35 为
    /// |place| ≤ 2.8（更远的卡不建视图、不预载封面），Phase 36 起
    /// 取消构造门、全部卡恒在树中（单时钟刚性列车的前提，详见下
    /// 方 Phase 36 注释）。
    /// 轮播感（Phase 28）：回转角改由连续 place 驱动、不随 near 在 ±1
    /// 饱和——angle = -clamp(place, ±1.5)×30°（±1 卡 30°、|place|≥1.5
    /// 45° 封顶，coverflow 常见 30°–45° 区间），透视 0.35 → 0.45。旧口径
    /// -near×24° 在 ±1 外角度冻结，后段卡是一面平墙跟着平移、读作整排
    /// 被推走；新口径下每张卡的角度随 place 逐帧插值到 45°，整排像轮盘
    /// 转过去。位置公式（place×stride − 内收 − 远退）与缩放 / 压暗曲线
    /// 逐字未动，命中与落点不经几何反推、不受影响；中心卡 angle 0、
    /// scale 1.0 的终点不变。
    /// 边缘淡变（Phase 31）：构造边界曾是 |place| ≤ 2，卡滑过边界时以
    /// 满不透明 + 45° 倾角凭空出现 / 消失（用户实测「两侧最边缘的封面
    /// 出现和消失太生硬」）。改构造范围 2.8 并叠 opacity 淡变：|place|
    /// ≤ 2.0 恒 1，2.0 → 2.8 线性降到 0——卡在完全淡出后才越过构造边
    /// 界，出现 / 消失全程淡变、无一帧突变。取舍：原「不预载」是为长
    /// 列表省封面解析，当前库规模（个位数款）下多渲染 1–2 张的成本可
    /// 忽略，以淡变连续性优先；淡变只挂 opacity，位置 / 缩放 / 角度 /
    /// 压暗曲线一律不动。命中与 opacity 同步：淡到 ≤0.05 的卡禁用命
    /// 中（allowsHitTesting），免得隐形卡拦下点向其身后内容的点按 /
    /// 长按；ZStack 底的 contentShape + 拖动手势不受单卡命中开关影
    /// 响，拖动全程可用。
    ///
    /// 边缘淡变的动画作用域（Phase 36）：Phase 31–35 里 place 与其
    /// 全部派生量都在本函数 body 里按**终点**偏移算好，再以独立修
    /// 饰符挂上卡——落点 withAnimation 事务下 body 不逐帧重算，
    /// SwiftUI 是让每个可动画修饰符各自在自己的参数空间里、按同
    /// 一条事务曲线在旧值与新值之间独立插值。位置 / 缩放 / 压暗 /
    /// opacity 是 place 的四种不同非线性函数（位置带 near 钳制与
    /// far 远退、缩放与压暗在 |near| = 1 饱和、opacity 在 |place|
    /// 2.0 处折点），独立插值下同一帧各参数反推的 place 互不相
    /// 等：如一张卡 place 2.4 → 0，进度 0.5 时位置反推 place ≈
    /// 1.2（按淡变函数本应实心 1），opacity 却只插到 0.5 + 0.5×
    /// 0.5 = 0.75——近中心处仍半透明、透出后面的卡（用户录屏
    /// f009：黑魂字样透过正面的丝之歌卡）；邻卡则位置已到、压暗
    /// 与 opacity 还在半途，整体发虚发白（f020）。目标卡「先显
    /// 示」同理：标题 / 焦点在过中点时已切（Phase 27 语义），缩
    /// 放与压暗又在 place 意义上先饱和到位，唯独 opacity 的端点
    /// 横跨淡变带、插值最晚收敛——卡看着大而正、却半透明。弹簧
    /// 时代（Phase 30）同病轻得多：总时长只约 0.38–0.45s，且指
    /// 数剖面把绝大部分行程压在起步约 0.1s 内走完，长尾爬行的
    /// ≲0.3 卡区间里各卡 |place| 已 ≤ 2、opacity 两端恒 1，半
    /// 透明只剩起步一闪；Phase 35 把多卡时长拉到最长 0.85s 且
    /// 中段近匀速，每张卡以稳定速度横穿整个淡变带与参数失配
    /// 区，失同步窗口近乎翻倍——用户实测「重影比上个版本更严
    /// 重」与此逐项吻合。短甩不受影响：拖动跟随的偏移写不带动
    /// 画事务、body 按当帧偏移同步求值；一卡段落点两端 |place|
    /// ≤ 2、opacity 恒 1 → 1，无从失同步（录屏 f037–042 的 2 卡
    /// 慢甩全程实心，慢在其行程主要走拖动段、落点动画只剩短
    /// 尾）。
    ///
    /// 第二个结构病在构造窗口：|place| ≤ 2.8 的门在落点事务开始
    /// 的那一遍 body 里按**终点**偏移求值——长甩时目标卡在拖动
    /// 段还在窗外（place 4–5），松手那一遍才插入视图树；新插入
    /// 的卡没有可插值的旧呈现值，只能直接落在终点（或自带一轮
    /// 插入动画），而窗内的卡还在途中：这就是「目标卡先固定、
    /// 后面的才滚过去」的字面机制，与属性失同步叠加成重影。窗
    /// 外的卡同理在松手帧凭空消失、不滚出。
    ///
    /// 修法（验收口径：快速与慢速同构——整列是单时钟刚性列车，
    /// 慢拖跟随段是基准形态，落点段与之同构）：
    /// ①取消构造门：全部卡恒在树中（库规模个位数，Phase 31 扩
    /// 窗到 2.8 时已论证多渲染 1–2 张成本可忽略；「全程在树」自
    /// 此是刚性的正确性前提而非性能取舍），飞行全程无插入 / 移
    /// 除，入场淡变只剩 opacity 这一条 place 纯函数；
    /// ②全部 place 派生变换收进 LCDeckCardTransform（Animatable
    /// 修饰符，animatableData = **偏移本人**——全列共享的同一
    /// 个标量，序号只是固定入参）：事务动画只插值这一个量，修
    /// 饰符 body 逐帧以插值后的偏移现算 place 与位置 / 角度 /
    /// 缩放 / 压暗 / zIndex / opacity / 命中——任何卡没有自己的
    /// 时钟，任意帧所有属性都是同一偏移的纯函数，opacity ≡ 淡
    /// 变函数（当帧 place）严格成立、|place| ≤ 2 逐帧恒实心。
    /// 各公式与修饰符相对次序逐字未动；落点曲线（Phase 35，
    /// 它决定列车的速度剖面）/ 正面门 / 卡位偏移 / 跟随投影橡
    /// 皮筋全保留——曲线之外再无任何属性另行插值。（Phase 37
    /// 后高速多卡松手的发布段改走自由动量积分：偏移逐帧直写、
    /// 连事务都没有，本修饰符的单时钟结论只更强，见
    /// startDeckMomentum。）
    ///
    /// Phase 39（小库统一）：≤3 张旧走 landscapeShelf（NX shelf 的
    /// 静态排列：一字排开居中、聚焦卡原大、邻卡渲染尺寸 0.8 +
    /// brightness -0.22、无存储偏移、位置每帧按 chosen 现算，横滑
    /// 过门槛一手势切一卡，点按裁决用时间制停稳 deckSettled 且正
    /// 面门恒真豁免）——观感与行为与本列车是两套（用户实测「横屏
    /// 只有 3 个封面时似乎还是旧排列方式」）。本轮起分流取消：1–3
    /// 张与 4 张起逐字同一条路径（同一份偏移状态、LCDeckCardTransform
    /// 的 place 派生式、同一拖动 / 落点 / 动量 / 点击裁决），卡尺寸
    /// 统一取 metrics.cover——shelf 的按卡数封顶（卡宽 ≤ 安全区宽 /
    /// (1 + (n−1)×0.8)）随 shelf 退役：那是「整排全显」旧排列的尺寸
    /// 口径，列车形态下邻卡本就以 place ±1 的倾斜位居于中心两侧，
    /// 与大库中段逐点同构，无需为小库另设尺寸。行为推论均由现行
    /// 公式直接得出、无小库特判：1 张时 place 恒 0、居中陈列，拖
    /// 动只有两端橡皮筋与松手回弹、点按即启动；2 张时落点行程
    /// ≤ 1 卡，动量门槛（投影行程 > 1 卡）天然不达、恒走低速落点
    /// 路径；3 张时端到端甩动行程可达 2 卡、初速过 1.2 卡/s 即可
    /// 进动量。回库落位 / 顺序冻结 / 正面门自此对小库同样成立
    /// （shelf 时代靠每帧现算位置规避回库错位，小库进列车后由
    /// Phase 30 冻结序 + Phase 31 卡位口径 + snap 安全网覆盖，
    /// 与大库同一套保证）。landscapeShelf 与仅它使用的
    /// deckSettled、metrics.contentWidth 一并删除；deckLastSwitchAt
    /// 随 deckSettled 失去最后一个读者，其状态与 setFocusFromDeck
    /// 内的写入一并移除（setFocusFromDeck 其余行为不变）。
    private func landscapeCarousel(list: [LCAppModel], metrics: LCLandscapeMetrics, size: CGSize) -> some View {
        let w = size.width
        let cover = metrics.cover
        let stride = metrics.stride
        let areaH = metrics.cardAreaHeight
        let focusIdx = landscapeFocusIndex(in: list)
        return ZStack {
            ForEach(list.indices, id: \.self) { idx in
                let app = list[idx]
                // Phase 36：不再按 |place| ≤ 2.8 门控构造（理由见函
                // 数头 Phase 36 注释）——全部卡恒在树中，place 的全
                // 部派生变换收进 LCDeckCardTransform（animatableData
                // = 全列共享的偏移本人），单时钟刚性列车。
                landscapeCard(app: app, cardW: cover, isFocused: idx == focusIdx)
                    // Phase 15 审计：命中走 position 布局落位（布局
                    // 帧即渲染帧、命中形状与渲染形状一致），无变换
                    // 后命中错位的误启动病；菜单原挂在旋转 / 缩放
                    // 之后的视图上、长按预览按布局帧取快照会被变
                    // 换推偏裁切，同源改挂到未变换的卡本体上——
                    // 系统快照源即卡本身，变换全部留在菜单之外。
                    .contextMenu {
                        gameContextMenu(for: app)
                    }
                    .modifier(LCDeckCardTransform(
                        index: idx,
                        offset: carouselOffsetCards,
                        width: w,
                        stride: stride,
                        cover: cover,
                        areaH: areaH,
                        reduceMotion: reduceMotion,
                        onTap: { carouselTap(app: app, index: idx, list: list) }
                    ))
            }
        }
        .frame(width: w, height: areaH)
        .contentShape(Rectangle())
        .gesture(carouselDrag(list: list, stride: stride))
        .onAppear {
            snapCarouselToFocus(list: list)
        }
        .onChange(of: focusKey) { _ in
            syncCarouselOffset(list: list)
        }
        // 顺序签名（Phase 28）：库重排 / 增删令聚焦卡在 list 里的序号
        // 变化而 focusKey 不变时，focusKey 的 onChange 不会火——偏移的
        // 同步挂到顺序本身上，见 snapCarouselToFocus 注释。
        .onChange(of: list.map { key(of: $0) }) { _ in
            snapCarouselToFocus(list: list)
        }
        // 宽度变化（Phase 31）：卡位偏移与宽无关、静止 place 恒精确，
        // 此 snap 已退化为纯安全网（兜焦点在旋转同帧被外部改动的极端
        // 时序），保留不删。
        .onChange(of: w) { _ in
            snapCarouselToFocus(list: list)
        }
        // Phase 37：牌组离屏停动量驱动（DisplayLink 不跨屏存活）。
        .onDisappear {
            stopDeckMomentum()
        }
    }

    /// 横屏牌组点击的唯一裁决点（Phase 27，取代 Phase 16 的快照裁决）：
    /// 滑动切换走既有手势、不经此；点后面的封面只切换；只有点已经
    /// 停稳在前面的封面才启动。
    ///
    /// Phase 16 的裁决读「手势开始时的聚焦位快照」：快照由一个与点击
    /// 同时识别的 DragGesture(minimumDistance: 0)（deckTouchWatcher）
    /// 在 onChanged 里写，而纯点按（落下即抬起、几乎无位移）时该回调
    /// 不保证赶在点击识别完成之前——观察手势漏写时，本次点按拿的是
    /// 上一触摸序列留下的旧快照裁决（快照从不失效、序列结束也不清；
    /// 旧注释写的「快照缺失时退回现读」只在全程第一次点按成立）。
    /// 旧值恰等于被点卡的典型路径：先前聚焦在该卡上、从它滑走（滑
    /// 动开始时快照 = 该卡），牌组停稳（settled 已翻 true）后再点它
    /// 想切回来——idx 与旧快照相等 → 误入启动分支。偶发与否取决于
    /// 两个手势识别器的回调次序，与实测「大多数时候先切换、偶发直
    /// 接启动」吻合；同一观察手势还独占消费标记的复位，漏写时下一
    /// 次点按会被整口吞掉（点了没反应）。
    ///
    /// 本裁决不再依赖任何快照，判定流程可自证：一次点按内，能改聚
    /// 焦的写入口只有拖动落点提交（点按不构成拖动，不会触发）与另
    /// 一次点按的 focusAction（在本裁决内、裁决之后执行），故裁决时
    /// 现读的聚焦位恒等于触摸开始时的聚焦位——「点未聚焦卡」在结
    /// 构上不可能进入启动分支，与手势识别次序无关。被点卡 = 现聚焦
    /// 卡时再叠停稳门（入参 isSettled，裁决时现读）。同一触摸被多
    /// 个识别器重复投递的防御改用时间窗：0.4s 内只裁决一次（同触
    /// 摸的重复识别相隔仅数毫秒；此窗与停稳窗同量级，窗内连点本
    /// 就被 settled 拦在启动之外，吞掉不改变结果）。
    ///
    /// Phase 31 正面门（结构兜底）：启动分支在「聚焦卡 + 已停稳」之
    /// 外再要求被点卡当前 |place| ≤ 0.02（入参 isFrontal，carousel
    /// 在卡位口径下现算——静止值是整数序号，判定精确）。聚焦卡停
    /// 在不正位置时（Phase 31 前的点值污染定格、或任何未来写出偏
    /// 值的路径），点它改走 focusAction 精确落位到该卡正面、不启
    /// 动：点一下必先归正，绝不带着倾角误启。Phase 39 前 shelf
    /// 路径不传此参（其位置每帧现算、被点卡即聚焦卡时 place 恒
    /// 为 0、正面门恒真）；小库统一后全路径经 carouselTap 传入现
    /// 算 place，默认值只剩签名兼容意义。
    private func deckTap(app: LCAppModel, index idx: Int, list: [LCAppModel], isSettled: Bool, isFrontal: Bool = true, focusAction: () -> Void) {
        if Date().timeIntervalSince(deckTapAdjudicatedAt) < 0.4 {
            return
        }
        deckTapAdjudicatedAt = Date()
        if idx != landscapeFocusIndex(in: list) {
            focusAction()
        } else if isSettled && isFrontal {
            onRun(app)
        } else if !isFrontal {
            focusAction()
        }
    }

    /// 点邻卡只居中、点已聚焦卡在轮播停稳且正面时才启动——裁决统一
    /// 走 deckTap（裁决时现读聚焦位 + 时间窗去重 + Phase 31 正面
    /// 门），此处只提供 carousel 的切换动作（滚动到该卡 + 落聚焦 +
    /// settled 计时；滚动动画按行程取时长，见 deckSettleAnimation）。
    private func carouselTap(app: LCAppModel, index idx: Int, list: [LCAppModel]) {
        // Phase 37：动量滚动中点卡先停驱动（点按本身即抓停意图），
        // 随后的裁决 / 落位都基于停住的当帧偏移。
        stopDeckMomentum()
        let place = CGFloat(idx) - carouselOffsetCards
        deckTap(app: app, index: idx, list: list, isSettled: carouselSettled && !carouselDragging, isFrontal: abs(place) <= 0.02) {
            beginCarouselScroll()
            withAnimation(deckSettleAnimation(distanceCards: CGFloat(idx) - carouselOffsetCards)) {
                carouselOffsetCards = CGFloat(idx)
            }
            setFocusFromDeck(app)
            finishCarouselScroll(epoch: carouselScrollEpoch)
        }
    }

    private func carouselDrag(list: [LCAppModel], stride: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if !carouselDragging {
                    carouselDragging = true
                    // Phase 37 抓停接管：动量滚动中落指先停驱动，拖
                    // 动起点就是当帧偏移（积分直接写偏移状态），无
                    // 缝接管、不跳位。
                    stopDeckMomentum()
                    carouselDragStartCards = carouselOffsetCards
                    carouselDragSamples = [(time: value.time, logical: carouselOffsetCards)]
                    beginCarouselScroll()
                }
                // Phase 27：逻辑偏移 = 手指原始位移的无钳制换算，落点
                // 投影按它算；显示偏移全程 1:1 跟随逻辑偏移、只在两端
                // 橡皮筋化（越界部分 ×0.35），不再硬停在边界。
                // Phase 31：手势的点位移在本边界除以 stride 换算成卡
                // 位再进出存储量（橡皮筋是线性缩放、与单位无关，系数
                // 逐字未动），内部全程卡位。
                let logical = carouselDragStartCards - value.translation.width / stride
                carouselDragLogicalCards = logical
                // Phase 38：末段采样只留末 120ms（估末速的窗口），
                // 逻辑偏移是未钳制口径、与落点投影同源。
                carouselDragSamples.append((time: value.time, logical: logical))
                carouselDragSamples.removeAll { value.time.timeIntervalSince($0.time) > 0.12 }
                let maxCards = CGFloat(list.count - 1)
                if logical < 0 {
                    carouselOffsetCards = logical * 0.35
                } else if logical > maxCards {
                    carouselOffsetCards = maxCards + (logical - maxCards) * 0.35
                } else {
                    carouselOffsetCards = logical
                }
                // Phase 27：焦点跟随最近卡——逻辑偏移过相邻中点即提
                // 交（取代 Phase 23 的「拖动中不提交」：连续滚动下标题 /
                // 信息区要跟着走）。setFocusFromDeck 只写 focusKey；
                // syncCarouselOffset 在拖动中被 carouselDragging 守卫
                // 挡下、不反抢偏移；背景 / 名牌的淡化由信息区自己的
                // 动画承接，逐步换不闪。
                let nearest = min(list.count - 1, max(0, Int(logical.rounded())))
                if nearest != landscapeFocusIndex(in: list) {
                    setFocusFromDeck(list[nearest])
                }
            }
            .onEnded { value in
                carouselDragging = false
                // Phase 27 落点：逻辑偏移 + 速度投影（velocity 换成朝
                // 后一张卡为正的卡位/ms，投影时长 220ms，公式见
                // cardSnap）——快甩可越过多张、慢拖落最近卡，不再有
                // NX CardSnap 的一卡钳制。停稳时长按行程放大（见
                // deckSettleAnimation；松手速度一并传入，多卡段
                // Phase 35 起走匀速主导的贝塞尔曲线、一卡段原式未
                // 动）。落点
                // 卡的聚焦在这一帧补正提
                // 交（拖动中已跟随到最近卡，落点因速度投影更远时在
                // 此对齐；Phase 23 的「背景 / 名牌淡化与吸附动画同帧
                // 起跑」时序不变）。settled 仍由 finishCarouselScroll
                // 在 +0.32 翻（与点邻卡 / 外部同步同一机制），
                // Phase 27 的点击裁决口径不动。
                let velocity = -value.velocity.width / 1000 / stride
                let card = Self.cardSnap(
                    logicalCards: carouselDragLogicalCards,
                    velocityCards: velocity,
                    count: list.count
                )
                // Phase 37：高速多卡松手改走 Cover Flow 式自由动量
                // （见 startDeckMomentum）——投影目标只用在门槛判定
                // 上（行程 > 1 卡、|初速| 过吸附阈值、偏移在界内），
                // 进动量后不再有「目标」，行程由初速与衰减率决定；
                // 不满足门槛的低速 / 短行程松手逐字走下面的旧路径
                // （投影定目标 + deckSettleAnimation）。
                // Phase 38：门槛与动量初速改吃末段采样估出的真实末
                // 速（deckReleaseVelocityPerSecond）——value.velocity
                // 是全程阻尼平均，快甩时可低估末速近半，按它判门槛
                // 会把真高速甩动误判成短行程、按它喂驱动则行程与
                // 甩力脱钩。低速路径内部仍用上面的阻尼 velocity 算
                // card 与 settle 初速，逐字未动——采样估速只决定
                // 「进不进动量、进去带多快」，不改低速落点口径。
                let velocityPerSecond = deckReleaseVelocityPerSecond(
                    endTime: value.time,
                    endLogical: carouselDragLogicalCards,
                    fallbackPerSecond: velocity * 1000
                )
                let estimatedCard = Self.cardSnap(
                    logicalCards: carouselDragLogicalCards,
                    velocityCards: velocityPerSecond / 1000,
                    count: list.count
                )
                let estimatedProjectedDistance = CGFloat(estimatedCard) - carouselOffsetCards
                // 低速路径的 settle 行程仍按阻尼口径的 card 算（与
                // 分支内写入的目标同源），逐字保持 Phase 37 前口径。
                let projectedDistance = CGFloat(card) - carouselOffsetCards
                if !reduceMotion,
                   abs(velocityPerSecond) > Self.deckMomentumSnapVelocity,
                   abs(estimatedProjectedDistance) > 1,
                   carouselOffsetCards >= 0,
                   carouselOffsetCards <= CGFloat(list.count - 1) {
                    startDeckMomentum(velocityPerSecond: velocityPerSecond, list: list)
                } else {
                    withAnimation(deckSettleAnimation(distanceCards: projectedDistance, releaseVelocityCards: velocity)) {
                        carouselOffsetCards = CGFloat(card)
                    }
                    if list.indices.contains(card) {
                        setFocusFromDeck(list[card])
                    }
                    finishCarouselScroll(epoch: carouselScrollEpoch)
                }
            }
    }

    /// 松手末速估计（Phase 38）：取拖动末 120ms 采样窗口内最早的
    /// 样本与松手点求斜率（卡/s，朝后一张卡为正、与 value.velocity
    /// 换算后的 velocity 同号同口径）。审计结论：速度链各站单位无
    /// 误——value.velocity 是 pt/s、除以 stride（现行度量下约
    /// 330pt）得卡/s；问题在信号本身：DragGesture 的 velocity 是
    /// 全手势的阻尼平均，快速甩动的末速集中在最后约 100ms，平均
    /// 值可低估近半（硬甩时真末速约 4000pt/s ≈ 12 卡/s，阻尼值常
    /// 只报约 2000pt/s ≈ 6 卡/s）。采样斜率是同一手势的直接测量，
    /// 不引入增益：窗口跨度不足 50ms（极短拖动，样本太少）、或斜
    /// 率与阻尼值反向（末段已回拉）时回退阻尼值；斜率绝对值钳 60
    /// 卡/s 仅防采样噪声尖峰，与行程上限无关（行程仍只由初速与
    /// λ 决定）。手指末段停顿再松开时，窗口内逻辑偏移不再变化、
    /// 斜率自然趋零，不会把停顿前的速度带进动量。
    private func deckReleaseVelocityPerSecond(endTime: Date, endLogical: CGFloat, fallbackPerSecond: CGFloat) -> CGFloat {
        let window = carouselDragSamples.filter { endTime.timeIntervalSince($0.time) <= 0.12 }
        guard let first = window.first else {
            return fallbackPerSecond
        }
        let span = endTime.timeIntervalSince(first.time)
        guard span >= 0.05 else {
            return fallbackPerSecond
        }
        let slope = (endLogical - first.logical) / CGFloat(span)
        if fallbackPerSecond != 0, slope != 0, (slope > 0) != (fallbackPerSecond > 0) {
            return fallbackPerSecond
        }
        return min(60, max(-60, slope))
    }

    /// 偏移按现行焦点无动画落位（Phase 28）：把 carouselOffsetCards
    /// 在当前 list 下重算为聚焦序号（Phase 31 起卡位口径，旧口径为
    /// 序号 × stride），关动画直接落位，并作废在途的 settle 计时
    /// （epoch +1、settled 直接置真）。
    ///
    /// 根因（回库错位，一直存在）：carouselOffset 是一份以「序号 ×
    /// stride」计价的独立存储量，序号的含义随 orderedApps 的顺序而
    /// 变，但旧同步点只有三处——carousel 自己的 onAppear（触发时父级
    /// onAppear 尚未刷新 libraryOrderKeys、读到的还是旧序，写回的是
    /// 同一个旧值）、onChange(focusKey)（动画跟随）、onChange(宽度)。
    /// 回库时 root onAppear 按最近游玩重排 libraryOrderKeys，聚焦卡
    /// 在新序里的序号变了，focusKey 却没变：没有任何一处再写偏移，
    /// 几何中心停在 list[旧序号]，而标题 / 计数 / 信息区是 focusKey
    /// 的纯推导、逐帧正确——于是中心卡与标题对不上（中心丝之歌、
    /// 标题 Hades II 之类），且聚焦卡本人停在 place ≠ 0 处不达正面
    /// 态，非要用户再点一下（走 carouselTap 现写偏移）才对齐；偶尔
    /// 「自己再滑一下」是迟到的 focusKey 变化触发了 syncCarouselOffset
    /// 的动画跟随。shelf（≤3 张）的位置每帧由 chosen 现算、无这份存
    /// 储量，故只有 carousel 中招。
    ///
    /// Phase 30 复盘（#68 的签名网为何在真机回库路径上没拦住，代码
    /// 查实）：回库不是存活视图上的一次重排，而是**进程重启后整棵
    /// 视图树重建**（LCAppListView 的回库淡入遮罩注释即「盖住进程
    /// 重启接缝」、returnFade 初值在 init 里读标记）。重建后整个重
    /// 排发生在出现级联之内：①牌组是深层子视图，onAppear 自内向
    /// 外送达，先于 root onAppear 写 libraryOrderKeys——本函数那时
    /// 读到的是快照为空的 orderedApps（退回 sharedAppSortManager
    /// 的原始入参序），把偏移写成聚焦卡在**旧序**里的序号；②root
    /// onAppear 随后写新序 + ensureFocus 定焦点，但这两个写都落在
    /// 牌组的 onChange 修饰符**首次提交基线之前**——onChange 只对
    /// 基线确立之后的变化触发，级联内完成的变序与焦点赋值被基线
    /// 吸收，顺序签名与 focusKey 两条 onChange 都不会火；③此后再
    /// 无任何写偏移的路径，几何永久停在旧序号，而信息区是纯推导
    /// 逐帧正确。对照组：横竖旋转时牌组子树在存活视图上重建，本
    /// 函数的 onAppear 读到的是早已提交的现行序，落位正确、可自
    /// 愈——分界正在「重排与重建是否同级联」。Phase 28 的分析默认
    /// 了「重排是存活视图上的事后变化」，对装 / 卸成立、对回库不
    /// 成立。Phase 30 的解法是取消回库重排本身（快照冻结 + 持久
    /// 化，见 maintainLibraryOrder）：级联里不再有变序，本函数的
    /// onAppear 读到的第一份 list 即冻结序，落位天然正确；焦点跟
    /// 随走 focusedApp 缺省推导（最近启动款），其序号全程不变，
    /// syncCarouselOffset 的动画跟随路径（存活期内改 focusKey，
    /// 基线早已确立）不受级联问题影响、逐字未动。
    ///
    /// 本函数的现行职责（Phase 30）：onAppear / 宽度变化时按现行
    /// 冻结序落位；顺序签名 onChange 保留作存活期安全网——装 / 卸
    /// 令 maintainLibraryOrder 收敛快照时，变序是基线确立之后的事
    /// 后变化，签名网正常触发、与重算落在同一次状态更新里。拖动
    /// 中不干预（手势的 list 是手势开始时的快照）。落位后 settled
    /// 即真：回库看到的聚焦卡可直接点启动，与「已停稳的聚焦卡」
    /// 裁决口径一致。
    ///
    /// Phase 31 复盘（#70 后仍间歇不正，录屏实证）：冻结序生效、信
    /// 息与中心卡身份已一致，但聚焦卡停在 place 偏 0.2–0.3 处（倾
    /// 角、压暗肉眼可见）、settled 为真，点它直接启动不归正。污染
    /// 机理（推断，代码侧可指认的写路径只有两条）：点值模型下本函
    /// 数与 syncCarouselOffset 的 target 都是「序号 × 当帧 stride」
    /// ——回库重建的出现级联里 metrics 宽度可能仍是过渡值，任一条
    /// 路径用过渡 stride 算出的点值一旦写下，最终 stride 下 place
    /// ≠ 0 即成终局：此后 settled 恒真、再无写偏移路径，snap 的
    /// 相等守卫也只会在「序号 × 某帧 stride」之间反复对不齐而无
    /// 法自证已正。卡位改制整类消除：target 是整数序号本身，所有
    /// 写入方写的都是与布局无关的精确值，place = 序号 − offset
    /// 在任何宽度下恒精确；本函数的相等守卫与 sync 的死区也随之
    /// 改卡位口径（sync 死区 0.001 卡 ≈ 亚点级，仅防浮点噪声触发
    /// 空动画）。纵深第二道是 deckTap 正面门：万一将来再有偏值，
    /// 点聚焦卡先归正不误启。
    private func snapCarouselToFocus(list: [LCAppModel]) {
        guard !carouselDragging else {
            return
        }
        // Phase 37：无动画落位前停动量，免驱动在落位后继续写偏移。
        stopDeckMomentum()
        carouselScrollEpoch += 1
        carouselSettled = true
        let target = CGFloat(landscapeFocusIndex(in: list))
        guard carouselOffsetCards != target else {
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            carouselOffsetCards = target
        }
    }

    /// 聚焦被外部改动（列表增删、竖屏切歌后转横屏）时把偏移跟上；
    /// 拖动中不干预（手势优先，与 NX 同义）。
    private func syncCarouselOffset(list: [LCAppModel]) {
        // Phase 37：动量滚动中焦点由积分的过中点跟随推进（本函数的
        // 触发源正是 focusKey 变化），同步动画不得与积分抢偏移。
        guard !carouselDragging, !carouselMomentumActive else {
            return
        }
        let target = CGFloat(landscapeFocusIndex(in: list))
        guard abs(carouselOffsetCards - target) > 0.001 else {
            return
        }
        beginCarouselScroll()
        withAnimation(deckSettleAnimation(distanceCards: target - carouselOffsetCards)) {
            carouselOffsetCards = target
        }
        finishCarouselScroll(epoch: carouselScrollEpoch)
    }

    /// 动量摩擦衰减率 λ（Phase 37 立、Phase 38 复调）：速度
    /// v(t) = v₀·e^(−λt)，总行程 D = v₀/λ，只由初速与 λ 决定、
    /// 不设人为上限（到界停界是唯一截断）。Phase 37 的 λ = 5.0 是
    /// 按「D ≈ 旧投影 0.22·v₀」标的，但那是拿阻尼平均速度标的：
    /// 采样估速后硬甩真末速约 12 卡/s，λ = 5.0 也只给 2.4 卡行
    /// 程——与用户「甩得很快也滚不到」吻合。λ = 2.6 复调后行程系
    /// 数 0.385·v₀：2 卡行程对应 v₀ = 5.2 卡/s（约 1700pt/s，寻
    /// 常一甩）、5 卡对应 v₀ = 13 卡/s（约 4300pt/s，真硬甩），
    /// 甩力与行程恢复比例、最硬的甩加拖动段行程可达列尾。
    private static let deckMomentumDecay: CGFloat = 2.6
    /// 动量收尾阈值（卡/s）：速度衰减到此值即结束积分、用现行短
    /// 曲线把剩余分数卡（≤0.5 卡）吸附到最近卡。Phase 38 由 0.8
    /// 提到 1.2：λ 变小后低速尾段拉长，0.8 时最后约 0.7 卡要爬
    /// 约 0.44s；1.2 时吸附接管点提前到剩余约 0.46 卡，尾段仍是
    /// 约 3 卡/s 以下逐张停出的节奏、又不拖。
    private static let deckMomentumSnapVelocity: CGFloat = 1.2

    /// Cover Flow 式自由动量（Phase 37，取代 Phase 35 在高速多卡
    /// 松手路径上的匀速定时曲线）：用户以 iPhone 4 年代音乐播放
    /// 器 Cover Flow 为参照定模型——松手后不预定目标卡，偏移以松
    /// 手速度为初速、在摩擦下连续衰减滚动（速度指数衰减，类
    /// UIScrollView deceleration），整列卡随速度流过中心、尾段自
    /// 然变慢逐张停出；速度衰减到 deckMomentumSnapVelocity 后，
    /// 才用现行短曲线（deckSettleAnimation 的 ≤1 卡原式）把剩余
    /// 分数卡（≤0.5 卡）吸附到最近卡。220ms 投影定目标只保留在
    /// 低速 / 短行程松手路径（onEnded 门槛外，逐字旧式）。
    ///
    /// 测算（Phase 38 复调后，λ = 2.6、阈值 1.2，按总行程反推
    /// 初速；吸附段 = deckSettleAnimation 的 ≤1 卡原式 0.3s）：
    /// 行程 2 卡（v₀ = 5.2 卡/s）：动量段 0.56s 走 1.54 卡（逐
    /// 卡 0.27 / 0.30s），吸附 0.46 卡，总约 0.86s；行程 3 卡
    /// （v₀ = 7.8）：动量段 0.72s 走 2.54 卡（逐卡 0.16 / 0.27
    /// / 0.30s），总约 1.02s；行程 5 卡（v₀ = 13）：动量段
    /// 0.92s 走 4.54 卡（逐卡 0.09 / 0.11 / 0.16 / 0.27 /
    /// 0.30s），总约 1.22s。逐卡通过速率 = 当帧速度：起步疾
    /// 过、尾段约 1.2–3 卡/s 逐张停出——与 #76 匀速到底的剖面
    /// 正相反，是本模型的目的。
    ///
    /// 刚性（承 Phase 36 单时钟）：积分逐帧解析求解（Δ偏移 =
    /// v/λ·(1 − e^(−λΔt))，帧率无关）并**直接写偏移状态本身**、
    /// 不挂任何动画事务——LCDeckCardTransform 逐帧按当帧偏移同
    /// 步渲染，动量段与慢拖跟随同构（都是偏移的逐写跳变）。抓停
    /// 接管：新触摸 / 点卡 / 外部落位先 stopDeckMomentum，拖动起
    /// 点读到的就是当帧偏移，无缝接管。到界：积分候选值越界即
    /// 钳到界值并结束动量、在界上吸附（停界语义），不穿界、不
    /// 弹回整列；橡皮筋仍只是拖动跟随段的事。焦点语义不变：积
    /// 分逐帧按最近卡过中点提交（setFocusFromDeck），sync 的动
    /// 画跟随在动量期被 carouselMomentumActive 守卫挡下。
    ///
    /// Phase 38 复盘（#77 装机验收两缺陷同根）：用户报「有时停在
    /// 过渡位、无正面卡且标题与画面对不上」+「滚得慢、甩得再快
    /// 也只到第三张」。查实根因不在积分与所有权：驱动对象是
    /// @State 持有、稳过焦点提交的重渲染；坏在
    /// LCDeckMomentumDriver.start() 开头先调 stop()，而 stop()
    /// 按断环约定把 onTick 清空——startDeckMomentum 偏是先赋
    /// onTick 再 start()，回调当场被自己人抹掉，DisplayLink 空
    /// 转、tick 永不触发。后果与两缺陷逐项吻合：越过门槛的硬甩
    /// 松手后偏移冻结在分数位、吸附永不发起（停过渡位；焦点停
    /// 在拖动末段的最近卡、画面停在分数位，静止后无人再对齐，
    /// 即标题 / 计数与中心对不上）；全程只有手指拖动段在动、松
    /// 手续滚恒为零，总行程 = 指触距离（约两卡），即「慢且只到
    /// 第三张」。「有时」是门槛依赖：慢甩不进动量、走旧路径正
    /// 常落位，只有硬甩进这条死路。修法：start() 只废旧链不清
    /// onTick（见驱动类注释）；stop() 的断环清空保留，只由
    /// stopDeckMomentum 走。终局必然性复核：动量的全部出口都有
    /// 收尾方——衰减 / 到界走 endDeckMomentum（吸附 + 焦点无条
    /// 件对齐到最终静止序号）、点卡走 carouselTap 的落位、落指
    /// 走拖动 onEnded、snap / 离屏先停驱动且 snap 自带整数落
    /// 位；syncCarouselOffset 的动画跟随在动量期被守卫挡下、挡
    /// 的只是抢写，吸附发起不在它那条路上，不会被挡掉。
    private func startDeckMomentum(velocityPerSecond: CGFloat, list: [LCAppModel]) {
        beginCarouselScroll()
        carouselMomentumActive = true
        deckMomentumVelocity = velocityPerSecond
        deckMomentumDriver.onTick = { [self] dt in
            deckMomentumTick(dt: dt, list: list)
        }
        deckMomentumDriver.start()
    }

    private func deckMomentumTick(dt: CGFloat, list: [LCAppModel]) {
        let decay = CGFloat(exp(Double(-Self.deckMomentumDecay * dt)))
        let velocity = deckMomentumVelocity
        let travel = velocity / Self.deckMomentumDecay * (1 - decay)
        deckMomentumVelocity = velocity * decay
        var next = carouselOffsetCards + travel
        let maxCards = CGFloat(list.count - 1)
        var hitBound = false
        if next <= 0, velocity < 0 {
            next = 0
            hitBound = true
        } else if next >= maxCards, velocity > 0 {
            next = maxCards
            hitBound = true
        }
        carouselOffsetCards = next
        // 焦点过中点提交（与拖动跟随同一口径）：积分跨过相邻中
        // 点即把最近卡提交为焦点，标题 / 信息区随动。
        let nearest = min(list.count - 1, max(0, Int(next.rounded())))
        if nearest != landscapeFocusIndex(in: list) {
            setFocusFromDeck(list[nearest])
        }
        if hitBound {
            endDeckMomentum(list: list, snapTo: Int(next))
        } else if abs(deckMomentumVelocity) <= Self.deckMomentumSnapVelocity {
            endDeckMomentum(list: list, snapTo: nearest)
        }
    }

    /// 动量的唯一正常出口（Phase 37；Phase 38 明示其终局职责）：
    /// 衰减到阈值与到界都收束到这里——先停驱动，再无条件把偏移
    /// 吸附到整数卡位、焦点对齐到同一序号（最终静止序号），标
    /// 题 / 计数是焦点的纯推导、随之与画面一致，不依赖积分途中
    /// 的过中点提交是否恰好落对。本函数直调 withAnimation、不经
    /// syncCarouselOffset，动量守卫挡不到它。
    private func endDeckMomentum(list: [LCAppModel], snapTo card: Int) {
        stopDeckMomentum()
        withAnimation(deckSettleAnimation(distanceCards: CGFloat(card) - carouselOffsetCards)) {
            carouselOffsetCards = CGFloat(card)
        }
        if list.indices.contains(card) {
            setFocusFromDeck(list[card])
        }
        finishCarouselScroll(epoch: carouselScrollEpoch)
    }

    private func stopDeckMomentum() {
        deckMomentumDriver.stop()
        carouselMomentumActive = false
        deckMomentumVelocity = 0
    }

    private func beginCarouselScroll() {
        carouselScrollEpoch += 1
        carouselSettled = false
    }

    private func finishCarouselScroll(epoch: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            if carouselScrollEpoch == epoch {
                carouselSettled = true
            }
        }
    }
}

/// 横屏牌组单卡的全部 place 派生变换（Phase 36）：单时钟刚性列车
/// 的执行件。animatableData 是**偏移本人**（carouselOffsetCards，
/// 全列共享的同一个标量），序号只是固定入参——落点 / 同步事务动
/// 画只插值这一个量，SwiftUI 逐帧以插值后的偏移回调 body，place
/// 与位置 / 角度 / 缩放 / 压暗 / zIndex / opacity / 命中全部由当
/// 帧偏移现算：任何卡没有自己的动画时钟，opacity 严格等于当帧
/// place 的淡变函数（|place| ≤ 2 恒 1、2.0–2.8 线性淡出），与位
/// 置同帧、不被任何曲线另行插值。拖动跟随段的偏移写不带事务动
/// 画，animatableData 逐写跳变，与旧 body 同步求值逐点同构。
/// 公式与修饰符相对次序与 Phase 31–35 的内联链逐字一致（旋转 →
/// 缩放 → 压暗 → contentShape → 点按 → position → zIndex →
/// opacity → 命中开关）；contextMenu 仍挂在修饰符之外的未变换卡
/// 本体上（Phase 15 口径）。机制复盘见 landscapeCarousel 头注释。
private struct LCDeckCardTransform: ViewModifier, Animatable {
    let index: Int
    var offset: CGFloat
    let width: CGFloat
    let stride: CGFloat
    let cover: CGFloat
    let areaH: CGFloat
    let reduceMotion: Bool
    let onTap: () -> Void

    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    func body(content: Content) -> some View {
        let place = CGFloat(index) - offset
        let near = max(-1, min(1, place))
        let tilt = max(-1.5, min(1.5, place))
        let far = place > 1 ? place - 1 : place < -1 ? place + 1 : 0
        let edgeOpacity = min(1, max(0, (2.8 - Double(abs(place))) / 0.8))
        return content
            .rotation3DEffect(
                .degrees(reduceMotion ? 0 : -tilt * 30),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.45
            )
            .scaleEffect(1 - abs(near) * 0.22)
            .brightness(-abs(near) * 0.25 - min(abs(far), 1) * 0.1)
            .contentShape(Rectangle())
            .onTapGesture {
                onTap()
            }
            .position(
                x: width / 2 + place * stride - near * cover * 0.28 - far * cover * 0.55,
                y: areaH / 2
            )
            .zIndex(-Double(abs(place)))
            // 边缘淡变：只挂 opacity（与命中），公式与 Phase 31 逐
            // 字一致；同步性来自本修饰符的单时钟构造，见头注释。
            .opacity(edgeOpacity)
            .allowsHitTesting(edgeOpacity > 0.05)
    }
}

/// 动量积分的帧时钟（Phase 37）：CADisplayLink 逐帧回调 dt（秒，
/// 首帧只记时刻、dt 钳 0.05 防切后台回来的大步）。只负责供时，
/// 积分与状态写全在 LCGameHomeView 的 deckMomentumTick。stop 时
/// 一并清 onTick，断开驱动器 → 闭包 → 视图状态的引用环——但
/// start 绝不能顺手清：调用方的契约是先赋 onTick 再 start，
/// Phase 37 的 start 开头调 stop() 把刚赋值的回调当场抹掉、驱
/// 动恒空转（#77 验收两缺陷的根因，Phase 38 复盘在
/// startDeckMomentum 注释）。start 只废旧链、重置时刻。
private final class LCDeckMomentumDriver: NSObject {
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    var onTick: ((CGFloat) -> Void)?

    func start() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = 0
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        onTick = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        if lastTimestamp == 0 {
            lastTimestamp = link.timestamp
            return
        }
        let dt = CGFloat(link.timestamp - lastTimestamp)
        lastTimestamp = link.timestamp
        onTick?(min(dt, 0.05))
    }
}

// MARK: - 库顺序快照持久化

/// 库顺序快照落盘（Phase 30）：回库是进程重启、@State 不跨进程
/// 存活，冻结的次序只能落 UserDefaults。只存相对路径键序列；读
/// 回后仍经 orderedApps 与当前游戏集合求交，落盘值过期（装 / 卸
/// 后未及收敛）不会产生幽灵条目，收敛由 maintainLibraryOrder 负责。
enum LCGameLibraryOrderStore {
    private static let defaultsKey = "gc.libraryOrderSnapshot.v1"

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }

    static func save(_ keys: [String]) {
        UserDefaults.standard.set(keys, forKey: defaultsKey)
    }
}

// MARK: - 已连接手柄监听（手柄胶囊数据源）

/// 实时维护已连接手柄列表：初始读 GCController.controllers()，之后靠
/// 连接/断开通知刷新。启动一次无线发现，让已配对的无线手柄尽早枚举出来。
/// 主页手柄胶囊与手柄页（LCControllersView）共用同一实例。
final class LCControllerMonitor: ObservableObject {
    @Published var controllers: [GCController] = []

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        GCController.startWirelessControllerDiscovery {}
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func refresh() {
        controllers = GCController.controllers()
    }
}

// MARK: - 手柄导航输入（游戏库主页版）

enum LCGamepadNavDirection {
    case up, down, left, right
}

/// 主页手柄导航的输入层：给每个已连接的 extendedGamepad 装
/// valueChangedHandler，把十字键 / 左摇杆 / A 键翻译成「移动一格 /
/// 确认」的边沿事件，回调给 LCGameHomeView 驱动现成聚焦状态。
/// 只在主页激活（setActive(true)）时装 handler——主页让位（面板 /
/// 弹层打开、切后台、离开主页）即摘除，手柄断开即 hasController
/// 转假（上层据此收起提示条与焦点缩放）。全仓此前没有任何地方装
/// valueChangedHandler（手柄页的按键测试是轮询读值），不存在抢占。
/// 摇杆防抖：触发阈值 0.55、取主导轴向定格方向，回中到 0.3 以内
/// 才重新武装——推住不连发、推一次只动一格。十字键同样只认按下
/// 边沿；v1 不做十字键长按连发。
final class LCGamepadNavHandler: ObservableObject {
    @Published private(set) var hasController = false

    var onMove: ((LCGamepadNavDirection) -> Void)?
    var onConfirm: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var isActive = false
    private var pressedEdges: [String: Bool] = [:]
    private var stickDirection: LCGamepadNavDirection?

    init() {
        refreshConnection()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.refreshConnection()
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.refreshConnection()
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        detachHandlers()
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active {
            attachHandlers()
        } else {
            detachHandlers()
        }
    }

    private func refreshConnection() {
        hasController = GCController.controllers().contains { $0.extendedGamepad != nil }
        if isActive {
            attachHandlers()
        }
    }

    private func attachHandlers() {
        for controller in GCController.controllers() {
            guard let gamepad = controller.extendedGamepad else {
                continue
            }
            gamepad.valueChangedHandler = { [weak self] gamepad, _ in
                self?.handle(gamepad)
            }
        }
    }

    private func detachHandlers() {
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = nil
        }
        pressedEdges.removeAll()
        stickDirection = nil
    }

    private func handle(_ gamepad: GCExtendedGamepad) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.handle(gamepad)
            }
            return
        }
        guard isActive else {
            return
        }
        if edge("dpad.up", gamepad.dpad.up.isPressed) { onMove?(.up) }
        if edge("dpad.down", gamepad.dpad.down.isPressed) { onMove?(.down) }
        if edge("dpad.left", gamepad.dpad.left.isPressed) { onMove?(.left) }
        if edge("dpad.right", gamepad.dpad.right.isPressed) { onMove?(.right) }
        handleStick(gamepad.leftThumbstick)
        if edge("buttonA", gamepad.buttonA.isPressed) { onConfirm?() }
    }

    /// 按下边沿：只在 false → true 跳变时返回 true
    private func edge(_ name: String, _ pressed: Bool) -> Bool {
        let was = pressedEdges[name] ?? false
        pressedEdges[name] = pressed
        return pressed && !was
    }

    private func handleStick(_ stick: GCControllerDirectionPad) {
        let x = stick.xAxis.value
        let y = stick.yAxis.value
        let magnitude = max(abs(x), abs(y))
        if stickDirection != nil {
            // 已定格：等摇杆回到近中心才重新武装，推住不连发
            if magnitude < 0.3 {
                stickDirection = nil
            }
            return
        }
        guard magnitude > 0.55 else {
            return
        }
        let direction: LCGamepadNavDirection = abs(x) > abs(y)
            ? (x > 0 ? .right : .left)
            : (y > 0 ? .up : .down)
        stickDirection = direction
        onMove?(direction)
    }
}

// MARK: - 隐藏游戏页（＋菜单进入，鉴权后由 LCAppListView 推进来）

struct LCHiddenAppsView: View {
    @EnvironmentObject private var sharedModel: SharedModel
    @EnvironmentObject private var sharedAppSortManager: LCAppSortManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false

    var onRun: (LCAppModel) -> Void
    var onSettings: (LCAppModel) -> Void
    var onOpenDataFolder: (LCAppModel) -> Void
    var onImportDatapack: (LCAppModel) -> Void
    var onUninstall: (LCAppModel) -> Void
    var onUnhide: (LCAppModel) -> Void

    private var apps: [LCAppModel] {
        sharedAppSortManager.sortedHiddenApps
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("lc.gameHome.hiddenGamesDesc".loc)
                    .font(.footnote)
                    .foregroundColor(.gray)
                if apps.isEmpty {
                    Text("lc.gameHome.noHiddenGames".loc)
                        .foregroundColor(.gray)
                        .padding(.top, 24)
                }
                ForEach(apps, id: \.self) { app in
                    HStack(spacing: 12) {
                        iconView(for: app)
                            .frame(width: 46, height: 46)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.displayName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(LCGameTheme.sectionText)
                                .lineLimit(1)
                            Text("lc.gameHome.version %@".localizeWithFormat(app.version))
                                .font(.system(size: 12.5))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Button {
                            onUnhide(app)
                        } label: {
                            Text("lc.gameHome.unhide".loc)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(LCGameTheme.creamColor)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .overlay(Capsule().strokeBorder(LCGameTheme.chipBorderOnSurface, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(LCGameTheme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button {
                            onRun(app)
                        } label: {
                            Label("lc.gameHome.launch".loc, systemImage: "play.fill")
                        }
                        Button {
                            onSettings(app)
                        } label: {
                            Label("lc.gameHome.gameSettings".loc, systemImage: "gear")
                        }
                        if !app.uiIsShared, app.uiSelectedContainer != nil {
                            Button {
                                onOpenDataFolder(app)
                            } label: {
                                Label("lc.appBanner.openDataFolder".loc, systemImage: "folder")
                            }
                        }
                        if !app.uiIsShared {
                            Button {
                                onImportDatapack(app)
                            } label: {
                                Label("lc.gameHome.importDataPack".loc, systemImage: "square.and.arrow.down")
                            }
                            Button(role: .destructive) {
                                onUninstall(app)
                            } label: {
                                Label("lc.appBanner.uninstall".loc, systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(LCGameTheme.pageBackground.ignoresSafeArea())
        .navigationTitle("lc.gameHome.hiddenGames".loc)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 本页以 sheet 呈现（列表层包 NavigationView）：右上给显式关闭钮，
            // 也可以下滑关掉弹层。放 confirmationAction 位——与数据包导入页
            // 「取消」的 cancellationAction 正好成对，同为素 Button 无自加样式，
            // 新系统渲染成与标题同行的圆角胶囊钮。
            ToolbarItem(placement: .confirmationAction) {
                Button("lc.common.close".loc) {
                    dismiss()
                }
            }
        }
    }

    private func iconView(for app: LCAppModel) -> some View {
        Group {
            if let iconImage = app.appInfo.iconIsDarkIcon(darkModeIcon) {
                Image(uiImage: iconImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
            }
        }
    }
}
