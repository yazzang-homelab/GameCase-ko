#import "FoundationPrivate.h"
#import "LCMachOUtils.h"
#import "LCSharedUtils.h"
#import "UIKitPrivate.h"
#import "utils.h"

#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/dyld_images.h>
#include <objc/runtime.h>

#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <stdlib.h>
#include "../litehook/src/litehook.h"
#import "Tweaks/Tweaks.h"
#import "Localization.h"
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#include <mach-o/ldsyms.h>

extern char **environ;
static int (*appMain)(int, char**, char**);
NSUserDefaults *lcUserDefaults;
NSUserDefaults *lcSharedDefaults;
NSString *lcAppGroupPath;
NSString* lcAppUrlScheme;
NSBundle* lcMainBundle;
NSDictionary* guestAppInfo;
NSDictionary* guestContainerInfo;
NSString* lcGuestAppId;
NSString* lcLaunchURL;
bool isLiveProcess = false;
bool isSharedBundle = false;
bool isSideStore = false;
bool sideStoreExist = false;

@implementation NSUserDefaults(LiveContainer)
+ (instancetype)lcUserDefaults {
    return lcUserDefaults;
}
+ (instancetype)lcSharedDefaults {
    if(!lcUserDefaults) {
        lcSharedDefaults = [[NSUserDefaults alloc] initWithSuiteName: [LCSharedUtils appGroupID]];
    }
    return lcSharedDefaults;
}
+ (NSString *)lcAppGroupPath {
    return lcAppGroupPath;
}
+ (NSString *)lcAppUrlScheme {
    return lcAppUrlScheme;
}
+ (NSBundle *)lcMainBundle {
    return lcMainBundle;
}
+ (NSDictionary *)guestAppInfo {
    return guestAppInfo;
}

+ (NSDictionary *)guestContainerInfo {
    return guestContainerInfo;
}

+ (bool)isLiveProcess {
    return isLiveProcess;
}
+ (bool)isSharedApp {
    return isSharedBundle;
}
+ (bool)isSideStore {
    return isSideStore;
}
+ (bool)sideStoreExist {
    return sideStoreExist;
}

+ (NSString*)lcGuestAppId {
    return lcGuestAppId;
}
+ (NSString*)lcLaunchURL {
    return lcLaunchURL;
}
@end

static BOOL checkJITEnabled() {
#if TARGET_OS_MACCATALYST || TARGET_OS_SIMULATOR
    return YES;
#else
    if([lcUserDefaults boolForKey:@"LCIgnoreJITOnLaunch"]) {
        return NO;
    }
    // check if jailbroken
    if (access("/usr/lib/systemhook.dylib", R_OK) == 0) {
        return YES;
    }
    
    // check csflags
    int flags;
    csops(getpid(), 0, &flags, sizeof(flags));
    return (flags & CS_DEBUGGED) != 0;
#endif
}

static uint64_t rnd64(uint64_t v, uint64_t r) {
    r--;
    return (v + r) & ~r;
}

void overwriteMainCFBundle(void) {
    // Overwrite CFBundleGetMainBundle
    uint32_t *pc = (uint32_t *)CFBundleGetMainBundle;
    void **mainBundleAddr = 0;
    
#if !TARGET_OS_SIMULATOR
    if(@available(iOS 27.0, *)) {
        // at least in iOS 27.0 db1, the logic is inversed and the __mainBundle is right after the first tbz instruction
        while (true) {
            bool isTbz = ((*pc) & 0x7F000000) == 0x36000000;
            if (isTbz) {
                // adrp <- pc-1
                // tbz <- pc
                // ldr  <- addr
                mainBundleAddr = (void **)aarch64_emulate_adrp_ldr(*(pc-1), *(uint32_t *)(pc+1), (uint64_t)(pc-1));
                break;
            }
            ++pc;
        }
    } else {
#endif
        while (true) {
            uint64_t addr = aarch64_get_tbnz_jump_address(*pc, (uint64_t)pc);
            if (addr) {
                // adrp <- pc-1
                // tbnz <- pc
                // ...
                // ldr  <- addr
                mainBundleAddr = (void **)aarch64_emulate_adrp_ldr(*(pc-1), *(uint32_t *)addr, (uint64_t)(pc-1));
                break;
            }
            ++pc;
        }
#if !TARGET_OS_SIMULATOR
    }
#endif
    assert(mainBundleAddr != NULL);
    *mainBundleAddr = (__bridge void *)NSBundle.mainBundle._cfBundle;
}

void overwriteMainNSBundle(NSBundle *newBundle) {
    // Overwrite NSBundle.mainBundle
    // iOS 16: x19 is _MergedGlobals
    // iOS 17: x19 is _MergedGlobals+4

    NSString *oldPath = NSBundle.mainBundle.executablePath;
    uint32_t *mainBundleImpl = (uint32_t *)method_getImplementation(class_getClassMethod(NSBundle.class, @selector(mainBundle)));
    for (int i = 0; i < 20; i++) {
        void **_MergedGlobals = (void **)aarch64_emulate_adrp_add(mainBundleImpl[i], mainBundleImpl[i+1], (uint64_t)&mainBundleImpl[i]);
        if (!_MergedGlobals) continue;

        // In iOS 17, adrp+add gives _MergedGlobals+4, so it uses ldur instruction instead of ldr
        if ((mainBundleImpl[i+4] & 0xFF000000) == 0xF8000000) {
            uint64_t ptr = (uint64_t)_MergedGlobals - 4;
            _MergedGlobals = (void **)ptr;
        }

        for (int mgIdx = 0; mgIdx < 20; mgIdx++) {
            if (_MergedGlobals[mgIdx] == (__bridge void *)NSBundle.mainBundle) {
                _MergedGlobals[mgIdx] = (__bridge void *)newBundle;
                break;
            }
        }
    }

    assert(![NSBundle.mainBundle.executablePath isEqualToString:oldPath]);
}

typedef struct {
    void *gap_0x0[2];                  // 0x00, 0x08
    char *mainExecutablePath_old;      // 0x10
    void *gap_0x18;                    // 0x18
    char *mainExecutablePath_18_4;     // 0x20
    size_t mainExecutablePathLen_27_0; // 0x28
} DyldConfig;
typedef struct {
    void *gap_0x0;
    DyldConfig *dyldConfig;
} DyldAPI;

int hook__NSGetExecutablePath_overwriteExecPath(DyldAPI* dyldApiInstancePtr, char* newPath, uint32_t* bufsize) {
    assert(dyldApiInstancePtr != 0);
    DyldConfig* dyldConfig = dyldApiInstancePtr->dyldConfig;
    assert(dyldConfig != 0);
    
    char** mainExecutablePathPtr = 0;
    // mainExecutablePath is at 0x10 for iOS 15~18.3.2, 0x20 for iOS 18.4+
    if(dyldConfig->mainExecutablePath_old != 0 && dyldConfig->mainExecutablePath_old[0] == '/') {
        mainExecutablePathPtr = &(dyldConfig->mainExecutablePath_old);
    } else if (dyldConfig->mainExecutablePath_18_4 != 0 && dyldConfig->mainExecutablePath_18_4[0] == '/') {
        mainExecutablePathPtr = &(dyldConfig->mainExecutablePath_18_4);
    } else {
        assert(mainExecutablePathPtr != 0);
    }

    kern_return_t ret = builtin_vm_protect(mach_task_self(), (mach_vm_address_t)dyldConfig, sizeof(dyldConfig), false, PROT_READ | PROT_WRITE);
    if(ret != KERN_SUCCESS) {
        assert(os_tpro_is_supported());
        os_thread_self_restrict_tpro_to_rw();
    }
    *mainExecutablePathPtr = newPath;
    
    // in iOS 27, the length is also cached, it's at +0x28
    if(@available(iOS 27.0, *)) {
        dyldConfig->mainExecutablePathLen_27_0 = strlen(newPath);
    }
    
    if(ret != KERN_SUCCESS) {
        os_thread_self_restrict_tpro_to_ro();
    }

    return 0;
}

void overwriteExecPath(const char *newExecPath) {
    // dyld4 stores executable path in a different place (iOS 15.0 +)
    // https://github.com/apple-oss-distributions/dyld/blob/ce1cc2088ef390df1c48a1648075bbd51c5bbc6a/dyld/DyldAPIs.cpp#L802
    int (*orig__NSGetExecutablePath)(void* dyldPtr, char* buf, uint32_t* bufsize);
    performHookDyldApi("_NSGetExecutablePath", 2, (void**)&orig__NSGetExecutablePath, hook__NSGetExecutablePath_overwriteExecPath);
    _NSGetExecutablePath((char*)newExecPath, NULL);
    // put the original function back
    performHookDyldApi("_NSGetExecutablePath", 2, (void**)&orig__NSGetExecutablePath, orig__NSGetExecutablePath);
}

static void *getAppEntryPoint(void *handle) {
    uint32_t entryoff = 0;
    const struct mach_header_64 *header = (struct mach_header_64 *)getGuestAppHeader();
    uint8_t *imageHeaderPtr = (uint8_t*)header + sizeof(struct mach_header_64);
    struct load_command *command = (struct load_command *)imageHeaderPtr;
    for(int i = 0; i < header->ncmds; ++i) {
        if(command->cmd == LC_MAIN) {
            struct entry_point_command ucmd = *(struct entry_point_command *)imageHeaderPtr;
            entryoff = ucmd.entryoff;
            break;
        }
        imageHeaderPtr += command->cmdsize;
        command = (struct load_command *)imageHeaderPtr;
    }
    assert(entryoff > 0);
    return (void *)header + entryoff;
}

#pragma mark - 快捷栏（游戏内「返回游戏库」）
// 形态：游戏在本进程内全屏直跑（standalone 路径），客体场景之上挂一个高层级小窗，
// 承载可四边吸附的玻璃舌与展开快捷栏。同进程内恢复宿主 UI 不可行——invokeAppMain
// 跳入客体 main 后不返回，宿主 UI 从未在本进程加载——因此回库动作沿用已真机验证的
// 自拉起机制：清掉 selected 后调用 launchToGuestAppWithClassicMode:，新启的 LC 进程
// 因 selected 已清而直接进入游戏库，客体进程随之终止（串行单开，符合既定规格）。
//
// 状态机（只吸上边，两态）：吸附态（横舌半藏于上边）→ 点击展开（完整胶囊自
// 上边垂下）→ 点「游戏库」回库 / 点栏外或 3 秒无操作收回吸附态。舌与栏均可拖动，
// 松手一律吸回上边，只保留落点的水平位置（沿上边的比例）。四边吸附 + 形态旋转
// 的组合在真机上屡修不稳，按定版规格收敛为上边单一形态。
// 持久化：本进程的 standardUserDefaults 已被客体钩子改指到客体容器（见
// Tweaks/NSUserDefaults.m 的 NUDGuestHooksInit），不能存宿主状态；改用宿主容器内
// 显式路径的 plist（LC_HOME_PATH/Library/Preferences/LCQuickBar.plist），存水平
// 位置比例与回库 returning 标记（edge 键恒写上边值、保留键位兼容旧状态文件），
// 库侧 LCAppListView 读同一文件消费 returning。

// 状态文件 edge 键的恒定值：上边（旧四边版本的编号），仅为兼容已落盘的旧文件。
static const NSInteger LCQBStoredEdgeTop = 2;

typedef NS_ENUM(NSInteger, LCQBDirection) {
    LCQBDirectionLeft,
    LCQBDirectionRight,
    LCQBDirectionUp,
    LCQBDirectionDown,
};

// 横舌全尺寸 44（厚）×60（长）pt、约 41% 半藏（露出 26pt）；展开胶囊高 46pt、离上边 12pt。
static const CGFloat LCQBTongueThickness = 44;
static const CGFloat LCQBTongueLength = 60;
static const CGFloat LCQBTongueVisible = 26;
static const CGFloat LCQBBarHeight = 46;
static const CGFloat LCQBBarGap = 12;
static const NSTimeInterval LCQBAutoCollapseDelay = 3;

// 宿主 App 包内查本地化文案：invokeAppMain 的报错在 mainBundle 已被
// overwriteMainNSBundle 换成客体包之后仍要取宿主文案，故显式用启动时
// 存下的 lcMainBundle 查 Localizable 表，不走 mainBundle 通道。
static NSString *LCBootstrapLocalized(NSString *key) {
    NSBundle *bundle = lcMainBundle ?: NSBundle.mainBundle;
    return [bundle localizedStringForKey:key value:nil table:nil];
}

// 宿主进程的系统首选语言缓存（赋值点在 invokeAppMain 调 NUDGuestHooksInit
// 之前）：LCQBLibraryTitle 在客体阶段才被调用，那时偏好 hooks 已把偏好域
// 换成客体、且未设 LCSelectedLanguage 时会删掉 AppleLanguages，
// preferredLanguages 退化成客体包的开发语言（恒 "en"），不能现读。
static NSString *LCQBHostPreferredLanguage = nil;

// 快捷栏「游戏库」文案：本代码跑在客体进程内，mainBundle 可能已指向客体，
// 不能走 NSLocalizedString；按系统首选语言直接挑文案（zh / pt / 其余英文）。
static NSString *LCQBLibraryTitle(void) {
    NSString *lang = (LCQBHostPreferredLanguage ?: NSLocale.preferredLanguages.firstObject).lowercaseString ?: @"en";
    if ([lang hasPrefix:@"zh"]) return @"游戏库";
    if ([lang hasPrefix:@"pt"]) return @"Biblioteca";
    return @"Library";
}

#pragma mark - 状态文件

static NSString *LCQBStatePath(void) {
    const char *home = getenv("LC_HOME_PATH");
    NSString *base = home ? [NSString stringWithUTF8String:home] : NSHomeDirectory();
    return [base stringByAppendingPathComponent:@"Library/Preferences/LCQuickBar.plist"];
}

static NSMutableDictionary *LCQBLoadState(void) {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:LCQBStatePath()];
    return dict ? [dict mutableCopy] : [NSMutableDictionary dictionary];
}

static void LCQBSaveState(NSDictionary *state) {
    NSString *path = LCQBStatePath();
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [state writeToFile:path atomically:YES];
}

#pragma mark - 游玩时长（Phase 18，与库侧 LCPlayStats 同一文件格式）
// 纯容器侧计时：开始戳由库侧 runApp 漏斗写进宿主 Documents/LCPlayStats.plist
// 的 openSession；本进程（客体）只做两件事——每 60 秒刷一次 lastHeartbeat、
// 回库时结清本局。路径同 LCQBStatePath 的口径：本进程 standardUserDefaults
// 已被改指到客体容器，必须用 LC_HOME_PATH 显式拼宿主路径。客体不需要知道
// 自己是谁：串行单开保证 openSession 至多一个，键里的 bundleId 由库侧写。
// 闪退/被划掉没结清的局，库主页下次出现时按 lastHeartbeat 补结（±60 秒）。

static NSString *LCPSStatsPath(void) {
    const char *home = getenv("LC_HOME_PATH");
    NSString *base = home ? [NSString stringWithUTF8String:home] : NSHomeDirectory();
    return [base stringByAppendingPathComponent:@"Documents/LCPlayStats.plist"];
}

static NSMutableDictionary *LCPSLoadRoot(void) {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:LCPSStatsPath()];
    return dict ? [dict mutableCopy] : nil;
}

static void LCPSSaveRoot(NSDictionary *root) {
    NSString *path = LCPSStatsPath();
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [root writeToFile:path atomically:YES];
}

static NSTimeInterval LCPSClampedDuration(NSTimeInterval duration) {
    if (duration < 0) return 0;
    if (duration > 24 * 3600) return 24 * 3600;
    return duration;
}

static void LCPSHeartbeat(void) {
    NSMutableDictionary *root = LCPSLoadRoot();
    if (!root) return;
    NSDictionary *open = root[@"openSession"];
    if (![open isKindOfClass:NSDictionary.class]) return;
    NSMutableDictionary *session = [open mutableCopy];
    session[@"lastHeartbeat"] = [NSDate date];
    root[@"openSession"] = session;
    LCPSSaveRoot(root);
}

// 回库结清：时长钳制 [0, 24h] 防时钟跳变；>0 才入账（与库侧补结同一规则）。
static void LCPSCloseSession(void) {
    NSMutableDictionary *root = LCPSLoadRoot();
    if (!root) return;
    NSDictionary *open = root[@"openSession"];
    [root removeObjectForKey:@"openSession"];
    if ([open isKindOfClass:NSDictionary.class]) {
        NSDate *start = open[@"start"];
        NSString *bundleId = open[@"bundleId"];
        NSDate *end = [NSDate date];
        if ([start isKindOfClass:NSDate.class] && [bundleId isKindOfClass:NSString.class]) {
            NSTimeInterval duration = LCPSClampedDuration([end timeIntervalSinceDate:start]);
            if (duration > 0) {
                NSMutableDictionary *apps = [root[@"apps"] mutableCopy] ?: [NSMutableDictionary dictionary];
                NSMutableDictionary *entry = [apps[bundleId] mutableCopy] ?: [NSMutableDictionary dictionary];
                entry[@"totalSeconds"] = @([entry[@"totalSeconds"] doubleValue] + duration);
                entry[@"lastSessionSeconds"] = @(duration);
                entry[@"lastPlayedAt"] = end;
                entry[@"sessionCount"] = @([entry[@"sessionCount"] integerValue] + 1);
                apps[bundleId] = entry;
                root[@"apps"] = apps;
            }
        }
    }
    LCPSSaveRoot(root);
}

#pragma mark - 图标绘制（与预览稿同构的白色线形图标）

static UIImage *LCQBRenderImage(CGSize size, void (^draw)(void)) {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
        draw();
    }];
}

// 六点握把：竖向 2 列 × 3 行，横向 3 列 × 2 行（横向款用于吸附舌，13×9）
static UIImage *LCQBGripImage(BOOL vertical) {
    CGSize size = vertical ? CGSizeMake(11, 17) : CGSizeMake(13, 9);
    return LCQBRenderImage(size, ^{
        [[UIColor colorWithWhite:1 alpha:0.55] setFill];
        CGFloat vCols[2] = {0.27, 0.73};
        CGFloat vRows[3] = {0.16, 0.5, 0.84};
        CGFloat hCols[3] = {0.16, 0.5, 0.84};
        CGFloat hRows[2] = {0.27, 0.73};
        CGFloat *colFrac = vertical ? vCols : hCols;
        CGFloat *rowFrac = vertical ? vRows : hRows;
        int cols = vertical ? 2 : 3;
        int rows = vertical ? 3 : 2;
        for (int i = 0; i < cols; i++) {
            for (int j = 0; j < rows; j++) {
                CGFloat cx = size.width * colFrac[i];
                CGFloat cy = size.height * rowFrac[j];
                [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(cx - 1.2, cy - 1.2, 2.4, 2.4)] fill];
            }
        }
    });
}

