//
//  LCGameState.swift
//  LiveContainerSwiftUI
//
//  游戏状态机：照 NX2Apple 壳 GameState / GameStateResolver 的形态移植
//  （frontend-ios 的 ShellUI/ShellInputs.swift、ShellHost/GameCatalogue.swift），
//  语义按 GC 的容器模型适配：
//   - NX2 的 .needsAppUpdate 是 framework 版本链专有（壳与游戏包的构建
//     链 / 最低系统版本比对），GC 客体是整包 IPA、没有这条链，不搬；
//   - NX2 的 .broken 来自包内 manifest/launcher.json 解析失败，GC 没有
//     等价清单文件，损坏判定只取「磁盘可实证」的四种：romfs.img 是
//     文件夹 / 读不到文件信息 / 大小为 0 / 与客体自带 romfs.id 记录的
//     大小对不上。其余一律落回旧二态（就绪 = 可玩、无包 = 缺数据包）。
//   - 「容器记录缺失」不单列为损坏：游戏刚导入、还没首次启动时本就
//     没有容器记录（记录在首次启动时才建），旧形态记录又会被
//     LCAppInfo.containers 的垫片合成出来，这个信号分不出「损坏」
//     与「没启动过」，按缺数据包呈现、修法也正是先启动或先导包。
//
//  库排序（LCGameLibraryInfo.libraryOrder）照 NX2 LibraryOrder.swift：
//  最近游玩过的在最前（组内按时间倒序），其后可玩 → 缺数据包 →
//  已损坏，组内按标题字母序；次序只在主页出现时定一次，浏览期间
//  状态变化不重排（NX2 原注：never on a single game's change of
//  state, so nothing moves under the player's finger）。
//

import Foundation

/// 一款游戏在库里的状态。broken 的 reason 是一句短原因（状态行用），
/// detail 是给玩家看的「出了什么事 + 怎么修」，technical 是底层实测
/// 值（路径 / 字节数），只在帮助卡的「详情」小字区出现——与 NX2
/// GameState.broken(reason:detail:technical) 同构。
enum LCGameState: Equatable {
    case playable
    case needsDatapack
    /// 玩家已声明本游戏无需数据包（LCGameDatapackNeed）且探针什么都
    /// 没探到：呈现按可玩处理（无帮助卡、无缺包徽标），只有设置页
    /// 数据包行单独显示中性的「无需」，不冒充「已导入」。
    case notRequired
    case broken(reason: String, detail: String, technical: String)

    /// 状态短名（主页状态行 / 帮助卡标题）
    var title: String {
        switch self {
        case .playable, .notRequired: return "lc.gameState.playable".loc
        case .needsDatapack: return "lc.gameState.needsDatapack".loc
        case .broken: return "lc.gameState.broken".loc
        }
    }

    /// 一句说明（帮助卡正文第一段）
    var explanation: String {
        switch self {
        case .playable, .notRequired:
            return ""
        case .needsDatapack:
            return "lc.gameState.needsDatapackExplanation".loc
        case .broken(let reason, _, _):
            return reason
        }
    }

    /// 「怎么修」正文（照 NX2 StateHelpView 的语气：说清在哪修、修完
    /// 会怎样，两三句封顶）。broken 的 detail 本身就是在解析点按具体
    /// 原因写好的修法，这里直接透传。
    var fixText: String {
        switch self {
        case .playable, .notRequired:
            return ""
        case .needsDatapack:
            return "lc.gameState.needsDatapackFix".loc
        case .broken(_, let detail, _):
            return detail
        }
    }

    var isPlayable: Bool {
        switch self {
        case .playable, .notRequired: return true
        case .needsDatapack, .broken: return false
        }
    }
}

/// 帮助页呈现载荷（主页 sheet(item:) 用）：点状态行时把当时的状态
/// 一并快照进来，页里不再重算。
struct LCGameStateTarget: Identifiable {
    let id = UUID()
    let app: LCAppModel
    let state: LCGameState
}

