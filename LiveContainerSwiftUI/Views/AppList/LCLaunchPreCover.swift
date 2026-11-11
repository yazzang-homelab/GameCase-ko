//
//  LCLaunchPreCover.swift
//  LiveContainerSwiftUI
//
//  宿主侧启动预盖层：掩盖进程交棒那一闪（与客体侧盖层 LCBootstrap 的
//  GCLaunchCover 配套）。
//
//  定案：点开始 → LCAppModel.runApp 派发 → LCSharedUtils
//  .launchToGuestApp 让系统自拉起本 App 并 SIGKILL 当前进程，新进程
//  LiveContainerMain → invokeAppMain 才安装客体侧盖层（挂客体场景、场
//  景激活时上盖）。SIGKILL 到客体场景激活之间，两个进程都没有可控窗
//  口，系统只能拿「宿主最后一帧」与「客体场景第一帧」做切换 morph：
//  入场快照未就绪时是纯黑帧 + 转圈，先就绪时是圆角卡片（内容即客体盖
//  层）浮在被虚化的库界面上。异常帧不在任何一段应用代码的窗口里，客
//  体侧盖层装得再早也盖不住。
//
//  修法：runApp 派发前在本文件把与客体侧盖层同图同构图的静态封面全
//  屏盖满宿主当前窗口，成为宿主进程的最后一帧；morph 两侧（宿主最后
//  一帧、客体盖层第一帧）同为满屏封面，一闪即被掩盖。静态态取客体盖
//  层的入场终态：封面 scale 1.14、罩/信息组满 alpha、无淡入。宿主经
//  UserDefaults 键 GCLaunchPreCoverPresented 告知新进程（与 selected
//  同一跨进程通道），新进程在 LiveContainerMain 跳 invokeAppMain 前
//  捕获并消费该标记（LCLaunchCoverCapturePreCoverFlag），客体盖层据
//  此跳过罩/信息组入场淡入，防止交接帧亮度下沉；封面缓推与光带、几
//  何/时机/撤盖公式均不变。
//
//  朝向定案：客体根 VC（dm front_ios.m）只声明 MaskLandscape、无
//  preferredInterfaceOrientationForPresentation 覆盖，宿主 Info.plist
//  首个横屏项为 LandscapeLeft，故从竖屏连接时客体场景恒落
//  LandscapeLeft——实测呈现为画布顺时针 90° 显示于竖屏（用户录屏帧
//  旋转 −90° 恰可摆正客体盖层）。故竖屏宿主窗口内，预盖层以横屏画
//  布（窗口高×宽）+ 旋转 +π/2 复现同一呈现；横屏宿主时客体场景在同
//  一物理横屏连接，画布即窗口 bounds 恒等呈现。
//
//  呈现时序：present 同步建窗上盖（深色底 + 标题 + 罩 + 光带立即可
//  见），封面图走库侧 LCGameLibraryInfo.bannerResolution 同链在后台
//  解析、到后原地换入，不阻塞派发（自拉起往返远长于一次解码，图几
//  乎总在进程交棒前到位）；五级全未命中时与客体侧同口径退图标虚化。
//  预盖层只活在宿主进程内：标准派发路径以 SIGKILL 收尾（completion
//  无条件自杀），永不滞留；派发抛错时由 runApp 的 catch 先撤层清标
//  记，报错弹层才可达用户。窗口不接收触摸，不拦截 runApp 任何流程。
//
//  打点：沿用 [launchcover] 前缀，宿主侧行以 [launchcover host] 写进
//  同一客体容器 Documents/log.txt（设置页日志查看器同一文件；客体启
//  动时会把旧 log.txt 轮转为 log.prev.txt，本文件的行随之前移，与客
//  体侧 install 行同一既有口径）。
//

import UIKit

final class LCLaunchPreCover {

    /// 与 LCBootstrap 的 LCLaunchCoverCapturePreCoverFlag 同一键，两侧勿改名
    static let presentedDefaultsKey = "GCLaunchPreCoverPresented"

    private static var window: UIWindow?
    private static var coverView: LCLaunchPreCoverView?
    private static var generation = 0
    private static var logContainerFolderName: String?

    // MARK: 呈现 / 撤除

