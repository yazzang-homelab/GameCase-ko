//
//  LCCustomCover.swift
//  LiveContainerSwiftUI
//
//  自定义游戏封面：玩家给没有横版素材的游戏换一张自己的封面图。
//  图存宿主侧 Documents/CustomCovers/<客体 bundleId>.jpg，不进客体容器，
//  按 bundleId 键存——重装同游戏（新容器）封面还在；删文件即恢复默认。
//  解析优先级最高（见 LCGameLibraryInfo.bannerResolution）：自定义封面 →
//  客体自带横版图 → 内置原画 → 联网抓取缓存 → 图标兜底。
//

import SwiftUI
import PhotosUI

private extension CGSize {
    static func + (lhs: CGSize, rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }
}

// MARK: - 存储（宿主 Documents/CustomCovers/<bundleId>.jpg）

enum LCCustomCoverStore {
    /// 落盘上限：长边 1600px，超出等比缩小（落盘图固定 16:9，长边即宽）
    private static let maxPixelDimension: CGFloat = 1600
    private static let jpegQuality: CGFloat = 0.85

    static var directoryURL: URL {
        LCPath.docPath.appendingPathComponent("CustomCovers", isDirectory: true)
    }

    static func fileURL(forBundleIdentifier bundleIdentifier: String) -> URL {
        directoryURL.appendingPathComponent("\(bundleIdentifier).jpg")
    }

    static func exists(forBundleIdentifier bundleIdentifier: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(forBundleIdentifier: bundleIdentifier).path)
    }

    static func load(forBundleIdentifier bundleIdentifier: String) -> UIImage? {
        let url = fileURL(forBundleIdentifier: bundleIdentifier)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }

    /// 存盘：长边压到 1600 后以 JPEG 0.85 落盘（临时文件 + 替换，避免写一半被读到）
    static func save(_ image: UIImage, forBundleIdentifier bundleIdentifier: String) throws {
        let resized = resizedForStorage(image)
        guard let data = resized.jpegData(compressionQuality: jpegQuality) else {
            throw LCCustomCoverError.encodeFailed
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let target = fileURL(forBundleIdentifier: bundleIdentifier)
        let tmp = directoryURL.appendingPathComponent(".\(bundleIdentifier).tmp.jpg")
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: tmp, to: target)
    }

    /// 恢复默认 = 删掉自定义文件，解析链自动回落到客体自带/内置/图标
    static func remove(forBundleIdentifier bundleIdentifier: String) {
        try? FileManager.default.removeItem(at: fileURL(forBundleIdentifier: bundleIdentifier))
    }

    private static func resizedForStorage(_ image: UIImage) -> UIImage {
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longEdge = max(pixelSize.width, pixelSize.height)
        guard longEdge > maxPixelDimension else {
            return image
        }
        let ratio = maxPixelDimension / longEdge
        let target = CGSize(width: (pixelSize.width * ratio).rounded(), height: (pixelSize.height * ratio).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

enum LCCustomCoverError: Error {
    case encodeFailed
}

// MARK: - 相册选择（PHPicker，部署目标 15 可用；SwiftUI PhotosPicker 需 iOS 16）

struct LCPhotoImagePicker: UIViewControllerRepresentable {
    /// 选中并成功解码出一张图
    var onPick: (UIImage) -> Void
    /// 选了但解不出图（格式损坏等）
    var onFail: () -> Void
    /// 用户取消（静默关页即可，调用方无需处理）
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: LCPhotoImagePicker

        init(parent: LCPhotoImagePicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let result = results.first else {
                parent.onCancel()
                return
            }
            let provider = result.itemProvider
            guard provider.canLoadObject(ofClass: UIImage.self) else {
                parent.onFail()
                return
            }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                DispatchQueue.main.async {
                    if let image = object as? UIImage {
                        self.parent.onPick(image)
                    } else {
                        self.parent.onFail()
                    }
                }
            }
        }
    }
}

// MARK: - 16:9 裁剪页（全屏深色编辑面：图片满屏平移/捏合，中央固定 16:9 画框）
//
// 改版口径（玩家反馈「剪裁页面不够优雅」「不应该是方形剪裁」）：整屏深色，
// 图片以填满画框为基准满屏呈现、可拖动平移 + 双指捏合缩放；中央画框固定
// 16:9（竖屏满宽、横屏按屏内最大拟合），框内即最终封面，框外是同一张图
// 压暗 + 三分网格，一眼可见裁掉的部分。顶栏/还原按钮走 GC 玻璃规范
// （gcGlassButtonStyle / gcGlassProminentButtonStyle：iOS 26 系统原生
// 玻璃、低版本系统边框样式）；页面底色与画框是内容层，不玻璃化。

