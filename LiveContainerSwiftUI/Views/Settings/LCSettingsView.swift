//
//  LCSettingsView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI
import UserNotifications

enum JITEnablerType : Int, CaseIterable, Identifiable {
    var id: Int { rawValue }
    case SideJITServer = 0
    case StikJIT = 1
    case JITStreamerEBLegacy = 2
    case StikJITLC = 3
    case SideStore = 4
    case StosDebug = 5
    case StosDebugLC = 6
    
    var displayName: String {
        switch self {
        case .StikJIT: "StikDebug"
        case .StikJITLC: "StikDebug (Another GameCase/Multitask)"
        case .StosDebug: "StosDebug"
        case .StosDebugLC: "StosDebug (Another GameCase/Multitask)"
        case .SideStore: "SideStore"
        case .JITStreamerEBLegacy: "JitStreamer-EB (Relaunch)"
        case .SideJITServer: "SideJITServer/JITStreamer 2.0"
        }
    }
}

struct LCSettingsView: View {
    @State var errorShow = false
    @State var errorInfo = ""
    @State var successShow = false
    @State var successInfo = ""

    @State private var certificateDataFound = false
    
    @StateObject private var certificateImportAlert = YesNoHelper()
    @StateObject private var certificateImportFromBuiltInSideStoreAlert = YesNoHelper()
    @StateObject private var certificateRemoveAlert = YesNoHelper()
    @StateObject private var certificateImportFileAlert = AlertHelper<URL>()
    @StateObject private var certificateImportPasswordAlert = InputHelper()
    
    @AppStorage("gc.appearance") var gcAppearance = 0
    @AppStorage("LCFrameShortcutIcons") var frameShortIcon = false
    @AppStorage("LCSwitchAppWithoutAsking") var silentSwitchApp = false
    @AppStorage("LCOpenWebPageWithoutAsking") var silentOpenWebPage = false
    @AppStorage("LCDontSignApp", store: LCUtils.appGroupUserDefault) var dontSignApp = false
    @AppStorage("LCStrictHiding", store: LCUtils.appGroupUserDefault) var strictHiding = false
    @AppStorage("dynamicColors", store: LCUtils.appGroupUserDefault) var dynamicColors = true
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    
    @AppStorage("LCSideJITServerAddress", store: LCUtils.appGroupUserDefault) var sideJITServerAddress : String = ""
    @AppStorage("LCDeviceUDID", store: LCUtils.appGroupUserDefault) var deviceUDID: String = ""
    @AppStorage("LCJITEnablerType", store: LCUtils.appGroupUserDefault) var JITEnabler: JITEnablerType = .SideJITServer
    
    @State var store : Store = .Unknown
    
    @AppStorage("LCLoadTweaksToSelf") var injectToLCItelf = false
    @AppStorage("LCIgnoreJITOnLaunch") var ignoreJITOnLaunch = false
    @AppStorage("LCSelected32BitEmulator", store: LCUtils.appGroupUserDefault) var selected32BitEmulator : String = ""
    @AppStorage("LCKeepSelectedWhenQuit") var keepSelectedWhenQuit = false
    @AppStorage("LCWaitForDebugger") var waitForDebugger = false
    @AppStorage("LCSharePrivateDataWithLiveProcess") var sharePrivateDataWithLiveProcess = false
    @AppStorage("BKNoWatchdogs") var disableLiveProcessWatchdog = false
    
    @EnvironmentObject private var sharedModel : SharedModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var isViewAppeared = false

    /// 横屏侧面板呈现时的关闭回调（Phase 14，列表层注入）：面板不是系统
    /// 呈现，dismiss 环境无效，关闭走此回调；nil = sheet 呈现，用
    /// dismiss 关闭，与原来一致。
    let onClose: (() -> Void)?