static UIImage *LCQBGamepadImage(void) {
    CGSize size = CGSizeMake(16, 16);
    return LCQBRenderImage(size, ^{
        CGFloat w = size.width, h = size.height;
        UIColor *ink = [UIColor colorWithWhite:1 alpha:0.92];
        [ink setStroke];
        [ink setFill];
        UIBezierPath *body = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(w * 0.05, h * 0.28, w * 0.90, h * 0.46)
                                                        cornerRadius:h * 0.23];
        body.lineWidth = 1.4;
        [body stroke];
        CGFloat cx = w * 0.30, cy = h * 0.51, a = w * 0.09;
        UIBezierPath *plus = [UIBezierPath bezierPath];
        [plus moveToPoint:CGPointMake(cx - a, cy)];
        [plus addLineToPoint:CGPointMake(cx + a, cy)];
        [plus moveToPoint:CGPointMake(cx, cy - a)];
        [plus addLineToPoint:CGPointMake(cx, cy + a)];
        plus.lineWidth = 1.4;
        [plus stroke];
        CGFloat r = w * 0.05;
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(w * 0.68 - r, h * 0.43 - r, 2 * r, 2 * r)] fill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(w * 0.81 - r, h * 0.57 - r, 2 * r, 2 * r)] fill];
    });
}

static UIImage *LCQBChevronImage(LCQBDirection dir) {
    CGSize size = CGSizeMake(12, 12);
    return LCQBRenderImage(size, ^{
        CGFloat w = size.width, h = size.height;
        CGPoint p1, p2, p3;
        switch (dir) {
            case LCQBDirectionLeft:
                p1 = CGPointMake(w * 0.66, h * 0.16); p2 = CGPointMake(w * 0.30, h * 0.50); p3 = CGPointMake(w * 0.66, h * 0.84);
                break;
            case LCQBDirectionRight:
                p1 = CGPointMake(w * 0.34, h * 0.16); p2 = CGPointMake(w * 0.70, h * 0.50); p3 = CGPointMake(w * 0.34, h * 0.84);
                break;
            case LCQBDirectionUp:
                p1 = CGPointMake(w * 0.16, h * 0.66); p2 = CGPointMake(w * 0.50, h * 0.30); p3 = CGPointMake(w * 0.84, h * 0.66);
                break;
            case LCQBDirectionDown:
                p1 = CGPointMake(w * 0.16, h * 0.34); p2 = CGPointMake(w * 0.50, h * 0.70); p3 = CGPointMake(w * 0.84, h * 0.34);
                break;
        }
        UIBezierPath *path = [UIBezierPath bezierPath];
        [path moveToPoint:p1];
        [path addLineToPoint:p2];
        [path addLineToPoint:p3];
        path.lineWidth = 1.6;
        path.lineJoinStyle = kCGLineJoinRound;
        path.lineCapStyle = kCGLineCapRound;
        [[UIColor colorWithWhite:1 alpha:0.78] setStroke];
        [path stroke];
    });
}

static UIImage *LCQBHouseImage(CGFloat side, CGFloat alpha, CGFloat lineWidth) {
    return LCQBRenderImage(CGSizeMake(side, side), ^{
        CGFloat w = side, h = side;
        [[UIColor colorWithWhite:1 alpha:alpha] setStroke];
        UIBezierPath *roof = [UIBezierPath bezierPath];
        [roof moveToPoint:CGPointMake(w * 0.08, h * 0.52)];
        [roof addLineToPoint:CGPointMake(w * 0.50, h * 0.12)];
        [roof addLineToPoint:CGPointMake(w * 0.92, h * 0.52)];
        roof.lineWidth = lineWidth;
        roof.lineJoinStyle = kCGLineJoinRound;
        roof.lineCapStyle = kCGLineCapRound;
        [roof stroke];
        UIBezierPath *body = [UIBezierPath bezierPath];
        [body moveToPoint:CGPointMake(w * 0.22, h * 0.42)];
        [body addLineToPoint:CGPointMake(w * 0.22, h * 0.88)];
        [body addLineToPoint:CGPointMake(w * 0.78, h * 0.88)];
        [body addLineToPoint:CGPointMake(w * 0.78, h * 0.42)];
        body.lineWidth = lineWidth;
        body.lineJoinStyle = kCGLineJoinRound;
        body.lineCapStyle = kCGLineCapRound;
        [body stroke];
        UIBezierPath *door = [UIBezierPath bezierPath];
        [door moveToPoint:CGPointMake(w * 0.44, h * 0.88)];
        [door addLineToPoint:CGPointMake(w * 0.44, h * 0.66)];
        [door addLineToPoint:CGPointMake(w * 0.56, h * 0.66)];
        [door addLineToPoint:CGPointMake(w * 0.56, h * 0.88)];
        door.lineWidth = lineWidth;
        door.lineJoinStyle = kCGLineJoinRound;
        [door stroke];
    });
}

#pragma mark - 触摸视图（轻点/拖动判别，与游戏触摸共存）
// 手工跟踪触摸：累计位移超过 8pt 才算拖动（此前不挪位置），轻点走 onTapAt。
// 拖动用绝对锚定：越过阈值那一刻记下锚点（触摸点 + 由处理器记起始帧），
// 之后每事件把当前触摸点原样回调，处理器以「起始帧 + 当前点 − 锚点」一次
// 算定新帧。不再逐事件累加增量——增量法曾用 locationInView:nil 取点，而
// nil 系是触摸所属窗口（正是被拖的浮层窗自己）的坐标系：窗口每挪一帧，
// 下一事件的报点基准被自己的移动反向污染一次，增量交替吃半，肉眼即步进
// 与末端细颤。测点统一换算到场景坐标空间（锚定显示器、恒定），锚定法下
// 测点误差也只影响当帧、不累积。

@interface LCQBTouchView : UIView
@property (nonatomic, copy, nullable) void (^onTapAt)(CGPoint point);
@property (nonatomic, copy, nullable) void (^onTouchBegan)(void);
@property (nonatomic, copy, nullable) void (^onDragStart)(CGPoint anchorPoint);
@property (nonatomic, copy, nullable) void (^onDragTo)(CGPoint point);
@property (nonatomic, copy, nullable) void (^onDragEnded)(void);
@end

@implementation LCQBTouchView {
    CGPoint _lastPoint;
    CGFloat _travel;
    BOOL _dragging;
}

// 固定测点：把触摸点换算到场景坐标空间。locationInView:nil 给的是触摸所属
// 窗口的坐标，随浮层窗移动而漂移，不能用作拖动基准。
- (CGPoint)fixedPointForTouch:(UITouch *)touch {
    CGPoint p = [touch locationInView:nil];
    UIWindowScene *scene = self.window.windowScene;
    if (scene && touch.window) {
        p = [scene.coordinateSpace convertPoint:p fromCoordinateSpace:touch.window.coordinateSpace];
    }
    return p;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _lastPoint = [self fixedPointForTouch:touches.anyObject];
    _travel = 0;
    _dragging = NO;
    if (self.onTouchBegan) self.onTouchBegan();
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint p = [self fixedPointForTouch:touches.anyObject];
    if (!_dragging) {
        _travel += fabs(p.x - _lastPoint.x) + fabs(p.y - _lastPoint.y);
        _lastPoint = p;
        if (_travel > 8) {
            _dragging = YES;
            // 锚点取越过阈值的当前点：阈值内的位移不计入拖动，无跳变无滞后
            if (self.onDragStart) self.onDragStart(p);
        }
        return;
    }
    if (self.onDragTo) self.onDragTo(p);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_dragging) {
        if (self.onDragEnded) self.onDragEnded();
    } else if (self.onTapAt) {
        // 轻点位置取视图自身坐标（当刻静止、无自参照问题），供处理器分发
        self.onTapAt([touches.anyObject locationInView:self]);
    }
    _dragging = NO;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_dragging && self.onDragEnded) self.onDragEnded();
    _dragging = NO;
}

@end

#pragma mark - 处理器

@class LCQuickBarHandler;

@interface LCQuickBarHandler : NSObject
+ (instancetype)sharedHandler;
- (void)attachToActiveSceneIfNeeded;
- (void)collapseFromOutsideTap;
- (void)relayoutForBounds:(CGRect)bounds;
- (void)screenSizeMayHaveChanged;
@end

@interface LCQBRootView : UIView
@property (nonatomic, weak) LCQuickBarHandler *handler;
@end

@implementation LCQBRootView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) {
        // 展开态下窗口全屏：点到栏外先收栏，且返回 nil 不吞这次触摸、让游戏接管。
        // 吸附态窗口只有舌大小，落到这里也只是让 collapseFromOutsideTap 空转。
        [self.handler collapseFromOutsideTap];
        return nil;
    }
    return hit;
}
@end

@interface LCQBRootViewController : UIViewController
@property (nonatomic, weak) LCQuickBarHandler *handler;
@end

@implementation LCQBRootViewController
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [self.handler relayoutForBounds:CGRectMake(0, 0, size.width, size.height)];
    } completion:nil];
}
@end

#pragma mark - 毛玻璃容器

// 深色毛玻璃：系统暗色模糊 + rgba(20,20,24) 染色近似预览稿的 .55 压暗，
// 白 0.18 描边，阴影挂在不裁剪的外层 wrapper 上。
static UIView *LCQBMakeGlass(CGFloat cornerRadius, UIView **outContentView) {
    UIView *wrapper = [[UIView alloc] init];
    wrapper.backgroundColor = UIColor.clearColor;
    wrapper.layer.shadowColor = UIColor.blackColor.CGColor;
    wrapper.layer.shadowOpacity = 0.35;
    wrapper.layer.shadowRadius = 10;
    wrapper.layer.shadowOffset = CGSizeMake(0, 4);
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    blur.layer.cornerRadius = cornerRadius;
    blur.layer.borderWidth = 1;
    blur.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    blur.clipsToBounds = YES;
    [wrapper addSubview:blur];
    UIView *tint = [[UIView alloc] init];
    tint.backgroundColor = [UIColor colorWithRed:20.0 / 255 green:20.0 / 255 blue:24.0 / 255 alpha:0.30];
    tint.userInteractionEnabled = NO;
    [blur.contentView addSubview:tint];
    if (outContentView) *outContentView = blur.contentView;
    return wrapper;
}

static void *LCQBSceneGeometryContext = &LCQBSceneGeometryContext;
static void *LCQBWindowBoundsContext = &LCQBWindowBoundsContext;

@implementation LCQuickBarHandler {
    UIWindow *_window;
    LCQBRootView *_rootView;
    UIWindowScene *_scene;
    BOOL _attached;
    CGSize _laidOutSize;
    NSMutableSet<UIWindow *> *_observedWindows;
    BOOL _geometryObserving;

    UIView *_tongueGlass;
    UIView *_tongueContent;
    LCQBTouchView *_tongueTouch;
    UIImageView *_gripView;
    UIImageView *_gamepadView;
    UIImageView *_chevronView;

    UIView *_barGlass;
    UIView *_barContent;
    LCQBTouchView *_barTouch;
    UIButton *_pillButton;
    UIButton *_collapseButton;
    CGFloat _barWidth;

    UIWindow *_veilWindow;
    NSTimer *_collapseTimer;

    CGFloat _ratio; // 沿上边的水平位置比例（0~1），唯一的落点记忆
    BOOL _expanded;
    BOOL _returning;
    BOOL _dragging;
    BOOL _animating;
    BOOL _relayoutPending; // 拖动/动画期间被守卫挡下的转屏重排，空闲后补跑一次
    CGPoint _dragAnchorPoint; // 拖动锚点（场景坐标），与 _dragStartFrame 成对
    CGRect _dragStartFrame;
    BOOL _dragAnchored;
}

+ (instancetype)sharedHandler {
    static LCQuickBarHandler *handler;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ handler = [LCQuickBarHandler new]; });
    return handler;
}

#pragma mark 挂载

- (void)sceneDidActivate:(NSNotification *)note {
    if ([note.object isKindOfClass:UIWindowScene.class]) {
        if (_attached && note.object == _scene) {
            // 已挂载的场景再次激活：所有旋转信号万一都漏了，这里按当前
            // bounds 做一次几何自愈（帧与现算结果不符才动，不闪烁）
            [self healLayoutIfNeeded];
        } else {
            [self attachToScene:(UIWindowScene *)note.object];
        }
    } else {
        [self attachToActiveSceneIfNeeded];
    }
}

- (void)windowDidBecomeKey:(NSNotification *)note {
    // 任一窗口成为 key 都顺带审计一次几何：attach 晚于客体转横屏完成时，
    // 初次布局可能用过过期 bounds，窗口焦点落定后按现状校正
    [self healLayoutIfNeeded];
}

- (void)attachToActiveSceneIfNeeded {
    if (_attached) {
        [self healLayoutIfNeeded];
        return;
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            [self attachToScene:(UIWindowScene *)scene];
            return;
        }
    }
}

- (void)attachToScene:(UIWindowScene *)scene {
    if (_attached || !scene) return;
    _attached = YES;
    _scene = scene;
    [self loadPersistedState];
    [self buildViews];

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelAlert + 100;
    window.backgroundColor = UIColor.clearColor;
    LCQBRootView *rootView = [[LCQBRootView alloc] init];
    rootView.handler = self;
    rootView.backgroundColor = UIColor.clearColor;
    LCQBRootViewController *rootVC = [LCQBRootViewController new];
    rootVC.handler = self;
    rootVC.view = rootView;
    window.rootViewController = rootVC;
    [rootView addSubview:_tongueGlass];
    [rootView addSubview:_barGlass];
    _rootView = rootView;
    _window = window;
    [self layoutForBounds:scene.coordinateSpace.bounds];
    // 显示前最后一道核对（硬验收）：窗口帧必须等于按当前 bounds 现算并钳制过
    // 的上边吸附帧，不一致就强制改回——旧 bounds 的过期几何（如竖长舌垂在顶上
    // 盖住客体标题）永远不许被直接亮出来
    CGRect expected = [self sanitizedDockedFrame:[self dockedFrameForBounds:scene.coordinateSpace.bounds]
                                       forBounds:scene.coordinateSpace.bounds];
    if (!CGRectEqualToRect(window.frame, expected)) {
        window.frame = expected;
    }
    window.hidden = NO;
    [self installRotationObservers];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(windowDidBecomeKey:)
                                               name:UIWindowDidBecomeKeyNotification
                                             object:nil];
    NSLog(@"[LCBootstrap][quickbar] 快捷栏已挂载（上边吸附, ratio=%.2f）", _ratio);
}

#pragma mark 旋转重排

// 重排不能只靠浮层窗口根 VC 的 viewWillTransitionToSize：真机上竖屏启动、客体把
// 场景转横屏后，该回调并不送达这个自建窗口的根 VC（窗口是被旋转变换整体搬走的，
// 内部布局没人重跑），舌就停在竖屏几何上，要点/拖一下触发 layout 才恢复。
// 改走与 VC 回调无关的可靠信号，任一触发都按场景当前 bounds 核对尺寸、变了才重排：
//   1) 场景 effectiveGeometry 的 KVO（iOS 16+，UIWindowScene 文档化可观察）；
//   2) 场景内其他窗口（客体主窗）bounds 的 KVO——客体窗被拉到新全屏尺寸即旋转落地；
//   3) UIApplicationDidChangeStatusBarOrientationNotification 兜底。
- (void)installRotationObservers {
    if (@available(iOS 16.0, *)) {
        if (!_geometryObserving) {
            _geometryObserving = YES;
            [_scene addObserver:self forKeyPath:@"effectiveGeometry" options:0 context:LCQBSceneGeometryContext];
        }
    }
    [self observeSceneWindows];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(screenSizeMayHaveChanged)
                                               name:UIApplicationDidChangeStatusBarOrientationNotification
                                             object:nil];
}

- (void)observeSceneWindows {
    if (!_observedWindows) _observedWindows = [NSMutableSet set];
    for (UIWindow *w in _scene.windows) {
        if (w == _window || w == _veilWindow || [_observedWindows containsObject:w]) continue;
        [_observedWindows addObject:w];
        [w addObserver:self forKeyPath:@"bounds" options:0 context:LCQBWindowBoundsContext];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (context == LCQBSceneGeometryContext || context == LCQBWindowBoundsContext) {
        [self screenSizeMayHaveChanged];
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)screenSizeMayHaveChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self relayoutIfScreenSizeChanged];
        // 窗口 bounds 可能先于场景坐标空间变化，0.3s 后再核对一次兜住滞后
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self relayoutIfScreenSizeChanged];
        });
    });
}

- (void)relayoutIfScreenSizeChanged {
    if (!_window || !_scene) return;
    // 拖动/动画期间不许整帧重排：重排按已持久化的旧 _ratio 把窗口写回吸附位，
    // 与手势直写形成双写者拉锯（录屏里的水平回弹、竖直弹回、宽度自变皆源于
    // 此）。与 healLayoutIfNeeded 同口径让行，但不丢弃：记待办，拖动/动画
    // 结束后由 flushPendingRelayoutIfNeeded 补跑，转屏跟随不回退。
    if (_dragging || _animating) {
        _relayoutPending = YES;
        return;
    }
    [self performRelayoutIfScreenSizeChanged];
}

- (void)performRelayoutIfScreenSizeChanged {
    [self observeSceneWindows]; // 顺带补上旋转后/迟建的客体窗口
    CGRect bounds = _scene.coordinateSpace.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return;
    if (CGSizeEqualToSize(bounds.size, _laidOutSize)) return;
    [self layoutForBounds:bounds];
}

// 补跑被守卫挡下的重排：调用点为拖动收尾（轻点/真拖动）与展开/收起动画完成，
// 彼时 _dragging/_animating 均已清零；重排内部仍会按尺寸判等，尺寸没变即空转。
- (void)flushPendingRelayoutIfNeeded {
    if (!_relayoutPending) return;
    _relayoutPending = NO;
    [self relayoutIfScreenSizeChanged];
}

// 自愈校正：不预设失效形态，按当前 scene bounds 现算上边吸附/展开几何，与
// 实际帧逐项比对，不符才走 layoutForBounds 重排（帧本就正确时零开销、不闪烁）。
// 触发源：场景再次激活、任一窗口成为 key、安装期的定时重试。覆盖：attach 时
// 用了过期 bounds、旋转信号全漏、拖动/动画中途被打断留下的错位帧。覆盖不了：
// bounds 本身还没更新完的瞬间（由旋转信号的 0.3s 二次核对接住）。
- (void)healLayoutIfNeeded {
    if (!_window || !_scene || _returning || _dragging || _animating) return;
    CGRect bounds = _scene.coordinateSpace.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return;
    BOOL mismatch;
    if (_expanded) {
        CGRect expectedBar = [self sanitizedBarFrame:[self barFrameForBounds:bounds] forBounds:bounds];
        mismatch = !CGRectEqualToRect(_window.frame, bounds) || !CGRectEqualToRect(_barGlass.frame, expectedBar);
    } else {
        CGRect expected = [self sanitizedDockedFrame:[self dockedFrameForBounds:bounds] forBounds:bounds];
        mismatch = !CGRectEqualToRect(_window.frame, expected);
    }
    if (mismatch) {
        NSLog(@"[LCBootstrap][quickbar] 几何自愈：按当前 bounds 重排（was %@）",
              NSStringFromCGRect(_window.frame));
        [self layoutForBounds:bounds];
    }
}

