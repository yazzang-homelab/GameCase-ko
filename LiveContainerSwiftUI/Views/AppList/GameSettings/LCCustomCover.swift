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

// MARK: - 16:9 裁剪页（拖动 + 双指缩放，框外变暗）

struct LCCoverCropView: View {
    let image: UIImage
    var onConfirm: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var gestureZoom: CGFloat = 1
    @GestureState private var gesturePan: CGSize = .zero
    /// 布局实测的可用尺寸（confirm 时按同尺寸算裁剪框，不靠 UIScreen 猜）
    @State private var viewSize: CGSize = .zero

    private static let aspect: CGFloat = 16.0 / 9.0
    private static let maxZoom: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let frameW = geo.size.width - 32
            let frameH = frameW / Self.aspect
            let frameRect = CGRect(
                x: (geo.size.width - frameW) / 2,
                y: (geo.size.height - frameH) / 2 - 30,
                width: frameW, height: frameH
            )
            ZStack {
                Color(UIColor.systemBackground).ignoresSafeArea()
                // 框外变暗（eoFill 挖洞）
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geo.size))
                    path.addRect(frameRect)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .ignoresSafeArea()
                .allowsHitTesting(false)

                cropViewport(frameRect: frameRect)
            }
            .onAppear { viewSize = geo.size }
            .onChange(of: geo.size) { viewSize = $0 }
        }
        .navigationTitle("lc.gameSettings.cropCover".loc)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("lc.common.cancel".loc) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button { confirm() } label: {
                    Text("lc.gameSettings.useThis".loc).bold()
                }
            }
        }
    }

    /// 图片窗口：以 frame 为界裁掉溢出，内部图片按 填充×zoom 缩放并跟随 pan
    private func cropViewport(frameRect: CGRect) -> some View {
        let frameSize = frameRect.size
        let effectiveZoom = clampedZoom(zoom * gestureZoom)
        let effectivePan = clampedPan(pan + gesturePan, zoom: effectiveZoom, frameSize: frameSize)
        return ZStack {
            Image(uiImage: image)
                .resizable()
                .frame(
                    width: fillSize(frameSize: frameSize).width * effectiveZoom,
                    height: fillSize(frameSize: frameSize).height * effectiveZoom
                )
                .offset(effectivePan)
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .clipped()
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.white.opacity(0.65), lineWidth: 1)
        )
        .position(x: frameRect.midX, y: frameRect.midY)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($gesturePan) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    pan = clampedPan(pan + value.translation, zoom: clampedZoom(zoom), frameSize: frameSize)
                }
        )
        .simultaneousGesture(
            MagnificationGesture()
                .updating($gestureZoom) { value, state, _ in
                    state = value
                }
                .onEnded { value in
                    zoom = clampedZoom(zoom * value)
                    pan = clampedPan(pan, zoom: zoom, frameSize: frameSize)
                }
        )
    }

    // MARK: 几何（显示与裁剪共用同一套换算，保证所见即所得）

    /// 图片在 zoom=1 时恰好填满框的显示尺寸（points）
    private func fillSize(frameSize: CGSize) -> CGSize {
        let s = max(frameSize.width / image.size.width, frameSize.height / image.size.height)
        return CGSize(width: image.size.width * s, height: image.size.height * s)
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, 1), Self.maxZoom)
    }

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

    /// 按当前 zoom/pan 把框内区域映射回原图像素裁出
    private func croppedImage() -> UIImage? {
        // 先把方向归一为 .up 且 scale=1，后续按像素坐标算
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let upright = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let cgImage = upright.cgImage else {
            return nil
        }
        let iw = CGFloat(cgImage.width)
        let ih = CGFloat(cgImage.height)
        // 裁剪框尺寸与 body 布局同公式（宽 = 可用宽-32，高 = 宽×9/16）
        let baseWidth = viewSize.width > 0 ? viewSize.width : UIScreen.main.bounds.width
        let frameW = baseWidth - 32
        let frameH = frameW / Self.aspect
        let frameSize = CGSize(width: frameW, height: frameH)
        let z = clampedZoom(zoom)
        let p = clampedPan(pan, zoom: z, frameSize: frameSize)
        // points 每像素：填充缩放 × zoom（upright 后 image.size 与像素同值）
        let fill = fillSize(frameSize: frameSize)
        let pointsPerPixel = (fill.width / iw) * z
        let cropW = frameW / pointsPerPixel
        let cropH = frameH / pointsPerPixel
        var rect = CGRect(
            x: iw / 2 - cropW / 2 - p.width / pointsPerPixel,
            y: ih / 2 - cropH / 2 - p.height / pointsPerPixel,
            width: cropW, height: cropH
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
