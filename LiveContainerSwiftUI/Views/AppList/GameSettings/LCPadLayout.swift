//
//  LCPadLayout.swift
//  LiveContainerSwiftUI
//
//  两款游戏触控按键的键位表与自定义布局的存储格式，与 NX2Apple 壳设置页的编辑器
//  （frontend-ios/Sources/ShellUI/GamePadLayout.swift，PR #51）逐值一致，引擎侧真源是
//  DmGamepad.m 的 k_skin / k_hades 表与 custLoad / custSave：
//  偏好字典 DmPadCustom（丝之歌）/ DmPadCustomHades（哈迪斯）里，每键只存中心相对
//  键位表的偏移（屏幕比例 dx / dy）与大小倍率 s（0.6–1.6），键名是素材名，摇杆存
//  在 "stick" 名下；没有改动的键不落条目，整表为空时删键。与游戏内编辑器（丝之歌
//  眼睛键长按、哈迪斯 − 键）共用同一份，两边改动互通。
//  区别只在落点：壳里存进程自己的 UserDefaults，这里存客体容器偏好 plist 的同名键
//  （经 LCGamePrefs 读写，写时保留文件里的其它键）。
//

import CoreGraphics
import Foundation

enum LCPadLayoutGame {
    case silksong
    case hades2

    var storeKey: String { self == .silksong ? "DmPadCustom" : "DmPadCustomHades" }
    var skinEnv: String { self == .silksong ? "DM_SILK_SKIN" : "DM_HADES_SKIN" }
    var displayName: String { self == .silksong ? "lc.padLayout.gameSilksong".loc : "lc.padLayout.gameHades2".loc }

    static let sizeStep: CGFloat = 0.05
    static let sizeRange: ClosedRange<CGFloat> = 0.6...1.6

    struct Key: Identifiable {
        var id: String { name }
        let name: String // 素材名，也是存储字典里的条目名（摇杆是 "stick"）
        let label: String // 编辑器面板里显示的中文名
        let glyph: String? // 玻璃键（无素材时）的字形；符号键 / 方向键为 nil，走符号图
        let x: CGFloat // 中心 x（宽度比例）；扇形键的 y 是相对 Y 键中心的偏移（宽度比例）
        let y: CGFloat
        let r: CGFloat // 半径（宽度比例，未乘倍率）
        enum Shape { case action, top, fan, plain }
        let shape: Shape
        let badged: Bool // 角标套把盘画在更大的画布里，图层要等比放大
    }

    var stickCentre: CGPoint { self == .silksong ? CGPoint(x: 0.162, y: 0.742) : CGPoint(x: 0.168, y: 0.664) }
    var stickRadius: CGFloat { self == .silksong ? 0.074 : 0.061 }

