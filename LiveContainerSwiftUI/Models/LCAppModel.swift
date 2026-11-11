import Foundation

protocol LCAppModelDelegate {
    func closeNavigationView()
    func changeAppVisibility(app : LCAppModel)
    func jitLaunch(appName: String, classicMode: UInt) async
    func jitLaunch(withScript script: String, appName: String, classicMode: UInt) async
    func jitLaunch(withPID pid: Int, withScript script: String?, appName: String) async
    func showRunWhenMultitaskAlert() async -> Bool?
}

class LCAppModel: ObservableObject, Hashable {
    
    @Published var appInfo : LCAppInfo
    
    @Published var isAppRunning = false
    @Published var isSigningInProgress = false
    @Published var signProgress = 0.0
    private var observer : NSKeyValueObservation?
    
    @Published var uiIsJITNeeded : Bool {
        didSet {
            appInfo.isJITNeeded = uiIsJITNeeded
        }
    }
    @Published var uiClassicMode : Bool {
        didSet {
            appInfo.classicMode = uiClassicMode
        }
    }
    @Published var uiIsHidden : Bool
    @Published var uiIsLocked : Bool
    @Published var uiIsShared : Bool
    @Published var uiDefaultDataFolder : String?
    @Published var uiContainers : [LCContainer]
    @Published var uiSelectedContainer : LCContainer?
    @Published var uiIs32bit : Bool
    @Published var uiIs32bitEmulator : Bool
    @Published var uiTweakFolder : String? {
        didSet {
            appInfo.tweakFolder = uiTweakFolder
        }
    }
    @Published var uiDoSymlinkInbox : Bool {
        didSet {
            appInfo.doSymlinkInbox = uiDoSymlinkInbox
        }
    }
    @Published var uiUseLCBundleId : Bool {
        didSet {
            appInfo.doUseLCBundleId = uiUseLCBundleId
        }
    }
    
    @Published var uiFixFilePickerNew : Bool {
        didSet {
            appInfo.fixFilePickerNew = uiFixFilePickerNew
        }
    }
    @Published var uiFixLocalNotification : Bool {
        didSet {
            appInfo.fixLocalNotification = uiFixLocalNotification
        }
    }
    
    @Published var uiHideLiveContainer : Bool {
        didSet {
            appInfo.hideLiveContainer = uiHideLiveContainer
        }
    }
    @Published var uiTweakLoaderInjectFailed : Bool
    @Published var uiDontInjectTweakLoader : Bool {
        didSet {
            appInfo.dontInjectTweakLoader = uiDontInjectTweakLoader
        }
    }
    @Published var uiDontLoadTweakLoader : Bool {
        didSet {
            appInfo.dontLoadTweakLoader = uiDontLoadTweakLoader
        }
    }
    @Published var uiOrientationLock : LCOrientationLock {
        didSet {
            appInfo.orientationLock = uiOrientationLock
        }
    }
    @Published var uiSelectedLanguage : String {
        didSet {
            appInfo.selectedLanguage = uiSelectedLanguage
        }
    }
    
    @Published var uiDontSign : Bool {
        didSet {
            appInfo.dontSign = uiDontSign
        }
    }
    
    @Published var jitLaunchScriptJs: String? {
        didSet {
            appInfo.jitLaunchScriptJs = jitLaunchScriptJs
        }
    }
    
    @Published var uiSelected32BitEmulator : String {
        didSet {
            appInfo.selected32BitEmulator = uiSelected32BitEmulator
        }
    }
    
    @Published var uiSpoofSDKVersion : Bool {
        didSet {
            appInfo.spoofSDKVersion = uiSpoofSDKVersion
        }
    }
    
    @Published var uiRemark : String {
        didSet {
            appInfo.remark = uiRemark
        }
    }
    
    @Published var uiIsMultitaskModeSpecificed : MultitaskSpecified {
        didSet {
            appInfo.multitaskSpecified = uiIsMultitaskModeSpecificed;
        }
    }
    