#pragma mark 视图构建

- (void)buildViews {
    __weak LCQuickBarHandler *weakSelf = self;

    // 吸附舌：触摸层在底，图标不拦截触摸、透传给触摸层
    UIView *tongueContent = nil;
    _tongueGlass = LCQBMakeGlass(15, &tongueContent);
    _tongueContent = tongueContent;
    LCQBTouchView *tongueTouch = [[LCQBTouchView alloc] init];
    tongueTouch.onTouchBegan = ^{ [weakSelf dragDidBegin]; };
    tongueTouch.onTapAt = ^(CGPoint point) { [weakSelf dragDidEnd]; [weakSelf expand]; };
    tongueTouch.onDragStart = ^(CGPoint point) { [weakSelf dragAnchorStartAtPoint:point forBar:NO]; };
    tongueTouch.onDragTo = ^(CGPoint point) { [weakSelf dragAnchoredToPoint:point forBar:NO]; };
    tongueTouch.onDragEnded = ^{ [weakSelf finishDragFromTongue]; };
    [_tongueContent addSubview:tongueTouch];
    _tongueTouch = tongueTouch;
    _gripView = [[UIImageView alloc] init];
    _gamepadView = [[UIImageView alloc] init];
    _chevronView = [[UIImageView alloc] init];
    [_tongueContent addSubview:_gripView];
    [_tongueContent addSubview:_gamepadView];
    [_tongueContent addSubview:_chevronView];

    // 展开栏：横向胶囊，B 档收窄后总宽 138——删纯装饰的握把+分隔线整段，
    // 胶囊左/上/下三边距同为 7、内边距 9/10、房子图标 17；收起钮视觉 28、命中域 44×46。
    // 触摸层盖在整栏最上层：栏身任意处可拖；轻点由处理器按落点分发到
    // 胶囊（回库）/收起钮（收起），两钮只作视觉、不拦截触摸。
    UIView *barContent = nil;
    _barGlass = LCQBMakeGlass(LCQBBarHeight / 2, &barContent);
    _barGlass.hidden = YES;
    _barContent = barContent;
    LCQBTouchView *barTouch = [[LCQBTouchView alloc] init];
    barTouch.onTouchBegan = ^{ [weakSelf dragDidBegin]; [weakSelf resetCollapseTimer]; };
    barTouch.onTapAt = ^(CGPoint point) { [weakSelf barTapAtPoint:point]; };
    barTouch.onDragStart = ^(CGPoint point) { [weakSelf dragAnchorStartAtPoint:point forBar:YES]; };
    barTouch.onDragTo = ^(CGPoint point) { [weakSelf dragAnchoredToPoint:point forBar:YES]; };
    barTouch.onDragEnded = ^{ [weakSelf finishDragFromBar]; };
    _barTouch = barTouch;

    UIFont *labelFont = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    CGFloat textWidth = ceil([LCQBLibraryTitle() sizeWithAttributes:@{NSFontAttributeName: labelFont}].width);
    CGFloat pillWidth = 9 + 17 + 6 + textWidth + 10;
    UIButton *pill = [UIButton buttonWithType:UIButtonTypeCustom];
    pill.frame = CGRectMake(7, (LCQBBarHeight - 32) / 2, pillWidth, 32);
    pill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.13];
    pill.layer.cornerRadius = 16;
    pill.layer.borderWidth = 1;
    pill.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;
    pill.clipsToBounds = YES;
    pill.userInteractionEnabled = NO;
    UIImageView *house = [[UIImageView alloc] initWithImage:LCQBHouseImage(17, 1.0, 1.5)];
    house.frame = CGRectMake(9, (32 - 17) / 2, 17, 17);
    [pill addSubview:house];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(9 + 17 + 6, 0, textWidth + 2, 32)];
    label.text = LCQBLibraryTitle();
    label.font = labelFont;
    label.textColor = UIColor.whiteColor;
    [pill addSubview:label];
    [_barContent addSubview:pill];
    _pillButton = pill;

    UIButton *collapse = [UIButton buttonWithType:UIButtonTypeCustom];
    collapse.frame = CGRectMake(7 + pillWidth, 0, 44, LCQBBarHeight);
    collapse.userInteractionEnabled = NO;
    [_barContent addSubview:collapse];
    _collapseButton = collapse;

    [_barContent addSubview:barTouch];

    _barWidth = 7 + pillWidth + 44;
}

#pragma mark 持久化

- (void)loadPersistedState {
    NSDictionary *state = LCQBLoadState();
    // edge 键是旧四边版本的遗留，一律忽略：只吸上边。只读水平位置比例，
    // 旧文件里的左右/下边落点比例平移过来即上边的位置，语义无损。
    NSNumber *ratio = state[@"ratio"];
    _ratio = ratio ? ratio.doubleValue : 0.5;
    _ratio = MAX(0, MIN(1, _ratio));
}

- (void)persistState {
    NSMutableDictionary *state = LCQBLoadState();
    state[@"edge"] = @(LCQBStoredEdgeTop);
    state[@"ratio"] = @(_ratio);
    LCQBSaveState(state);
}

#pragma mark 几何与布局

// 沿上边的水平中心点：比例换算后钳制在两角内侧
- (CGFloat)alongCenterForBounds:(CGRect)bounds {
    CGFloat center = _ratio * bounds.size.width;
    CGFloat half = LCQBTongueLength / 2 + 6;
    return MAX(half, MIN(center, bounds.size.width - half));
}

// 上边吸附帧（唯一的吸附几何）：横舌 60×44，上侧 18pt 藏在屏外
- (CGRect)dockedFrameForBounds:(CGRect)bounds {
    CGFloat center = [self alongCenterForBounds:bounds];
    return CGRectMake(center - LCQBTongueLength / 2, -(LCQBTongueThickness - LCQBTongueVisible),
                      LCQBTongueLength, LCQBTongueThickness);
}

// 合理性钳制（硬验收）：吸附帧的长/厚必须是规格值、原点必须落在顶边半藏位、
// 水平不得越出两角；任一不满足即按当前 bounds 现算的规范帧替换。所有显示路径
// 都经 layoutForBounds / attach 的这道钳制，禁止把跨 bounds 沿用的旧帧亮出来——
// 竖长舌从顶上垂下盖住客体标题的形态（旧 bounds 的 44×76 竖帧被原样显示）
// 在这里被结构性排除：本帧高恒为 44、y 恒为 -18。
- (CGRect)sanitizedDockedFrame:(CGRect)frame forBounds:(CGRect)bounds {
    CGFloat tucked = LCQBTongueThickness - LCQBTongueVisible;
    BOOL sane = fabs(frame.size.width - LCQBTongueLength) < 0.6 &&
                fabs(frame.size.height - LCQBTongueThickness) < 0.6 &&
                fabs(frame.origin.y + tucked) < 0.6 &&
                frame.origin.x >= -LCQBTongueLength / 2 - 1 &&
                frame.origin.x <= bounds.size.width - LCQBTongueLength / 2 + 1;
    if (sane) return frame;
    NSLog(@"[LCBootstrap][quickbar] 吸附帧不合规格 %@，按当前 bounds 重算", NSStringFromCGRect(frame));
    return [self dockedFrameForBounds:bounds];
}

// 展开胶囊帧：自上边垂下，离顶边 12pt，水平跟随舌的落点中心
- (CGRect)barFrameForBounds:(CGRect)bounds {
    CGFloat center = [self alongCenterForBounds:bounds];
    CGFloat w = _barWidth, h = LCQBBarHeight;
    CGFloat x = MAX(8, MIN(center - w / 2, bounds.size.width - w - 8));
    return CGRectMake(x, LCQBBarGap, w, h);
}

// 展开帧的合理性钳制：高/宽须为规格值、顶距恒为 12pt、水平不越界
- (CGRect)sanitizedBarFrame:(CGRect)frame forBounds:(CGRect)bounds {
    BOOL sane = fabs(frame.size.height - LCQBBarHeight) < 0.6 &&
                fabs(frame.size.width - _barWidth) < 0.6 &&
                fabs(frame.origin.y - LCQBBarGap) < 0.6 &&
                frame.origin.x >= 8 - 1 &&
                frame.origin.x <= bounds.size.width - _barWidth - 8 + 1;
    if (sane) return frame;
    NSLog(@"[LCBootstrap][quickbar] 展开帧不合规格 %@，按当前 bounds 重算", NSStringFromCGRect(frame));
    return [self barFrameForBounds:bounds];
}

- (void)sizeGlass:(UIView *)glass {
    UIVisualEffectView *blur = (UIVisualEffectView *)glass.subviews.firstObject;
    blur.frame = glass.bounds;
    blur.contentView.subviews.firstObject.frame = blur.bounds; // 染色层
}

- (void)layoutForBounds:(CGRect)bounds {
    if (!_window) return;
    _laidOutSize = bounds.size;
    if (_expanded) {
        _window.frame = bounds;
        _rootView.frame = bounds;
        _barGlass.frame = [self sanitizedBarFrame:[self barFrameForBounds:bounds] forBounds:bounds];
        [self sizeGlass:_barGlass];
        _barTouch.frame = _barContent.bounds;
        _tongueGlass.hidden = YES;
        _barGlass.hidden = NO;
    } else {
        CGRect frame = [self sanitizedDockedFrame:[self dockedFrameForBounds:bounds] forBounds:bounds];
        _window.frame = frame;
        _rootView.frame = CGRectMake(0, 0, frame.size.width, frame.size.height);
        _tongueGlass.frame = _rootView.bounds;
        [self sizeGlass:_tongueGlass];
        [self layoutTongueContent];
        _tongueGlass.hidden = NO;
        _barGlass.hidden = YES;
    }
    [self refreshChevronImages];
}

- (void)relayoutForBounds:(CGRect)bounds {
    [self layoutForBounds:bounds];
}

// 舌内元素沿长轴（水平）依次排：握把 13、间 6、手柄 16、间 6、箭头 10，共 51，
// 居中于长轴（两侧各 4.5）；纵轴对准可见带中心（贴顶边一侧 18pt 藏在屏外）。
- (void)layoutTongueContent {
    _tongueTouch.frame = _tongueContent.bounds;
    CGFloat stripCenter = LCQBTongueThickness - LCQBTongueVisible / 2;
    _gripView.image = LCQBGripImage(NO);
    _gamepadView.image = LCQBGamepadImage();
    CGFloat along[3] = {13, 16, 10};
    CGFloat cross[3] = {9, 16, 10};
    UIView *views[3] = {_gripView, _gamepadView, _chevronView};
    CGFloat pos = (LCQBTongueLength - 51) / 2;
    for (int i = 0; i < 3; i++) {
        views[i].frame = CGRectMake(pos, stripCenter - cross[i] / 2, along[i], cross[i]);
        pos += along[i] + 6;
    }
}

// 吸附态箭头朝下（向屏内展开）；展开态收起箭头朝上（向顶边收回）
- (void)refreshChevronImages {
    _chevronView.image = LCQBChevronImage(LCQBDirectionDown);
    [_collapseButton setImage:LCQBChevronImage(LCQBDirectionUp) forState:UIControlStateNormal];
}

#pragma mark 展开/收起

// 展开/收起的滑动方向恒为纵向：展开自上边垂下（入场从上方落下），收起升回上边
- (CGAffineTransform)edgeTranslation:(CGFloat)distance {
    return CGAffineTransformMakeTranslation(0, -distance);
}

- (void)expand {
    if (_expanded || !_window) return;
    _expanded = YES;
    _animating = YES;
    CGRect bounds = _scene.coordinateSpace.bounds;
    _window.frame = bounds;
    _rootView.frame = bounds;
    // 亮出之前先过钳制：帧按当前 bounds 现算，旧帧不直接显示
    _barGlass.frame = [self sanitizedBarFrame:[self barFrameForBounds:bounds] forBounds:bounds];
    [self sizeGlass:_barGlass];
    _barTouch.frame = _barContent.bounds;
    [self refreshChevronImages];
    _tongueGlass.hidden = YES;
    _barGlass.hidden = NO;
    UIView *bar = _barGlass;
    bar.alpha = 0;
    bar.transform = [self edgeTranslation:28];
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        bar.alpha = 1;
        bar.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        self->_animating = NO;
        [self flushPendingRelayoutIfNeeded];
    }];
    [self resetCollapseTimer];
}

- (void)collapseAnimated {
    if (!_expanded) return;
    _expanded = NO;
    _animating = YES;
    [self invalidateCollapseTimer];
    UIView *bar = _barGlass;
    CGAffineTransform slide = [self edgeTranslation:28];
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        bar.alpha = 0;
        bar.transform = slide;
    } completion:^(BOOL finished) {
        bar.hidden = YES;
        bar.alpha = 1;
        bar.transform = CGAffineTransformIdentity;
        self->_animating = NO;
        // 收回后回到吸附态：经 layoutForBounds 的钳制按当前 bounds 重排
        [self layoutForBounds:self->_scene.coordinateSpace.bounds];
        [self flushPendingRelayoutIfNeeded];
    }];
}

- (void)collapseFromOutsideTap {
    if (_expanded) [self collapseAnimated];
}

- (void)resetCollapseTimer {
    [_collapseTimer invalidate];
    _collapseTimer = nil;
    if (!_expanded) return;
    _collapseTimer = [NSTimer scheduledTimerWithTimeInterval:LCQBAutoCollapseDelay
                                                       target:self
                                                     selector:@selector(collapseFromTimer)
                                                     userInfo:nil
                                                      repeats:NO];
}

- (void)collapseFromTimer {
    if (_dragging) {
        // 拖动中不收栏：改期到松手后再计 3 秒（拖动路径已不再逐帧重置此计时器）
        [self resetCollapseTimer];
        return;
    }
    [self collapseAnimated];
}

- (void)invalidateCollapseTimer {
    [_collapseTimer invalidate];
    _collapseTimer = nil;
}

#pragma mark 拖动与吸附

// 展开栏轻点分发：触摸层全栏覆盖、两钮不拦截，落点在胶囊内走回库、
// 在收起钮命中域内走收起，其余只重置自动收起计时（与旧 onTap 行为一致）。
- (void)barTapAtPoint:(CGPoint)point {
    [self dragDidEnd];
    if (CGRectContainsPoint(_pillButton.frame, point)) {
        [self returnToLibrary];
    } else if (CGRectContainsPoint(_collapseButton.frame, point)) {
        [self collapseAnimated];
    } else {
        [self resetCollapseTimer];
    }
}

// 拖动跟手（绝对锚定）：越过拖动阈值时记锚点（场景坐标触摸点）与起始帧，
// 之后每事件以「起始帧 + 当前点 − 锚点」一次算定——不累加增量、无自参照
// 污染。只写 x：Y 全程钉死在起始帧的 y（舌 −18 / 栏 12），竖直拉不动。
// 每事件只做一次无动画直写，不走 layoutForBounds 全量几何（吸附判定 /
// 钳制 / 持久化只在松手时各做一次，见 finishDragFromTongue/Bar），
// CATransaction 关掉隐式动画，避免图层把每帧位移再插值一遍造成拖尾。
- (void)dragAnchorStartAtPoint:(CGPoint)point forBar:(BOOL)isBar {
    _dragAnchorPoint = point;
    _dragStartFrame = isBar ? _barGlass.frame : _window.frame;
    _dragAnchored = YES;
}

- (void)dragAnchoredToPoint:(CGPoint)point forBar:(BOOL)isBar {
    if (!_dragAnchored) return;
    CGRect frame = _dragStartFrame;
    frame.origin.x = _dragStartFrame.origin.x + (point.x - _dragAnchorPoint.x);
    // frame.origin.y 不写：保持 _dragStartFrame 的 y，即钉死
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (isBar) _barGlass.frame = frame; else _window.frame = frame;
    [CATransaction commit];
    // 注：不逐事件 resetCollapseTimer（每事件销毁/重建 NSTimer 是无谓的
    // runloop churn）；拖动中的自动收起由 collapseFromTimer 的 _dragging
    // 改期兜住，计时在 touchBegan 时已重置。
}

- (void)dragDidBegin {
    _dragging = YES;
    // 掐断可能在飞的吸附归位动画：它在动画块里持续写窗口帧，用户快速回抓时
    // 会与拖动直写抢帧。其 completion 为 nil，剥离无副作用。（展开/收起动画
    // 动的是栏的 transform/alpha、completion 非 nil，不在此剥离。）
    [_window.layer removeAllAnimations];
}

// 轻点（未成拖动）结束触摸时复位：自愈只在真拖动/动画期间让行；
// 若轻点期间有转屏重排被挡下，在此补跑（随后若触发展开，动画完成还会再核对）
- (void)dragDidEnd {
    _dragging = NO;
    _dragAnchored = NO;
    [self flushPendingRelayoutIfNeeded];
}

// 松手一律吸回上边：只取落点的水平坐标换算沿边比例落盘，纵向位置不保留
- (void)snapToTopFromCenter:(CGPoint)center inBounds:(CGRect)bounds {
    _ratio = bounds.size.width > 0 ? center.x / bounds.size.width : 0.5;
    _ratio = MAX(0, MIN(1, _ratio));
    [self persistState];
}

- (void)finishDragFromTongue {
    _dragging = NO;
    _dragAnchored = NO;
    CGRect bounds = _scene.coordinateSpace.bounds;
    [self snapToTopFromCenter:_window.center inBounds:bounds];
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        [self layoutForBounds:bounds];
    } completion:^(BOOL finished) {
        // 归位动画本身不置 _animating，待办重排在此补跑（内部按当前 bounds
        // 判等，拖动中真转了屏才生效，不与归位帧冲突）
        [self flushPendingRelayoutIfNeeded];
    }];
}

- (void)finishDragFromBar {
    _dragging = NO;
    _dragAnchored = NO;
    CGRect bounds = _scene.coordinateSpace.bounds;
    CGPoint center = CGPointMake(CGRectGetMidX(_barGlass.frame), CGRectGetMidY(_barGlass.frame));
    [self snapToTopFromCenter:center inBounds:bounds];
    [self collapseAnimated]; // 其 completion 补跑待办重排
}

#pragma mark 回库

- (void)returnToLibrary {
    if (_returning) return;
    _returning = YES;
    // 游玩时长先结清本局再走回库流程：重启后本进程不复存在，拖到库侧
    // 补结就只能按心跳算（白丢最后一分钟内的时间）。
    LCPSCloseSession();
    [self invalidateCollapseTimer];
    // returning 标记与吸附状态同文件：库侧冷启动读到后首帧盖黑、淡出时清除
    NSMutableDictionary *state = LCQBLoadState();
    state[@"edge"] = @(LCQBStoredEdgeTop);
    state[@"ratio"] = @(_ratio);
    state[@"returning"] = @YES;
    LCQBSaveState(state);
    [self showReturnVeil];
}