/// 每游戏「无需数据包」声明（游戏设置页数据包导入页的开关）：一体包
/// （数据已打进 IPA）与其他非移植类游戏没有外置数据包，探针永远探
/// 不到，库与设置页会一直挂「未导入」提示；玩家打开此开关即声明本
/// 游戏无需数据包，状态解析在「什么都没探到」的出口改判 .notRequired
/// （见 gameState）。标记只存宿主 UserDefaults
/// （gc.datapack.notRequired.<bundleId>，默认 false = 需要数据包），
/// 与 LauncherGate 同类：GC 自己的呈现开关，不进客体偏好。删游戏后
/// 残留键无害（同 bundleId 重装同名游戏才会被读到，语义仍成立），
/// 现行没有这类键的清理钩子，不单独为它加。
enum LCGameDatapackNeed {
    private static func key(forBundleIdentifier bundleIdentifier: String) -> String {
        "gc.datapack.notRequired.\(bundleIdentifier)"
    }

    static func isNotRequired(forBundleIdentifier bundleIdentifier: String) -> Bool {
        UserDefaults.standard.bool(forKey: key(forBundleIdentifier: bundleIdentifier))
    }

    static func setNotRequired(_ notRequired: Bool, forBundleIdentifier bundleIdentifier: String) {
        UserDefaults.standard.set(notRequired, forKey: key(forBundleIdentifier: bundleIdentifier))
    }
}