    public var bundleIdentifier: String {
        get {
            return appInfo.bundleIdentifier() ?? "?"
        }
    }
    
    public var version: String {
        get {
            return appInfo.version() ?? "?"
        }
    }
    
    public var displayName: String {
        get {
            return appInfo.displayName() ?? "?"
        }
    }
    
    public var shouldLaunchInMultitaskMode : Bool {
        get {
            if #available(iOS 16.0, *) {
                return uiIsMultitaskModeSpecificed == .yes ||
                (uiIsMultitaskModeSpecificed == .default && UserDefaults.standard.bool(forKey: "LCLaunchInMultitaskMode"))
            } else {
                return false
            }
        }
    }
    
    @Published var supportedLanguages : [String]?
    
    var delegate : LCAppModelDelegate?
    
    init(appInfo : LCAppInfo, delegate: LCAppModelDelegate? = nil) {
        self.appInfo = appInfo
        self.delegate = delegate

        if !appInfo.isLocked && appInfo.isHidden {
            appInfo.isLocked = true
        }
        
        self.uiIsJITNeeded = appInfo.isJITNeeded
        self.uiClassicMode = appInfo.classicMode
        self.uiIsHidden = appInfo.isHidden
        self.uiIsLocked = appInfo.isLocked
        self.uiIsShared = appInfo.isShared
        self.uiSelectedLanguage = appInfo.selectedLanguage ?? ""
        self.uiDefaultDataFolder = appInfo.dataUUID
        self.uiContainers = appInfo.containers
        self.uiTweakFolder = appInfo.tweakFolder
        self.uiDoSymlinkInbox = appInfo.doSymlinkInbox
        self.uiOrientationLock = appInfo.orientationLock
        self.uiIsMultitaskModeSpecificed = appInfo.multitaskSpecified
        self.uiUseLCBundleId = appInfo.doUseLCBundleId
        self.uiFixFilePickerNew = appInfo.fixFilePickerNew
        self.uiFixLocalNotification = appInfo.fixLocalNotification
        self.uiHideLiveContainer = appInfo.hideLiveContainer
        self.uiDontInjectTweakLoader = appInfo.dontInjectTweakLoader
        self.uiTweakLoaderInjectFailed = appInfo.info()["LCTweakLoaderCantInject"] as? Bool ?? false
        self.uiDontLoadTweakLoader = appInfo.dontLoadTweakLoader
        self.uiDontSign = appInfo.dontSign
        self.jitLaunchScriptJs = appInfo.jitLaunchScriptJs
        self.uiSelected32BitEmulator = appInfo.selected32BitEmulator ?? ""
        self.uiSpoofSDKVersion = appInfo.spoofSDKVersion
        self.uiRemark = appInfo.remark ?? ""
        self.uiIs32bit = appInfo.is32bit
        self.uiIs32bitEmulator = appInfo.is32bitEmulator
        for container in uiContainers {
            if container.folderName == uiDefaultDataFolder {
                self.uiSelectedContainer = container;
                break
            }
        }
    }
    
    /// 按当前 appInfo 记录重算容器名单与选中容器（选中规则与 init 一致：folderName
    /// 与 dataUUID 一致者）。init 只在模型创建时算一次快照，进程内高级页改默认容器、
    /// 重装、容器增删等动作改的都是 appInfo 记录，快照不跟随就会脱钩——设置页按旧
    /// 快照读到的容器可能既不是记录里的默认容器、也不是客体刚写完偏好的那个，
    /// 表现就是设置/数据包状态整页停在旧容器上。打开设置页前调它对齐到记录，
    /// 与 runApp 读的 uiSelectedContainer 同源同值。
    func refreshContainerSelection() {
        // 赋值全部带变更守卫：名单按 folderName 序列判变、选中按 folderName
        // 判同。对齐完成后重复调用是零发布的空转——这样数据包就绪的共用
        // 求值入口（LCGameLibraryInfo.datapackReady）敢在视图求值期先调它
        // 对齐，不会每次 body 重跑都写 @Published 引发更新风暴；终态与无
        // 守卫版逐项一致（名单换过时选中从新名单里重取实例，保同源）。
        let containers = appInfo.containers
        let defaultFolder = appInfo.dataUUID
        let listChanged = uiContainers.map(\.folderName) != containers.map(\.folderName)
        if listChanged {
            uiContainers = containers
        }
        if uiDefaultDataFolder != defaultFolder {
            uiDefaultDataFolder = defaultFolder
        }
        if let uuid = defaultFolder,
           let match = containers.first(where: { $0.folderName == uuid }) {
            if listChanged || uiSelectedContainer?.folderName != match.folderName {
                uiSelectedContainer = match
            }
        } else if let current = uiSelectedContainer,
                  !containers.contains(where: { $0.folderName == current.folderName }) {
            // 快照里的选中容器已不在名单内：清掉，defaultContainer 回退名单首个
            uiSelectedContainer = nil
        }
    }

    static func == (lhs: LCAppModel, rhs: LCAppModel) -> Bool {
        return lhs === rhs
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
    
    // You should let LCAppModel.runApp to decide whether to run in multitask mode, but you may override the multitask parameter if necessary
    func runApp(multitask: Bool? = nil, containerFolderName : String? = nil, bundleIdOverride : String? = nil, urlStr : String? = nil, forceJIT: Bool? = nil) async throws{
        if isAppRunning {
            return
        }
        
        if uiContainers.isEmpty {
            let newName = LCContainer.generateFolderName(displayName: appInfo.displayName(), bundleIdentifier: appInfo.bundleIdentifier(), siblingFolderNames: uiContainers.map(\.folderName))
            let newContainer = LCContainer(folderName: newName, name: newName, isShared: uiIsShared)
            uiContainers.append(newContainer)
            if uiSelectedContainer == nil {
                uiSelectedContainer = newContainer;
            }
            appInfo.containers = uiContainers;
            newContainer.makeLCContainerInfoPlist(appIdentifier: appInfo.bundleIdentifier()!, keychainGroupId: Int.random(in: 0..<SharedModel.keychainAccessGroupCount))
            appInfo.dataUUID = newName
            uiDefaultDataFolder = newName
        }
        if let containerFolderName {
            uiSelectedContainer = uiContainers.first { $0.folderName == containerFolderName } ?? uiSelectedContainer
        }
        let currentDataFolder = containerFolderName ?? uiSelectedContainer?.folderName
        
        let classicMode = appInfo.defaultClassicMode
        // 专用游戏容器：强制串行单开，忽略全局/单应用多任务设置，永不以多任务模式启动
        let multitask = false
        
        if MultitaskManager.isMultitasking() || multitask,
           let currentDataFolder {
            if await bringExistingMultitaskWindowIfNeeded(dataUUID: currentDataFolder, urlScheme: urlStr) {
                return
            }
            
        }
        
        // this is rerouted to bringing app to front, so not needed here?
//        if(MultitaskManager.isUsing(container: uiSelectedContainer!.folderName)) {
//            throw "lc.container.inUse".loc + "\n MultiTask"
//        }
        
        // if the selected container is in use (either other lc or multitask), open the host lc associated with it
        if
            let fn = uiSelectedContainer?.folderName,
            var runningLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: fn)
        {
            runningLC = (runningLC as NSString).deletingPathExtension
            
            var openURLComp = URLComponents()
            openURLComp.scheme = runningLC
            if let urlStr {
                openURLComp.host = "open-url"
                openURLComp.queryItems = [
                    URLQueryItem(name: "url", value: Data(urlStr.utf8).base64EncodedString())
                ]
            }
            if await UIApplication.shared.canOpenURL(openURLComp.url!) {
                await UIApplication.shared.open(openURLComp.url!)
                return
            }
        }
        
        // find a free lc to run non-multitasking shared app. If none, ask user if they want to terminate all multitasking apps
        if MultitaskManager.isMultitasking() && !multitask {
            if self.uiIsShared {
                var freeScheme: String? = nil
                LCUtils.forEachInstalledLC(isFree: true) { scheme, shouldBreak in
                    freeScheme = scheme
                    shouldBreak = true
                }
                if let freeScheme {
                    LCUtils.appGroupUserDefault.set(freeScheme, forKey: "LCLaunchExtensionScheme")
                    LCUtils.appGroupUserDefault.set(self.appInfo.relativeBundlePath, forKey: "LCLaunchExtensionBundleID")
                    LCUtils.appGroupUserDefault.set(uiSelectedContainer?.folderName, forKey: "LCLaunchExtensionContainerName")
                    if let urlStr {
                        LCUtils.appGroupUserDefault.set(urlStr, forKey: "LCLaunchExtensionLaunchURL")
                    }
                    LCUtils.appGroupUserDefault.set(Date.now, forKey: "LCLaunchExtensionLaunchDate")
                    var launchURLComp = URLComponents()
                    launchURLComp.scheme = freeScheme
                    launchURLComp.host = "gamecase-launch"
                    var queryItems: [URLQueryItem] = []
                    if let bundlePath = self.appInfo.relativeBundlePath {
                        queryItems.append(URLQueryItem(name: "bundle-name", value: bundlePath))
                    }
                    if let folderName = uiSelectedContainer?.folderName {
                        queryItems.append(URLQueryItem(name: "container-folder-name", value: folderName))
                    }
                    
                    launchURLComp.queryItems = queryItems
                    
                    if let url = launchURLComp.url {
                        await UIApplication.shared.open(url)
                    } else {
                        throw "Unable to build URL from launchURLComp???"
                    }
                    return
                }
            }
            
            guard let ans = await delegate?.showRunWhenMultitaskAlert(), ans else {
                return
            }
        }
        
        await MainActor.run {
            isAppRunning = true
        }
        defer {
            Task { await MainActor.run {
                isAppRunning = false
            }}
        }
        try await signApp(force: false)
        
        if let bundleIdOverride {
            UserDefaults.standard.set(bundleIdOverride, forKey: "selected")
        } else {
            UserDefaults.standard.set(self.appInfo.relativeBundlePath, forKey: "selected")
        }
        if let urlStr {
            UserDefaults.standard.setValue(urlStr, forKey: "launchAppUrlScheme")
        }
        UserDefaults.standard.set(uiSelectedContainer?.folderName, forKey: "selectedContainer")

        // 启动 env 维护：按将启动容器的现状重算 DM_ROMFS_OVERLAY
        // （Documents/mods）、DM_CHEATS（Documents/cheats）与
        // DM_SAVE_SYNC（云存档书签，见 LCGameCloudSaves）三行、行
        // 级维护进该容器 Documents/env.txt（客体 boot 时自读），与
        // 下方游玩时长打戳同处漏斗——已越过全部早退分支、派发在
        // 即，每次启动现算，玩家在文件 App 增删 mod / 金手指后下次
        // 启动即生效。override 启动（如内置 SideStore）不是 dm 客
        // 体，不适用。维护失败静默，绝不挡启动。见 LCGameMods.swift
        // / LCGameCheats.swift。
        if bundleIdOverride == nil {
            LCGameMods.refreshEnvOverlay(for: self)
        }

        // 游玩时长开始戳（Phase 18）：runApp 是所有启动入口（主页开始胶囊 /
        // 横屏牌组 / 列表菜单 / 深链等）的最深公共漏斗，且此处已越过全部
        // 早退分支（已运行、多任务窗口已存在、转交其他 LC 副本——那些情形
        // 要么本局已在计、要么由接手副本在它自己的漏斗打戳），启动派发只剩
        // 下方 JIT / 经典模式两条路，只在这里打一次不会重复计。
        // 内置 SideStore 不计游玩时长：它不是游戏，且其会话永远不会被
        // 正常结清（无快捷栏回库动作），从源头不产生伪会话。
        if bundleIdOverride != "builtinSideStore" {
            LCPlayStats.beginSession(bundleId: bundleIdOverride ?? bundleIdentifier)
        }

        // 宿主侧启动预盖层（仅游戏本体启动，override 启动不盖——与客体侧
        // 不为 SideStore 装盖层同口径）：此处已越过全部早退分支（已运行 /
        // 多任务窗口已存在 / 转交其他 LC 副本 / 终止多任务询问），再往下
        // 只剩派发。present 同步在宿主当前窗口盖满与客体侧盖层同图同构
        // 图的静态封面，成为宿主进程被 SIGKILL 前的最后一帧，掩盖进程
        // 交棒区间系统 morph 的黑帧 / 卡片帧（定案见 LCLaunchPreCover
        // .swift 头注）；标记经 UserDefaults 告知新进程，客体盖层据此跳
        // 过入场淡入。封面解析在后台进行、不阻塞派发。派发抛错时下方
        // catch 先撤层清标记再上抛，报错弹层不被罩住；派发成功即进程交
        // 棒（标准路径 completion 无条件 SIGKILL），预盖层不撤、随进程
        // 终止自然消失。
        let preCoverPresented = bundleIdOverride == nil
        if preCoverPresented {
            LCLaunchPreCover.present(app: self, containerFolderName: currentDataFolder)
        }

        var jitNeeded = appInfo.isJITNeeded || appInfo.is32bit
        if let forceJIT {
            jitNeeded = forceJIT
        }
#if targetEnvironment(simulator)
        jitNeeded = false
#endif
        do {
            if jitNeeded {
                if multitask, #available(iOS 17.4, *) {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        LCUtils.launchMultitaskGuestApp(appInfo.displayName()) { pidNumber, error in
                            if let error {
                                continuation.resume(throwing: error)
                                return
                            }
                            guard let pidNumber = pidNumber else {
                                continuation.resume(throwing: "Failed to obtain PID from LiveProcess")
                                return
                            }
                            Task {
                                if let scriptData = self.jitLaunchScriptJs, !scriptData.isEmpty {
                                    await self.delegate?.jitLaunch(withPID: pidNumber.intValue, withScript: scriptData, appName: self.appInfo.displayName())
                                } else {
                                    await self.delegate?.jitLaunch(withPID: pidNumber.intValue, withScript: nil, appName: self.appInfo.displayName())
                                }
                                continuation.resume()
                            }
                        }
                    }
                } else {
                    // Non-multitask JIT flow remains unchanged
                    if let scriptData = jitLaunchScriptJs, !scriptData.isEmpty {
                        await delegate?.jitLaunch(withScript: scriptData, appName: self.appInfo.displayName(), classicMode: classicMode)
                    } else {
                        await delegate?.jitLaunch(appName: self.appInfo.displayName(), classicMode: classicMode)
                    }
                }
            } else if multitask, #available(iOS 16.0, *) {
                try await LCUtils.launchMultitaskGuestApp(appInfo.displayName())
            } else {
                if #available(iOS 26.0, *), FileManager.default.fileExists(atPath: "\(appInfo.bundlePath()!)/Frameworks/MetalANGLE.framework/MetalANGLE") {
                    let fileContents = "\(appInfo.bundlePath()!)/Frameworks/MetalANGLE.framework/MetalANGLE".data(using: .utf8)
                    let fileURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("preloadLibraries.txt")
                    try fileContents?.write(to: fileURL)
                }
                LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)
            }
        } catch {
            // 派发失败、宿主进程存活：先撤预盖层并清标记，报错才可达用户
            if preCoverPresented {
                LCLaunchPreCover.remove()
            }
            throw error
        }
        
        // Record the launch time
        appInfo.lastLaunched = Date()

        await MainActor.run {
            isAppRunning = false
        }
    }
    
    func forceResign() async throws {
        if isAppRunning {
            return
        }
        isAppRunning = true
        defer {
            Task{ await MainActor.run {
                self.isAppRunning = false
            }}

        }
        try await signApp(force: true)
    }
    
    func signApp(force: Bool = false) async throws {
        var signError : String? = nil
        var signSuccess = false
        defer {
            Task{ await MainActor.run {
                self.isSigningInProgress = false
            }}
        }
        
        await withUnsafeContinuation({ c in
            appInfo.patchExecAndSignIfNeed(completionHandler: { success, error in
                signError = error;
                signSuccess = success;
                c.resume()
            }, progressHandler: { signProgress in
                guard let signProgress else {
                    return
                }
                self.isSigningInProgress = true
                self.observer = signProgress.observe(\.fractionCompleted) { p, v in
                    DispatchQueue.main.async {
                        self.signProgress = signProgress.fractionCompleted
                    }
                }
            }, forceSign: force)
        })
        if let signError {
            if !signSuccess {
                throw signError.loc
            }
        }
        
        // sign its tweak
        guard let tweakFolder = appInfo.tweakFolder else {
            return
        }
        
        let tweakFolderUrl : URL
        if(appInfo.isShared) {
            tweakFolderUrl = LCPath.lcGroupTweakPath.appendingPathComponent(tweakFolder)
        } else {
            tweakFolderUrl = LCPath.tweakPath.appendingPathComponent(tweakFolder)
        }
        try await LCUtils.signTweaks(tweakFolderUrl: tweakFolderUrl, force: force) { p in
            Task{ await MainActor.run {
                self.isSigningInProgress = true
            }}
        }
        
        // sign global tweak
        try await LCUtils.signTweaks(tweakFolderUrl: LCPath.tweakPath, force: force) { p in
            Task{ await MainActor.run {
                self.isSigningInProgress = true
            }}
        }
    }

    func setLocked(newLockState: Bool) async {
        // if locked state in appinfo already match with the new state, we just the change
        if appInfo.isLocked == newLockState {
            return
        }
        
        if newLockState {
            appInfo.isLocked = true
        } else {
            // authenticate before cancelling locked state
            do {
                let result = try await LCUtils.authenticateUser()
                if !result {
                    uiIsLocked = true
                    return
                }
            } catch {
                uiIsLocked = true
                return
            }
            
            // auth pass, we need to cancel app's lock and hidden state
            appInfo.isLocked = false
            if appInfo.isHidden {
                await toggleHidden()
            }
        }
    }
    
    func toggleHidden() async {
        delegate?.closeNavigationView()
        if appInfo.isHidden {
            appInfo.isHidden = false
            uiIsHidden = false
        } else {
            appInfo.isHidden = true
            uiIsHidden = true
        }
        delegate?.changeAppVisibility(app: self)
    }
    
    func loadSupportedLanguages() throws {
        let fm = FileManager.default
        if supportedLanguages != nil {
            return
        }
        supportedLanguages = []
        let fileURLs = try fm.contentsOfDirectory(at: URL(fileURLWithPath: appInfo.bundlePath()!) , includingPropertiesForKeys: nil)
        for fileURL in fileURLs {
            let attributes = try fm.attributesOfItem(atPath: fileURL.path)
            let fileType = attributes[.type] as? FileAttributeType
            if(fileType == .typeDirectory && fileURL.lastPathComponent.hasSuffix(".lproj")) {
                supportedLanguages?.append(fileURL.deletingPathExtension().lastPathComponent)
            }
        }
        
    }
    
    private func bringExistingMultitaskWindowIfNeeded(dataUUID: String, urlScheme: String?) async -> Bool {
        guard #available(iOS 16.0, *) else { return false }
        return await MainActor.run {
            if let urlScheme {
                UserDefaults.standard.setValue(urlScheme, forKey: "launchAppUrlScheme")
            }
            var found = false
            if #available(iOS 16.1, *) {
                found = MultitaskWindowManager.openExistingAppWindow(dataUUID: dataUUID)
            }
            if !found {
                found = MultitaskDockManager.shared.bringMultitaskViewToFront(uuid: dataUUID)
            }
            if let urlScheme, !found  {
                UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
            }
            return found
        }
    }
}