// 全屏黑遮罩：0.25s 淡入至全黑（中央白房子图标 + 「游戏库」小字），
// 全黑后再走回库原语，进程重启的接缝被盖在黑场里；库侧以同一标记接淡出。
- (void)showReturnVeil {
    CGRect bounds = _scene.coordinateSpace.bounds;
    UIWindow *veil = [[UIWindow alloc] initWithWindowScene:_scene];
    veil.windowLevel = UIWindowLevelAlert + 200;
    veil.frame = bounds;
    veil.backgroundColor = UIColor.blackColor;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.blackColor;
    UIImageView *house = [[UIImageView alloc] initWithImage:LCQBHouseImage(38, 0.9, 2.2)];
    house.frame = CGRectMake((bounds.size.width - 38) / 2, (bounds.size.height - 38) / 2 - 14, 38, 38);
    [vc.view addSubview:house];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, CGRectGetMaxY(house.frame) + 8, bounds.size.width, 18)];
    label.text = LCQBLibraryTitle();
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    label.textAlignment = NSTextAlignmentCenter;
    [vc.view addSubview:label];
    veil.rootViewController = vc;
    veil.alpha = 0;
    veil.hidden = NO;
    _veilWindow = veil;
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        veil.alpha = 1;
    } completion:^(BOOL finished) {
        // 以下为 dock-test-3 已真机验证的回库原语，调用内容与顺序保持原样
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults removeObjectForKey:@"selected"];
        [defaults removeObjectForKey:@"selectedContainer"];
        [defaults synchronize];
        NSLog(@"[LCBootstrap][quickbar] 点击返回游戏库，自拉起宿主 UI");
        [LCSharedUtils launchToGuestAppWithClassicMode:0];
    }];
}

@end

static BOOL lcQuickBarInstallAttempted;

static void LCQuickBarInstall(void) {
    if (lcQuickBarInstallAttempted) return;
    lcQuickBarInstallAttempted = YES;
    // 关闭开关（默认装）
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"LCQuickBarDisable"]) return;
    // 游玩时长心跳（Phase 18）：本函数在跳客体 main 前、进程内直跑路径上
    // 调用，是客体侧最早的可靠时点——先补一拍（openSession 自此有心跳，
    // 库侧补结能与「客体没跑起来」区分），之后每 60 秒一拍。NSTimer 挂主
    // runloop、随客体进程同生共死，正是需要的生命周期（进程没了就没心跳，
    // 库侧按最后一拍补结）。
    dispatch_async(dispatch_get_main_queue(), ^{
        LCPSHeartbeat();
        [NSTimer scheduledTimerWithTimeInterval:60 repeats:YES block:^(NSTimer *timer) {
            LCPSHeartbeat();
        }];
    });
    LCQuickBarHandler *handler = [LCQuickBarHandler sharedHandler];
    [NSNotificationCenter.defaultCenter addObserver:handler
                                           selector:@selector(sceneDidActivate:)
                                               name:UISceneDidActivateNotification
                                             object:nil];
    // 兜底重试：场景可能在通知注册前已激活，或客体建场较晚
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [handler attachToActiveSceneIfNeeded];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [handler attachToActiveSceneIfNeeded];
    });
}

// 客体容器「游玩名」换名：容器夹的静息名按产品口径取游戏名、可能含中文，
// 而某些第三方打包的客体（如 GLESign 的 Unity 一体包）在初始化早期会被
// 数据路径里的非 ASCII 字符弄坏（函数指针被未重定位数据占据后跳飞）。
// 修法不动静息名：启动漏斗在算客体 HOME 之前把真实文件夹同目录改名为
// ASCII 游玩名（客体 bundle id，被占则 .2/.3），客体全程面对真实 ASCII
// 路径；宿主每次启动（LiveContainerMain，进库读任何容器之前）先做一遍
// 回名扫描把处于换名态的夹改回静息名——回库必经宿主进程重拉，游玩中途
// 断电/被杀停在游玩名的夹也在下次打开 GC 时自愈。符号链接别名不行：
// 客体侧会把路径还原成真实路径，别名下照样崩（已实测否决）。
// 启用口径：只对静息名含非 ASCII 字符的容器启用（正是已证实的崩溃类）；
// ASCII 名容器零行为变化。书签容器与内置 SideStore 不走本漏斗，不受影响。
// 状态载体：容器夹内的标记文件，内容 = 静息夹名（UTF-8 纯文本）。状态
// 完全从文件系统判读、不依赖内存与宿主偏好：换名前先落标记再 rename，
// rename(2) 原子，进程在任何窗口被杀都能被回名扫描判读——夹在静息名且
// 有标记 = 残留标记（杀在落标记与 rename 之间），只删标记；夹在游玩名
// 且标记记着静息名 = 换名态，改回并删标记。
static NSString * const GCPlayNameSwapMarkerName = @".gcPlayNameSwap";

static BOOL GCPlayNameSwapNameHasNonASCII(NSString *name) {
    for (NSUInteger i = 0; i < name.length; i++) {
        if ([name characterAtIndex:i] > 0x7F) {
            return YES;
        }
    }
    return NO;
}

// 回名：扫一个数据根，把带标记且当前名 ≠ 标记所记静息名的真实目录改回
// 静息名。符号链接条目一律跳过；静息名位置被任何东西占用时绝不强占，
// 原样留待下轮（宿主每次启动都会再扫，占用方只可能是用户在文件 App 的
// 手工操作）。任何失败只 NSLog、绝不挡宿主启动。
static void GCPlayNameSwapRestoreDataRoot(NSString *dataRootPath) {
    if (dataRootPath.length == 0) {
        return;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:dataRootPath error:nil];
    for (NSString *entry in entries) {
        NSString *entryPath = [dataRootPath stringByAppendingPathComponent:entry];
        struct stat st;
        if (lstat(entryPath.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) {
            continue;
        }
        NSString *markerPath = [entryPath stringByAppendingPathComponent:GCPlayNameSwapMarkerName];
        NSString *restingName = [NSString stringWithContentsOfFile:markerPath encoding:NSUTF8StringEncoding error:nil];
        restingName = [restingName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (restingName.length == 0 || [restingName containsString:@"/"]) {
            continue; // 无标记或标记损坏：不动
        }
        if ([entry isEqualToString:restingName]) {
            [fm removeItemAtPath:markerPath error:nil]; // 残留标记
            continue;
        }
        NSString *restingPath = [dataRootPath stringByAppendingPathComponent:restingName];
        struct stat rst;
        if (lstat(restingPath.fileSystemRepresentation, &rst) == 0) {
            NSLog(@"[GCPlayNameSwap] rename-back blocked, resting slot occupied: %@", restingPath);
            continue;
        }
        if (rename(entryPath.fileSystemRepresentation, restingPath.fileSystemRepresentation) == 0) {
            [fm removeItemAtPath:[restingPath stringByAppendingPathComponent:GCPlayNameSwapMarkerName] error:nil];
        } else {
            NSLog(@"[GCPlayNameSwap] rename-back failed: %@ -> %@", entryPath, restingPath);
        }
    }
}

// 换名：把静息夹改名为游玩名并返回生效夹名（失败/不启用一律返回静息名，
// 行为与现行一致、绝不挡启动）。游玩名候选 = bundle id、.2、.3：位置为
// 空直接改名；位置是符号链接且指向本夹（旧别名方案的残留）删链让位再
// 改名；位置是真实目录/文件或指向别家的链接，绝不删除、试下一候选。
// 先落标记后改名，标记落不了就不换名（无状态载体不冒险）。
static NSString *GCPlayNameSwapToPlayName(NSString *dataRootPath, NSString *restingName, NSString *bundleId) {
    if (restingName.length == 0 || bundleId.length == 0 || dataRootPath.length == 0) {
        return restingName;
    }
    if (!GCPlayNameSwapNameHasNonASCII(restingName)) {
        return restingName;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *restingPath = [dataRootPath stringByAppendingPathComponent:restingName];
    struct stat st;
    if (lstat(restingPath.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) {
        return restingName;
    }
    NSString *markerPath = [restingPath stringByAppendingPathComponent:GCPlayNameSwapMarkerName];
    if (![restingName writeToFile:markerPath atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        return restingName;
    }
    NSArray<NSString *> *candidates = @[bundleId,
                                        [bundleId stringByAppendingString:@".2"],
                                        [bundleId stringByAppendingString:@".3"]];
    for (NSString *candidate in candidates) {
        if ([candidate isEqualToString:restingName]) {
            [fm removeItemAtPath:markerPath error:nil];
            return restingName;
        }
        NSString *candidatePath = [dataRootPath stringByAppendingPathComponent:candidate];
        struct stat cst;
        if (lstat(candidatePath.fileSystemRepresentation, &cst) == 0) {
            if (S_ISLNK(cst.st_mode)) {
                NSString *dest = [fm destinationOfSymbolicLinkAtPath:candidatePath error:nil];
                if (![dest isEqualToString:restingName] && ![dest isEqualToString:restingPath]) {
                    continue; // 别家的链接：让位
                }
                [fm removeItemAtPath:candidatePath error:nil]; // 指向本夹的残留别名：删链让位
            } else {
                continue; // 真实目录/文件：绝不删除
            }
        }
        if (rename(restingPath.fileSystemRepresentation, candidatePath.fileSystemRepresentation) == 0) {
            return candidate;
        }
    }
    [fm removeItemAtPath:markerPath error:nil]; // 候选全败：回滚标记，维持静息态
    return restingName;
}

#pragma mark - 启动动画（游戏启动封面）
// standalone 进程内直跑路径上，跳客体 main 前与快捷栏同处预置。与快捷栏一样，
// 本进程不存在宿主 UI，盖层只能挂在客体场景上：最早可建窗的时点是客体场景
// 激活（UISceneDidActivateNotification，与快捷栏同一挂载信号），盖层在那一刻
// 盖满场景，罩住客体加载至首帧的整段等待（此前的进程重拉与 invokeAppMain
// 装载段没有窗口可用，是架构上盖不住的固有黑段，不在本动画范围）。
// 画面（与批准预览同构图）：横版封面全屏缓推（scale 1.14→1.03，6s 缓出、
// 到顶停住不回弹）、底部渐变罩 + 游戏标题 + 细往复光带（indeterminate）。
// 结束信号认客体真正开始渲染的第一帧：钩 -[CAMetalLayer nextDrawable]
// （详见下方「首帧信号」段），第一块 drawable 被取走即渲染已开始。
// 撤盖时刻 = max(上盖 + 1.6s 总下限, 首帧信号 + 0.35s 落定)，其后 0.35s
// 淡出；点按跳过不受下限约束，30s 兜底不变。1.6s 下限的来由：首帧
// drawable 只是引擎开始画第一帧，dm 客体的第一帧是黑底清屏（手柄是
// UIKit 另绘、不经 Metal），logo 等真正内容还晚 1–2 秒，只按信号加
// 落定撤盖会在内容出现前露黑；0.9s 最短显示被 1.6s 下限包含。
// 两轮实测证伪的旧判读（勿再引入任何 attach 前置判死）：#106 用客体
// 主窗成为 key（UIWindowDidBecomeKeyNotification）判首帧并在 attach
// 前置检查里见 key 窗判死——客体窗在 UIApplicationMain 启动早期即成
// 为 key；#107 改认首帧信号、又在 attach 前置检查里见信号已到判死
// 迟到 attach——客体在场景连接/首个刷新周期就取走首块 drawable。
// 两个判据都必然早于最早的 attach 触发（场景激活通知，其次 2s/5s
// 兜底重试——与快捷栏同一套触发，快捷栏同期录屏稳定出现，证明触发
// 路径可靠），于是 attach 一律在入口判死、盖层从未上盖，两轮录屏症
// 状完全一致（黑屏段手柄可见、无封面无标题无光带）。现行口径：本次
// 启动内 attach 必上盖，信号先到只影响撤盖时刻、不影响上盖。
// 带启动器界面的客体若不用 Metal，信号不触发，走 30s 兜底撤盖。
// 全生命周期打点见下方「盖层打点日志」段：每行同步写进客体容器
// Documents/log.txt（设置页日志查看器读的同一文件）。若再不见盖层，
// 先看日志里 attach 的分支行定案，不要再靠时序推理改判读。
// 点任意处跳过：立即淡出撤层，客体在后面继续加载，不取消启动。
// 层级 Alert+50：盖住客体普通窗，低于快捷栏（+100，盖层之上舌仍露、
// 可回库逃生）与回库黑 veil（+200）。
// 封面解析与库侧 LCGameLibraryInfo.bannerResolution 同优先级：自定义封面 →
// 客体自带横版图 → 宿主内置原画 → 联网抓取缓存 → 应用图标放大虚化；解析在
// 后台队列做，不拖慢跳 main；未解析完先以深色底 + 标题上盖，图到后原地换入。
// 失败路径：安装点在 invokeAppMain 全部早期错误返回之后，早期报错不装盖层；
// 跳 main 后客体报错退出，进程随之终止、盖层同灭；下一进程的报错弹层由库侧
// 呈现，与盖层无交叠（库侧开屏动画在待报错时亦不播，见 LCAppListView init）。

/// 宿主进程首选语言在 LiveContainerMain 跳 invokeAppMain 前捕获（此后客体钩子
/// 会改写本进程的 AppleLanguages，届时现读 preferredLanguages 会退化成客体
/// 包语言——快捷栏语言修复同因）。仅供盖层提示文案按宿主语言查表。
static NSString *lcLaunchHostLanguage;

static void LCLaunchCoverCaptureHostLanguage(void) {
    lcLaunchHostLanguage = NSLocale.preferredLanguages.firstObject;
}

static NSString *LCLaunchCoverHintText(void) {
    NSString *key = @"lc.launchCover.skipHint";
    NSString *lang = lcLaunchHostLanguage;
    while (lang.length) {
        NSString *path = [lcMainBundle pathForResource:lang ofType:@"lproj"];
        if (path) {
            NSString *s = [[NSBundle bundleWithPath:path] localizedStringForKey:key value:nil table:nil];
            if (s.length && ![s isEqualToString:key]) return s;
            break;
        }
        NSRange cut = [lang rangeOfString:@"-" options:NSBackwardsSearch];
        if (cut.location == NSNotFound) break;
        lang = [lang substringToIndex:cut.location];
    }
    return [key localized];
}

#pragma mark 盖层打点日志

// 全生命周期打点（永久保留，仅启动路径低频事件）：同一行同步进 NSLog 与
// 客体容器 Documents/log.txt——设置页日志查看器读的就是这个文件，用户在
// GC 里打开该游戏的日志即可看到、也可直接发出。落点成立的依据：install
// 时点 invokeAppMain 已把本进程 HOME 切到客体容器根（见 invokeAppMain
// 中段 setenv HOME），此后按 $HOME/Documents/log.txt 拼路径即客体日志。
// 逐条 open(O_APPEND)-write-close 按路径写、不缓存句柄：dm 客体在自己
// main 入口会把上一局 log.txt 轮转为 log.prev.txt 并新建当期文件，按路
// 径写才能保证 main 之后的行落进当期 log.txt（install 行本身可能随轮转
// 进 log.prev.txt，attach/撤盖等关键行在 main 之后、不受影响）。
// 时间戳 = 相对 install 的单调毫秒（CACurrentMediaTime 差值），便于与
// 录屏逐帧对时序。
static CFTimeInterval lcCoverT0;
static void LCLaunchCoverLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void LCLaunchCoverLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    long long relMs = lcCoverT0 > 0 ? (long long)llround((CACurrentMediaTime() - lcCoverT0) * 1000.0) : -1;
    NSLog(@"[LCBootstrap][launchcover] %@", msg);
    const char *home = getenv("HOME");
    if (!home) return;
    NSString *line = [NSString stringWithFormat:@"[launchcover %+lldms] %@\n", relMs, msg];
    NSString *path = [NSString stringWithFormat:@"%s/Documents/log.txt", home];
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd >= 0) {
        const char *utf8 = line.UTF8String;
        (void)write(fd, utf8, strlen(utf8));
        close(fd);
    }
}

#pragma mark 封面解析（后台队列）

static BOOL LCLaunchCoverIsLandscapePixelSize(CGSize px) {
    return px.width > px.height && px.width >= 600 && px.width / px.height <= 3;
}

static UIImage *LCLaunchCoverGuestLandscapeImage(NSString *bundlePath) {
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:bundlePath error:nil];
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    for (NSString *e in entries) {
        NSString *ext = e.pathExtension.lowercaseString;
        if (([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"])
            && ![e.lowercaseString hasPrefix:@"appicon"]) {
            [files addObject:e];
        }
    }
    if (!files.count) return nil;
    // 候选名与库侧 bannerCandidateNames 同表同序
    static NSArray<NSString *> *candidates;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        candidates = @[@"LCBanner.jpg", @"LCBanner.png", @"banner.jpg", @"banner.png",
                       @"cover.jpg", @"cover.png", @"keyart.jpg", @"keyart.png",
                       @"header.jpg", @"header.png", @"capsule.jpg", @"capsule.png",
                       @"hero.jpg", @"hero.png", @"poster.jpg", @"poster.png",
                       @"artwork.jpg", @"artwork.png"];
    });
    NSMutableSet<NSString *> *candidateSet = [NSMutableSet set];
    for (NSString *cand in candidates) {
        for (NSString *f in files) {
            if ([f.lowercaseString isEqualToString:cand]) {
                [candidateSet addObject:f];
                UIImage *img = [UIImage imageWithContentsOfFile:[bundlePath stringByAppendingPathComponent:f]];
                if (img && LCLaunchCoverIsLandscapePixelSize(CGSizeMake(CGImageGetWidth(img.CGImage), CGImageGetHeight(img.CGImage)))) {
                    return img;
                }
            }
        }
    }
    UIImage *best = nil;
    CGFloat bestArea = 0;
    for (NSString *f in [files sortedArrayUsingSelector:@selector(compare:)]) {
        if ([candidateSet containsObject:f]) continue;
        UIImage *img = [UIImage imageWithContentsOfFile:[bundlePath stringByAppendingPathComponent:f]];
        if (!img) continue;
        CGSize px = CGSizeMake(CGImageGetWidth(img.CGImage), CGImageGetHeight(img.CGImage));
        if (!LCLaunchCoverIsLandscapePixelSize(px)) continue;
        CGFloat area = px.width * px.height;
        if (area > bestArea) { bestArea = area; best = img; }
    }
    return best;
}

static NSString *LCLaunchCoverTitleId(NSString *bundleId) {
    if (!bundleId.length) return nil;
    NSArray<NSString *> *parts = [bundleId.lowercaseString componentsSeparatedByString:@"."];
    // 与库侧 titleId(from:) 同规则：末段是 16 位十六进制优先，否则取首个命中段
    NSString *(^check)(NSArray<NSString *> *) = ^NSString *(NSArray<NSString *> *list) {
        for (NSString *p in list) {
            if (p.length != 16) continue;
            BOOL hex = YES;
            for (NSUInteger i = 0; i < p.length; i++) {
                unichar c = [p characterAtIndex:i];
                if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) { hex = NO; break; }
            }
            if (hex) return p.uppercaseString;
        }
        return nil;
    };
    NSString *hit = check(@[parts.lastObject ?: @""]);
    return hit ?: check(parts);
}

static UIImage *LCLaunchCoverBundledImage(NSString *bundleId) {
    NSString *titleId = LCLaunchCoverTitleId(bundleId);
    if (!titleId) return nil;
    NSString *name = [NSString stringWithFormat:@"cover-%@", titleId];
    NSString *fwPath = [lcMainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/LiveContainerSwiftUI.framework"];
    NSBundle *fwBundle = [NSBundle bundleWithPath:fwPath];
    NSMutableArray<NSBundle *> *bundles = [NSMutableArray array];
    if (fwBundle) [bundles addObject:fwBundle];
    [bundles addObject:lcMainBundle];
    for (NSBundle *b in bundles) {
        for (NSString *sub in @[[NSNull null], @"GameCovers"]) {
            NSURL *url = [b URLForResource:name withExtension:@"jpg" subdirectory:(sub == (id)NSNull.null ? nil : sub)];
            if (url) {
                UIImage *img = [UIImage imageWithContentsOfFile:url.path];
                if (img) return img;
            }
        }
    }
    return nil;
}

static UIImage *LCLaunchCoverGuestIconImage(NSString *bundlePath) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSArray *iconFiles = info[@"CFBundleIcons"][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"];
    if ([iconFiles isKindOfClass:NSArray.class]) {
        for (NSString *f in iconFiles) {
            if ([f isKindOfClass:NSString.class]) [names addObject:f];
        }
    }
    if (!names.count) {
        for (NSString *e in [NSFileManager.defaultManager contentsOfDirectoryAtPath:bundlePath error:nil]) {
            if ([e.lowercaseString hasPrefix:@"appicon"] && [e.lowercaseString hasSuffix:@".png"]) {
                [names addObject:e.stringByDeletingPathExtension];
            }
        }
    }
    UIImage *best = nil;
    CGFloat bestArea = 0;
    for (NSString *name in names) {
        for (NSString *suffix in @[@"@3x.png", @"@2x.png", @".png"]) {
            NSString *path = [bundlePath stringByAppendingPathComponent:[name stringByAppendingString:suffix]];
            if (![NSFileManager.defaultManager fileExistsAtPath:path]) continue;
            UIImage *img = [UIImage imageWithContentsOfFile:path];
            if (!img) continue;
            CGFloat area = img.size.width * img.size.height;
            if (area > bestArea) { bestArea = area; best = img; }
        }
    }
    return best;
}

static UIImage *LCLaunchCoverBlurredImage(UIImage *image) {
    CIImage *input = [CIImage imageWithCGImage:image.CGImage];
    if (!input) return nil;
    CGFloat radius = MAX(24, MIN(64, input.extent.size.width * 0.09));
    CIFilter *clamp = [CIFilter filterWithName:@"CIAffineClamp"];
    [clamp setValue:input forKey:kCIInputImageKey];
    [clamp setValue:[NSValue valueWithCGAffineTransform:CGAffineTransformIdentity] forKey:kCIInputTransformKey];
    CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
    [blur setValue:clamp.outputImage forKey:kCIInputImageKey];
    [blur setValue:@(radius) forKey:kCIInputRadiusKey];
    CIContext *context = [CIContext contextWithOptions:nil];
    CGImageRef cg = [context createCGImage:blur.outputImage fromRect:input.extent];
    if (!cg) return nil;
    UIImage *out = [UIImage imageWithCGImage:cg scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(cg);
    return out;
}

static NSString *LCLaunchCoverImageDesc(UIImage *img) {
    if (!img) return @"nil";
    return [NSString stringWithFormat:@"%.0fx%.0fpx",
            (double)CGImageGetWidth(img.CGImage), (double)CGImageGetHeight(img.CGImage)];
}

/// 与库侧 bannerResolution 同优先级：自定义 → 客体横版 → 内置原画 → 抓取缓存 → 图标虚化
static UIImage *LCLaunchCoverResolveImage(NSString *bundlePath, NSString *bundleId) {
    NSString *docPath = [NSString stringWithFormat:@"%s/Documents", getenv("LC_HOME_PATH")];
    UIImage *img = [UIImage imageWithContentsOfFile:[NSString stringWithFormat:@"%@/CustomCovers/%@.jpg", docPath, bundleId]];
    if (img) { LCLaunchCoverLog(@"封面解析命中 1/5 自定义封面 %@", LCLaunchCoverImageDesc(img)); return img; }
    img = LCLaunchCoverGuestLandscapeImage(bundlePath);
    if (img) { LCLaunchCoverLog(@"封面解析命中 2/5 客体自带横版图 %@", LCLaunchCoverImageDesc(img)); return img; }
    img = LCLaunchCoverBundledImage(bundleId);
    if (img) { LCLaunchCoverLog(@"封面解析命中 3/5 宿主内置原画 %@", LCLaunchCoverImageDesc(img)); return img; }
    img = [UIImage imageWithContentsOfFile:[NSString stringWithFormat:@"%@/FetchedCovers/%@.jpg", docPath, bundleId]];
    if (img) { LCLaunchCoverLog(@"封面解析命中 4/5 联网抓取缓存 %@", LCLaunchCoverImageDesc(img)); return img; }
    UIImage *icon = LCLaunchCoverGuestIconImage(bundlePath);
    if (icon) {
        UIImage *blurred = LCLaunchCoverBlurredImage(icon);
        LCLaunchCoverLog(@"封面解析命中 5/5 应用图标%@ %@", blurred ? @"虚化" : @"原图（虚化失败）",
                         LCLaunchCoverImageDesc(blurred ?: icon));
        return blurred ?: icon;
    }
    LCLaunchCoverLog(@"封面解析五级全未命中，结果 nil（盖层只剩深色底+标题）");
    return nil;
}

#pragma mark 盖层视图

/// 底部渐变罩：与预览同 stops（底 .82 → 42% 处 .25 → 65% 处全透）
@interface LCLaunchScrimView : UIView
@end
@implementation LCLaunchScrimView
+ (Class)layerClass { return CAGradientLayer.class; }
- (instancetype)init {
    self = [super init];
    CAGradientLayer *g = (CAGradientLayer *)self.layer;
    UIColor *ink = [UIColor colorWithRed:4/255.0 green:4/255.0 blue:8/255.0 alpha:1];
    g.colors = @[(__bridge id)[ink colorWithAlphaComponent:0.82].CGColor,
                 (__bridge id)[ink colorWithAlphaComponent:0.25].CGColor,
                 (__bridge id)UIColor.clearColor.CGColor];
    g.locations = @[@0, @0.42, @0.65];
    g.startPoint = CGPointMake(0.5, 1);
    g.endPoint = CGPointMake(0.5, 0);
    self.userInteractionEnabled = NO;
    return self;
}
@end

/// 盖层根视图：子视图帧全在 layoutSubviews 按当前 bounds 现算，旋转跟随无状态
@interface LCLaunchCoverView : UIView
@property (nonatomic, strong) UIImageView *coverView;
@property (nonatomic, strong) LCLaunchScrimView *scrimView;
@property (nonatomic, strong) UIView *metaView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *barTrack;
@property (nonatomic, strong) UIView *barSegment;
@property (nonatomic, copy) dispatch_block_t onTap;
@end
@implementation LCLaunchCoverView
- (instancetype)init {
    self = [super init];
    self.backgroundColor = [UIColor colorWithRed:7/255.0 green:7/255.0 blue:12/255.0 alpha:1];
    _coverView = [[UIImageView alloc] init];
    _coverView.contentMode = UIViewContentModeScaleAspectFill;
    _coverView.clipsToBounds = YES;
    [self addSubview:_coverView];
    _scrimView = [[LCLaunchScrimView alloc] init];
    [self addSubview:_scrimView];
    _metaView = [[UIView alloc] init];
    _metaView.userInteractionEnabled = NO;
    [self addSubview:_metaView];
    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.numberOfLines = 2;
    _titleLabel.layer.shadowColor = UIColor.blackColor.CGColor;
    _titleLabel.layer.shadowOpacity = 0.6;
    _titleLabel.layer.shadowRadius = 12;
    _titleLabel.layer.shadowOffset = CGSizeMake(0, 2);
    [_metaView addSubview:_titleLabel];
    _barTrack = [[UIView alloc] init];
    _barTrack.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
    _barTrack.layer.cornerRadius = 1.5;
    _barTrack.clipsToBounds = YES;
    [_metaView addSubview:_barTrack];
    _barSegment = [[UIView alloc] init];
    _barSegment.backgroundColor = [UIColor colorWithRed:0.949 green:0.918 blue:0.847 alpha:1];
    _barSegment.layer.cornerRadius = 1.5;
    [_barTrack addSubview:_barSegment];
    UILabel *hint = [[UILabel alloc] init];
    hint.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    hint.textColor = [UIColor colorWithWhite:1 alpha:0.55];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.attributedText = [[NSAttributedString alloc] initWithString:LCLaunchCoverHintText()
                                                          attributes:@{NSKernAttributeName: @1.8,
                                                                       NSFontAttributeName: hint.font,
                                                                       NSForegroundColorAttributeName: hint.textColor}];
    hint.tag = 1;
    [_metaView addSubview:hint];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
    [self addGestureRecognizer:tap];
    return self;
}
- (void)handleTap { if (self.onTap) self.onTap(); }
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    _coverView.frame = b;
    _scrimView.frame = b;
    // 底部信息组：标题 24 + 间隔 12 + 光带 3 + 间隔 10 + 提示 14，底边距取高 9% 与 28 的大者
    CGFloat metaH = 24 + 12 + 3 + 10 + 14;
    CGFloat bottomGap = MAX(b.size.height * 0.09, 28);
    _metaView.frame = CGRectMake(0, b.size.height - bottomGap - metaH, b.size.width, metaH);
    _titleLabel.frame = CGRectMake(20, 0, b.size.width - 40, 24);
    CGFloat trackW = 118;
    _barTrack.frame = CGRectMake((b.size.width - trackW) / 2, 24 + 12, trackW, 3);
    _barSegment.frame = CGRectMake(-12, 0, 52, 3);
    UIView *hint = [_metaView viewWithTag:1];
    hint.frame = CGRectMake(20, 24 + 12 + 3 + 10, b.size.width - 40, 14);
}
@end

#pragma mark 盖层处理器

@interface LCLaunchCoverHandler : NSObject
@property (nonatomic, copy) NSString *title;
+ (instancetype)sharedHandler;
- (void)beginObserving;
- (void)setResolvedCoverImage:(UIImage *)image;
- (void)guestFirstFrameDidRender;
- (void)evaluateDismissCondition;
- (void)dismissWithReason:(NSString *)reason duration:(NSTimeInterval)duration;
@end

#pragma mark 首帧信号（CAMetalLayer nextDrawable）

// 撤盖信号认客体真正开始渲染的第一帧：Metal 引擎渲染每帧前必经
// -[CAMetalLayer nextDrawable] 取走一块可绘制面，第一块被取走即渲染已开始，
// 其呈现在随后一两帧内（命令缓冲提交后）。这与窗口是否成为 key 无关——
// #106 用 UIWindowDidBecomeKeyNotification 判首帧已实测证伪（见段首总注）。
// #107 曾在本信号上再叠一层 attach 前置判死（信号已到 = 迟到 attach 不
// 上盖），同样证伪：客体在场景连接/首个刷新周期就取走首块 drawable，
// 必早于激活通知与 2s/5s 重试，于是 attach 永远判死、症状与 #106 一致。
// 现行：信号只决定撤盖时刻（见「撤盖看门狗」段的公式与周期重估），
// 永远不决定上不上盖。钩子由 LCBootstrap 本体在跳客体 main 前装，不经
// TweakLoader.dylib，「不加载 TweakLoader」开关打开时照常工作。撤盖后
// 恢复原 IMP、零残留。若客体不用 CAMetalLayer（纯 UIKit/老 GL 引擎），
// 信号不触发，走 30s 兜底撤盖。
static IMP lcOrigNextDrawableIMP;
static BOOL lcNextDrawableHookInstalled;
static BOOL lcFirstDrawableSeen;
static BOOL lcNextDrawableCallLogged;
static CFTimeInterval lcFirstDrawableTime;

static void LCLaunchCoverNoteFirstDrawable(void) {
    if (!__sync_bool_compare_and_swap(&lcFirstDrawableSeen, NO, YES)) return;
    lcFirstDrawableTime = CACurrentMediaTime();
    LCLaunchCoverLog(@"首帧信号触发：CAMetalLayer 首个非空 drawable 已被取走");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[LCLaunchCoverHandler sharedHandler] guestFirstFrameDidRender];
    });
}