extension LCGameLibraryInfo {
    /// 游戏状态解析（单一入口，主页状态行 / 设置页头部与数据包行 /
    /// 帮助卡 / 库排序共用）：先按记录对齐容器快照（与 datapackReady
    /// 同方），再按 probeDatapack 的枚举探测判定（与 datapackReady
    /// 同一套探测，不再拼写死路径）。判定顺序：无容器记录 → 缺数据
    /// 包；探到镜像文件（romfs.img 任意大小写）→ 走完好判定链（读
    /// 不出信息 / 0 字节 / 与 romfs.id 大小不符 → 已损坏，见文件
    /// 头）；无镜像文件但有 romfs 文件夹 → 可玩（散装文件夹是引擎
    /// romfs_locate 的正牌回退形态，前提是内含该游戏档案的标记文
    /// 件——标记路径是客体编译期常量、GC 无从校验，完整解包必含
    /// 它；不完整的夹子启动时由客体自己报「找不到游戏文件」）；只
    /// 有同名文件夹占着 romfs.img 的位置 → 已损坏（放错）；什么都
    /// 没有 → 缺数据包。玩家声明「无需数据包」（LCGameDatapackNeed）
    /// 时，「什么都没有」的两个出口（无容器记录 / 无任何条目）改判
    /// .notRequired——开关只压这一件事：探到镜像或文件夹的路径完全
    /// 不看开关，后来真导入了数据包仍按已导入 / 已损坏呈现。本函
    /// 数只读不写。
    static func gameState(for app: LCAppModel) -> LCGameState {
        app.refreshContainerSelection()
        let missing: LCGameState = LCGameDatapackNeed.isNotRequired(forBundleIdentifier: app.bundleIdentifier)
            ? .notRequired : .needsDatapack
        guard let container = defaultContainer(for: app) else {
            return missing
        }
        let probe = probeDatapack(container: container)
        guard let romfsURL = probe.imageFile else {
            if probe.folderEntry != nil {
                return .playable
            }
            if let entry = probe.imageEntry {
                return .broken(
                    reason: "lc.gameState.folderOccupiesReason".loc,
                    detail: "lc.gameState.folderOccupiesDetail".loc,
                    technical: "lc.gameState.folderOccupiesTechnical %@".localizeWithFormat(entry.path))
            }
            return missing
        }
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: romfsURL.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return .broken(
                reason: "lc.gameState.unreadableReason".loc,
                detail: "lc.gameState.unreadableDetail".loc,
                technical: "lc.gameState.unreadableTechnical %@".localizeWithFormat(romfsURL.path))
        }
        if size == 0 {
            return .broken(
                reason: "lc.gameState.emptyReason".loc,
                detail: "lc.gameState.emptyDetail".loc,
                technical: "lc.gameState.emptyTechnical %@".localizeWithFormat(romfsURL.path))
        }
        if let want = expectedRomfsSize(for: app.appInfo), want != size {
            return .broken(
                reason: "lc.gameState.mismatchReason".loc,
                detail: "lc.gameState.mismatchDetail".loc,
                technical: "lc.gameState.mismatchTechnical %lld %lld".localizeWithFormat(want, size))
        }
        return .playable
    }

    /// 客体自带 romfs.id 里记录的数据包大小（`DMROMFSID1 title=… size=…
    /// index=…` 的 size 字段，解析法与 NX2 DataLocator.expectedImageSize
    /// 相同）。第三方 IPA 没有 romfs.id 时返回 nil，跳过比对、不误判。
    static func expectedRomfsSize(for appInfo: LCAppInfo) -> Int64? {
        guard let bundlePath = appInfo.bundlePath() else {
            return nil
        }
        let url = URL(fileURLWithPath: bundlePath).appendingPathComponent("romfs.id")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return text
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .first { $0.hasPrefix("size=") }
            .flatMap { Int64($0.dropFirst(5)) }
    }

    /// 客体日志路径：dm 客体入口（dm/ios/Sources/main.m）把 stderr
    /// 重定向到它 NSDocumentDirectory 下的 log.txt（上一局保留为
    /// log.prev.txt）；在 LC 里客体 HOME 即容器根，Documents 就是
    /// 容器下的 Documents，所以日志恒为 <容器>/Documents/log.txt。
    static func guestLogURL(for app: LCAppModel) -> URL? {
        app.refreshContainerSelection()
        return defaultContainer(for: app)?.containerURL.appendingPathComponent("Documents/log.txt")
    }

    /// 客体日志大小（设置页日志行右侧显示用）；无日志返回 nil
    static func guestLogSize(for app: LCAppModel) -> Int64? {
        guard let url = guestLogURL(for: app),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value, size > 0 else {
            return nil
        }
        return size
    }

    /// 库排序（照 NX2 LibraryOrder.ids 的分组与组内规则）：玩过的
    /// （lastLaunched 有值）整组在最前、组内按时间倒序；没玩过的按
    /// 状态分组 可玩 → 缺数据包 → 已损坏、组内按标题本地化不分大小
    /// 写字母序；标题相同以相对包路径兜底定序（与主页 key(of:) 同源）。
    /// 只在主页出现时求值一次并存成顺序快照，浏览期间不重排。
    static func libraryOrder(of apps: [LCAppModel]) -> [LCAppModel] {
        func group(of app: LCAppModel) -> Int {
            if app.appInfo.lastLaunched != nil {
                return 0
            }
            switch gameState(for: app) {
            case .playable, .notRequired: return 1
            case .needsDatapack: return 2
            case .broken: return 3
            }
        }
        return apps.sorted { a, b in
            let (ga, gb) = (group(of: a), group(of: b))
            if ga != gb {
                return ga < gb
            }
            if ga == 0 {
                let (da, db) = (a.appInfo.lastLaunched ?? .distantPast, b.appInfo.lastLaunched ?? .distantPast)
                if da != db {
                    return da > db
                }
            }
            let byTitle = a.displayName.localizedCaseInsensitiveCompare(b.displayName)
            if byTitle != .orderedSame {
                return byTitle == .orderedAscending
            }
            return (a.appInfo.relativeBundlePath as String) < (b.appInfo.relativeBundlePath as String)
        }
    }
}
