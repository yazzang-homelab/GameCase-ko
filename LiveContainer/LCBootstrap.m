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
#include <signal.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <stdlib.h>
#include "../litehook/src/litehook.h"
#import "Tweaks/Tweaks.h"
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