struct LCCoverCropView: View {
    let image: UIImage
    var onConfirm: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var gestureZoom: CGFloat = 1
    @GestureState private var gesturePan: CGSize = .zero
    /// 布局实测的可用尺寸（confirm 时按同尺寸算画框，不靠 UIScreen 猜）
    @State private var viewSize: CGSize = .zero

    private static let aspect: CGFloat = 16.0 / 9.0
    private static let maxZoom: CGFloat = 4
    /// 框外压暗强度（改版预览定版值）
    private static let dimOpacity: Double = 0.52

    var body: some View {
        GeometryReader { geo in
            let frameRect = Self.frameRect(in: geo.size)
            ZStack {
                Color.black.ignoresSafeArea()

                stageImage(frameRect: frameRect)

                // 手势层：整屏接拖动/捏合（顶/底栏在其上层，按钮优先命中）
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(dragGesture(frameSize: frameRect.size))
                    .simultaneousGesture(magnifyGesture(frameSize: frameRect.size))

                dimOverlay(frameRect: frameRect, canvasSize: geo.size, insets: geo.safeAreaInsets)
                gridOverlay(frameRect: frameRect)

                topBar(safeTop: geo.safeAreaInsets.top)
                bottomBar(safeBottom: geo.safeAreaInsets.bottom)
            }
            .onAppear { viewSize = geo.size }
            .onChange(of: geo.size) { newSize in
                viewSize = newSize
                let fr = Self.frameRect(in: newSize)
                pan = clampedPan(pan, zoom: clampedZoom(zoom), frameSize: fr.size)
            }
        }
        .navigationBarHidden(true)
        .preferredColorScheme(.dark)
    }

    // MARK: 舞台与覆盖层

    /// 图片本体：不裁剪、满屏呈现，以画框中心为锚按 填充×zoom 显示并跟随 pan
    private func stageImage(frameRect: CGRect) -> some View {
        let frameSize = frameRect.size
        let effectiveZoom = clampedZoom(zoom * gestureZoom)
        let effectivePan = clampedPan(pan + gesturePan, zoom: effectiveZoom, frameSize: frameSize)
        let fill = fillSize(frameSize: frameSize)
        return Image(uiImage: image)
            .resizable()
            .frame(width: fill.width * effectiveZoom, height: fill.height * effectiveZoom)
            .offset(effectivePan)
            .position(x: frameRect.midX, y: frameRect.midY)
            .allowsHitTesting(false)
    }