    let storeName = LCUtils.getStoreName()

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        _certificateDataFound = State(initialValue: LCSharedUtils.certificatePassword() != nil)
        _store = State(initialValue: LCUtils.store())
    }
    
    var body: some View {
        NavigationView {
            // 横屏定宽加在容器本体（Form）上：LCSettingsColumn 在页面根层读
            // 自身尺寸，横屏时把 Form 显式定宽 640 并居中（此页此前没有任何
            // 640 约束，横屏整表满宽；Form 是列表容器、行宽由它决定，见
            // LCSettingsColumn.swift）。经 NavigationLink 推出的子页是独立
            // 视图、不随此列收窄（与原来一致）。
            LCSettingsColumn { _ in
                settingsForm
            }
                .toolbar {
                    // 关闭钮与数据包导入页「取消」同款做法：sheet 自己的工具栏
                    // cancellationAction 位、素 Button 无自加样式，新系统在 sheet
                    // 里把它渲染成与标题行对齐的圆角胶囊钮（横竖屏都落在 sheet 内）。
                    // 工具栏不直接挂到巨型 Form 表达式上（PR #4 试过、类型检查超时），
                    // 故 Form 先收进独立计算属性 settingsForm，工具栏只挂 body 的小表达式。
                    ToolbarItem(placement: .cancellationAction) {
                        Button("lc.common.close".loc) {
                            if let onClose {
                                onClose()
                            } else {
                                dismiss()
                            }
                        }
                    }
                }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear() {
            if !isViewAppeared {
                guard sharedModel.selectedTab == .settings, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .settings, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
    }

    /// 设置表单本体：原 body 中 NavigationView 内的 Form 与其全部修饰符，
    /// 内容与顺序未动，仅从 body 拆为独立计算属性（见 body 内工具栏注释）。
    private var settingsForm: some View {
        Form {
            if sharedModel.multiLCStatus != 2 {
                Section{
                    if !certificateDataFound {
                        Button {
                            Task{ await importCertificate() }
                        } label: {
                            Text("lc.settings.importCertificate".loc)
                        }
                    } else {
                        Button {
                            Task{ await removeCertificate() }
                        } label: {
                            Text("lc.settings.removeCertificate".loc)
                        }
                    }
                    // 显示条件在上游「宿主由 AltStore/SideStore 安装」之外
                    // 补上内置 SideStore 存在的情况：GameCase 宿主多经
                    // LCSign/证书安装，store 检测为 .Unknown 时上游条件
                    // 永假，这行永远不显示，但处理函数内的内置路线
                    // （按 sideStoreExist 读共享钥匙串）本就可用。
                    // 名称同理：.Unknown 时 getStoreName 返回 Unknown
                    // Store，内置场景固定显示 SideStore。
                    if store == .AltStore || store == .SideStore || UserDefaults.sideStoreExist() {
                        Button {
                            Task{ await importCertificateFromSideStore() }
                        } label: {
                            if certificateDataFound {
                                Text("lc.settings.refreshCertificateFromStore %@".localizeWithFormat(store == .AltStore ? storeName : "SideStore"))
                            } else {
                                Text("lc.settings.importCertificateFromStore %@".localizeWithFormat(store == .AltStore ? storeName : "SideStore"))
                            }
                        }
                    }
                    // 内置 SideStore 的打开入口（仅 +SideStore 版有这个
                    // framework）：游戏库改版后上游 Apps 页的 SideStore
                    // 按钮已不在，这里补回——玩家要先在内置 SideStore
                    // 里登录 Apple ID 并刷新一次，上面的一键导入证书
                    // 才读得到共享钥匙串里的证书。
                    if UserDefaults.sideStoreExist() {
                        Button {
                            LCUtils.openSideStore()
                        } label: {
                            Text("lc.settings.openBuiltinSideStore".loc)
                        }
                    }
                    
                    NavigationLink {
                        LCJITLessDiagnoseView()
                    } label: {
                        Text("lc.settings.jitlessDiagnose".loc)
                    }

                } header: {
                    Text("lc.settings.jitLess".loc)
                } footer: {
                    Text("lc.settings.jitLessDesc".loc)
                }
            }
            Section {
                Picker("lc.settings.appearance".loc, selection: $gcAppearance) {
                    Text("lc.settings.appearance.dark".loc).tag(0)
                    Text("lc.settings.appearance.system".loc).tag(1)
                    Text("lc.settings.appearance.light".loc).tag(2)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("lc.settings.appearance".loc)
            }
            if (store != .Unknown && store != .ADP) || LCUtils.isAppGroupAltStoreLike() {
                Section{
                    NavigationLink {
                        LCMultiLCManagementView()
                    } label: {
                        if sharedModel.multiLCStatus == 0 {
                            Text("lc.settings.multiLC".loc)
                        } else if sharedModel.multiLCStatus == 2 {
                            Text("lc.settings.multiLCIsSecond".loc)
                        }
                        
                    }
                    .disabled(sharedModel.multiLCStatus == 2)
                    
                    if(sharedModel.multiLCStatus == 2) {
                        NavigationLink {
                            LCJITLessDiagnoseView()
                        } label: {
                            Text("lc.settings.jitlessDiagnose".loc)
                        }
                    }
                } footer: {
                    Text("lc.settings.multiLCDesc".loc)
                }
            }
            
            // 专用游戏容器：多任务恒关，设置页不再提供多任务入口（LCMultitaskSettingView 文件保留未引用）
            
            Section {
                if JITEnabler == .SideJITServer || JITEnabler == .JITStreamerEBLegacy {
                    HStack {
                        Text("lc.settings.JitAddress".loc)
                        Spacer()
                        TextField(JITEnabler == .SideJITServer ? "http://x.x.x.x:8080" : "http://[fd00::]:9172", text: $sideJITServerAddress)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if JITEnabler == .SideJITServer {
                    HStack {
                        Text("lc.settings.JitUDID".loc)
                        Spacer()
                        TextField("", text: $deviceUDID)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Picker(selection: $JITEnabler) {
                    ForEach(JITEnablerType.allCases) { enablerType in
                        Text(enablerType.displayName).tag(enablerType)
                    }
                } label: {
                    Text("lc.settings.jitEnabler".loc)
                }

            } header: {
                Text("JIT")
            } footer: {
                Text("lc.settings.JitDesc".loc)
            }
            
            Section {
                Picker(selection: $selected32BitEmulator) {
                    ForEach(sharedModel.arm32EmuApps, id: \.self) { app in
                        Text("lc.common.none".loc).tag("")
                        Text(app.appInfo.displayName()).tag(app.appInfo.relativeBundlePath!)
                    }
                } label: {
                    Text("lc.settings.selected32BitEmulator".loc)
                }
            }
            
            Section{
                Toggle(isOn: $dynamicColors) {
                    Text("lc.settings.dynamicColors".loc)
                }
                if #available(iOS 18.0, *) {
                    Toggle(isOn: $darkModeIcon) {
                        Text("lc.settings.darkModeIcon".loc)
                    }
                }
                
            } header: {
                Text("lc.settings.interface".loc)
            } footer: {
                Text("lc.settings.dynamicColors.desc".loc)
            }
            Section{
                Toggle(isOn: $frameShortIcon) {
                    Text("lc.settings.FrameIcon".loc)
                }
            } header: {
                Text("lc.common.miscellaneous".loc)
            } footer: {
                Text("lc.settings.FrameIconDesc".loc)
            }
            
            Section {
                Toggle(isOn: $silentSwitchApp) {
                    Text("lc.settings.silentSwitchApp".loc)
                }
            } footer: {
                Text("lc.settings.silentSwitchAppDesc".loc)
            }
            
            Section {
                Toggle(isOn: $silentOpenWebPage) {
                    Text("lc.settings.silentOpenWebPage".loc)
                }
            } footer: {
                Text("lc.settings.silentOpenWebPageDesc".loc)
            }
            
            if sharedModel.isHiddenAppUnlocked {
                Section {
                    Toggle(isOn: $strictHiding) {
                        Text("lc.settings.strictHiding".loc)
                    }
                } footer: {
                    Text("lc.settings.strictHidingDesc".loc)
                }
            }
            
            Section {
                Toggle(isOn: $dontSignApp) {
                    Text("lc.settings.dontSign".loc)
                }
            } footer: {
                Text("lc.settings.dontSignDesc".loc)
            }

            Section {
                Button {
                    clearNotifications()
                } label: {
                    Text("lc.settings.clearNotifications".loc)
                }
            }

            Section {
                if sharedModel.multiLCStatus != 2 {
                    NavigationLink {
                        LCStorageManagementView()
                    } label: {
                        Text("lc.settings.storageManagement".loc)
                    }
                }
                NavigationLink {
                    LCDataManagementView()
                } label: {
                    Text("lc.settings.dataManagement".loc)
                }
            }
            
            Section {
                HStack {
                    Image("GitHub")
                    Button("Tiaoge-tou/GameCase") {
                        openGameCase()
                    }
                }
                HStack {
                    Image("GitHub")
                    Button("LiveContainer/LiveContainer") {
                        openGitHub()
                    }
                }
                HStack {
                    Image("Twitter")
                    Button("khanhduytran0") {
                        openTwitter()
                    }
                }
                HStack {
                    Image("GitHub")
                    Button("Huge_Black") {
                        openGitHub2()
                    }
                }
                HStack {
                    Image(systemName: "doc.text")
                        .frame(width: 24, alignment: .center)
                    Button("GNU AGPL-3.0") {
                        openLicense()
                    }
                }
            } header: {
                Text("lc.settings.about".loc)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("lc.settings.aboutGameCase".loc)
                    Text("lc.settings.warning".loc)
                }
            }
            
            VStack{
                Text("GameCase \(LCUtils.getVersionInfo())")
                    .foregroundStyle(.gray)
                    .onTapGesture(count: 5) {
                        sharedModel.developerMode = true
                    }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .background(Color(UIColor.systemGroupedBackground))
                .listRowInsets(EdgeInsets())
            
            if sharedModel.developerMode {
                Section {
                    Toggle(isOn: $injectToLCItelf) {
                        Text("lc.settings.injectLCItself".loc)
                    }
                    Toggle(isOn: $ignoreJITOnLaunch) {
                        Text("Ignore JIT on Launching App")
                    }
                    Toggle(isOn: $keepSelectedWhenQuit) {
                        Text("Keep Selected App when Quit")
                    }
                    Toggle(isOn: $waitForDebugger) {
                        Text("Wait For Debugger")
                    }
                    Toggle(isOn: $sharePrivateDataWithLiveProcess) {
                        Text("Allow Private Data access from LiveProcess")
                    }
                    Toggle(isOn: $disableLiveProcessWatchdog) {
                        Text("Disable LiveProcess watchdog termination")
                    }
                    Button {
                        export()
                    } label: {
                        Text("Export Cert")
                    }
                    Button {
                        exportDyld()
                    } label: {
                        Text("Export Dyld")
                    }
                    Button {
                        Task { await nukeSideStore() }
                    } label: {
                        Text("Nuke SideStore")
                    }
                    Button {
                        exportMainBundle()
                    } label: {
                        Text("Export Main Bundle")
                    }
                    Button {
                        resetSymbolOffsets()
                    } label: {
                        Text("Reset Symbol Offsets")
                    }
                    Button {
                        presentFLEXOverlay()
                    } label: {
                        Text("Show FLEX Overlay")
                    }
                    .disabled(NSClassFromString("FLEXManager") == nil)
                } header: {
                    Text("Developer Settings")
                } footer: {
                    Text("lc.settings.injectLCItselfDesc".loc)
                }
            }
        }
        .navigationBarTitle("lc.tabView.settings".loc)
        .alert("lc.common.error".loc, isPresented: $errorShow){
        } message: {
            Text(errorInfo)
        }
        .alert("lc.common.success".loc, isPresented: $successShow){
        } message: {
            Text(successInfo)
        }
        .alert("lc.settings.importCertificate".loc, isPresented: $certificateImportAlert.show) {
            Button {
                certificateImportAlert.close(result: true)
            } label: {
                Text("lc.common.ok".loc)
            }

            Button("lc.common.cancel".loc, role: .cancel) {
                certificateImportAlert.close(result: false)
            }
        } message: {
            Text("lc.settings.importCertificateDesc".loc)
        }
        .alert("lc.settings.removeCertificate".loc, isPresented: $certificateRemoveAlert.show) {
            Button(role: .destructive) {
                certificateRemoveAlert.close(result: true)
            } label: {
                Text("lc.common.ok".loc)
            }

            Button("lc.common.cancel".loc, role: .cancel) {
                certificateRemoveAlert.close(result: false)
            }
        } message: {
            Text("lc.settings.removeCertificateDesc".loc)
        }
        .alert("lc.settings.importCertFromBuiltinSideStore".loc, isPresented: $certificateImportFromBuiltInSideStoreAlert.show) {
            Button {
                certificateImportFromBuiltInSideStoreAlert.close(result: true)
            } label: {
                Text("lc.common.ok".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                certificateImportFromBuiltInSideStoreAlert.close(result: false)
            }
        } message: {
            Text("lc.settings.importCertFromBuiltinSideStoreDesc".loc)
        }
        .betterFileImporter(isPresented: $certificateImportFileAlert.show, types: [.p12], multiple: false, callback: { fileUrls in
            certificateImportFileAlert.close(result: fileUrls[0])
        }, onDismiss: {
            certificateImportFileAlert.close(result: nil)
        })
        .textFieldAlert(
            isPresented: $certificateImportPasswordAlert.show,
            title: "lc.settings.importCertificateInputPassword".loc,
            text: $certificateImportPasswordAlert.initVal,
            placeholder: "",
            action: { newText in
                certificateImportPasswordAlert.close(result: newText)
            },
            actionCancel: {_ in
                certificateImportPasswordAlert.close(result: nil)
                certificateImportPasswordAlert.show = false
            }
        )
    }
    
    func openGameCase() {
        UIApplication.shared.open(URL(string: "https://github.com/Tiaoge-tou/GameCase")!)
    }

    func openLicense() {
        UIApplication.shared.open(URL(string: "https://github.com/Tiaoge-tou/GameCase/blob/main/LICENSE")!)
    }

    func openGitHub() {
        UIApplication.shared.open(URL(string: "https://github.com/LiveContainer/LiveContainer")!)
    }
    
    func openGitHub2() {
        UIApplication.shared.open(URL(string: "https://github.com/hugeBlack")!)
    }
    
    func openTwitter() {
        UIApplication.shared.open(URL(string: "https://twitter.com/khanhduytran0")!)
    }

    func clearNotifications() {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removeAllDeliveredNotifications()
        notificationCenter.removeAllPendingNotificationRequests()
        if #available(iOS 16.0, *) {
            notificationCenter.setBadgeCount(0)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }

    func export() {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        
        // 1. Copy embedded.mobileprovision from the main bundle to Documents
        if let embeddedURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") {
            let destinationURL = documentsURL.appendingPathComponent("embedded.mobileprovision")
            do {
                try fileManager.copyItem(at: embeddedURL, to: destinationURL)
                print("Successfully copied embedded.mobileprovision to Documents.")
            } catch {
                print("Error copying embedded.mobileprovision: \(error)")
            }
        } else {
            print("embedded.mobileprovision not found in the main bundle.")
        }
        
        // 2. Read "certData" from UserDefaults and save to cert.p12 in Documents
        if let certData = LCUtils.certificateData() {
            let certFileURL = documentsURL.appendingPathComponent("cert.p12")
            do {
                try certData.write(to: certFileURL)
                print("Successfully wrote certData to cert.p12 in Documents.")
            } catch {
                print("Error writing certData to cert.p12: \(error)")
            }
        } else {
            print("certData not found in UserDefaults.")
        }
        
        // 3. Read "certPassword" from UserDefaults and save to pass.txt in Documents
        if let certPassword = LCSharedUtils.certificatePassword() {
            let passwordFileURL = documentsURL.appendingPathComponent("pass.txt")
            do {
                try certPassword.write(to: passwordFileURL, atomically: true, encoding: .utf8)
                print("Successfully wrote certPassword to pass.txt in Documents.")
            } catch {
                print("Error writing certPassword to pass.txt: \(error)")
            }
        } else {
            print("certPassword not found in UserDefaults.")
        }
    }
    
    func exportMainBundle() {
        let url = Bundle.main.bundleURL
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        do {
            let destinationURL = documentsURL.appendingPathComponent(url.lastPathComponent)
            try fileManager.copyItem(at: url, to: destinationURL)
            print("Successfully copied main bundle to Documents.")
        } catch {
            print("Error copying main bundle \(error)")
        }
    }
    
    func resetSymbolOffsets() {
        LCUtils.appGroupUserDefault.removeObject(forKey: "symbolOffsetCache")
    }
    
    func presentFLEXOverlay() {
        let manager = (NSClassFromString("FLEXManager") as? NSObject.Type)?.perform(NSSelectorFromString("sharedManager"))
            .takeUnretainedValue() as? NSObject
        manager?.perform(NSSelectorFromString("showExplorer"))
    }
    
    func importCertificate() async {
        guard let doImport = await certificateImportAlert.open(), doImport else {
            return
        }
        guard let certificateURL = await certificateImportFileAlert.open() else {
            return
        }
        guard let certificatePassword = await certificateImportPasswordAlert.open() else {
            return
        }
        let certificateData : Data
        do {
            certificateData = try Data(contentsOf: certificateURL)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
        
        guard let _ = LCUtils.getCertTeamId(withKeyData: certificateData, password: certificatePassword) else {
            errorInfo = "lc.settings.invalidCertError".loc
            errorShow = true
            return
        }

        LCUtils.appGroupUserDefault.set(certificateData, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(certificatePassword, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(NSDate.now, forKey: "LCCertificateUpdateDate")
        certificateDataFound = true

        UserDefaults.standard.set(LCSharedUtils.appGroupID(), forKey: "LCAppGroupID")
    }
    
    func importCertificateFromSideStore() async {
        if UserDefaults.sideStoreExist() {
            if let ans = await certificateImportFromBuiltInSideStoreAlert.open(), ans {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrAccount as String: "signingCertificate",
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecAttrService as String: "com.tiaoge.gamecase",
                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
                ]
                
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                
                guard status == errSecSuccess else {
                    if status == errSecItemNotFound {
                        errorInfo = "lc.settings.importCertFromBuiltinSideStore.certNotFounndErr".loc
                        errorShow = true
                    } else {
                        errorInfo = "Keychain read error: \(status)"
                        errorShow = true
                    }
                    return
                }
                
                guard let data = item as? Data else {
                    errorInfo = "Failed to decode certificate data"
                    errorShow = true
                    return
                }
                
                let passwordQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrAccount as String: "signingCertificatePassword",
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecAttrService as String: "com.tiaoge.gamecase",
                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
                ]
                
                var passwordItem: CFTypeRef?
                let passwordStatus = SecItemCopyMatching(passwordQuery as CFDictionary, &passwordItem)
                var password = ""
                if passwordStatus == errSecSuccess,
                   let passwordData = passwordItem as? Data,
                   let pwd = String(data: passwordData, encoding: .utf8) {
                    password = pwd
                }
                
                onSideStoreCertificateCallback(certificateData: data, password: password)
                
                return
            }
        }
        
        let storeScheme : String
        if store == .AltStore {
            storeScheme = "altstore-classic"
        } else {
            storeScheme = "sidestore"
        }
        
        guard let url = URL(string: "\(storeScheme.lowercased())://certificate?callback_template=gamecase%3A%2F%2Fcertificate%3Fcert%3D%24%28BASE64_CERT%29%26password%3D%24%28PASSWORD%29") else {
            errorInfo = "Failed to initialize certificate import URL."
            errorShow = true
            return
        }
        await UIApplication.shared.open(url)
    }
    func onSideStoreCertificateCallback(certificateData: Data, password: String) {
        LCUtils.appGroupUserDefault.set(certificateData, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(password, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(NSDate.now, forKey: "LCCertificateUpdateDate")
        certificateDataFound = true
    }
    
    func removeCertificate() async {
        guard let doRemove = await certificateRemoveAlert.open(), doRemove else {
            return
        }

        LCUtils.appGroupUserDefault.set(nil, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(nil, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(nil, forKey: "LCCertificateUpdateDate")
        certificateDataFound = false

        UserDefaults.standard.set(nil, forKey: "LCAppGroupID")
    }
    
    func nukeSideStore() async {
        guard let doRemove = await certificateRemoveAlert.open(), doRemove else {
            return
        }
        do {
            let fm = FileManager.default
            let sidestoreAppGroupURL = LCPath.lcGroupDocPath.deletingLastPathComponent()
            try fm.removeItem(at: sidestoreAppGroupURL.appendingPathComponent("Database"))
            try fm.removeItem(at: sidestoreAppGroupURL.appendingPathComponent("Apps"))
        } catch {
            print("wtf \(error)")
        }
    }
    
    func exportDyld() {
        let url = URL(fileURLWithPath: "/usr/lib/dyld")
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        do {
            let destinationURL = documentsURL.appendingPathComponent(url.lastPathComponent)
            try fileManager.copyItem(at: url, to: destinationURL)
            print("Successfully copied dyld to Documents.")
        } catch {
            print("Error copying dyld \(error)")
        }
    }
    
    func handleURL(url: URL) {
        if url.host == "certificate" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
                guard let encodedCert = queryItems["cert"]?.removingPercentEncoding,
                      let password = queryItems["password"],
                      let certData = Data(base64Encoded: encodedCert)
                else { return }
                
                onSideStoreCertificateCallback(certificateData: certData, password: password)
                
            }
        }
    }
}