static id LCLaunchCoverHookedNextDrawable(id self, SEL _cmd) {
    id drawable = ((id (*)(id, SEL))lcOrigNextDrawableIMP)(self, _cmd);
    if (__sync_bool_compare_and_swap(&lcNextDrawableCallLogged, NO, YES)) {
        LCLaunchCoverLog(@"nextDrawable 首次被调用，返回 %@%@",
                         drawable ? @"非空" : @"nil",
                         drawable ? @"" : @"（层未就绪，继续等首个非空）");
    }
    if (drawable) LCLaunchCoverNoteFirstDrawable();
    return drawable;
}

static void LCLaunchCoverInstallFirstFrameHook(void) {
    if (lcNextDrawableHookInstalled) {
        LCLaunchCoverLog(@"首帧钩子安装跳过：已安装");
        return;
    }
    Method m = class_getInstanceMethod(CAMetalLayer.class, @selector(nextDrawable));
    if (!m) {
        LCLaunchCoverLog(@"首帧钩子安装失败：CAMetalLayer 无 nextDrawable 方法，信号不可用，只剩 30s 兜底");
        return;
    }
    lcOrigNextDrawableIMP = method_getImplementation(m);
    method_setImplementation(m, (IMP)LCLaunchCoverHookedNextDrawable);
    lcNextDrawableHookInstalled = YES;
    LCLaunchCoverLog(@"首帧钩子已装：-[CAMetalLayer nextDrawable]");
}

static void LCLaunchCoverTeardownFirstFrameHook(void) {
    if (!lcNextDrawableHookInstalled) return;
    Method m = class_getInstanceMethod(CAMetalLayer.class, @selector(nextDrawable));
    if (m) method_setImplementation(m, lcOrigNextDrawableIMP);
    lcNextDrawableHookInstalled = NO;
    LCLaunchCoverLog(@"首帧钩子已拆除（恢复原 IMP）");
}

static void *LCLaunchCoverSceneGeometryContext = &LCLaunchCoverSceneGeometryContext;
static void *LCLaunchCoverWindowBoundsContext = &LCLaunchCoverWindowBoundsContext;

// 窗口几何摘要（打点/定案用）：frame 是派生值（bounds+center+transform 的
// 包围盒），三件套分开记才能看出几何到底由谁托管。
static NSString *LCLaunchCoverTransformDesc(CGAffineTransform t) {
    if (CGAffineTransformIsIdentity(t)) return @"identity";
    return [NSString stringWithFormat:@"[%.2f %.2f %.2f %.2f %.1f %.1f]", t.a, t.b, t.c, t.d, t.tx, t.ty];
}

static NSString *LCLaunchCoverWindowDesc(UIWindow *w) {
    if (!w) return @"无";
    return [NSString stringWithFormat:@"frame=%@ center={%.1f,%.1f} bounds=%@ transform=%@",
            NSStringFromCGRect(w.frame), w.center.x, w.center.y,
            NSStringFromCGRect(w.bounds), LCLaunchCoverTransformDesc(w.transform)];
}

@implementation LCLaunchCoverHandler {
    UIWindowScene *_scene;
    UIWindow *_window;
    UIWindow *_guestWindow; // 最近一次对齐所跟随的客体主窗（仅记账，每次对齐重选）
    LCLaunchCoverView *_rootView;
    UIImage *_coverImage;
    BOOL _attached;
    BOOL _dismissed;
    NSUInteger _watchdogGeneration;
    BOOL _watchdogSignalLogged;
    CFTimeInterval _attachTime;
    NSMutableSet<UIWindow *> *_observedWindows;
    BOOL _geometryObserving;
}

+ (instancetype)sharedHandler {
    static LCLaunchCoverHandler *handler;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ handler = [LCLaunchCoverHandler new]; });
    return handler;
}

- (void)beginObserving {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(sceneDidActivate:) name:UISceneDidActivateNotification object:nil];
    [nc addObserver:self selector:@selector(orientationDidChange) name:UIApplicationDidChangeStatusBarOrientationNotification object:nil];
    LCLaunchCoverLog(@"已注册场景激活观察，并排定 2s/5s 兜底重试（与快捷栏同款触发）");
    // 兜底重试（与快捷栏同款）：场景可能已激活或客体建场较晚
    __weak LCLaunchCoverHandler *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf attachToActiveSceneIfNeeded];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf attachToActiveSceneIfNeeded];
    });
}

- (void)setResolvedCoverImage:(UIImage *)image {
    _coverImage = image;
    LCLaunchCoverLog(@"封面图送达 handler：%@（attached=%d dismissed=%d）",
                     LCLaunchCoverImageDesc(image), _attached, _dismissed);
    if (_attached && !_dismissed && image) {
        _rootView.coverView.image = image;
    }
}

- (void)sceneDidActivate:(NSNotification *)note {
    if ([note.object isKindOfClass:UIWindowScene.class]) {
        UIWindowScene *scene = (UIWindowScene *)note.object;
        LCLaunchCoverLog(@"收到 UISceneDidActivateNotification（activationState=%ld attached=%d dismissed=%d）",
                         (long)scene.activationState, _attached, _dismissed);
        [self attachToScene:scene];
    } else {
        LCLaunchCoverLog(@"收到 UISceneDidActivateNotification 但 object 非窗口场景（%@），走扫描兜底",
                         NSStringFromClass([note.object class]));
        [self attachToActiveSceneIfNeeded];
    }
}

- (void)attachToActiveSceneIfNeeded {
    if (_attached || _dismissed) {
        LCLaunchCoverLog(@"兜底重试触发：attached=%d dismissed=%d，不重复上盖", _attached, _dismissed);
        return;
    }
    NSArray<UIScene *> *scenes = UIApplication.sharedApplication.connectedScenes.allObjects;
    for (UIScene *scene in scenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            LCLaunchCoverLog(@"兜底重试：connectedScenes 共 %lu 个，找到前台活跃窗口场景，尝试上盖",
                             (unsigned long)scenes.count);
            [self attachToScene:(UIWindowScene *)scene];
            return;
        }
    }
    LCLaunchCoverLog(@"兜底重试：connectedScenes 共 %lu 个，无前台活跃窗口场景，继续等激活通知",
                     (unsigned long)scenes.count);
}