    var keys: [Key] {
        switch self {
        case .silksong: return [
            Key(name: "attack", label: "lc.padLayout.keyAttack".loc, glyph: "Y", x: 0.7859, y: 0.770, r: 0.0374, shape: .action, badged: true),
            Key(name: "jump", label: "lc.padLayout.keyJump".loc, glyph: "B", x: 0.898, y: 0.770, r: 0.0480, shape: .action, badged: true),
            Key(name: "dash", label: "lc.padLayout.keyDash".loc, glyph: "ZR", x: 0.8188, y: 0.5983, r: 0.0374, shape: .action, badged: true),
            Key(name: "tool", label: "lc.padLayout.keyTool".loc, glyph: "R", x: 0.7103, y: 0.770, r: 0.0254, shape: .action, badged: true),
            Key(name: "needolin", label: "lc.padLayout.keyNeedolin".loc, glyph: "X", x: 0.6468, y: 0.770, r: 0.0254, shape: .action, badged: true),
            Key(name: "bind", label: "lc.padLayout.keyBind".loc, glyph: "A", x: 0.898, y: 0.5271, r: 0.0374, shape: .action, badged: true),
            Key(name: "clawline", label: "lc.padLayout.keyClawline".loc, glyph: "ZL", x: 0.898, y: 0.3631, r: 0.0254, shape: .action, badged: true),
            Key(name: "eye", label: "lc.padLayout.keyEye".loc, glyph: nil, x: 0.670, y: 0.082, r: 0.0224, shape: .top, badged: true),
            Key(name: "map", label: "lc.padLayout.keyMap".loc, glyph: "L", x: 0.746, y: 0.082, r: 0.0224, shape: .top, badged: true),
            Key(name: "bag", label: "lc.padLayout.keyBag".loc, glyph: nil, x: 0.822, y: 0.082, r: 0.0224, shape: .top, badged: true),
            Key(name: "pause", label: "lc.padLayout.keyPause".loc, glyph: nil, x: 0.898, y: 0.082, r: 0.0224, shape: .top, badged: true),
        ]
        case .hades2: return [
            Key(name: "minus", label: "lc.padLayout.keyMinus".loc, glyph: "−", x: 0.691, y: 0.086, r: 0.020, shape: .top, badged: true),
            Key(name: "plus", label: "lc.padLayout.keyPlus".loc, glyph: "+", x: 0.754, y: 0.086, r: 0.020, shape: .top, badged: true),
            Key(name: "l", label: "L", glyph: "L", x: 0.817, y: 0.086, r: 0.020, shape: .top, badged: true),
            Key(name: "zl", label: "ZL", glyph: "ZL", x: 0.880, y: 0.086, r: 0.020, shape: .top, badged: true),
            Key(name: "zr", label: "ZR", glyph: "ZR", x: 0.943, y: 0.086, r: 0.020, shape: .top, badged: true),
            Key(name: "r", label: "R", glyph: "R", x: 0.903, y: -0.1451, r: 0.031, shape: .fan, badged: true),
            Key(name: "a", label: "A", glyph: "A", x: 0.8305, y: -0.1257, r: 0.031, shape: .fan, badged: true),
            Key(name: "x", label: "X", glyph: "X", x: 0.7773, y: -0.0726, r: 0.031, shape: .fan, badged: true),
            Key(name: "b", label: "B", glyph: "B", x: 0.758, y: 0.0, r: 0.031, shape: .fan, badged: true),
            Key(name: "y", label: "Y", glyph: "Y", x: 0.903, y: 0.715, r: 0.038, shape: .plain, badged: true),
            Key(name: "left", label: "lc.padLayout.keyLeft".loc, glyph: nil, x: 0.645, y: 0.896, r: 0.019, shape: .plain, badged: false),
            Key(name: "up", label: "lc.padLayout.keyUp".loc, glyph: nil, x: 0.701, y: 0.896, r: 0.019, shape: .plain, badged: false),
            Key(name: "down", label: "lc.padLayout.keyDown".loc, glyph: nil, x: 0.753, y: 0.896, r: 0.019, shape: .plain, badged: false),
            Key(name: "right", label: "lc.padLayout.keyRight".loc, glyph: nil, x: 0.807, y: 0.896, r: 0.019, shape: .plain, badged: false),
        ]
        }
    }

    /// 键的原始中心（未加玩家偏移）：与引擎 skinCenterRaw / hadesCenter 的算法一致
    func rawCentre(_ key: Key, in size: CGSize) -> CGPoint {
        switch key.shape {
        case .action:
            // 丝之歌的动作行以底行（y 0.822）为锚、按宽度比例向上堆（SKIN_REF_HW 0.4615）
            let y = 0.822 + (key.y - 0.822) * 0.4615 * size.width / size.height
            return CGPoint(x: key.x * size.width, y: y * size.height)
        case .fan:
            // 哈迪斯扇形键：y 是相对 Y 键中心（0.715）的偏移，按宽度比例
            return CGPoint(x: key.x * size.width, y: (0.715 + key.y * size.width / size.height) * size.height)
        case .top, .plain:
            return CGPoint(x: key.x * size.width, y: key.y * size.height)
        }
    }

    func rawStickCentre(in size: CGSize) -> CGPoint {
        CGPoint(x: stickCentre.x * size.width, y: stickCentre.y * size.height)
    }

