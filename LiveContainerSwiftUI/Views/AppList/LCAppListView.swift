//
//  ContentView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

class SearchContext: ObservableObject {
    @Published var query: String = ""
    @Published var debouncedQuery: String = ""
    @Published var isTyping: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        $query
            .debounce(for: .seconds(0.2), scheduler: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isTyping = true
                self?.debouncedQuery = value
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.isTyping = false
                }
            }
            .store(in: &cancellables)
    }
}

struct AppReplaceOption : Hashable {
    var isReplace: Bool
    var nameOfFolderToInstall: String
    var appToReplace: LCAppModel?
}

/// 每游戏设置页的 sheet 载荷：id 用包相对路径，同一游戏重复打开即同一弹层
struct LCGameSettingsSheetItem: Identifiable {
    let app: LCAppModel
    var id: String { app.appInfo.relativeBundlePath as String }
}

/// 遗留 AnyView 页（LCAppBannerDelegate 入口）的 sheet 载荷
struct LCLegacySheetItem: Identifiable {
    let id = UUID()
    let view: AnyView
}

struct LCAppListView : View, LCAppBannerDelegate, LCAppModelDelegate {
    @State var didAppear = false
    // 快捷栏回库淡入：游戏内点「游戏库」时 LCBootstrap 在宿主容器 plist 写 returning
    // 标记并盖黑遮罩自拉起；本视图冷启动读到标记则首帧盖黑、0.3s 淡出后清除标记。
    @State private var returnFadeVisible = false
    @State private var returnFadeOpacity: Double = 0
    // ipa choosing stuff
    @State var choosingIPA = false
    @State var errorShow = false
    @State var errorInfo = ""
    
    // ipa installing stuff
    @State var installprogressVisible = false
    @State var installProgressPercentage : Float = 0.0
    @State var installObserver : NSKeyValueObservation?
    
    @State var installOptions: [AppReplaceOption]
    @StateObject var installReplaceAlert = AlertHelper<AppReplaceOption>()
    
    @State var webViewOpened = false
    @State var webViewURL : URL = URL(string: "about:blank")!
    @StateObject private var webViewUrlInput = InputHelper()
    
    @EnvironmentObject var downloadHelper: DownloadHelper
    @StateObject private var installUrlInput = InputHelper()
    
    @State private var jitLog = ""
    @StateObject private var jitAlert = YesNoHelper()
    
    @StateObject private var runWhenMultitaskAlert = YesNoHelper()
    
    @StateObject private var generatedIconStyleSelector = AlertHelper<GeneratedIconStyle>()
    
    @State var safariViewOpened = false
    @State var safariViewURL = URL(string: "https://google.com")!
    
    /// 库内容刷新令牌：设置页 / 数据包导入页关闭后 bump，强制主页按磁盘现状
    /// 重算封面与数据包状态。主页是纯 let 入参的值视图，自身不观察任何磁盘
    /// 派生状态——弹层里改了封面文件 / romfs.img 后若没人通知它，它的 body
    /// 不会重跑，大图、卡片、状态点就停在旧结果上（真机实测：要重进才变）。
    @State private var libraryRefresh = 0
    /// 前台回归感知：经「文件」App 手动放 / 删 romfs.img 没有任何 App
    /// 内事件能 bump 上面的令牌，靠 scenePhase 回到 active 时对齐快照
    /// + bump 令牌兜底（见 body 的 onChange），不引入轮询
    @Environment(\.scenePhase) private var scenePhase
    // 设置类页面呈现状态（Phase 22 起三页统一走 LCSidePanelContainer
    // 自适应宿主：横屏 = 右侧面板、竖屏 = 整屏，形态随当前尺寸跟随、
    // 旋转原地变形，不再有 sheet / 面板两套状态按打开时方向二选一）
    @State var gameSettingsPanelItem: LCGameSettingsSheetItem? = nil
    @State var containerSettingsPanelPresented = false
    @State var hiddenAppsPresented = false
    @State var legacySheetItem: LCLegacySheetItem? = nil

    // 游戏库换皮：数据包导入（Phase 2 接通）与卸载确认
    @State var datapackImportRequest: LCDatapackRequest? = nil
    @State var appPendingUninstall: LCAppModel? = nil

    @State private var helpPresent = false
    
    @State private var customSortViewPresent = false
    
    @EnvironmentObject private var sharedModel : SharedModel
    @EnvironmentObject private var sharedAppSortManager : LCAppSortManager
    
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false
    
    @State private var isViewAppeared = false
    
    var sortedApps: [LCAppModel] {
        return sharedAppSortManager.sortedApps
    }
    
    var sortedHiddenApps: [LCAppModel] {
        return sharedAppSortManager.sortedHiddenApps
    }
    init() {
        _installOptions = State(initialValue: [])
        // 首帧就要盖黑，标记必须在视图首次渲染前读到，故在 init 里定初值
        let returning = Self.quickBarReturningMarker()
        _returnFadeVisible = State(initialValue: returning)
        _returnFadeOpacity = State(initialValue: returning ? 1 : 0)
    }