- (void)attachToScene:(UIWindowScene *)scene {
    if (_attached || _dismissed || !scene) {
        LCLaunchCoverLog(@"attach 放弃：attached=%d dismissed=%d scene=%@",
                         _attached, _dismissed, scene ? @"非空" : @"nil");
        return;
    }
    // 本次启动内必上盖：首帧信号先到也照常上盖（只影响撤盖时刻）。
    // #107 在这里按 lcFirstDrawableSeen 判死是已定案的病根——客体在场景
    // 连接/首个刷新周期就取走首块 drawable，必然早于本方法的任何触发
    // （激活通知/2s/5s 重试），判死即盖层永不上盖，与 #106 的 key 窗判
    // 死症状完全一致。勿再加回任何形式的前置判死。
    _attached = YES;
    _attachTime = CACurrentMediaTime();
    _scene = scene;
    if (lcFirstDrawableSeen) {
        LCLaunchCoverLog(@"attach 开始上盖：首帧信号已先于上盖到达（信号在 %+lldms），照常上盖、按下限公式撤盖",
                         (long long)llround((lcFirstDrawableTime - lcCoverT0) * 1000.0));
    } else {
        LCLaunchCoverLog(@"attach 开始上盖：首帧信号尚未到达，scene bounds=%@",
                         NSStringFromCGRect(scene.coordinateSpace.bounds));
    }

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelAlert + 50;
    // 此处不写 frame：在 rootViewController 赋值/亮窗之前写场景 bounds 会被
    // UIKit 按 effectiveGeometry 落定覆盖（定案见「几何跟随」段），几何改在
    // rootVC 赋值后、亮窗前由 alignCoverToGuestWindow 一次对齐（与快捷栏
    // 「rootVC 后写帧、亮窗前复核」的顺序同款）。
    window.backgroundColor = [UIColor colorWithRed:7/255.0 green:7/255.0 blue:12/255.0 alpha:1];
    LCLaunchCoverView *rootView = [[LCLaunchCoverView alloc] init];
    rootView.titleLabel.text = self.title;
    if (_coverImage) rootView.coverView.image = _coverImage;
    __weak LCLaunchCoverHandler *weakSelf = self;
    rootView.onTap = ^{ [weakSelf dismissWithDuration:0.3]; };
    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view = rootView;
    window.rootViewController = rootVC;
    _rootView = rootView;
    _window = window;
    // 亮窗前把几何对齐到客体主窗（同源几何，见「几何跟随」段定案）
    [self alignCoverToGuestWindowWithReason:@"attach" checkpoint:YES];
    window.hidden = NO;
    // 几何跟随的信号从上盖起就装好：场景旋转/落定多发生在上盖后头一两秒内
    [self installGeometryObservers];
    LCLaunchCoverLog(@"attach 已上盖：window level=%.0f frame=%@ rootView frame=%@ 封面图=%@ 标题=%@",
                     window.windowLevel, NSStringFromCGRect(window.frame),
                     NSStringFromCGRect(rootView.frame),
                     _coverImage ? LCLaunchCoverImageDesc(_coverImage) : @"未到（先深色底+标题）",
                     self.title ?: @"");

    // 入场（与预览同时序）：罩 0.25s 起 0.7s 淡入、信息组 0.4s 起 0.6s 淡入、
    // 封面缓推与光带同时启动
    rootView.scrimView.alpha = 0;
    rootView.metaView.alpha = 0;
    rootView.coverView.transform = CGAffineTransformMakeScale(1.14, 1.14);
    [UIView animateWithDuration:0.7 delay:0.25 options:UIViewAnimationOptionCurveEaseOut animations:^{
        rootView.scrimView.alpha = 1;
    } completion:nil];
    [UIView animateWithDuration:0.6 delay:0.4 options:UIViewAnimationOptionCurveEaseOut animations:^{
        rootView.metaView.alpha = 1;
    } completion:nil];
    [UIView animateWithDuration:6 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        rootView.coverView.transform = CGAffineTransformMakeScale(1.03, 1.03);
    } completion:nil];
    CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
    slide.fromValue = @0;
    slide.toValue = @90;
    slide.duration = 1.1;
    slide.autoreverses = YES;
    slide.repeatCount = HUGE_VALF;
    slide.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [rootView.barSegment.layer addAnimation:slide forKey:@"lcLaunchBarSlide"];
    // 最长兜底：首帧信号永不到达（客体不用 CAMetalLayer 等）时 30s 自动撤盖
    __weak LCLaunchCoverHandler *weakSelf2 = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf2 dismissWithReason:@"fallback-30s" duration:0.35];
    });
    // 撤盖看门狗自上盖起跑：周期重估撤盖公式，不依赖信号/上盖任一单次
    // 事件送达（见「撤盖看门狗」段的失效路径枚举）
    [self startDismissWatchdog];
}

- (void)guestFirstFrameDidRender {
    // 客体已取走第一块 drawable、开始渲染首帧。信号可能先于上盖到达
    // （常态，见 attach 注释），此时只记账——撤盖由看门狗周期重估，不
    // 靠这次送达排定；已上盖则在此立即重估一次，缩短迟滞。
    LCLaunchCoverLog(@"首帧信号送达 handler（attached=%d dismissed=%d 距上盖 %+lldms）",
                     _attached, _dismissed,
                     _attached ? (long long)llround((CACurrentMediaTime() - _attachTime) * 1000.0) : -1);
    // 兜底检查点：撤盖判定前强制与客体主窗对一次几何，防错位被带进淡出
    [self alignCoverToGuestWindowWithReason:@"first-frame" checkpoint:YES];
    [self evaluateDismissCondition];
}

#pragma mark 撤盖看门狗（条件式周期重估）

// 自动撤盖失效路径枚举（实测：有时自动淡出、有时不自动消失必须手点）：
//   ① lost-wakeup（单次事件排定、无重估）：旧实现里公式排定只有两个单
//      次调用点——attach 末尾与信号送达，且带 _dismissScheduled 一次性
//      闩锁。信号先于上盖到达时，信号侧排定在 !_attached 守卫处静默返
//      回（只记账），全靠 attach 末尾补排这一次交接；排出的单个
//      dispatch_after 在客体加载期主队列被长占用时可被推迟到远超公式
//      时刻且无人复查。任一环丢失/迟到即永久不排定，只能手点或等
//      30s——点按有效正是因为触摸泵动运行循环、且点按路径不依赖那次
//      排定。
//   ② 信号对钩子不可见：钩子在跳客体 main 之前装好（LCLaunchCover
//      Install），同进程内客体不可能更早取 drawable，「装前已发生」结
//      构上排除；但变体真实存在——客体金属层类重写 nextDrawable 不走
//      基类实现、或客体根本不用 CAMetalLayer 呈现（老 GL 等），钩子
//      永不触发，与③同归「无信号」。
//   ③ 无信号长加载：着色器重建期（换包首启）前端只画 UIKit 手柄、游
//      戏层不出帧，nextDrawable 长时间不被调用。口径：这是真加载，盖
//      层保持是对的、不许到点乱撤；旧实现下这段时间只能等 30s 兜底或
//      手点。看门狗保证信号一旦置位（哪怕其单次送达/排定被丢），最多
//      一个判定周期内按公式撤盖，「信号到了却不撤」就此消除；30s 兜
//      底仍在，只防信号永不到达。
// 修法：撤盖改条件式看门狗——自上盖起每 0.25s 在主队列重估一次撤盖条
// 件，满足即撤、不依赖任何单次事件送达；信号送达时仍立即重估一次降迟
// 滞。撤盖公式不变：撤盖 = max(上盖 + 1.6s, 首帧信号 + 0.35s 落定)，
// 其后 0.35s 淡出（1.6s 总下限覆盖「引擎先画黑帧再出内容」的那段；
// 0.9s 最短显示被该下限包含）。撤盖后以代数计数作废在途链、停表；点
// 按跳过不走公式、立即撤。
- (void)startDismissWatchdog {
    NSUInteger gen = ++_watchdogGeneration;
    LCLaunchCoverLog(@"撤盖看门狗已启动：每 250ms 重估撤盖条件（公式 max(上盖+1.6s, 首帧+0.35s)）");
    [self runWatchdogGeneration:gen];
}

- (void)runWatchdogGeneration:(NSUInteger)gen {
    if (_dismissed || !_attached || gen != _watchdogGeneration) return;
    [self evaluateDismissCondition];
    if (_dismissed || gen != _watchdogGeneration) return;
    __weak LCLaunchCoverHandler *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf runWatchdogGeneration:gen];
    });
}

- (void)stopDismissWatchdog {
    _watchdogGeneration++; // 作废在途的看门狗链，链在下一跳自检时自停
}

// 单次判定（看门狗每 0.25s 调用 + 信号送达时立即调用）：未上盖/已撤盖
// 直接返回；无信号 = 真加载中（路径③口径），盖层保持且不记流水——仅
// 状态变化时打点：信号由未到变已到的首次判定记一行目标时刻，其后每
// 0.25s 静默重估直到公式时刻已过即撤（来源 formula，见撤盖日志）。
- (void)evaluateDismissCondition {
    if (!_attached || _dismissed) return;
    if (!lcFirstDrawableSeen) return;
    NSTimeInterval target = MAX(_attachTime + 1.6, lcFirstDrawableTime + 0.35);
    if (!_watchdogSignalLogged) {
        _watchdogSignalLogged = YES;
        LCLaunchCoverLog(@"看门狗判定变化：首帧信号已确认，撤盖目标为上盖后 %.0fms（公式 max(上盖+1.6s, 首帧+0.35s)），到期即撤",
                         (target - _attachTime) * 1000.0);
    }
    if (CACurrentMediaTime() >= target) {
        [self dismissWithReason:@"formula" duration:0.35];
    }
}

- (void)orientationDidChange {
    // 状态栏方向通知只作兜底一路，与 effectiveGeometry/客体窗 bounds 的
    // KVO 走同一条几何跟随路径（见下方定案注）
    [self geometryMayHaveChanged];
}

#pragma mark 几何跟随（与客体主窗同源对齐）

// 定案（以撒竖屏启动 log-90 打点逐条对应，2026-11-11）：
//   14:51:40.164 attach 读 scene.coordinateSpace.bounds = 420×912——场景
//     初始方向 = 点开瞬间机身方向（竖屏），旋转尚未落定，这是未落定值；
//   14:51:40.166 attach 的 window.frame = scene.coordinateSpace.bounds 写
//     入的明明是这份 420×912，「attach 已上盖」回读却是 912×420。写入与
//     回读之间只隔 rootViewController 赋值与 hidden=NO 两步，二者都会触
//     发 UIKit 按场景 effectiveGeometry 落定窗口几何：客体已把方向落到
//     横屏、有效几何为 912×420，刚写入的竖屏帧被托管几何覆盖。故错不在
//     表达式取值，在于场景托管窗口不能拿未落定的 coordinateSpace.bounds
//     当目标值、在托管落定前写帧；
//   14:51:40.171 自愈把 frame 改写成 420×912，呈现终局仍是 912×420 横带
//     （#108/#109 两轮录屏一致）：自愈在上盖后 5ms 落地，盖层内容最早
//     +250ms 才入场——若 420×912 真主导过任何一帧呈现，按根视图 bounds
//     布局出的应是竖屏满幅封面，录屏从未出现。即 frame 是 bounds+center
//     +transform 的派生包围盒，直写 frame 不触及托管的有效几何，后续任
//     一次几何应用即恢复托管值。#109 的 syncGeometry 与自愈同病（同一错
//     误目标），且额外把 rootView 帧直写成竖屏值，使内容布局方向与窗口
//     局部坐标（横屏）互相打架。
// 客体主窗为什么对（dm 前端源码核实：nxnative dm/ios/Sources/main.m 的
// SceneDelegate 与 front_ios.m）：建窗只有 initWithWindowScene +
// rootViewController + makeKeyAndVisible，全程零 frame/center/transform
// 手写、前端无任何旋转变换代码——其几何百分百由同一套场景托管决定
// （局部 bounds 落为横屏值、经场景呈现满屏）。盖层要与撤盖后露出的客
// 体画面同框同位，唯一同源做法是复制客体主窗当下实测的 bounds+center+
// transform 并跟随其变化，而不是再从场景推导任何数值。
// 修法：
//   1) attach 在 rootVC 赋值后、亮窗前对齐一次（顺序与快捷栏「rootVC 后
//      写帧、亮窗前复核」同款）；每次对齐重选客体主窗候选并复制三件套，
//      根视图帧 = 盖层窗口 bounds（局部坐标），内容由 LCLaunchCoverView
//      .layoutSubviews 按 bounds 现算，不改；
//   2) 跟随触发沿用：场景 effectiveGeometry KVO、场景内窗口 bounds/
//      center/frame KVO、状态栏方向通知（信号后 0.3s 复核），另加
//      UIWindowDidBecomeKeyNotification 接住上盖后才成为 key 的客体主
//      窗；但所有触发只做「重新对齐客体主窗」，不再把 scene bounds 直写
//      盖层窗口帧；
//   3) 客体主窗尚不存在时以场景 effectiveGeometry 占位（读有效几何而非
//      coordinateSpace 的未落定值），客体窗一出现即改对齐；
//   4) 首帧送达与撤盖开始前的检查点沿用，目标同为客体主窗对齐。
- (void)installGeometryObservers {
    if (@available(iOS 16.0, *)) {
        if (!_geometryObserving) {
            _geometryObserving = YES;
            [_scene addObserver:self forKeyPath:@"effectiveGeometry" options:0 context:LCLaunchCoverSceneGeometryContext];
        }
    }
    [self observeSceneWindows];
    // 客体主窗在上盖之后才成为 key（makeKeyAndVisible 晚于场景激活）时，
    // 靠这一路接住「对齐目标出现了」（与快捷栏 windowDidBecomeKey 几何审
    // 计同款信号）；attach 只装一次，撤盖时随 removeObserver:self 摘除。
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(geometryMayHaveChanged)
                                               name:UIWindowDidBecomeKeyNotification
                                             object:nil];
}

- (void)observeSceneWindows {
    if (!_observedWindows) _observedWindows = [NSMutableSet set];
    for (UIWindow *w in _scene.windows) {
        if (w == _window || [_observedWindows containsObject:w]) continue;
        [_observedWindows addObject:w];
        // 跟随目标是客体主窗的 bounds/center/transform 三件套：frame 为派
        // 生值，四者任一变化都触发重对齐（重对齐时现读三件套全值，单个
        // keyPath 漏报也会被其余变化顺带接住）
        [w addObserver:self forKeyPath:@"bounds" options:0 context:LCLaunchCoverWindowBoundsContext];
        [w addObserver:self forKeyPath:@"center" options:0 context:LCLaunchCoverWindowBoundsContext];
        [w addObserver:self forKeyPath:@"frame" options:0 context:LCLaunchCoverWindowBoundsContext];
    }
}

- (void)removeGeometryObservers {
    if (_geometryObserving) {
        _geometryObserving = NO;
        [_scene removeObserver:self forKeyPath:@"effectiveGeometry" context:LCLaunchCoverSceneGeometryContext];
    }
    for (UIWindow *w in _observedWindows) {
        [w removeObserver:self forKeyPath:@"bounds" context:LCLaunchCoverWindowBoundsContext];
        [w removeObserver:self forKeyPath:@"center" context:LCLaunchCoverWindowBoundsContext];
        [w removeObserver:self forKeyPath:@"frame" context:LCLaunchCoverWindowBoundsContext];
    }
    [_observedWindows removeAllObjects];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (context == LCLaunchCoverSceneGeometryContext || context == LCLaunchCoverWindowBoundsContext) {
        [self geometryMayHaveChanged];
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)geometryMayHaveChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self alignCoverToGuestWindowWithReason:@"signal" checkpoint:NO];
        // 客体主窗几何可能滞后于触发信号（旋转落定分步走），0.3s 后再核对一次
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self alignCoverToGuestWindowWithReason:@"signal-settle" checkpoint:NO];
        });
    });
}

// 客体主窗候选：场景内 Normal 层级、可见、非盖层自身的窗口——宿主浮层
// （快捷栏 Alert+100、回库 veil Alert+200、盖层自身 Alert+50）全在
// Normal 之上，层级一条即排除。key 窗优先（客体主窗 makeKeyAndVisible
// 后即 key 窗），无 key 窗时取面积最大者；每次对齐重选，迟建/换窗跟得上。
- (UIWindow *)guestMainWindowCandidate {
    UIWindow *key = nil;
    UIWindow *largest = nil;
    CGFloat largestArea = 0;
    for (UIWindow *w in _scene.windows) {
        if (w == _window || w.windowScene != _scene) continue;
        if (w.windowLevel != UIWindowLevelNormal || w.hidden || w.alpha <= 0.01) continue;
        if (w.isKeyWindow) key = w;
        CGFloat area = w.bounds.size.width * w.bounds.size.height;
        if (area > largestArea) { largestArea = area; largest = w; }
    }
    return key ?: largest;
}

// 与客体主窗对齐盖层几何：复制其 bounds+center+transform 三件套（frame
// 是派生值，只读不写），根视图帧取盖层窗口的局部 bounds、内容随之按
// bounds 重排（LCLaunchCoverView.layoutSubviews 现算）。客体主窗尚不存
// 在时以场景 effectiveGeometry 占位。每次实际修正、或 checkpoint 强制
// 核对时打点：客体主窗摘要 + 盖层最终采用值——下一轮若仍错位，日志能直
// 接区分「没跟上」与「跟上了但呈现仍偏」，不必再靠录屏猜。
- (BOOL)alignCoverToGuestWindowWithReason:(NSString *)reason checkpoint:(BOOL)checkpoint {
    if (!_window || !_scene || _dismissed) return NO;
    [self observeSceneWindows]; // 顺带补上旋转后/迟建的客体窗口
    UIWindow *guest = [self guestMainWindowCandidate];
    _guestWindow = guest;
    CGRect targetBounds;
    CGPoint targetCenter;
    CGAffineTransform targetTransform;
    NSString *source;
    if (guest) {
        targetBounds = guest.bounds;
        targetCenter = guest.center;
        targetTransform = guest.transform;
        source = @"客体主窗";
    } else {
        CGRect b = _scene.coordinateSpace.bounds;
        if (@available(iOS 16.0, *)) {
            b = _scene.effectiveGeometry.coordinateSpace.bounds;
        }
        if (b.size.width <= 0 || b.size.height <= 0) return NO;
        targetBounds = b;
        targetCenter = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
        targetTransform = CGAffineTransformIdentity;
        source = @"场景有效几何(占位)";
    }
    BOOL mismatch = !CGRectEqualToRect(_window.bounds, targetBounds) ||
                    !CGPointEqualToPoint(_window.center, targetCenter) ||
                    !CGAffineTransformEqualToTransform(_window.transform, targetTransform) ||
                    !CGRectEqualToRect(_rootView.frame, targetBounds);
    if (!mismatch && !checkpoint) return NO;
    if (mismatch) {
        _window.bounds = targetBounds;
        _window.center = targetCenter;
        _window.transform = targetTransform;
        _rootView.frame = targetBounds;
        [_rootView setNeedsLayout];
        [_rootView layoutIfNeeded];
    }
    LCLaunchCoverLog(@"几何对齐[%@]：来源=%@ 客体主窗[%@] 盖层采用[%@]%@",
                     reason, source, LCLaunchCoverWindowDesc(guest),
                     LCLaunchCoverWindowDesc(_window),
                     mismatch ? @"（已修正）" : @"（本已对齐）");
    return mismatch;
}