    /// 在宿主当前窗口全屏呈现预盖层并置标记。必须在派发前调用；同步完成
    /// 建窗，封面解析在后台进行、不等待。
    static func present(app: LCAppModel, containerFolderName: String?) {
        if !Thread.isMainThread {
            DispatchQueue.main.sync { present(app: app, containerFolderName: containerFolderName) }
            return
        }
        teardownWindow()
        generation += 1
        let gen = generation
        logContainerFolderName = containerFolderName
        UserDefaults.standard.set(true, forKey: presentedDefaultsKey)

        guard let scene = activeWindowScene() else {
            appendLog("预盖层放弃：无可用窗口场景（标记已置，客体侧将按交接语境跳过淡入）")
            return
        }
        let bounds = scene.coordinateSpace.bounds
        let win = UIWindow(windowScene: scene)
        win.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 50) // 与客体侧盖层同层级口径
        win.backgroundColor = LCLaunchPreCoverView.backgroundInk
        win.isUserInteractionEnabled = false

        let container = UIView(frame: bounds)
        container.backgroundColor = LCLaunchPreCoverView.backgroundInk
        let view = LCLaunchPreCoverView()
        view.titleLabel.text = app.appInfo.displayName()
        let portrait = bounds.height > bounds.width
        if portrait {
            // 横屏画布 + 旋转 +π/2，复现客体场景 LandscapeLeft 的呈现
            view.bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
            view.center = CGPoint(x: bounds.midX, y: bounds.midY)
            view.transform = CGAffineTransform(rotationAngle: .pi / 2)
        } else {
            view.frame = bounds
        }
        container.addSubview(view)
        let rootVC = UIViewController()
        rootVC.view = container
        win.rootViewController = rootVC
        win.isHidden = false
        window = win
        coverView = view
        appendLog("预盖层已呈现：标题=\(app.appInfo.displayName()) 宿主 bounds=\(NSStringFromCGRect(bounds)) 朝向=\(portrait ? "竖屏（横屏画布+旋转 +π/2）" : "横屏（画布即 bounds）") 封面解析中")

        // 封面解析不阻塞派发：后台走库侧同链，到后主线程换入
        let appInfo = app.appInfo
        DispatchQueue.global(qos: .userInitiated).async {
            var image = LCGameLibraryInfo.bannerResolution(for: appInfo).image
            var desc: String
            if let image {
                desc = "库侧解析命中 \(Int(image.size.width * image.scale))x\(Int(image.size.height * image.scale))px"
            } else if let icon = appInfo.iconIsDarkIcon(false) {
                image = blurredIcon(icon) ?? icon
                desc = "库侧五级未命中，退应用图标虚化（与客体侧 5/5 同口径）"
            } else {
                desc = "库侧五级未命中且无图标，预盖层只有深色底+标题"
            }
            DispatchQueue.main.async {
                guard gen == generation, let view = coverView else { return }
                view.coverImageView.image = image
                appendLog("预盖层封面图已换入：\(desc)")
            }
        }
    }

    /// 派发失败时撤层并清标记（宿主进程存活，报错弹层不得被罩住）
    static func remove() {
        if !Thread.isMainThread {
            DispatchQueue.main.sync { remove() }
            return
        }
        teardownWindow()
        generation += 1
        UserDefaults.standard.removeObject(forKey: presentedDefaultsKey)
        appendLog("预盖层已撤除：派发失败，清标记（宿主进程存活）")
    }

    private static func teardownWindow() {
        window?.isHidden = true
        window = nil
        coverView = nil
    }

    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    // MARK: 打点（同一 log.txt 通道）

    private static func appendLog(_ message: String) {
        NSLog("[LCLaunchPreCover][launchcover] %@", message)
        guard let folder = logContainerFolderName else { return }
        let url = LCPath.dataPath
            .appendingPathComponent(folder)
            .appendingPathComponent("Documents/log.txt")
        let line = "[launchcover host] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

    // MARK: 图标虚化（与客体侧 LCLaunchCoverBlurredImage 同参同法）

    private static func blurredIcon(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        let radius = max(24, min(64, Double(input.extent.width) * 0.09))
        let clamp = CIFilter(name: "CIAffineClamp")
        clamp?.setValue(input, forKey: kCIInputImageKey)
        clamp?.setValue(NSValue(cgAffineTransform: .identity), forKey: kCIInputTransformKey)
        let blur = CIFilter(name: "CIGaussianBlur")
        blur?.setValue(clamp?.outputImage, forKey: kCIInputImageKey)
        blur?.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = blur?.outputImage,
              let outCG = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: outCG, scale: image.scale, orientation: image.imageOrientation)
    }
}