    /// 快捷栏状态文件：与 LCBootstrap 同一路径（宿主容器 Library/Preferences/LCQuickBar.plist）
    static var quickBarStatePath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Preferences/LCQuickBar.plist")
    }

    static func quickBarReturningMarker() -> Bool {
        (NSDictionary(contentsOfFile: quickBarStatePath)?["returning"] as? Bool) ?? false
    }

    static func clearQuickBarReturningMarker() {
        guard let state = NSMutableDictionary(contentsOfFile: quickBarStatePath) else { return }
        state["returning"] = false
        state.write(toFile: quickBarStatePath, atomically: true)
    }

    /// 消费 returning 标记：清标记后把黑遮罩 0.3s 淡出（普通冷启动无标记时不触发）
    func consumeReturnFade() {
        guard returnFadeVisible else { return }
        Self.clearQuickBarReturningMarker()
        withAnimation(.easeOut(duration: 0.3)) {
            returnFadeOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            returnFadeVisible = false
        }
    }

    var uninstallDialogTitle: String {
        return "lc.appList.uninstallTitle %@".localizeWithFormat(appPendingUninstall?.displayName ?? "")
    }

    var uninstallDialogPresented: Binding<Bool> {
        Binding(
            get: { appPendingUninstall != nil },
            set: { presented in
                if !presented {
                    appPendingUninstall = nil
                }
            }
        )
    }

    /// 打开每游戏设置页：全部入口（主页滑杆钮、网格卡长按、最近游玩行
    /// 长按、隐藏页行）都汇到这一个函数，只置宿主状态——呈现形态由
    /// LCSidePanelContainer 按当前尺寸决定（横屏右侧面板 / 竖屏整屏），
    /// 打开后旋转跟随变形（Phase 22；Phase 14 的打开时二选一已废除：
    /// sheet 一旦呈现终身是 sheet，旋转后变不回面板）。
    /// 更旧的路径是隐藏 NavigationLink push：关闭靠跨视图写本层的 isActive @State，
    /// 连续两轮修复（dismiss 语义、关页时序）在真机都没让顶部按钮活过来，故整体换掉。
    func openGameSettings(app: LCAppModel) {
        gameSettingsPanelItem = LCGameSettingsSheetItem(app: app)
    }

    /// 打开容器设置：与游戏设置同一个自适应宿主、同一条形态规则
    func presentContainerSettings() {
        containerSettingsPanelPresented = true
    }

    /// 关闭游戏设置页：关页后 bump 刷新令牌，主页按磁盘现状重算封面
    /// 与数据包状态（原 sheet 路径的 onDismiss 语义收敛到此一处）
    func closeGameSettingsPanel() {
        gameSettingsPanelItem = nil
        libraryRefresh += 1
    }

    /// 隐藏游戏恢复入口（主页 ＋ 菜单）：未解锁先鉴权，再以 sheet 打开隐藏游戏页
    func openHiddenApps() {
        Task {
            if !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    return
                }
            }
            hiddenAppsPresented = true
        }
    }

    /// 取消隐藏：与 LCAppModel.toggleHidden 的状态变更一致，但不连带关闭当前页
    func unhideApp(app: LCAppModel) {
        app.appInfo.isHidden = false
        app.uiIsHidden = false
        changeAppVisibility(app: app)
    }

    var body: some View {
        NavigationView {
            ZStack {
                // 游戏库主页（NX2Apple 壳式界面）：呈现与聚焦在 LCGameHomeView，
                // 启动 / 设置 / 导入 / 卸载全部回调回本视图的既有机制。
                // 这一层不忽略安全区，GeometryReader 读到的是真实 safeAreaInsets，
                // 注入主页供浮钮排定位（主页内部为全屏出血忽略了安全区，读不到）。
                GeometryReader { proxy in
                    LCGameHomeView(
                        apps: sortedApps,
                        hiddenAppsCount: sharedModel.hiddenApps.count,
                        multiLCStatus: sharedModel.multiLCStatus,
                        installProgressVisible: installprogressVisible,
                        installProgress: installProgressPercentage,
                        safeAreaInsets: proxy.safeAreaInsets,
                        safeSize: proxy.size,
                        refreshToken: libraryRefresh,
                        // 主页手柄导航的让位判据：本层任何面板 / 弹层
                        // 盖在主页之上时为真（主页据此摘掉手柄 handler）
                        overlayPresented: gameSettingsPanelItem != nil
                            || containerSettingsPanelPresented
                            || hiddenAppsPresented
                            || datapackImportRequest != nil
                            || appPendingUninstall != nil
                            || errorShow
                            || choosingIPA
                            || legacySheetItem != nil
                            || installReplaceAlert.show
                            || runWhenMultitaskAlert.show
                            || generatedIconStyleSelector.show
                            || webViewUrlInput.show
                            || installUrlInput.show
                            || jitAlert.show,
                        onRun: { runGame(app: $0) },
                        onSettings: { openGameSettings(app: $0) },
                        onOpenDataFolder: { openGameDataFolder(app: $0) },
                        onImportDatapack: { datapackImportRequest = LCDatapackRequest(app: $0) },
                        onUninstall: { appPendingUninstall = $0 },
                        onImportIPA: { choosingIPA = true },
                        onImportDatapackGeneric: { datapackImportRequest = LCDatapackRequest(app: nil) },
                        onOpenHiddenApps: { openHiddenApps() },
                        onOpenContainerSettings: { presentContainerSettings() }
                    )
                }

                // 回库淡入遮罩：与游戏内回库黑遮罩同款（黑底 + 房子图标 + 「游戏库」），
                // 盖住进程重启接缝，出现后由 consumeReturnFade 淡出。不拦截触摸。
                if returnFadeVisible {
                    ZStack {
                        Color.black
                        VStack(spacing: 8) {
                            Image(systemName: "house")
                                .font(.system(size: 38, weight: .light))
                            Text("lc.appList.library".loc)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Color(white: 0.75))
                        }
                    }
                    .foregroundColor(Color(white: 0.9))
                    .ignoresSafeArea()
                    .opacity(returnFadeOpacity)
                    .allowsHitTesting(false)
                }

                // 设置类页面自适应宿主（Phase 22；Phase 14 时仅横屏面板）：
                // 游戏设置与容器设置。形态由宿主按当前尺寸决定——横屏 =
                // 右侧抽屉面板（主页留在 ZStack 下层、被压暗且不可交互）、
                // 竖屏 = 整屏；打开后旋转原地变形，页面状态与滚动不丢。
                // 游戏设置内包 NavigationView，供页内子页（高级设置等）推进。
                // 顶部（Phase 26）：封面出血与安全区补偿由页面自己在物理
                // 顶坐标系里处理（见 LCGameSettingsView 封面头注释），
                // 宿主不垫、不裁。
                LCSidePanelContainer(isPresented: gameSettingsPanelItem != nil, onClose: { closeGameSettingsPanel() }) {
                    if let item = gameSettingsPanelItem {
                        NavigationView {
                            LCGameSettingsView(
                                app: item.app,
                                onOpenDataFolder: { openGameDataFolder(app: item.app) },
                                onClose: { closeGameSettingsPanel() }
                            )
                        }
                        .navigationViewStyle(StackNavigationViewStyle())
                    }
                }
                // LCSettingsView 自带 NavigationView：导航栏背景延伸覆盖
                // 状态栏带、工具栏「关闭」在栏内不撞岛（Phase 26 核查），
                // 顶部零处理、页面本体不动。
                LCSidePanelContainer(isPresented: containerSettingsPanelPresented, onClose: { containerSettingsPanelPresented = false }) {
                    LCSettingsView(onClose: { containerSettingsPanelPresented = false })
                }
            }
            .navigationBarHidden(true)
            .navigationBarProgressBar(show: $installprogressVisible, progress: $installProgressPercentage)
            .onAppear {
                if !didAppear {
                    onAppear()
                }
                consumeReturnFade()
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onChange(of: sharedModel.selectedTab) { tab in
            // 底栏已摘除：证书等深链要求去设置页时，呈现容器设置
            // （自适应宿主，与齿轮入口同一条形态规则）
            if tab == .settings {
                sharedModel.selectedTab = .apps
                presentContainerSettings()
            }
        }
        .onChange(of: scenePhase) { phase in
            // App 回到前台：先把全部游戏的容器快照按记录对齐，再 bump
            // 库刷新令牌——用户在「文件」App 里手动放进 / 删掉的数据包
            // 在切回 GC 时即按磁盘现状反映到库界面（玩家实证：此前无
            // 人 bump、也无人对齐，状态长期停在旧值）
            guard phase == .active else { return }
            for app in sharedModel.apps + sharedModel.hiddenApps {
                app.refreshContainerSelection()
            }
            libraryRefresh += 1
        }
        // onDismiss 覆盖全部退出路径（完成 / 取消 / 下滑）：导入成败、取消都要
        // 让主页按磁盘现状重算数据包状态——导入视图的 onFinished 只挂在「完成」
        // 钮上、且本层此前根本没传，其余路径关页后主页一直停在旧状态。
        .sheet(item: $datapackImportRequest, onDismiss: { libraryRefresh += 1 }) { request in
            LCDatapackImportView(request: request, apps: sharedModel.apps + sharedModel.hiddenApps)
        }
        .sheet(isPresented: $hiddenAppsPresented) {
            NavigationView {
                LCHiddenAppsView(
                    onRun: { app in
                        hiddenAppsPresented = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            runGame(app: app)
                        }
                    },
                    onSettings: { app in
                        // 先收隐藏页 sheet，等退场后再开设置 sheet（两层弹层不能同帧交接）
                        hiddenAppsPresented = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            openGameSettings(app: app)
                        }
                    },
                    onOpenDataFolder: { openGameDataFolder(app: $0) },
                    onImportDatapack: { app in
                        // 数据包 sheet 锚在本层、被隐藏页 sheet 盖住时呈不出来，
                        // 先收隐藏页再开数据包导入
                        hiddenAppsPresented = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            datapackImportRequest = LCDatapackRequest(app: app)
                        }
                    },
                    onUninstall: { appPendingUninstall = $0 },
                    onUnhide: { unhideApp(app: $0) }
                )
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
        .sheet(item: $legacySheetItem) { item in
            item.view
        }
        .confirmationDialog(uninstallDialogTitle, isPresented: uninstallDialogPresented, titleVisibility: .visible) {
            Button("lc.appList.uninstallKeepData".loc, role: .destructive) {
                if let app = appPendingUninstall {
                    performUninstall(app: app, removeData: false)
                }
                appPendingUninstall = nil
            }
            Button("lc.appList.uninstallDeleteData".loc, role: .destructive) {
                if let app = appPendingUninstall {
                    performUninstall(app: app, removeData: true)
                }
                appPendingUninstall = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                appPendingUninstall = nil
            }
        }
        .alert("lc.common.error".loc, isPresented: $errorShow){
            Button("lc.common.ok".loc, action: {
            })
            Button("lc.common.copy".loc, action: {
                copyError()
            })
        } message: {
            Text(errorInfo)
        }
        .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { fileUrls in
            Task { await startInstallApp(fileUrls[0]) }
        }, onDismiss: {
            choosingIPA = false
        })
        .alert("lc.appList.installation".loc, isPresented: $installReplaceAlert.show) {
            ForEach(installOptions, id: \.self) { installOption in
                Button(role: installOption.isReplace ? .destructive : nil, action: {
                    installReplaceAlert.close(result: installOption)
                }, label: {
                    Text(installOption.isReplace ? installOption.nameOfFolderToInstall : "lc.appList.installAsNew".loc)
                })
            
            }
            Button(role: .cancel, action: {
                installReplaceAlert.close(result: nil)
            }, label: {
                Text("lc.appList.abortInstallation".loc)
            })
        } message: {
            Text("lc.appList.installReplaceTip".loc)
        }
        .alert("lc.webView.runApp".loc, isPresented: $runWhenMultitaskAlert.show) {
            Button(role: .destructive) {
                runWhenMultitaskAlert.close(result: true)
            } label: {
                Text("lc.common.continue".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                runWhenMultitaskAlert.close(result: false)
            }
        } message: {
            Text("lc.appBanner.confirmRunWhenMultitasking".loc)
        }
        .alert("lc.appList.generatedIconStyleSelector.title".loc, isPresented:$generatedIconStyleSelector.show) {
            Button {
                generatedIconStyleSelector.close(result: .Light)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.light".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Dark)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.dark".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Original)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.original".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                generatedIconStyleSelector.close(result: nil)
            }
        }
        .textFieldAlert(
            isPresented: $webViewUrlInput.show,
            title:  "lc.appList.enterUrlTip".loc,
            text: $webViewUrlInput.initVal,
            placeholder: "scheme://",
            action: { newText in
                webViewUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                webViewUrlInput.close(result: nil)
            }
        )
        .textFieldAlert(
            isPresented: $installUrlInput.show,
            title:  "lc.appList.installUrlInputTip".loc,
            text: $installUrlInput.initVal,
            placeholder: "https://",
            action: { newText in
                installUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                installUrlInput.close(result: nil)
            }
        )
        .sheet(isPresented: $jitAlert.show, onDismiss: {
            jitAlert.close(result: false)
        }) {
            JITEnablingModal
        }
        .onChange(of: jitAlert.show) { newValue in
            sharedModel.isJITModalOpen = newValue
        }
        .fullScreenCover(isPresented: $webViewOpened) {
            LCWebView(url: $webViewURL, isPresent: $webViewOpened, itmsServicesHandler: { urlStr in
                await installFromPlist(urlStr: urlStr)
            })
        }
        .fullScreenCover(isPresented: $safariViewOpened) {
            SafariView(url: $safariViewURL)
        }
        .sheet(isPresented: $helpPresent) {
            LCHelpView(isPresent: $helpPresent)
        }
        .sheet(isPresented: $customSortViewPresent) {
            LCCustomSortView()
        }
        .onAppear() {
            if !isViewAppeared {
                if let webpageUrlStr = UserDefaults.standard.string(forKey: "webPageToOpen") {
                    Task { await openWebView(urlString: webpageUrlStr) }
                    UserDefaults.standard.set(nil, forKey: "webPageToOpen")
                }
                
                guard sharedModel.selectedTab == .apps, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .apps, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
        .onDrop(of: [.url], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let url else { return }
                Task {
                    guard let urlToOpen = await webViewUrlInput.open(initVal: url.absoluteString), urlToOpen != "" else {
                        return
                    }
                    await openWebView(urlString: urlToOpen)
                }
            }
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.InstallAppNotification)) { obj in
            if let obj2 = obj.object as? [String: Any], let installUrl = obj2["url"] as? URL {
                Task { await installFromUrl(urlStr: installUrl.absoluteString) }
            }
        }

    }
    
    var JITEnablingModal : some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    Text("lc.appBanner.waitForJitMsg".loc)
                        .padding(.vertical)
                        .id(0)
                    
                    HStack {
                        Text(jitLog)
                            .font(.system(size: 12).monospaced())
                            .fixedSize(horizontal: false, vertical: false)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .onAppear {
                    proxy.scrollTo(0)
                }
            }
            .navigationTitle("lc.appBanner.waitForJitTitle".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("lc.common.cancel".loc, role: .cancel) {
                        jitAlert.close(result: false)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        jitAlert.close(result: true)
                    } label: {
                        Text("lc.appBanner.jitLaunchNow".loc)
                    }
                }
            }
        }
    }
    
    func onOpenWebViewTapped() async {
        guard let urlToOpen = await webViewUrlInput.open(), urlToOpen != "" else {
            return
        }
        await openWebView(urlString: urlToOpen)
        
    }
    func onAppear() {
        // 联网封面抓取成功 → bump 既有库刷新令牌，主页随下一次 body 按磁盘
        // 重算封面（Phase 19；服务侧不另设通知，回调只汇到这条既有通道）
        LCCoverFetchService.shared.onCoverUpdated = {
            self.libraryRefresh += 1
        }
        for app in sharedModel.apps {
            app.delegate = self
        }
        for app in sharedModel.hiddenApps {
            app.delegate = self
        }
        didAppear = true
    }
    
    
    func openWebView(urlString: String) async {
        guard var urlToOpen = URLComponents(string: urlString), urlToOpen.url != nil else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        if urlToOpen.scheme == nil || urlToOpen.scheme! == "" {
            urlToOpen.scheme = "https"
        }
        
        if urlToOpen.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: urlString)
            return
        }
        
        if urlToOpen.scheme != "https" && urlToOpen.scheme != "http" {
            var appToLaunch : LCAppModel? = nil
            var appListsToConsider = [sharedModel.apps]
            if sharedModel.isHiddenAppUnlocked || !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
                appListsToConsider.append(sharedModel.hiddenApps)
            }
            appLoop:
            for appList in appListsToConsider {
                for app in appList {
                    if let schemes = app.appInfo.urlSchemes() {
                        for scheme in schemes {
                            if let scheme = scheme as? String, scheme == urlToOpen.scheme {
                                appToLaunch = app
                                break appLoop
                            }
                        }
                    }
                }
            }


            guard let appToLaunch = appToLaunch else {
                errorInfo = "lc.appList.schemeCannotOpenError %@".localizeWithFormat(urlToOpen.scheme!)
                errorShow = true
                return
            }
            
            if appToLaunch.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    return
                }
            }
            
            do {
                try await appToLaunch.runApp(urlStr: urlToOpen.url!.absoluteString)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            
            return
        }
        webViewURL = urlToOpen.url!
        if webViewOpened {
            webViewOpened = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
                webViewOpened = true
            })
        } else {
            webViewOpened = true
        }
    }


    
    func startInstallApp(_ fileUrl:URL) async {
        do {
            self.installprogressVisible = true
            try await installIpaFile(fileUrl)
            try FileManager.default.removeItem(at: fileUrl)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            self.installprogressVisible = false
        }
    }
    
    nonisolated func decompress(_ path: String, _ destination: String ,_ progress: Progress) async -> Int32 {
        extract(path, destination, progress)
    }
    
    func installIpaFile(_ url:URL) async throws {
        let fm = FileManager()
        
        let installProgress = Progress.discreteProgress(totalUnitCount: 100)
        self.installProgressPercentage = 0.0
        self.installObserver = installProgress.observe(\.fractionCompleted) { p, v in
            DispatchQueue.main.async {
                self.installProgressPercentage = Float(p.fractionCompleted)
            }
        }
        let decompressProgress = Progress.discreteProgress(totalUnitCount: 100)
        installProgress.addChild(decompressProgress, withPendingUnitCount: 80)
        let payloadPath = fm.temporaryDirectory.appendingPathComponent("Payload")
        if fm.fileExists(atPath: payloadPath.path) {
            try fm.removeItem(at: payloadPath)
        }
        
        // decompress
        guard await decompress(url.path, fm.temporaryDirectory.path, decompressProgress) == 0 else {
            throw "lc.appList.urlFileIsNotIpaError".loc
        }

        let payloadContents = try fm.contentsOfDirectory(atPath: payloadPath.path)
        var appBundleName : String? = nil
        for fileName in payloadContents {
            if fileName.hasSuffix(".app") {
                appBundleName = fileName
                break
            }
        }
        guard let appBundleName = appBundleName else {
            throw "lc.appList.bundleNotFondError".loc
        }

        let appFolderPath = payloadPath.appendingPathComponent(appBundleName)
        
        guard let newAppInfo = LCAppInfo(bundlePath: appFolderPath.path) else {
            throw "lc.appList.infoPlistCannotReadError".loc
        }

        var appRelativePath = "\(newAppInfo.bundleIdentifier()!.sanitizeNonACSII()).app"
        var outputFolder = LCPath.bundlePath.appendingPathComponent(appRelativePath)
        var appToReplace : LCAppModel? = nil
        // Folder exist! show alert for user to choose which bundle to replace
        var sameBundleIdApp = sharedModel.apps.filter { app in
            return app.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
        }
        if sameBundleIdApp.count == 0 {
            sameBundleIdApp = sharedModel.hiddenApps.filter { app in
                return app.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
            }
            
            // we found a hidden app, we need to authenticate before proceeding
            if sameBundleIdApp.count > 0 && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        self.installprogressVisible = false
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    self.installprogressVisible = false
                    return
                }
            }
            
        }
        
        if fm.fileExists(atPath: outputFolder.path) || sameBundleIdApp.count > 0 {
            appRelativePath = "\(newAppInfo.bundleIdentifier()!)_\(Int(CFAbsoluteTimeGetCurrent())).app"
            
            self.installOptions = [AppReplaceOption(isReplace: false, nameOfFolderToInstall: appRelativePath)]
            
            for app in sameBundleIdApp {
                self.installOptions.append(AppReplaceOption(isReplace: true, nameOfFolderToInstall: app.appInfo.relativeBundlePath, appToReplace: app))
            }

            guard let installOptionChosen = await installReplaceAlert.open() else {
                // user cancelled
                self.installprogressVisible = false
                try fm.removeItem(at: payloadPath)
                return
            }
            
            if let appToReplace = installOptionChosen.appToReplace, appToReplace.uiIsShared {
                outputFolder = LCPath.lcGroupBundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            } else {
                outputFolder = LCPath.bundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            }
            appRelativePath = installOptionChosen.nameOfFolderToInstall
            appToReplace = installOptionChosen.appToReplace
            if installOptionChosen.isReplace {
                try fm.removeItem(at: outputFolder)
            }
        }
        // Move it!
        try fm.moveItem(at: appFolderPath, to: outputFolder)
        let finalNewApp = LCAppInfo(bundlePath: outputFolder.path)
        finalNewApp?.relativeBundlePath = appRelativePath
        
        guard let finalNewApp else {
            errorInfo = "lc.appList.appInfoInitError".loc
            errorShow = true
            return
        }
        
        // patch and sign it
        var signError : String? = nil
        var signSuccess = false
        await withUnsafeContinuation({ c in
            if appToReplace?.uiDontSign ?? false || LCUtils.appGroupUserDefault.bool(forKey: "LCDontSignApp") {
                finalNewApp.dontSign = true
            }
            finalNewApp.patchExecAndSignIfNeed(completionHandler: { success, error in
                signError = error
                signSuccess = success
                c.resume()
            }, progressHandler: { signProgress in
                installProgress.addChild(signProgress!, withPendingUnitCount: 20)
            }, forceSign: false)
        })
        
        // we leave it unsigned even if signing failed
        if let signError {
            if signSuccess {
                errorInfo = "\("lc.appList.signSuccessWithError".loc)\n\n\(signError)"
            } else {
                errorInfo = signError.loc
            }
            errorShow = true
        }
        
        if let appToReplace {
            // copy previous configration to new app
            finalNewApp.autoSaveDisabled = true
            finalNewApp.isLocked = appToReplace.appInfo.isLocked
            finalNewApp.isHidden = appToReplace.appInfo.isHidden
            finalNewApp.isJITNeeded = appToReplace.appInfo.isJITNeeded
            finalNewApp.isShared = appToReplace.appInfo.isShared
            finalNewApp.spoofSDKVersion = appToReplace.appInfo.spoofSDKVersion
            finalNewApp.doSymlinkInbox = appToReplace.appInfo.doSymlinkInbox
            finalNewApp.containerInfo = appToReplace.appInfo.containerInfo
            finalNewApp.tweakFolder = appToReplace.appInfo.tweakFolder
            finalNewApp.selectedLanguage = appToReplace.appInfo.selectedLanguage
            finalNewApp.dataUUID = appToReplace.appInfo.dataUUID
            finalNewApp.orientationLock = appToReplace.appInfo.orientationLock
            finalNewApp.dontInjectTweakLoader = appToReplace.appInfo.dontInjectTweakLoader
            finalNewApp.hideLiveContainer = appToReplace.appInfo.hideLiveContainer
            finalNewApp.dontLoadTweakLoader = appToReplace.appInfo.dontLoadTweakLoader
            finalNewApp.doUseLCBundleId = appToReplace.appInfo.doUseLCBundleId
            finalNewApp.fixFilePickerNew = appToReplace.appInfo.fixFilePickerNew
            finalNewApp.fixLocalNotification = appToReplace.appInfo.fixLocalNotification
            finalNewApp.lastLaunched = appToReplace.appInfo.lastLaunched
            finalNewApp.jitLaunchScriptJs = appToReplace.appInfo.jitLaunchScriptJs
            finalNewApp.multitaskSpecified = appToReplace.appInfo.multitaskSpecified
            finalNewApp.classicMode = appToReplace.appInfo.classicMode
            finalNewApp.autoSaveDisabled = false
            finalNewApp.save()
        } else {
            // enable SDK version spoof by defalut
            finalNewApp.spoofSDKVersion = true
        }
        finalNewApp.installationDate = Date.now
        
        DispatchQueue.main.async {
            if let appToReplace {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self)
                
                if appToReplace.uiIsHidden {
                    sharedModel.hiddenApps.removeAll { $0 == appToReplace }
                    sharedModel.hiddenApps.append(newAppModel)
                } else {
                    sharedModel.apps.removeAll { $0 == appToReplace }
                    sharedModel.apps.append(newAppModel)
                }

            } else {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self)
                sharedModel.apps.append(newAppModel)
                
                // add url schemes
                if let urlSchemes = finalNewApp.urlSchemes(), urlSchemes.count > 0 {
                    UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                        .addObjects(from: urlSchemes as! [Any])
                }
            }

            // 导入完成预抓封面（Phase 19）：解析链落到图标且能解析出标题 ID
            // 时后台抓一次官方主视觉，结果走服务回调 bump libraryRefresh
            LCCoverFetchService.shared.prefetch(appInfo: finalNewApp)
            self.installprogressVisible = false
        }
    }

    func startInstallFromUrl() async {
        guard let installUrlStr = await installUrlInput.open(), installUrlStr.count > 0 else {
            return
        }
        if let url = URL(string:installUrlStr), url.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: installUrlStr)
            return
        }
        await installFromUrl(urlStr: installUrlStr)
    }
    
    func installFromPlist(urlStr: String) async {
        if self.installprogressVisible {
            return
        }
        
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        var plistUrlStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if plistUrlStr.lowercased().hasPrefix("itms-services://") {
            if let urlComponents = URLComponents(string: plistUrlStr),
               let queryItems = urlComponents.queryItems,
               let urlParam = queryItems.first(where: { $0.name == "url" })?.value {
                plistUrlStr = urlParam
            } else {
                errorInfo = "lc.appList.plistInvalidError".loc
                errorShow = true
                return
            }
        }
        
        guard let plistUrl = URL(string: plistUrlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: plistUrl)
            
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let items = plist["items"] as? [[String: Any]],
                  let firstItem = items.first,
                  let assets = firstItem["assets"] as? [[String: Any]] else {
                errorInfo = "lc.appList.plistParseError".loc
                errorShow = true
                return
            }
            
            var ipaUrlStr: String?
            for asset in assets {
                if let kind = asset["kind"] as? String, kind == "software-package",
                   let url = asset["url"] as? String {
                    ipaUrlStr = url
                    break
                }
            }
            
            guard let ipaUrlStr else {
                errorInfo = "lc.appList.plistNoIpaError".loc
                errorShow = true
                return
            }
            
            await installFromUrl(urlStr: ipaUrlStr)
            
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    func installFromUrl(urlStr: String) async {
        // ignore any install request if we are installing another app
        if self.installprogressVisible {
            return
        }
        
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        guard var installUrl = URL(string: urlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        self.installprogressVisible = true
        defer {
            self.installprogressVisible = false
        }
        
        if installUrl.isFileURL {
            // install from local, we directly call local install method
            let fileExtension = installUrl.pathExtension.lowercased()
            if fileExtension != "ipa" && fileExtension != "tipa" {
                errorInfo = "lc.appList.urlFileIsNotIpaError".loc
                errorShow = true
                return
            }
            
            let fm = FileManager.default
            var didStartAccessing = false
            if !fm.isReadableFile(atPath: installUrl.path),
               let bookmarkData = LCUtils.appGroupUserDefault.data(forKey: "LCLaunchExtensionFileBookmark") {
                do {
                    var isStale = false
                    let resolvedURL = try URL(
                        resolvingBookmarkData: bookmarkData,
                        options: URL.BookmarkResolutionOptions(rawValue: 1 << 10),
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    installUrl = resolvedURL
                    didStartAccessing = resolvedURL.startAccessingSecurityScopedResource()
                } catch {
                    errorInfo =  "Failed to resolve shared IPA bookmark: \(error.localizedDescription)"
                    errorShow = true
                    return
                }
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                didStartAccessing = installUrl.startAccessingSecurityScopedResource()
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                errorInfo = "lc.appList.ipaAccessError".loc
                errorShow = true
                return
            }
            
            defer {
                if didStartAccessing {
                    installUrl.stopAccessingSecurityScopedResource()
                }
            }
            
            do {
                try await installIpaFile(installUrl)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            
            do {
                // delete ipa if it's in inbox
                var shouldDelete = false
                if let documentsDirectory = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let inboxURL = documentsDirectory.appendingPathComponent("Inbox")
                    shouldDelete = installUrl.deletingLastPathComponent().standardizedFileURL == inboxURL.standardizedFileURL
                }
                if shouldDelete {
                    try fm.removeItem(at: installUrl)
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            return
        }
        
        do {
            let fileManager = FileManager.default
            let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(installUrl.lastPathComponent)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            
            try await downloadHelper.download(url: installUrl, to: destinationURL)
            if downloadHelper.cancelled {
                return
            }
            try await installIpaFile(destinationURL)
            try fileManager.removeItem(at: destinationURL)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        
    }
    
    func removeApp(app: LCAppModel) {
        DispatchQueue.main.async {
            sharedModel.apps.removeAll { now in
                return app == now
            }
            sharedModel.hiddenApps.removeAll { now in
                return app == now
            }

        }
    }

    // MARK: 游戏库卡片动作（与横幅 runButtonTapped / 长按菜单同语义，恒串行单开）

    func runGame(app: LCAppModel) {
        Task {
            if app.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    return
                }
            }
            do {
                try await app.runApp()
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
        }
    }

    func openGameDataFolder(app: LCAppModel) {
        guard let folderName = app.uiSelectedContainer?.folderName,
              let url = URL(string: "shareddocuments://\(LCPath.dataPath.path)/\(folderName)") else {
            return
        }
        UIApplication.shared.open(url)
    }

    func performUninstall(app: LCAppModel, removeData: Bool) {
        do {
            guard let bundlePath = app.appInfo.bundlePath() else {
                throw CocoaError(.fileNoSuchFile)
            }
            let fm = FileManager.default
            try fm.removeItem(atPath: bundlePath)
            removeApp(app: app)
            if removeData {
                for container in app.appInfo.containers {
                    let dataUUID = container.folderName
                    try? fm.removeItem(at: LCPath.dataPath.appendingPathComponent(dataUUID))
                    LCUtils.removeAppKeychain(dataUUID: dataUUID)
                    sharedModel.appDataFolderNames.removeAll { $0 == dataUUID }
                }
            }
            // 顺带清扫孤儿空壳：该游戏若有不在任何记录里的历史孤儿夹，
            // 上面的按记录删夹够不着；它不被任何应用记录引用，满足空壳
            // 条件即一并回收。有真实内容的目录（含本游戏保留数据的
            // 容器）一律不动。
            let sweptShells = LCContainer.sweepOrphanContainerShells(apps: sharedModel.apps + sharedModel.hiddenApps)
            if !sweptShells.isEmpty {
                sharedModel.appDataFolderNames.removeAll { sweptShells.contains($0) }
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    func changeAppVisibility(app: LCAppModel) {
        DispatchQueue.main.async {
            if app.appInfo.isHidden {
                sharedModel.apps.removeAll { now in
                    return app == now
                }
                if !sharedModel.hiddenApps.contains(app) {
                    sharedModel.hiddenApps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .removeObjects(in: app.appInfo.urlSchemes() as! [Any])
            } else {
                sharedModel.hiddenApps.removeAll { now in
                    return app == now
                }
                if !sharedModel.apps.contains(app) {
                    sharedModel.apps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .addObjects(from: app.appInfo.urlSchemes() as! [Any])
            }
            
        }
    }
    
    func launchAppWithBundleId(bundleId : String, container : String?, urlStr: String? = nil, forceJIT: Bool? = nil) async {
        if bundleId == "" {
            return
        }
        var appFound : LCAppModel? = nil
        var isFoundAppLocked = false
        for app in sharedModel.apps {
            if app.appInfo.relativeBundlePath == bundleId {
                appFound = app
                if app.appInfo.isLocked {
                    isFoundAppLocked = true
                }
                break
            }
        }
        if appFound == nil && !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
            for app in sharedModel.hiddenApps {
                if app.appInfo.relativeBundlePath == bundleId {
                    appFound = app
                    isFoundAppLocked = true
                    break
                }
            }
        }
        
        if appFound == nil && bundleId == "builtinSideStore" {
            appFound = LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared)
        }
        
        if isFoundAppLocked && !sharedModel.isHiddenAppUnlocked {
            do {
                let result = try await LCUtils.authenticateUser()
                if !result {
                    return
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
                return
            }
        }
        
        guard let appFound else {
            errorInfo = "lc.appList.appNotFoundError".loc
            errorShow = true
            return
        }

        do {
            try await appFound.runApp(multitask: nil, containerFolderName: container, urlStr: urlStr, forceJIT: forceJIT)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        
    }
    
    func authenticateUser() async {
        do {
            if !(try await LCUtils.authenticateUser()) {
                return
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
    }
    
    func jitLaunch(appName: String, classicMode: UInt) async {
        await jitLaunch(withScript: "", appName: appName, classicMode: classicMode)
    }

    func jitLaunch(withScript script: String, appName: String, classicMode: UInt) async {
        await MainActor.run {
            jitLog = ""
        }
        let enableJITTask = Task {
            
            let _ = await LCUtils.askForJIT(withScript: script, appName: appName, classicMode: classicMode) { newMsg in
                Task { await MainActor.run {
                    self.jitLog += "\(newMsg)\n"
                }}
            }
            guard let _ = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) else {
                return
            }
        }
        guard let result = await jitAlert.open(), result else {
            UserDefaults.standard.removeObject(forKey: "selected")
            enableJITTask.cancel()
            return
        }
        LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)

    }
    
    func jitLaunch(withPID pid: Int, withScript script: String? = nil, appName: String) async {
        await MainActor.run {
            let encodedData = script?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                
            
            if let jitEnabler = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) {
                if jitEnabler == .StosDebug || jitEnabler == .StosDebugLC {
                    let encoded = encodedData.map { "&script=\($0)" } ?? ""
                    if jitEnabler == .StosDebugLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stosdebug") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            if var url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&relaunchApp=false& forcePID=true\(encoded)") {
                                Task { await openWebView(urlString: url.absoluteString) }
                            }
                        } else {
                            errorInfo = "StosDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        if var url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&forcePID=true\(encoded)") {
                            UIApplication.shared.open(url)
                        }
                    }
                    return
                }
                
                let encoded = encodedData.map { "&script-data=\($0)" } ?? ""
                if let url = URL(string: "stikjit://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)&pid=\(pid)\(encoded)") {
                    if jitEnabler == .StikJITLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stikjit") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            Task { await openWebView(urlString: url.absoluteString) }
                        } else {
                            errorInfo = "StikDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
    }

    func showRunWhenMultitaskAlert() async -> Bool? {
        return await runWhenMultitaskAlert.open()
    }
    
    func installMdm(data: Data) {
        safariViewURL = URL(string:"data:application/x-apple-aspen-config;base64,\(data.base64EncodedString())")!
        safariViewOpened = true
    }
    
    /// LCAppBannerDelegate 的遗留入口（上游 UIKit 横幅的「打开设置」）：横幅
    /// representable 在本 fork 的界面里已无实例化点，此入口仅为协议完整性保留，
    /// 呈现统一走 sheet，不再有第二套 push 机制。
    func openNavigationView(view: AnyView) {
        legacySheetItem = LCLegacySheetItem(view: view)
    }
    
    func promptForGeneratedIconStyle() async -> GeneratedIconStyle? {
        if #available(iOS 18.0, *) {
            return await generatedIconStyleSelector.open()
        } else {
            return .Light
        }
        
    }
    
    /// LCAppModelDelegate 的关页钩子（名称沿用上游协议）：模型层在隐藏应用等
    /// 路径上调它收掉当前页。这里统一收掉库内全部弹层（如在高级设置里隐藏
    /// 当前游戏 → 设置页随之关闭，语义不变）。
    func closeNavigationView() {
        gameSettingsPanelItem = nil
        containerSettingsPanelPresented = false
        hiddenAppsPresented = false
        legacySheetItem = nil
    }
    
    func copyError() {
        UIPasteboard.general.string = errorInfo
    }
    
    func handleURL(url : URL) {
        if url.isFileURL {
            Task { await installFromUrl(urlStr: url.absoluteString) }
            return
        }
        
        if url.scheme == "sidestore" && UserDefaults.sideStoreExist() {
            UserDefaults.standard.setValue(url.absoluteString, forKey: "launchAppUrlScheme")
            LCUtils.openSideStore(delegate: self)
            return
        }
        
        if url.host == "open-web-page" || url.host == "open-url" {
            if let urlComponent = URLComponents(url: url, resolvingAgainstBaseURL: false), let queryItem = urlComponent.queryItems?.first {
                if queryItem.value?.isEmpty ?? true {
                    return
                }
                
                if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                   let decodedUrl = String(data: decodedData, encoding: .utf8) {
                    Task { await openWebView(urlString: decodedUrl) }
                }
            }
        } else if url.host == "gamecase-launch" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var bundleId : String? = nil
                var containerName : String? = nil
                var forceJIT: Bool? = nil
                var urlStr: String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "bundle-name", let bundleId1 = queryItem.value {
                        bundleId = bundleId1
                    } else if queryItem.name == "container-folder-name", let containerName1 = queryItem.value {
                        containerName = containerName1
                    } else if queryItem.name == "jit", let forceJIT1 = queryItem.value {
                        if forceJIT1 == "true" {
                            forceJIT = true
                        } else if forceJIT1 == "false" {
                            forceJIT = false
                        }
                    } else if queryItem.name == "open-url" {
                        if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                           let decodedUrl = String(data: decodedData, encoding: .utf8) {
                            urlStr = decodedUrl
                        }
                    }
                }
                if let bundleId, bundleId != "ui"{
                    Task { await launchAppWithBundleId(bundleId: bundleId, container: containerName, urlStr: urlStr, forceJIT: forceJIT) }
                }
            }
        } else if url.host == "install" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var installUrl : String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "url", let installUrl1 = queryItem.value {
                        installUrl = installUrl1
                    }
                }
                if let installUrl {
                    Task { await installFromUrl(urlStr: installUrl) }
                }
            }
        }
    }
    
}

extension View {
    func apply<V: View>(@ViewBuilder _ block: (Self) -> V) -> V { block(self) }
}

// MARK: - 游戏库封面信息（专用容器换皮）

enum LCGameLibraryInfo {
    /// 客体包内横版封面的候选文件名（按优先级排，大小写不敏感匹配 .app 根目录）。
    static let bannerCandidateNames = ["LCBanner.jpg", "LCBanner.png", "banner.jpg", "banner.png", "cover.jpg", "cover.png", "keyart.jpg", "keyart.png", "header.jpg", "header.png", "capsule.jpg", "capsule.png", "hero.jpg", "hero.png", "poster.jpg", "poster.png", "artwork.jpg", "artwork.png"]

    /// 客体 IPA 自带的横版封面：扫 .app 根目录的图片，先按候选名优先级找，
    /// 再兜底取其余图片里面积最大的一张；每张都要过横版校验（宽>高、宽≥600、
    /// 长宽比≤3），方形图标与细长条按钮图不会被误拿。名字/尺寸都不解码整图，
    /// 先用 ImageIO 只读像素尺寸过滤，命中后才真正加载。
    /// 注：我们两款 nxnative 客体包内实测没有横版图（根目录只有方形 AppIcon 与
    /// 只含 AppIcon 的 Assets.car），此扫描主要为导入他人 IPA 时读对方自带封面。
    static func guestLandscapeCover(for appInfo: LCAppInfo) -> UIImage? {
        guard let bundlePath = appInfo.bundlePath(),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: bundlePath) else {
            return nil
        }
        let imageExts: Set<String> = ["png", "jpg", "jpeg"]
        let files = entries.filter {
            imageExts.contains(($0 as NSString).pathExtension.lowercased())
                && !$0.lowercased().hasPrefix("appicon")
        }
        guard !files.isEmpty else {
            return nil
        }
        // 候选名优先（按 bannerCandidateNames 的顺序），其余按文件名排稳
        let lowered = Dictionary(uniqueKeysWithValues: files.map { ($0.lowercased(), $0) })
        var ordered: [String] = []
        for candidate in bannerCandidateNames {
            if let real = lowered[candidate.lowercased()] {
                ordered.append(real)
            }
        }
        let candidateSet = Set(ordered)
        let rest = files.filter { !candidateSet.contains($0) }.sorted()
        // 候选名逐个验；兜底组里取通过校验且面积最大的
        for name in ordered {
            if let image = landscapeImage(at: (bundlePath as NSString).appendingPathComponent(name)) {
                return image
            }
        }
        var best: (image: UIImage, area: CGFloat)?
        for name in rest {
            let path = (bundlePath as NSString).appendingPathComponent(name)
            guard let size = imagePixelSize(atPath: path), isLandscapeCoverSize(size) else {
                continue
            }
            let area = size.width * size.height
            if area > (best?.area ?? 0), let image = UIImage(contentsOfFile: path) {
                best = (image, area)
            }
        }
        return best?.image
    }

    /// 横版封面尺寸门槛：横向、够大、又不能是细长条
    private static func isLandscapeCoverSize(_ size: CGSize) -> Bool {
        return size.width > size.height && size.width >= 600 && size.width / size.height <= 3
    }

    private static func landscapeImage(at path: String) -> UIImage? {
        guard let size = imagePixelSize(atPath: path), isLandscapeCoverSize(size) else {
            return nil
        }
        return UIImage(contentsOfFile: path)
    }

    /// 只读图片像素尺寸（不整图解码）
    private static func imagePixelSize(atPath path: String) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber else {
            return nil
        }
        return CGSize(width: width.doubleValue, height: height.doubleValue)
    }

    /// 宿主内置封面：LiveContainerSwiftUI/GameCovers/cover-<标题ID>.jpg，
    /// 该目录属 LiveContainerSwiftUI 同步根组，资源打进 LiveContainerSwiftUI.framework 的 bundle。
    static func bundledCoverImage(for appInfo: LCAppInfo) -> UIImage? {
        guard let titleId = titleId(from: appInfo) else {
            return nil
        }
        let resourceName = "cover-\(titleId)"
        // 先本模块 framework 的 bundle（LCAppModel 为本模块类作锚），再兜底主 app bundle；
        // 同步组资源一般摊平在 bundle 根，也兼容 GameCovers 子目录形态。
        for bundle in [Bundle(for: LCAppModel.self), Bundle.main] {
            for subdirectory in [nil, "GameCovers"] {
                if let url = bundle.url(forResource: resourceName, withExtension: "jpg", subdirectory: subdirectory),
                   let image = UIImage(contentsOfFile: url.path) {
                    return image
                }
            }
        }
        return nil
    }

    /// 从客体 bundle id 提取标题 ID：形如 org.nxnative.010013c00e930000，末段 16 位十六进制即标题 ID（大小写归一为大写）。
    static func titleId(from appInfo: LCAppInfo) -> String? {
        guard let bundleId = appInfo.bundleIdentifier()?.lowercased() else {
            return nil
        }
        let components = bundleId.split(separator: ".").map(String.init)
        let isTitleId: (String) -> Bool = { $0.count == 16 && $0.allSatisfy(\.isHexDigit) }
        if let last = components.last, isTitleId(last) {
            return last.uppercased()
        }
        return components.first(where: isTitleId)?.uppercased()
    }

    /// 封面来源（设置页封面行显示用，顺序即解析优先级）
    enum BannerSource {
        case custom   // 玩家自定义（宿主 Documents/CustomCovers）
        case guest    // 客体 IPA 自带横版图
        case bundled  // 宿主内置原画
        case fetched  // 联网获取（宿主 Documents/FetchedCovers，按标题 ID 抓的官方主视觉）
        case icon     // 无横版图，卡片退回应用图标兜底

        var displayName: String {
            switch self {
            case .custom: return "lc.appList.coverSourceCustom".loc
            case .guest: return "lc.appList.coverSourceGuest".loc
            case .bundled: return "lc.appList.coverSourceBundled".loc
            case .fetched: return "lc.appList.coverSourceFetched".loc
            case .icon: return "lc.appList.coverSourceIcon".loc
            }
        }
    }

    /// 玩家自定义封面：宿主 Documents/CustomCovers/<bundleId>.jpg，用户显式设置即最高优先
    static func customCoverImage(for appInfo: LCAppInfo) -> UIImage? {
        guard let bundleId = appInfo.bundleIdentifier() else {
            return nil
        }
        return LCCustomCoverStore.load(forBundleIdentifier: bundleId)
    }

    /// 联网抓取缓存：宿主 Documents/FetchedCovers/<bundleId>.jpg（抓取链见 LCFetchedCover）
    static func fetchedCoverImage(for appInfo: LCAppInfo) -> UIImage? {
        guard let bundleId = appInfo.bundleIdentifier() else {
            return nil
        }
        return LCFetchedCoverStore.load(forBundleIdentifier: bundleId)
    }

    /// 封面解析（单一入口，主页 hero / 网格卡 / 横屏轮播 / 最近游玩 / 设置页共用）：
    /// 自定义封面 → 客体 IPA 自带横版封面 → 宿主内置原画 → 联网抓取缓存
    /// → nil（卡片再退回图标兜底）。
    /// 本链不做图片缓存：每次求值都从磁盘现读现解码，换自定义封面后各处随下一次
    /// 界面刷新（关设置页、状态变更）即为新图，无需额外失效处理。
    static func bannerResolution(for appInfo: LCAppInfo) -> (image: UIImage?, source: BannerSource) {
        if let custom = customCoverImage(for: appInfo) {
            return (custom, .custom)
        }
        if let guest = guestLandscapeCover(for: appInfo) {
            return (guest, .guest)
        }
        if let bundled = bundledCoverImage(for: appInfo) {
            return (bundled, .bundled)
        }
        if let fetched = fetchedCoverImage(for: appInfo) {
            return (fetched, .fetched)
        }
        return (nil, .icon)
    }

    static func bannerImage(for appInfo: LCAppInfo) -> UIImage? {
        return bannerResolution(for: appInfo).image
    }

    static func defaultContainer(for app: LCAppModel) -> LCContainer? {
        return app.uiSelectedContainer ?? app.uiContainers.first
    }

    /// 容器数据包探测（全仓唯一探测口，状态机 / 旧二态 / 导入链复核
    /// 共用）：枚举容器 Documents 的真实条目再认形态，不靠写死路径的
    /// 大小写运气——NSP 工具产出的镜像本名是 RomFS.img，iOS 上精确名
    /// 查找（fileExists 拼 "romfs.img"）永远找不到它（客体引擎
    /// dm/ios main.m 的 romfs_document_images 同注，引擎靠枚举 +
    /// caseInsensitiveCompare 认任意大小写、精确小写名优先）。文件夹
    /// 形态只认精确名 romfs（引擎 romfs_locate 对文件夹就是精确名
    /// fileExists，名字大小写不对引擎同样不认，状态不许先认）。
    struct DatapackProbe {
        /// 名为 romfs.img 的条目真实 URL（优先精确小写名，
        /// 其次任意大小写）；Documents 里没有这个名字时为 nil
        var imageEntry: URL?
        /// imageEntry 是文件夹（放错形态）而非文件
        var imageIsDirectory = false
        /// 名为 romfs 的文件夹真实 URL；不存在或同名不是文件夹时为 nil
        var folderEntry: URL?
        /// 可当数据包文件用的条目（是文件形态的 romfs.img）
        var imageFile: URL? {
            imageEntry != nil && !imageIsDirectory ? imageEntry : nil
        }
    }

    static func probeDatapack(container: LCContainer?) -> DatapackProbe {
        var probe = DatapackProbe()
        guard let container else {
            return probe
        }
        let documents = container.containerURL.appendingPathComponent("Documents")
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: documents.path) else {
            return probe
        }
        let imageNames = names.filter { $0.lowercased() == "romfs.img" }
            .sorted { a, b in
                let (ea, eb) = (a == "romfs.img", b == "romfs.img")
                return ea != eb ? ea : a < b
            }
        if let name = imageNames.first {
            let url = documents.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                probe.imageEntry = url
                probe.imageIsDirectory = isDir.boolValue
            }
        }
        if names.contains("romfs") {
            let url = documents.appendingPathComponent("romfs")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                probe.folderEntry = url
            }
        }
        return probe
    }

    /// 数据包是否就绪（存在口径）：探测到 romfs.img 条目（任意大小
    /// 写、文件或同名文件夹）或 romfs 文件夹即算有包；完好与否由
    /// gameState 的三态细判，本二态只答有没有（与旧 fileExists
    /// 口径对同名文件夹返 true 的行为一致）。
    static func isDatapackReady(container: LCContainer?) -> Bool {
        let probe = probeDatapack(container: container)
        return probe.imageEntry != nil || probe.folderEntry != nil
    }

    /// 数据包就绪的共用求值入口：先按 appInfo 记录对齐容器快照（与
    /// Phase 7 设置页 loadState 同方），再解析容器求值。全部就绪读数
    /// （库主页卡片 / 状态点、游戏设置页、数据包导入页复核）都走这里，
    /// 不再各自拿快照直查——快照与记录脱钩时直查读的是错误容器：包
    /// 已放进实际启动的容器、游戏能跑，库界面却对着另一个空容器长期
    /// 报「缺数据包」（玩家实证）。refreshContainerSelection 带变更
    /// 守卫，对齐后重复调用零发布，求值期调用安全收敛。
    static func datapackReady(for app: LCAppModel) -> Bool {
        app.refreshContainerSelection()
        return isDatapackReady(container: defaultContainer(for: app))
    }

    /// 读默认容器偏好 plist 里的按键皮肤设置并映射为显示名；无皮肤档案的游戏返回 nil（卡上只显示通用信息）
    static func skinDisplayName(container: LCContainer?, bundleIdentifier: String) -> String? {
        guard let container else {
            return nil
        }
        let prefsURL = container.containerURL
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent("\(bundleIdentifier).plist")
        guard let dict = NSDictionary(contentsOf: prefsURL) as? [String: Any] else {
            return nil
        }
        if let raw = dict["launcher.DM_SILK_SKIN"] as? String, let idx = Int(raw) {
            let names = ["lc.appList.skinGlass".loc, "lc.appList.skinThorn".loc, "lc.appList.skinBadge".loc, "lc.appList.skinIron".loc]
            if names.indices.contains(idx) {
                return names[idx]
            }
        }
        if let raw = dict["launcher.DM_HADES_SKIN"] as? String, let idx = Int(raw) {
            let names = ["lc.appList.skinGlass".loc, "lc.appList.skinMoon".loc, "lc.appList.skinMoonBadge".loc]
            if names.indices.contains(idx) {
                return names[idx]
            }
        }
        return nil
    }
}