- (void)dismissWithDuration:(NSTimeInterval)duration {
    [self dismissWithReason:@"tap" duration:duration];
}

- (void)dismissWithReason:(NSString *)reason duration:(NSTimeInterval)duration {
    if (_dismissed || !_attached) {
        LCLaunchCoverLog(@"撤盖请求忽略：reason=%@ attached=%d dismissed=%d", reason, _attached, _dismissed);
        return;
    }
    [self stopDismissWatchdog]; // 任一来源撤盖都先停表，在途链自检自停
    // 兜底检查点：开始淡出前强制与客体主窗对一次几何，错位不许带进淡出
    // （须在 _dismissed 置位前调，对齐以未撤盖为前提）
    [self alignCoverToGuestWindowWithReason:@"pre-dismiss" checkpoint:YES];
    _dismissed = YES;
    LCLaunchCoverTeardownFirstFrameHook();
    // 触发来源三值：formula=看门狗判定公式满足 / tap=点按跳过 / fallback-30s=30s 兜底
    LCLaunchCoverLog(@"撤盖：触发来源=%@ 上盖总时长 %.0fms 淡出 %.2fs",
                     reason, (CACurrentMediaTime() - _attachTime) * 1000.0, duration);
    UIWindow *window = _window;
    [UIView animateWithDuration:duration animations:^{
        window.alpha = 0;
    } completion:^(BOOL finished) {
        window.hidden = YES;
        [self removeGeometryObservers];
        [NSNotificationCenter.defaultCenter removeObserver:self];
    }];
}

@end

static BOOL lcLaunchCoverInstallAttempted;
static void LCLaunchCoverInstall(NSString *bundlePath, NSString *bundleId, NSString *displayName) {
    if (lcLaunchCoverInstallAttempted) return;
    lcLaunchCoverInstallAttempted = YES;
    // 打点时钟原点先于一切盖层事件（含钩子安装），日志相对时刻自此起算
    lcCoverT0 = CACurrentMediaTime();
    LCLaunchCoverHandler *handler = [LCLaunchCoverHandler sharedHandler];
    handler.title = displayName.length ? displayName : (bundleId ?: @"");
    LCLaunchCoverLog(@"==== 盖层会话开始 bundleId=%@ 标题=%@ ====", bundleId ?: @"", handler.title);
    // 首帧信号钩子必须赶在跳客体 main 前装好，才不会漏掉第一块 drawable
    LCLaunchCoverInstallFirstFrameHook();
    [handler beginObserving];
    NSString *pathCopy = [bundlePath copy];
    NSString *idCopy = [bundleId copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *image = LCLaunchCoverResolveImage(pathCopy, idCopy);
        dispatch_async(dispatch_get_main_queue(), ^{
            [handler setResolvedCoverImage:image];
        });
    });
}