    /// 框外压暗（eoFill 挖洞）：洞外仍是同一张图，只是压暗。
    /// 洞口与画框边/网格共用同一个 frameRect、同一坐标系：本视图**不得**
    /// ignoresSafeArea——忽略安全区会把 Path 的 frame 按 inset 外扩、绘制
    /// 原点相对兄弟视图偏移 (−leading, −top)，洞口随之偏移，遮罩便从画框
    /// 下游一侧漏入一条（竖屏底部 ≈ 顶 inset、横屏右侧 ≈ 左 inset，
    /// 灵动岛机型实测约 59pt）。外圈则按 inset 把画布外扩一圈，保证本地
    /// 画布若止于安全区内缘，图片伸进安全区的部分同样被压暗；洞口大小
    /// 只由 frameRect 决定，外扩不影响洞口。
    private func dimOverlay(frameRect: CGRect, canvasSize: CGSize, insets: EdgeInsets) -> some View {
        let canvas = CGRect(
            x: -insets.leading,
            y: -insets.top,
            width: canvasSize.width + insets.leading + insets.trailing,
            height: canvasSize.height + insets.top + insets.bottom
        )
        return Path { path in
            path.addRect(canvas)
            path.addRect(frameRect)
        }
        .fill(Color.black.opacity(Self.dimOpacity), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    /// 画框：细亮边 + 三分网格
    private func gridOverlay(frameRect: CGRect) -> some View {
        ZStack {
            Path { path in
                for i in 1...2 {
                    let x = frameRect.minX + frameRect.width * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: frameRect.minY))
                    path.addLine(to: CGPoint(x: x, y: frameRect.maxY))
                    let y = frameRect.minY + frameRect.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: frameRect.minX, y: y))
                    path.addLine(to: CGPoint(x: frameRect.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.28), lineWidth: 1)
            Rectangle()
                .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: frameRect.width, height: frameRect.height)
                .position(x: frameRect.midX, y: frameRect.midY)
        }
        .allowsHitTesting(false)
    }

    // MARK: 顶/底栏（控件走 GC 玻璃规范，文字与底色不玻璃化）

    private func topBar(safeTop: CGFloat) -> some View {
        VStack {
            ZStack {
                HStack {
                    Button("lc.common.cancel".loc) { dismiss() }
                        .gcGlassButtonStyle()
                    Spacer()
                    Button { confirm() } label: {
                        Text("lc.gameSettings.useThis".loc).bold()
                    }
                    .gcGlassProminentButtonStyle()
                }
                Text("lc.gameSettings.cropCover".loc)
                    .font(.headline)
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 1)
            }
            .padding(.horizontal, 14)
            .padding(.top, safeTop + 8)
            Spacer()
        }
    }

    private func bottomBar(safeBottom: CGFloat) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                Text("lc.gameSettings.cropHint".loc)
                    .font(.footnote)
                    .foregroundColor(Color.white.opacity(0.75))
                    .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 1)
                HStack {
                    Spacer()
                    Button("lc.gameSettings.cropReset".loc) { resetView() }
                        .gcGlassButtonStyle()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, safeBottom + 14)
        }
    }

    // MARK: 手势

    private func dragGesture(frameSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($gesturePan) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                pan = clampedPan(pan + value.translation, zoom: clampedZoom(zoom), frameSize: frameSize)
            }
    }

    private func magnifyGesture(frameSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .updating($gestureZoom) { value, state, _ in
                state = value
            }
            .onEnded { value in
                zoom = clampedZoom(zoom * value)
                pan = clampedPan(pan, zoom: zoom, frameSize: frameSize)
            }
    }

    private func resetView() {
        withAnimation(.easeOut(duration: 0.25)) {
            zoom = 1
            pan = .zero
        }
    }

    // MARK: 几何（显示与裁剪共用同一套换算，保证所见即所得）

    /// 中央 16:9 画框：屏内最大拟合（竖屏满宽、横屏按高拟合），居中
    static func frameRect(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else {
            return .zero
        }
        var w = size.width
        var h = w / aspect
        if h > size.height {
            h = size.height
            w = h * aspect
        }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// 图片在 zoom=1 时恰好填满框的显示尺寸（points）
    private func fillSize(frameSize: CGSize) -> CGSize {
        let s = max(frameSize.width / image.size.width, frameSize.height / image.size.height)
        return CGSize(width: image.size.width * s, height: image.size.height * s)
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, 1), Self.maxZoom)
    }

    /// 平移钳制：图片任何时刻完全覆盖画框，不许露边
    private func clampedPan(_ value: CGSize, zoom: CGFloat, frameSize: CGSize) -> CGSize {
        let fill = fillSize(frameSize: frameSize)
        let maxX = max(0, (fill.width * zoom - frameSize.width) / 2)
        let maxY = max(0, (fill.height * zoom - frameSize.height) / 2)
        return CGSize(
            width: min(max(value.width, -maxX), maxX),
            height: min(max(value.height, -maxY), maxY)
        )
    }

    private func confirm() {
        guard let cropped = croppedImage() else {
            return
        }
        onConfirm(cropped)
        dismiss()
    }

    /// 按当前 zoom/pan 把画框区域映射回原图像素裁出
    private func croppedImage() -> UIImage? {
        // 先把方向归一为 .up：按 size×scale 的像素尺寸重绘，@2x/@3x 图不降采样
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let upright = UIGraphicsImageRenderer(size: pixelSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
        guard let cgImage = upright.cgImage else {
            return nil
        }
        let iw = CGFloat(cgImage.width)
        let ih = CGFloat(cgImage.height)
        // 画框尺寸与 body 布局同公式（屏内最大 16:9 拟合）
        let baseSize = viewSize.width > 0 ? viewSize : UIScreen.main.bounds.size
        let frameRect = Self.frameRect(in: baseSize)
        let z = clampedZoom(zoom)
        let p = clampedPan(pan, zoom: z, frameSize: frameRect.size)
        // 图片显示左上在屏幕坐标中的位置，再把画框矩形换算回原图坐标
        let fill = fillSize(frameSize: frameRect.size)
        let dispW = fill.width * z
        let dispH = fill.height * z
        let pointsPerPixel = dispW / iw
        let imgMinX = frameRect.midX + p.width - dispW / 2
        let imgMinY = frameRect.midY + p.height - dispH / 2
        var rect = CGRect(
            x: (frameRect.minX - imgMinX) / pointsPerPixel,
            y: (frameRect.minY - imgMinY) / pointsPerPixel,
            width: frameRect.width / pointsPerPixel,
            height: frameRect.height / pointsPerPixel
        )
        // 整数化并钳进图像范围（浮点误差兜底，正常 clamp 下不会越界）
        rect = rect.integral.intersection(CGRect(x: 0, y: 0, width: iw, height: ih))
        guard !rect.isNull, rect.width >= 16, rect.height >= 9,
              let cropped = cgImage.cropping(to: rect) else {
            return nil
        }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }
}