    /// 当前皮肤对应的素材夹（相对客体包内 dm/）；0 是玻璃键（绘制）返回 nil
    func artFolder(skin: Int) -> String? {
        switch (self, skin) {
        case (.silksong, 1): return "padskin"
        case (.silksong, 2): return "padskin-badge"
        case (.silksong, 3): return "padskin-metal"
        case (.hades2, 1): return "hadesskin"
        case (.hades2, 2): return "hadesskin-badge"
        default: return nil
        }
    }

    func skinDisplayName(_ skin: Int) -> String {
        switch self {
        case .silksong: return ["lc.padLayout.skinGlass".loc, "lc.padLayout.skinThorns".loc, "lc.padLayout.skinBadge".loc, "lc.padLayout.skinIron".loc][min(max(skin, 0), 3)]
        case .hades2: return ["lc.padLayout.skinGlass".loc, "lc.padLayout.skinMoon".loc, "lc.padLayout.skinMoonBadge".loc][min(max(skin, 0), 2)]
        }
    }

    /// 素材图层相对键盘直径的放大：角标套画布更大（丝之歌 1020/880、哈迪斯 594/448，
    /// 仅角标键）；哈迪斯素材的盘只占画布 0.875，非角标时也要放大
    func artScale(_ key: Key, skin: Int) -> CGFloat {
        if skin == 2 && key.badged { return self == .silksong ? 1020.0 / 880.0 : 594.0 / 448.0 }
        return self == .hades2 ? 1.0 / 0.875 : 1.0
    }
}

// MARK: - 玩家自定义布局（存储字典的内存形态）

struct LCPadCustom: Equatable {
    struct Entry: Equatable {
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var s: CGFloat = 1
        var isDefault: Bool { dx == 0 && dy == 0 && s == 1 }
    }

    private(set) var entries: [String: Entry] = [:]

    init() {}

    init(dictionary: [String: Any]) {
        for (name, value) in dictionary {
            guard let e = value as? [String: Any] else { continue }
            var entry = Entry()
            entry.dx = (e["dx"] as? NSNumber)?.doubleValue ?? 0
            entry.dy = (e["dy"] as? NSNumber)?.doubleValue ?? 0
            let s = (e["s"] as? NSNumber)?.doubleValue ?? 1
            entry.s = LCPadLayoutGame.sizeRange.contains(CGFloat(s)) ? CGFloat(s) : 1
            if !entry.isDefault { entries[name] = entry }
        }
    }

    func entry(_ name: String) -> Entry { entries[name] ?? Entry() }
    var isEmpty: Bool { entries.isEmpty }

    mutating func set(_ name: String, _ entry: Entry) {
        entries[name] = entry.isDefault ? nil : entry
    }

    mutating func reset(_ name: String) { entries[name] = nil }
    mutating func resetAll() { entries.removeAll() }

    /// 落盘形态：只含改动过的键，每键 dx / dy / s（与引擎 custSave 一致）
    var dictionary: [String: [String: Double]] {
        entries.mapValues { ["dx": Double($0.dx), "dy": Double($0.dy), "s": Double($0.s)] }
    }

    /// 与引擎 clampCentre 一致：中心最多越界半径的五分之一
    static func clamp(_ centre: CGPoint, radius: CGFloat, in size: CGSize) -> CGPoint {
        let m = 0.2 * radius
        return CGPoint(x: min(max(centre.x, -m), size.width + m),
                       y: min(max(centre.y, -m), size.height + m))
    }

    func centre(of key: LCPadLayoutGame.Key, game: LCPadLayoutGame, in size: CGSize) -> CGPoint {
        let e = entry(key.name)
        let raw = game.rawCentre(key, in: size)
        let c = CGPoint(x: raw.x + e.dx * size.width, y: raw.y + e.dy * size.height)
        return Self.clamp(c, radius: key.r * e.s * size.width, in: size)
    }

    func stickCentre(game: LCPadLayoutGame, in size: CGSize) -> CGPoint {
        let e = entry("stick")
        let raw = game.rawStickCentre(in: size)
        let c = CGPoint(x: raw.x + e.dx * size.width, y: raw.y + e.dy * size.height)
        return Self.clamp(c, radius: game.stickRadius * e.s * size.width, in: size)
    }
}