static NSString* invokeAppMain(NSString *selectedApp, NSString *selectedContainer, int argc, char *argv[]) {
    NSString *appError = nil;
    if([[lcUserDefaults objectForKey:@"LCWaitForDebugger"] boolValue]) {
        sleep(100);
    }
    if (!LCSharedUtils.certificatePassword && !isSideStore) {
#if !TARGET_OS_SIMULATOR
        if(@available(iOS 26.0 ,*))  {
            return LCBootstrapLocalized(@"lc.bootstrap.error.jitlessRequiredSinceIOS26");
        }
#endif
        // First of all, let's check if we have JIT
        for (int i = 0; i < 10 && !checkJITEnabled(); i++) {
            usleep(1000*100);
        }
        if (!checkJITEnabled()) {
            appError = LCBootstrapLocalized(@"lc.bootstrap.error.jitNotEnabled");
            return appError;
        }
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docPath = [NSString stringWithFormat:@"%s/Documents", getenv("LC_HOME_PATH")];
    
    NSURL *appGroupFolder = nil;
    
    NSString *bundlePath = 0;
    if(!isSideStore) {
        bundlePath = [NSString stringWithFormat:@"%@/Applications/%@", docPath, selectedApp];
    } else if (isLiveProcess) {
        bundlePath = [[NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"Frameworks/SideStoreApp.framework"] path];
    } else {
        bundlePath = [[NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Frameworks/SideStoreApp.framework"] path];
    }
    

    guestAppInfo = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/LCAppInfo.plist", bundlePath]];

    // not found locally, let's look for the app in shared folder
    if(!guestAppInfo) {
        NSURL *appGroupPath = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[LCSharedUtils appGroupID]];
        appGroupFolder = [appGroupPath URLByAppendingPathComponent:@"GameCase"];
        bundlePath = [NSString stringWithFormat:@"%@/Applications/%@", appGroupFolder.path, selectedApp];
        guestAppInfo = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/LCAppInfo.plist", bundlePath]];
        isSharedBundle = true;
    }
    
    if(!guestAppInfo) {
        return LCBootstrapLocalized(@"lc.bootstrap.error.appBundleNotFound");
    }
    
    if([guestAppInfo[@"doUseLCBundleId"] boolValue] ) {
        NSMutableDictionary* infoPlist = [NSMutableDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/Info.plist", bundlePath]];
        CFErrorRef error = NULL;
        void* taskSelf = SecTaskCreateFromSelf(NULL);
        CFTypeRef value = SecTaskCopyValueForEntitlement(taskSelf, CFSTR("application-identifier"), &error);
        CFRelease(taskSelf);
        if (value) {
            NSString *entStr = (__bridge NSString *)value;
            CFRelease(value);
            NSRange dotRange = [entStr rangeOfString:@"."];
            if (dotRange.location != NSNotFound) {
                NSString *expectedBundleId = [entStr substringFromIndex:dotRange.location + 1];
                if(![infoPlist[@"CFBundleIdentifier"] isEqualToString:expectedBundleId]) {
                    infoPlist[@"CFBundleIdentifier"] = expectedBundleId;
                    [infoPlist writeBinToFile:[NSString stringWithFormat:@"%@/Info.plist", bundlePath] atomically:YES];
                }
            }
        }
    }
    
    NSBundle *appBundle = [[NSBundle alloc] initWithPathForMainBundle:bundlePath];
    
    if(!appBundle) {
        return LCBootstrapLocalized(@"lc.bootstrap.error.appNotFound");
    }
    
    // find container in Info.plist
    NSString* dataUUID = selectedContainer;
    if(!dataUUID) {
        dataUUID = guestAppInfo[@"LCDataUUID"];
    }

    if(dataUUID == nil) {
        return LCBootstrapLocalized(@"lc.bootstrap.error.containerNotFound");
    }
    
    if(isLiveProcess && !isSideStore) {
        lcAppUrlScheme = [lcUserDefaults stringForKey:@"hostUrlScheme"];
        [lcUserDefaults removeObjectForKey:@"hostUrlScheme"];
    }
    
    NSError *error;

    // Setup tweak loader
    NSString *tweakFolder = nil;
    if (isSharedBundle) {
        tweakFolder = [appGroupFolder.path  stringByAppendingPathComponent:@"Tweaks"];
    } else {
        tweakFolder = [docPath stringByAppendingPathComponent:@"Tweaks"];
    }
    setenv("LC_GLOBAL_TWEAKS_FOLDER", tweakFolder.UTF8String, 1);

    // Update TweakLoader symlink
    NSString *tweakLoaderPath = [tweakFolder stringByAppendingPathComponent:@"TweakLoader.dylib"];
    if (![fm fileExistsAtPath:tweakLoaderPath]) {
        remove(tweakLoaderPath.UTF8String);
        NSString *bundlePath = NSBundle.mainBundle.bundlePath;
        if([bundlePath hasSuffix:@"PlugIns/LiveProcess.appex"]) {
            // traverse back to LiveContainer.app
            bundlePath = bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
        }
        NSString *target = [bundlePath stringByAppendingPathComponent:@"Frameworks/TweakLoader.dylib"];
        symlink(target.UTF8String, tweakLoaderPath.UTF8String);
    }

    // If JIT is enabled, bypass library validation so we can load arbitrary binaries
    bool isJitEnabled = checkJITEnabled();
    if (isJitEnabled) {
        init_bypassDyldLibValidation();
    }

    // Locate dyld image name address
    const char **path = _CFGetProcessPath();
    const char *oldPath = *path;
    
    // Overwrite @executable_path
    const char *appExecPath = appBundle.executablePath.fileSystemRepresentation;
    *path = appExecPath;
    overwriteExecPath(appExecPath);
    
    // Overwrite NSUserDefaults
    if([guestAppInfo[@"doUseLCBundleId"] boolValue]) {
        lcGuestAppId = guestAppInfo[@"LCOrignalBundleIdentifier"];
    } else {
        lcGuestAppId = appBundle.bundleIdentifier;
        
    }

    // Overwrite home and tmp path
    NSString *newHomePath = nil;
    NSArray<NSDictionary*>* containers = guestAppInfo[@"LCContainers"];
    NSURL* bookmarkURL = nil;

    // see if the container contains a bookmark. if so, resolve it and report error upon failure.
    if(containers && [containers isKindOfClass:NSArray.class]) {
        for(NSDictionary* container in containers){
            if(![container isKindOfClass:NSDictionary.class]) {
                continue;
            }
            if([container[@"folderName"] isEqualToString:dataUUID]) {
                NSData* bookmarkData = container[@"bookmarkData"];
                if(bookmarkData && [bookmarkData isKindOfClass:NSData.class]) {
                    // we will be killed by watchdog before timedout, so we set this error beforehand.
                    [lcUserDefaults setObject:LCBootstrapLocalized(@"lc.bootstrap.error.bookmarkResolutionTimeout") forKey:@"error"];
                    NSError* err = nil;
                    BOOL isStale = false;
                    bookmarkURL = [NSURL URLByResolvingBookmarkData:bookmarkData options:0 relativeToURL:nil bookmarkDataIsStale:&isStale error:&err];
                    bool access = [bookmarkURL startAccessingSecurityScopedResource];
                    if(!bookmarkURL || !access) {
                        return [LCBootstrapLocalized(@"lc.bootstrap.error.bookmarkResolutionFailed %@") stringByAppendingString:err.localizedDescription];
                    }
                    [lcUserDefaults removeObjectForKey:@"error"];
                }
                break;
            }
        }
    }
    
    if(isSideStore) {
        if(isLiveProcess) {
            newHomePath = [lcUserDefaults stringForKey:@"specifiedSideStoreContainerPath"];;
            [lcUserDefaults removeObjectForKey:@"specifiedSideStoreContainerPath"];
        } else {
            newHomePath = [docPath stringByAppendingPathComponent:@"SideStore"];
        }
    } else if (bookmarkURL) {
        newHomePath = bookmarkURL.path;
    } else {
        // 算 HOME 的漏斗处先把容器夹换成 ASCII 游玩名（见上方
        // GCPlayNameSwapToPlayName），HOME 与由它派生的一切（CFFIXED_USER_
        // HOME、tmp 软链落点、骨架目录、LCContainerInfo 读取）自然落在
        // 真实 ASCII 路径。书签分支在上面已先行返回、不走换名（外置存储
        // 是用户自管目录）。宿主侧记账（setContainerUsingByLC 的键、偏好
        // 回收、LCContainer.containerURL）继续用静息名 dataUUID——那是
        // 容器的记录身份，不是当下路径。
        NSString *dataRootPath = isSharedBundle ? [appGroupFolder.path stringByAppendingPathComponent:@"Data/Application"]
                                                : [docPath stringByAppendingPathComponent:@"Data/Application"];
        NSString *effectiveFolderName = GCPlayNameSwapToPlayName(dataRootPath, dataUUID, appBundle.bundleIdentifier);
        newHomePath = [dataRootPath stringByAppendingPathComponent:effectiveFolderName];
    }
    
    
    NSString *newTmpPath = [newHomePath stringByAppendingPathComponent:@"tmp"];
    remove(newTmpPath.UTF8String);
    symlink(getenv("TMPDIR"), newTmpPath.UTF8String);
    
    if([guestAppInfo[@"doSymlinkInbox"] boolValue]) {
        NSString* inboxSymlinkPath = [NSString stringWithFormat:@"%s/%@-Inbox", getenv("TMPDIR"), [appBundle bundleIdentifier]];
        NSString* inboxPath = [newHomePath stringByAppendingPathComponent:@"Inbox"];
        
        if (![fm fileExistsAtPath:inboxPath]) {
            [fm createDirectoryAtPath:inboxPath withIntermediateDirectories:YES attributes:nil error:&error];
        }
        if([fm fileExistsAtPath:inboxSymlinkPath]) {
            NSString* fileType = [fm attributesOfItemAtPath:inboxSymlinkPath error:&error][NSFileType];
            if(fileType == NSFileTypeDirectory) {
                NSArray* contents = [fm contentsOfDirectoryAtPath:inboxSymlinkPath error:&error];
                for(NSString* content in contents) {
                    [fm moveItemAtPath:[inboxSymlinkPath stringByAppendingPathComponent:content] toPath:[inboxPath stringByAppendingPathComponent:content] error:&error];
                }
                [fm removeItemAtPath:inboxSymlinkPath error:&error];
            }
        }
        

        symlink(inboxPath.UTF8String, inboxSymlinkPath.UTF8String);
    } else {
        NSString* inboxSymlinkPath = [NSString stringWithFormat:@"%s/%@-Inbox", getenv("TMPDIR"), [appBundle bundleIdentifier]];
        NSDictionary* targetAttribute = [fm attributesOfItemAtPath:inboxSymlinkPath error:&error];
        if(targetAttribute) {
            if(targetAttribute[NSFileType] == NSFileTypeSymbolicLink) {
                [fm removeItemAtPath:inboxSymlinkPath error:&error];
            }
        }

    }
    
    setenv("CFFIXED_USER_HOME", newHomePath.UTF8String, 1);
    setenv("HOME", newHomePath.UTF8String, 1);
    // we don't change TMP's env in case some apps clear cache by directly deleting the tmp folder,
    // which if symlinked, the new tmp cannot be recreated (#1040, #1125) or the app may camplain about the tmp folder being a symlimk (#884)

    // Setup directories
    NSArray *dirList = @[@"Library/Caches", @"Library/Cookies", @"Documents", @"SystemData"];
    for (NSString *dir in dirList) {
        NSString *dirPath = [newHomePath stringByAppendingPathComponent:dir];
        [fm createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    NSString* containerInfoPath = [newHomePath stringByAppendingPathComponent:@"LCContainerInfo.plist"];
    guestContainerInfo = [NSDictionary dictionaryWithContentsOfFile:containerInfoPath];
    
    [LCSharedUtils setContainerUsingByLC:lcAppUrlScheme folderName:dataUUID auditToken:0];

    // Overwrite NSBundle
    overwriteMainNSBundle(appBundle);

    // Overwrite CFBundle
    overwriteMainCFBundle();

    // Overwrite executable info
    if(!appBundle.executablePath) {
        return LCBootstrapLocalized(@"lc.bootstrap.error.executablePathNotFound");
    }

    NSMutableArray<NSString *> *objcArgv = NSProcessInfo.processInfo.arguments.mutableCopy;
    objcArgv[0] = appBundle.executablePath;
    [NSProcessInfo.processInfo performSelector:@selector(setArguments:) withObject:objcArgv];
    NSProcessInfo.processInfo.processName = appBundle.infoDictionary[@"CFBundleExecutable"];
    *_CFGetProgname() = NSProcessInfo.processInfo.processName.UTF8String;
    Class swiftNSProcessInfo = NSClassFromString(@"_NSSwiftProcessInfo");
    if(swiftNSProcessInfo) {
        // Swizzle the arguments method to return the ObjC arguments
        SEL selector = @selector(arguments);
        method_setImplementation(class_getInstanceMethod(swiftNSProcessInfo, selector), class_getMethodImplementation(NSProcessInfo.class, selector));
    }
    
    // 缓存宿主系统首选语言：下面的 NUDGuestHooksInit 会把偏好域换成客体
    // 并可能删掉 AppleLanguages，之后 preferredLanguages 读不到系统语言
    // （快捷栏 LCQBLibraryTitle 读这份缓存，见其上方注释）。
    LCQBHostPreferredLanguage = NSLocale.preferredLanguages.firstObject;
    // hook NSUserDefault before running libraries' initializers
    NUDGuestHooksInit();
    if(!isSideStore) {
        SecItemGuestHooksInit();
        NSFMGuestHooksInit();
        initDead10ccFix();
    }
    if(isLiveProcess) {
        NSURLSCGuestHooksInit();
    }
    // ignore setting handler from guest app
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, NSSetUncaughtExceptionHandler, hook_do_nothing, nil);
    
    BOOL hookDlopen = !isSideStore && !isSharedBundle && LCSharedUtils.certificatePassword && isLiveProcess;
    DyldHooksInit([guestAppInfo[@"hideLiveContainer"] boolValue], hookDlopen, [guestAppInfo[@"spoofSDKVersion"] unsignedIntValue]);
    
    if([guestContainerInfo[@"spoofIdentifierForVendor"] boolValue]) {
        NSString* idForVendorStr = guestContainerInfo[@"spoofedIdentifierForVendor"];
        if([idForVendorStr isKindOfClass:NSString.class]) {
            NSUUID* idForVendorUUID = [[NSUUID UUID] initWithUUIDString:idForVendorStr];
            if(idForVendorUUID) {
                IDFVHookInit(idForVendorUUID);
            }
        }
    }
    
    bool is32bit = [guestAppInfo[@"is32bit"] boolValue];
    if(is32bit) {
        [lcUserDefaults removeObjectForKey:@"LC32BitTranslationLayerLogFile"];
        if (!isJitEnabled) {
            return LCBootstrapLocalized(@"lc.bootstrap.error.jitRequiredFor32Bit");
        }
        
        NSString *selected32BitLayer = guestAppInfo[@"selected32BitEmulator"] ?: [lcSharedDefaults stringForKey:@"LCSelected32BitEmulator"];
        if(selected32BitLayer.length == 0) {
            appError = LCBootstrapLocalized(@"lc.bootstrap.error.no32BitEmulatorSelected");
            NSLog(@"[LCBootstrap] No 32-bit emulator selected");
            *path = oldPath;
            return appError;
        }
        NSBundle *selected32bitLayerBundle = [NSBundle bundleWithPath:[NSString stringWithFormat:@"%@/Applications/%@", docPath, selected32BitLayer]];
        if(!selected32bitLayerBundle) {
            selected32bitLayerBundle = [NSBundle bundleWithPath:[NSString stringWithFormat:@"%@/Applications/%@", appGroupFolder.path, selected32BitLayer]];
        }
        if(!selected32bitLayerBundle) {
            appError = LCBootstrapLocalized(@"lc.bootstrap.error.emulatorAppNotFound");
            NSLog(@"[LCBootstrap] The specified 32-bit emulator app is not found");
            *path = oldPath;
            return appError;
        }
        // maybe need to save selected32bitLayerBundle to static variable?
        appExecPath = strdup(selected32bitLayerBundle.executablePath.UTF8String);
        overwriteExecPath(appExecPath);
    }
    if(![guestAppInfo[@"dontInjectTweakLoader"] boolValue]) {
        tweakLoaderLoaded = true;
    }
    
    // Preload executable to bypass RT_NOLOAD
    appMainImageIndex = _dyld_image_count();
    __block void *appHandle = 0;
    void (^dlopenBlock)(void) = ^{
        appHandle = dlopen_nolock(appExecPath, RTLD_LAZY|RTLD_GLOBAL|RTLD_FIRST);
    };
    
    BOOL is27up = false;
    if(@available(iOS 27, *)) { is27up = true; }
    if(is27up && [guestAppInfo[@"segCountMismatch"] boolValue]) {
        bypass_seg_count_check(dlopenBlock);
    } else {
        dlopenBlock();
    }

    appExecutableHandle = appHandle;
    const char *dlerr = dlerror();
    
    if (!appHandle || (uint64_t)appHandle > 0xf00000000000) {
        // 日志保持英文原文：dlerr 分支记系统原文，未知错误分支记固定英文串；
        // 上屏的 appError 单独取本地化版本（dlerr 系统原文不译）。
        NSString *dlopenLogMessage;
        if (dlerr) {
            dlopenLogMessage = @(dlerr);
            appError = dlopenLogMessage;
        } else {
            dlopenLogMessage = @"dlopen: an unknown error occurred";
            appError = LCBootstrapLocalized(@"lc.bootstrap.error.dlopenUnknownError");
        }
        NSLog(@"[LCBootstrap] %@", dlopenLogMessage);
        *path = oldPath;
        return appError;
    }
    
    if([guestAppInfo[@"dontInjectTweakLoader"] boolValue] && ![guestAppInfo[@"dontLoadTweakLoader"] boolValue]) {
        tweakLoaderLoaded = true;
        if([guestAppInfo[@"hideLiveContainer"] boolValue]) {
            dlopen([lcMainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/TweakLoader.dylib"].UTF8String, RTLD_LAZY|RTLD_GLOBAL);
        } else {
            dlopen("@loader_path/../TweakLoader.dylib", RTLD_LAZY|RTLD_GLOBAL);
        }
    }
    
    if(isSideStore) {
        tweakLoaderLoaded = true;
        dlopen([lcMainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/TweakLoader.dylib"].UTF8String, RTLD_LAZY|RTLD_GLOBAL);
    }
    
    if(sideStoreExist) {
        if (!isLiveProcess && (isSideStore || ![guestAppInfo[@"dontInjectTweakLoader"] boolValue])) {
            dlopen([lcMainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/SideStoreSupport.framework/SideStoreSupport"].UTF8String, RTLD_LAZY);
        } else if (isLiveProcess && isSideStore) {
            dlopen([lcMainBundle.bundlePath stringByAppendingPathComponent:@"../../Frameworks/SideStoreSupport.framework/SideStoreSupport"].UTF8String, RTLD_LAZY);
        }
    }
    
    // Fix dynamic properties of some apps
    [NSUserDefaults performSelector:@selector(initialize)];

    // Attempt to load the bundle. 32-bit bundle will always fail because of 32-bit main executable, so ignore it
    if (!is32bit && ![appBundle loadAndReturnError:&error]) {
        appError = error.localizedDescription;
        NSLog(@"[LCBootstrap] loading bundle failed: %@", error);
        *path = oldPath;
        return appError;
    }
    NSLog(@"[LCBootstrap] loaded bundle");

    // Find main()
    appMain = getAppEntryPoint(appHandle);
    if (!appMain) {
        appError = LCBootstrapLocalized(@"lc.bootstrap.error.mainEntryPointNotFound");
        NSLog(@"[LCBootstrap] Could not find the main entry point");
        *path = oldPath;
        return appError;
    }

    // standalone 进程内直跑：跳客体 main 前预置快捷栏（回游戏库）。
    // 多任务 LiveProcess 路径不装（快捷栏是进程内直跑形态的一部分）。
    // 内置 SideStore 也不装：它有自己的返回路径（SideStoreSupport 在其
    // My Apps 页注入 escape 图标回库），不是游戏、不需要回库浮钮；
    // 且快捷栏一次绑定场景不迁移，SideStore 的 scene 切换会让它绑到
    // 非前台 scene——渲染可见但收不到触摸（真机实测点不动）。连带停掉
    // 的游玩时长心跳对 SideStore 本就是误计（伪会话永远不会正常结清）。
    if (!isLiveProcess && !isSideStore) {
        LCQuickBarInstall();
        // 启动动画（游戏启动封面）：安装点全部早期错误返回之后、跳 main 前，
        // 与快捷栏同处预置；盖层挂客体场景必上盖，撤盖时刻 =
        // max(上盖 + 1.6s, 首帧信号 + 0.35s)，详见上方启动动画总注。
        NSString *guestDisplayName = appBundle.infoDictionary[@"CFBundleDisplayName"]
            ?: appBundle.infoDictionary[@"CFBundleName"] ?: selectedApp;
        LCLaunchCoverInstall(bundlePath, appBundle.bundleIdentifier, guestDisplayName);
    }

    // Go!
    NSLog(@"[LCBootstrap] jumping to main %p", appMain);
    int ret;
    if(!is32bit) {
        argv[0] = (char *)appExecPath;
        ret = appMain(argc, argv, environ);
    } else {
        char *argv32[] = {(char*)appExecPath, (char*)*path, NULL};
        ret = appMain(sizeof(argv32)/sizeof(*argv32) - 1, argv32, environ);
    }
    return [NSString stringWithFormat:LCBootstrapLocalized(@"lc.bootstrap.error.appReturnedFromMain %d"), ret];
}

static void exceptionHandler(NSException *exception) {
    NSString *error = [NSString stringWithFormat:@"%@\nCall stack: %@", exception.reason, exception.callStackSymbols];
    if(isLiveProcess) {
        NSExtensionContext *context = [NSClassFromString(@"LiveProcessHandler") extensionContext];
        [context cancelRequestWithError:[NSError errorWithDomain:@"LiveProcess" code:1 userInfo:@{NSLocalizedDescriptionKey: error}]];
    } else {
        [lcUserDefaults setObject:error forKey:@"error"];
    }
}

int LiveContainerMain(int argc, char *argv[]) {
    lcMainBundle = [NSBundle mainBundle];
    lcUserDefaults = NSUserDefaults.standardUserDefaults;
    
    lcSharedDefaults = [[NSUserDefaults alloc] initWithSuiteName: [LCSharedUtils appGroupID]];
    lcAppUrlScheme = NSBundle.mainBundle.infoDictionary[@"CFBundleURLTypes"][0][@"CFBundleURLSchemes"][0];
    lcAppGroupPath = [[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[NSClassFromString(@"LCSharedUtils") appGroupID]] path];
    isLiveProcess = [lcAppUrlScheme isEqualToString:@"gamecaseprocess"];
    setenv("LC_HOME_PATH", getenv("HOME"), 0);

    NSString *selectedApp = [lcUserDefaults stringForKey:@"selected"];
    NSString *selectedContainer = [lcUserDefaults stringForKey:@"selectedContainer"];
    NSString *launchUrl = nil;
    do {
        if(selectedApp) {
            launchUrl = [lcUserDefaults stringForKey:@"launchAppUrlScheme"];
            break;
        }
        // check launch task in shared defaults
        NSString* scheemFromLaunchExtension = [lcSharedDefaults stringForKey:@"LCLaunchExtensionScheme"];
        if(![scheemFromLaunchExtension isEqualToString:lcAppUrlScheme]) break;
        NSString* selectedAppFromLaunchExtension = [lcSharedDefaults stringForKey:@"LCLaunchExtensionBundleID"];
        if(!selectedAppFromLaunchExtension) break;
        NSDate* launchDate = [lcSharedDefaults objectForKey:@"LCLaunchExtensionLaunchDate"];
        NSTimeInterval secondsSinceDate = [launchDate timeIntervalSinceNow];
        if (secondsSinceDate >= 0 || secondsSinceDate < -3.0) break;
        
        selectedApp = selectedAppFromLaunchExtension;
        selectedContainer = [lcSharedDefaults stringForKey:@"LCLaunchExtensionContainerName"];
        launchUrl = [lcSharedDefaults stringForKey:@"LCLaunchExtensionLaunchURL"];
        
        [lcSharedDefaults removeObjectForKey:@"LCLaunchExtensionBundleID"];
        if (selectedContainer) [lcSharedDefaults removeObjectForKey:@"LCLaunchExtensionContainerName"];
        if (launchUrl) [lcSharedDefaults removeObjectForKey:@"LCLaunchExtensionLaunchURL"];
    } while (0);
    
    NSString* lastLaunchDataUUID;
    if(!isLiveProcess) {
        lastLaunchDataUUID = [lcUserDefaults objectForKey:@"lastLaunchDataUUID"];
    } else {
        lastLaunchDataUUID = selectedContainer;
    }
    
    // we put all files in app group after fixing 0xdead10cc. This call is here in case user upgraded lc with app's data in private Library/SharedDocuments
    [LCSharedUtils moveSharedAppFolderBack];

    // 回名自愈扫描，须在库与启动链读任何容器之前（尤其下方遗留偏好回收
    // 按静息名拼路径之前，孤儿空壳清扫在 SwiftUI 层、更在其后）。回库
    // 必经本入口，故每次回库都会先把上一局的换名夹改回；游玩中途断电/
    // 被杀停在游玩名的夹也在下次打开 GC 时在此自愈。LiveProcess 跳过：
    // 它是多任务托管进程（GC 已强制串行单开、永不走通），且其启动时主
    // 进程客体可能正以游玩名运行。
    if(!isLiveProcess) {
        NSString *docPath = [NSString stringWithFormat:@"%s/Documents", getenv("LC_HOME_PATH")];
        GCPlayNameSwapRestoreDataRoot([docPath stringByAppendingPathComponent:@"Data/Application"]);
        GCPlayNameSwapRestoreDataRoot([lcAppGroupPath stringByAppendingPathComponent:@"GameCase/Data/Application"]);
    }

    if(lastLaunchDataUUID) {
        NSString* lastLaunchType = [lcUserDefaults objectForKey:@"lastLaunchType"];
        NSString* preferencesTo;
        if([lastLaunchType isEqualToString:@"Shared"]) {
            preferencesTo = [LCSharedUtils.appGroupPath.path stringByAppendingPathComponent:[NSString stringWithFormat:@"GameCase/Data/Application/%@/Library/Preferences", lastLaunchDataUUID]];
        } else {
            NSString *docPath = [NSString stringWithFormat:@"%s/Documents", getenv("LC_HOME_PATH")];
            preferencesTo = [docPath stringByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@/Library/Preferences", lastLaunchDataUUID]];
        }
        // recover preferences
        // this is not needed anymore, it's here for backward competability
        [LCSharedUtils dumpPreferenceToPath:preferencesTo dataUUID:lastLaunchDataUUID];
        if(!isLiveProcess) {
            [lcUserDefaults removeObjectForKey:@"lastLaunchDataUUID"];
            [lcUserDefaults removeObjectForKey:@"lastLaunchType"];
        }
    }
    // in case some weird apps remove the tmp folder
    [NSFileManager.defaultManager createDirectoryAtPath:@(getenv("TMPDIR")) withIntermediateDirectories:YES attributes:nil error:nil];
    
    if([selectedApp isEqualToString:@"ui"]) {
        selectedApp = nil;
        [lcUserDefaults removeObjectForKey:@"selected"];
        [lcUserDefaults removeObjectForKey:@"selectedContainer"];
    }
    
    if(isLiveProcess) {
        sideStoreExist = [NSFileManager.defaultManager fileExistsAtPath:[lcMainBundle.bundlePath stringByAppendingPathComponent:@"../../Frameworks/SideStoreApp.framework"]];
    } else {
        sideStoreExist = [NSFileManager.defaultManager fileExistsAtPath:[lcMainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/SideStoreApp.framework"]];
    }

    if([lcUserDefaults boolForKey:@"LCOpenSideStore"] || [selectedApp isEqualToString:@"builtinSideStore"]) {
        if(sideStoreExist) {
            isSideStore = true;
        } else {
            [lcUserDefaults setBool:NO forKey:@"LCOpenSideStore"];
        }
    }
    
    if(selectedApp && !isSideStore && !selectedContainer) {
        selectedContainer = [LCSharedUtils findDefaultContainerWithBundleId:selectedApp];
    }
    NSString* runningLC = [LCSharedUtils getContainerUsingLCSchemeWithFolderName:selectedContainer];
    // if another instance is running, we just switch to that one, these should be called after uiapplication initialized
    // however if the running lc is gamecaseprocess and current lc is gamecase1 we just continue
    if(selectedApp && runningLC) {
        [lcUserDefaults removeObjectForKey:@"selected"];
        [lcUserDefaults removeObjectForKey:@"selectedContainer"];
        
        if([runningLC hasSuffix:@"gamecaseprocess"]) {
            runningLC = runningLC.stringByDeletingPathExtension;
        }
        
        NSString* selectedAppBackUp = selectedApp;
        selectedApp = nil;
        dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC));
        dispatch_after(delay, dispatch_get_main_queue(), ^{
            // Base64 encode the data
            NSString* urlStr;
            if(selectedContainer) {
                urlStr = [NSString stringWithFormat:@"%@://gamecase-launch?bundle-name=%@&container-folder-name=%@", runningLC, selectedAppBackUp, selectedContainer];
            } else {
                urlStr = [NSString stringWithFormat:@"%@://gamecase-launch?bundle-name=%@", runningLC, selectedAppBackUp];
            }
            
            NSURL* url = [NSURL URLWithString:urlStr];
            if([[NSClassFromString(@"UIApplication") sharedApplication] canOpenURL:url]){
                [[NSClassFromString(@"UIApplication") sharedApplication] openURL:url options:@{} completionHandler:nil];
                
                NSString *launchUrl = [lcUserDefaults stringForKey:@"launchAppUrlScheme"];
                // also pass url scheme to another lc
                if(launchUrl) {
                    [lcUserDefaults removeObjectForKey:@"launchAppUrlScheme"];

                    // Base64 encode the data
                    NSData *data = [launchUrl dataUsingEncoding:NSUTF8StringEncoding];
                    NSString *encodedUrl = [data base64EncodedStringWithOptions:0];
                    
                    NSString* finalUrl = [NSString stringWithFormat:@"%@://open-url?url=%@", runningLC, encodedUrl];
                    NSURL* url = [NSURL URLWithString: finalUrl];
                    
                    [[NSClassFromString(@"UIApplication") sharedApplication] openURL:url options:@{} completionHandler:nil];

                }
            }
        });

    }
    NSSetUncaughtExceptionHandler(&exceptionHandler);
    if (selectedApp || isSideStore) {
        [lcUserDefaults removeObjectForKey:@"selected"];
        [lcUserDefaults removeObjectForKey:@"selectedContainer"];
        if(launchUrl) {
            lcLaunchURL = launchUrl;
            [lcUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
        }
        // 先捕获宿主首选语言（启动封面提示文案用）：invokeAppMain 内的客体
        // 钩子会改写本进程 AppleLanguages，之后现读会失真
        LCLaunchCoverCaptureHostLanguage();
        NSString *appError = invokeAppMain(selectedApp, selectedContainer, argc, argv);
        if (appError) {
            if(isLiveProcess) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                    NSExtensionContext *context = [NSClassFromString(@"LiveProcessHandler") extensionContext];
                    [context cancelRequestWithError:[NSError errorWithDomain:@"LiveProcess" code:1 userInfo:@{NSLocalizedDescriptionKey: appError}]];
                    exit(1);
                });
                // spin and wait for iOS to terminate
                CFRunLoopRun();
            } else {
                [lcUserDefaults setObject:appError forKey:@"error"];
                // potentially unrecovable state, exit now
                return 1;
            }
        }
    }
    
    if(isLiveProcess) {
        NSLog(@"LiveProcess should not launch lcui!");
        return 0;
    }
    
    // put back cookies
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *libraryURL = [fm URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;;
    NSURL *cookies2URL = [libraryURL URLByAppendingPathComponent:@"Cookies2"];
    
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:cookies2URL.path isDirectory:&isDir] && isDir) {
        NSError *error = nil;
        NSURL *cookiesURL  = [libraryURL URLByAppendingPathComponent:@"Cookies"];
        // Remove old Caches folder if exists
        if ([fm fileExistsAtPath:cookiesURL.path]) {
            if ([fm removeItemAtURL:cookiesURL error:&error]) {
                [fm moveItemAtURL:cookies2URL toURL:cookiesURL error:&error];
            } else{
                NSLog(@"Failed to remove old Cookies folder: %@", error);
            }
        }
    }
    
    void *LiveContainerSwiftUIHandle = dlopen("@executable_path/Frameworks/LiveContainerSwiftUI.framework/LiveContainerSwiftUI", RTLD_LAZY);
    NSCAssert(LiveContainerSwiftUIHandle, @"%s", dlerror());
    
    if(sideStoreExist) {
        void* sideStoreHandle = dlopen("@executable_path/Frameworks/SideStoreSupport.framework/SideStoreSupport", RTLD_LAZY);
    }

    if ([lcUserDefaults boolForKey:@"LCLoadTweaksToSelf"]) {
        NSString *tweakFolder = nil;
        if (isSharedBundle) {
            NSURL *appGroupPath = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[LCSharedUtils appGroupID]];
            tweakFolder = [appGroupPath.path stringByAppendingPathComponent:@"GameCase/Tweaks"];
        } else {
            NSString *docPath = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject.path;
            tweakFolder = [docPath stringByAppendingPathComponent:@"Tweaks"];
        }
        setenv("LC_GLOBAL_TWEAKS_FOLDER", tweakFolder.UTF8String, 1);
#if TARGET_OS_MACCATALYST || TARGET_OS_SIMULATOR
        extern void DyldHookLoadableIntoProcess(void);
        DyldHookLoadableIntoProcess();
#endif
        dlopen("@executable_path/Frameworks/TweakLoader.dylib", RTLD_LAZY);
    }

    int (*LiveContainerSwiftUIMain)(void) = dlsym(LiveContainerSwiftUIHandle, "main");
    return LiveContainerSwiftUIMain();

}

#ifdef DEBUG
int callAppMain(int argc, char *argv[], char *envp[]) {
    assert(appMain != NULL);
    __attribute__((musttail)) return appMain(argc, argv, envp);
}
#endif
