//
//  NSUserDefaults.m
//  LiveContainer
//
//  Created by s s on 2024/11/29.
//

#import "FoundationPrivate.h"
#import "LCMachOUtils.h"
#import "LCSharedUtils.h"
#import "utils.h"
#import "../../litehook/src/litehook.h"
#include "Tweaks.h"
@import ObjectiveC;
@import MachO;

BOOL hook_return_false(void) {
    return NO;
}

void swizzle2(Class class, SEL originalAction, Class class2, SEL swizzledAction) {
    Method m1 = class_getInstanceMethod(class2, swizzledAction);
    class_addMethod(class, swizzledAction, method_getImplementation(m1), method_getTypeEncoding(m1));
    method_exchangeImplementations(class_getInstanceMethod(class, originalAction), class_getInstanceMethod(class, swizzledAction));
}

NSURL* appContainerURL = 0;
NSString* appContainerPath = 0;

void NUDGuestHooksInit(void) {
    appContainerPath = [NSString stringWithUTF8String:getenv("HOME")];
    appContainerURL = [NSURL URLWithString:appContainerPath];
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    
#if TARGET_OS_MACCATALYST || TARGET_OS_SIMULATOR
    // fix for macOS host
    method_setImplementation(class_getInstanceMethod(NSClassFromString(@"CFPrefsPlistSource"), @selector(_isSharedInTheiOSSimulator)), (IMP)hook_return_false);
#endif

    Class CFPrefsPlistSourceClass = NSClassFromString(@"CFPrefsPlistSource");

    swizzle2(CFPrefsPlistSourceClass, @selector(initWithDomain:user:byHost:containerPath:containingPreferences:), CFPrefsPlistSource2.class, @selector(hook_initWithDomain:user:byHost:containerPath:containingPreferences:));
#pragma clang diagnostic pop
    
    Class CFXPreferencesClass = NSClassFromString(@"_CFXPreferences");
    NSMutableDictionary* sources = object_getIvar([CFXPreferencesClass copyDefaultPreferences], class_getInstanceVariable(CFXPreferencesClass, "_sources"));

    [sources removeObjectForKey:@"C/A//B/L"];
    [sources removeObjectForKey:@"C/C//*/L"];
    // 再把其余来源一并逐出：宿主 UI 对客体偏好是直写 plist 文件的（LCGamePrefs），
    // 进程内残留的旧 plist 来源会让客体启动器读到旧值、并在启动 apply() 时把旧值
    // 回写覆盖库内新值（读通写不通）。上面两个键是上游已知的当前应用来源，这里
    // 扩到全部，强制客体阶段的每次偏好读取都按磁盘现状重建来源。本 fork 串行
    // 单开、客体退出即进程重拉回库，宿主域来源在下次访问时按磁盘重建，无回滚风险。
    [sources removeAllObjects];
    
    // replace _CFPrefsCurrentAppIdentifierCache so kCFPreferencesCurrentApplication refers to the guest app
    const char* coreFoundationPath = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";
    mach_header_u* coreFoundationHeader = LCGetLoadedImageHeader(2, coreFoundationPath);
    
#if !TARGET_OS_SIMULATOR
    CFStringRef* _CFPrefsCurrentAppIdentifierCache = getCachedSymbol(@"__CFPrefsCurrentAppIdentifierCache", coreFoundationHeader);
    if(!_CFPrefsCurrentAppIdentifierCache) {
        _CFPrefsCurrentAppIdentifierCache = litehook_find_dsc_symbol(coreFoundationPath, "__CFPrefsCurrentAppIdentifierCache");
        uint64_t offset = (uint64_t)((void*)_CFPrefsCurrentAppIdentifierCache - (void*)coreFoundationHeader);
        saveCachedSymbol(@"__CFPrefsCurrentAppIdentifierCache", coreFoundationHeader, offset);
    }
    [NSUserDefaults.lcUserDefaults _setIdentifier:(__bridge NSString*)CFStringCreateCopy(nil, *_CFPrefsCurrentAppIdentifierCache)];
    *_CFPrefsCurrentAppIdentifierCache = (__bridge CFStringRef)NSUserDefaults.lcGuestAppId;
#else
    // FIXME: for now we skip overwriting _CFPrefsCurrentAppIdentifierCache on simulator, since there is no way to find private symbol
#endif
    
    NSUserDefaults* newStandardUserDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"whatever"];
    [newStandardUserDefaults _setIdentifier:NSUserDefaults.lcGuestAppId];
    NSUserDefaults.standardUserDefaults = newStandardUserDefaults;