/// 底部渐变罩：与客体侧 LCLaunchScrimView 同 stops
private final class LCLaunchPreScrimView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        let g = layer as! CAGradientLayer
        let ink = UIColor(red: 4 / 255, green: 4 / 255, blue: 8 / 255, alpha: 1)
        g.colors = [ink.withAlphaComponent(0.82).cgColor,
                    ink.withAlphaComponent(0.25).cgColor,
                    UIColor.clear.cgColor]
        g.locations = [0, 0.42, 0.65]
        g.startPoint = CGPoint(x: 0.5, y: 1)
        g.endPoint = CGPoint(x: 0.5, y: 0)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 预盖层根视图：与客体侧 LCLaunchCoverView 同构图同参数，差别仅在静态
/// 呈现——罩/信息组满 alpha、封面停在缓推起点 scale 1.14（客体侧盖层
/// 的入场终态），无淡入、无缓推（缓推由客体侧接棒续走）。
private final class LCLaunchPreCoverView: UIView {
    static let backgroundInk = UIColor(red: 7 / 255, green: 7 / 255, blue: 12 / 255, alpha: 1)

    let coverImageView = UIImageView()
    let titleLabel = UILabel()
    private let scrimView = LCLaunchPreScrimView()
    private let metaView = UIView()
    private let barTrack = UIView()
    private let barSegment = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Self.backgroundInk
        coverImageView.contentMode = .scaleAspectFill
        coverImageView.clipsToBounds = true
        coverImageView.transform = CGAffineTransform(scaleX: 1.14, y: 1.14)
        addSubview(coverImageView)
        addSubview(scrimView)
        metaView.isUserInteractionEnabled = false
        addSubview(metaView)
        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        titleLabel.layer.shadowColor = UIColor.black.cgColor
        titleLabel.layer.shadowOpacity = 0.6
        titleLabel.layer.shadowRadius = 12
        titleLabel.layer.shadowOffset = CGSize(width: 0, height: 2)
        metaView.addSubview(titleLabel)
        barTrack.backgroundColor = UIColor(white: 1, alpha: 0.22)
        barTrack.layer.cornerRadius = 1.5
        barTrack.clipsToBounds = true
        metaView.addSubview(barTrack)
        barSegment.backgroundColor = UIColor(red: 0.949, green: 0.918, blue: 0.847, alpha: 1)
        barSegment.layer.cornerRadius = 1.5
        barTrack.addSubview(barSegment)
        let hint = UILabel()
        hint.font = .systemFont(ofSize: 10, weight: .medium)
        hint.textColor = UIColor(white: 1, alpha: 0.55)
        hint.textAlignment = .center
        hint.attributedText = NSAttributedString(
            string: "lc.launchCover.skipHint".loc,
            attributes: [.kern: NSNumber(value: 1.8), .font: hint.font!, .foregroundColor: hint.textColor!])
        hint.tag = 1
        metaView.addSubview(hint)
        // 光带往复：与客体侧盖层同参（0→90、1.1s、往复、easeInEaseOut）
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = 0
        slide.toValue = 90
        slide.duration = 1.1
        slide.autoreverses = true
        slide.repeatCount = .infinity
        slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        barSegment.layer.add(slide, forKey: "lcLaunchBarSlide")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = bounds
        // 封面图带 scale 变换，用 bounds+center 定位（与 frame 等价、无变换冲突）
        coverImageView.bounds = CGRect(origin: .zero, size: b.size)
        coverImageView.center = CGPoint(x: b.midX, y: b.midY)
        scrimView.frame = b
        // 底部信息组排布与客体侧 layoutSubviews 逐项一致
        let metaH: CGFloat = 24 + 12 + 3 + 10 + 14
        let bottomGap = max(b.height * 0.09, 28)
        metaView.frame = CGRect(x: 0, y: b.height - bottomGap - metaH, width: b.width, height: metaH)
        titleLabel.frame = CGRect(x: 20, y: 0, width: b.width - 40, height: 24)
        let trackW: CGFloat = 118
        barTrack.frame = CGRect(x: (b.width - trackW) / 2, y: 24 + 12, width: trackW, height: 3)
        barSegment.frame = CGRect(x: -12, y: 0, width: 52, height: 3)
        metaView.viewWithTag(1)?.frame = CGRect(x: 20, y: 24 + 12 + 3 + 10, width: b.width - 40, height: 14)
    }
}