#if !TARGET_OS_SIMULATOR
    NSString* selectedLanguage = NSUserDefaults.guestAppInfo[@"LCSelectedLanguage"];
    if(selectedLanguage) {
        [newStandardUserDefaults setObject:@[selectedLanguage] forKey:@"AppleLanguages"];
        CFMutableArrayRef* _CFBundleUserLanguages = getCachedSymbol(@"__CFBundleUserLanguages", coreFoundationHeader);
        if(!_CFBundleUserLanguages) {
            _CFBundleUserLanguages = litehook_find_dsc_symbol(coreFoundationPath, "__CFBundleUserLanguages");
            uint64_t offset = (uint64_t)((void*)_CFBundleUserLanguages - (void*)coreFoundationHeader);
            saveCachedSymbol(@"__CFBundleUserLanguages", coreFoundationHeader, offset);
        }
        // set _CFBundleUserLanguages to selected languages
        NSMutableArray* newUserLanguages = [NSMutableArray arrayWithObjects:selectedLanguage, nil];
        *_CFBundleUserLanguages = (__bridge CFMutableArrayRef)newUserLanguages;
    } else {
        [newStandardUserDefaults removeObjectForKey:@"AppleLanguages"];
    }
#endif
    
    // Create Library/Preferences folder in app's data folder in case it does not exist
    NSFileManager* fm = NSFileManager.defaultManager;
    NSURL* libraryPath = [fm URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].lastObject;
    NSURL* preferenceFolderPath = [libraryPath URLByAppendingPathComponent:@"Preferences"];
    if(![fm fileExistsAtPath:preferenceFolderPath.path]) {
        NSError* error;
        [fm createDirectoryAtPath:preferenceFolderPath.path withIntermediateDirectories:YES attributes:@{} error:&error];
    }

    // 把客体域的偏好状态按磁盘 plist 对齐（Phase 12 第 3 项，真机证据定案）：
    // 宿主 UI（游戏库设置页）是绕过 cfprefsd 直写客体 plist 文件的，而
    // cfprefsd 按「自己是域文件的唯一写者」缓存域内容——它在客体上次运行
    // 时缓存的那一代值不会因外部改文件而失效。于是单向同步：客体写→经
    // cfprefsd 落盘→宿主直读文件能看到；宿主直写文件→客体启动经 cfprefsd
    // 读到的仍是上一代。上面的 _sources 逐出只清本进程的来源表（PR #9 已
    // 扩到全量，真机仍失败），陈旧层在守护进程、不在进程内。故在身份切换
    // 完成、客体任何初始化器运行之前，把磁盘文件逐键种进客体域：文件有
    // 的键以文件为准；文件已删的托管键（launcher.* / DmPadCustom*，宿主
    // 「恢复默认」会删键）若域缓存里还残留，一并摘除；最后同步一次，把
    // 对齐后的状态压回 cfprefsd，覆盖它手里的上一代缓存——此后经
    // UserDefaults 与经 CFPreferences 的读都以文件现状为准。文件不存在
    // （客体没跑过）时无事可做，跳过。
    NSString* guestPrefsPath = [[appContainerPath stringByAppendingPathComponent:@"Library/Preferences"]
        stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", NSUserDefaults.lcGuestAppId]];
    NSDictionary* fileValues = [NSDictionary dictionaryWithContentsOfFile:guestPrefsPath];
    if(fileValues) {
        NSDictionary* cachedDomain = [newStandardUserDefaults persistentDomainForName:NSUserDefaults.lcGuestAppId];
        for(NSString* key in cachedDomain) {
            if(!fileValues[key] && ([key hasPrefix:@"launcher."] || [key hasPrefix:@"DmPadCustom"])) {
                [newStandardUserDefaults removeObjectForKey:key];
            }
        }
        for(NSString* key in fileValues) {
            [newStandardUserDefaults setObject:fileValues[key] forKey:key];
        }
        CFPreferencesAppSynchronize((__bridge CFStringRef)NSUserDefaults.lcGuestAppId);
    }

}

NSArray* appleIdentifierPrefixes = @[
    @"com.apple.",
    @"group.com.apple.",
    @"systemgroup.com.apple."
];

bool isAppleIdentifier(NSString* identifier) {
    for(NSString* cur in appleIdentifierPrefixes) {
        if([identifier hasPrefix:cur]) {
            return true;
        }
    }
    return false;
}


@implementation CFPrefsPlistSource2
-(id)hook_initWithDomain:(CFStringRef)domain user:(CFStringRef)user byHost:(bool)host containerPath:(CFStringRef)containerPath containingPreferences:(id)arg5 {
    // The global domain holds system-wide settings, AppleKeyboards among them. Moved into the guest's
    // container it is empty, so the guest's keyboard has one input mode and no globe key.
    if(isAppleIdentifier((__bridge NSString*)domain) || CFEqual(domain, kCFPreferencesAnyApplication)) {
        return [self hook_initWithDomain:domain user:user byHost:host containerPath:containerPath containingPreferences:arg5];
    }
    if(user == kCFPreferencesAnyUser) {
        user = kCFPreferencesCurrentUser;
    }
    return [self hook_initWithDomain:domain user:user byHost:host containerPath:(__bridge CFStringRef)appContainerPath containingPreferences:arg5];
}
@end
