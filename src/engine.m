// BGNetwork 2.1.5 —— 父进程看门狗 + 子进程策略引擎
//
// 设计依据（设备实测）：
//   * 原版 1.2.2 守护进程**静态链接** NetworkExtension / BackBoardServices 时能正常工作；
//     我用 dlopen 加载这些 UI 类私有框架时进程启动后很快退出（launchctl status 11）。
//     → 这里完全对齐原版的链接方式，不做 dlopen。
//   * 原版每次 tick 都 new NEPolicySession + removeAllPolicies + 全量 addPolicy，
//     应用一多就耗尽内核 NECP 槽位 → apply 全失败 → 用户看到「掉服务」。
//     → 这里改成单会话 + 差分下发 + 目录缓存。
//   * App 每 3 秒读一次 status.json，updated 过期就显示「等待服务启动」。
//     → 父进程独立负责写 status.json（每 2 秒），引擎子进程崩了也不影响界面新鲜度；
//       同时自动重启子进程，做到「掉服务可自愈」。
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>
#import <signal.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <stdio.h>
#import <stdarg.h>
#import <string.h>
#import <time.h>
#include <dlfcn.h>

static const char *kPrefPath  = "/var/mobile/Library/Preferences/com.local.bgnetwork.plist";
static const char *kPrefAlt   = "/private/var/mobile/Library/Preferences/com.local.bgnetwork.plist";
static const char *kLogPath   = "/var/mobile/Library/Preferences/com.local.bgnetwork.daemon.log";
static const char *kStatusDir = "/var/jb/var/lib/BGNetwork";
static const char *kEngineOut = "/var/jb/var/lib/BGNetwork/engine.json";
static const char *kSafeMode = "/var/jb/var/lib/BGNetwork/safemode";

#define VERSION_STR "2.1.5"
#define MAX_CHANGES_PER_TICK 32
#define UUID_CACHE_TTL       300.0
#define REBUILD_COOLDOWN     30.0

#pragma mark - 日志 / 工具

static void L(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    char buf[1024]; vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap);
    printf("BGNetwork: %s\n", buf); fflush(stdout);
    FILE *f = fopen(kLogPath, "a");
    if (!f) f = fopen("/private/var/mobile/Library/Preferences/com.local.bgnetwork.daemon.log", "a");
    if (f) {
        time_t t = time(NULL); struct tm m; localtime_r(&t, &m);
        fprintf(f, "%02d:%02d:%02d %s\n", m.tm_hour, m.tm_min, m.tm_sec, buf);
        fclose(f);
    }
}

static NSDictionary *readPrefs(void) {
    const char *paths[2] = {kPrefPath, kPrefAlt};
    for (int i = 0; i < 2; i++) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithUTF8String:paths[i]]];
        if ([d isKindOfClass:[NSDictionary class]]) return d;
    }
    return @{};
}

// 把状态写到所有可能的根（RootHide 下 /var/jb 与 .jbroot-* 可能不是同一视角）
static void write_status_data(NSData *data) {
    if (!data) return;
    const char *cands[] = {
        "/var/jb/var/lib/BGNetwork/status.json",
        "/private/var/jb/var/lib/BGNetwork/status.json",
        NULL };
    NSFileManager *fm = [NSFileManager defaultManager];
    for (int i = 0; cands[i]; i++) {
        NSString *dir = [[NSString stringWithUTF8String:cands[i]] stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        [data writeToFile:[NSString stringWithUTF8String:cands[i]] options:NSDataWritingAtomic error:NULL];
    }
    NSArray *apps = [fm contentsOfDirectoryAtPath:@"/private/var/containers/Bundle/Application" error:NULL];
    for (NSString *a in apps) {
        if (![a hasPrefix:@".jbroot-"]) continue;
        NSString *dir = [[[@"/private/var/containers/Bundle/Application" stringByAppendingPathComponent:a]
                          stringByAppendingPathComponent:@"var/lib/BGNetwork"] copy];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;
        [data writeToFile:[dir stringByAppendingPathComponent:@"status.json"]
                  options:NSDataWritingAtomic error:NULL];
    }
}

static NSDictionary *minimal_status(NSString *err) {
    NSDictionary *cfg = readPrefs();
    NSMutableDictionary *o = [NSMutableDictionary dictionary];
    o[@"version"] = @VERSION_STR;
    o[@"updated"] = @([[NSDate date] timeIntervalSince1970]);
    o[@"engine"] = @"NEPolicySession(diff)";
    o[@"enabled"] = cfg[@"enabled"] ?: @NO;
    o[@"delay"] = cfg[@"delay"] ?: @0;
    o[@"apps"] = @[];
    o[@"names"] = @{};
    o[@"policies"] = @0;
    o[@"applyFails"] = @0;
    if (err) o[@"error"] = err;
    return o;
}

#pragma mark - 私有类访问（静态链接后 objc_getClass 即可见）

static Class CL(const char *n) { return objc_getClass(n); }

static id M0(id o, const char *s) {
    if (!o) return nil; SEL x = sel_registerName(s);
    return [o respondsToSelector:x] ? ((id (*)(id, SEL))objc_msgSend)(o, x) : nil;
}
static id M1(id o, const char *s, id a) {
    if (!o) return nil; SEL x = sel_registerName(s);
    return [o respondsToSelector:x] ? ((id (*)(id, SEL, id))objc_msgSend)(o, x, a) : nil;
}
static id C1(Class c, const char *s, id a) {
    if (!c) return nil; SEL x = sel_registerName(s);
    return [c respondsToSelector:x] ? ((id (*)(id, SEL, id))objc_msgSend)((id)c, x, a) : nil;
}
static long long LI(id o, const char *s) {
    if (!o) return 0; SEL x = sel_registerName(s);
    return [o respondsToSelector:x] ? ((long long (*)(id, SEL))objc_msgSend)(o, x) : 0;
}
static BOOL B0(id o, const char *s) {
    if (!o) return NO; SEL x = sel_registerName(s);
    return [o respondsToSelector:x] ? ((BOOL (*)(id, SEL))objc_msgSend)(o, x) : NO;
}

#pragma mark - 框架预加载

// 静态链接后类已可见，这里仅做存在性检查并记录，便于定位崩溃
void preload_fw(void) {
    const char *need[] = {"NEPolicySession","NEPolicy","NEPolicyCondition","NEPolicyResult",
                          "NEProcessInfo","BKSApplicationStateMonitor","LSApplicationWorkspace",NULL};
    for (int i = 0; need[i]; i++)
        L("    class %-26s %s", need[i], objc_getClass(need[i]) ? "OK" : "MISSING");
}

#pragma mark - 引擎

@interface BGN : NSObject
@property (nonatomic, strong) id session;
@property (nonatomic, strong) id monitor;
@property (nonatomic, strong) NSMutableSet *applied;
@property (nonatomic, strong) NSMutableDictionary *uuidCache;
@property (nonatomic, strong) NSMutableDictionary *uuidStamp;
@property (nonatomic, strong) NSMutableDictionary *since;
@property (nonatomic, strong) NSMutableSet *blocked;
@property (nonatomic, strong) NSMutableDictionary *exeMap;
@property (nonatomic, strong) NSMutableDictionary *nameMap;
@property (nonatomic) double exeStamp;
@property (nonatomic) double lastRebuild;
@property (nonatomic) long long applyFails;
@property (nonatomic, copy) NSString *err;
@property (nonatomic, strong) NSArray *lastRows;
- (void)tick;
@end

@implementation BGN
- (instancetype)init {
    if ((self = [super init])) {
        _applied = [NSMutableSet set];
        _uuidCache = [NSMutableDictionary dictionary];
        _uuidStamp = [NSMutableDictionary dictionary];
        _since = [NSMutableDictionary dictionary];
        _blocked = [NSMutableSet set];
        _exeMap = [NSMutableDictionary dictionary];
        _nameMap = [NSMutableDictionary dictionary];
    }
    return self;
}

- (id)sessionObject {
    if (self.session) return self.session;
    Class c = CL("NEPolicySession");
    if (!c) { self.err = @"NEPolicySession missing"; return nil; }
    id a = ((id (*)(id, SEL))objc_msgSend)((id)c, sel_registerName("alloc"));
    id s = nil;
    if (a && [a respondsToSelector:sel_registerName("init")])
        s = ((id (*)(id, SEL))objc_msgSend)(a, sel_registerName("init"));
    if (!s) s = M0((id)c, "new");
    if (s) { self.session = s; [self.applied removeAllObjects]; L("new session %p", s); }
    return s;
}

- (void)dropSession {
    if (self.session) M0(self.session, "removeAllPolicies");
    self.session = nil;
    [self.applied removeAllObjects];
}

- (id)monitorObject {
    if (self.monitor) return self.monitor;
    Class c = CL("BKSApplicationStateMonitor");
    if (!c) return nil;
    id m = M0((id)c, "sharedInstance");
    if (!m) {
        id a = ((id (*)(id, SEL))objc_msgSend)((id)c, sel_registerName("alloc"));
        if (a && [a respondsToSelector:sel_registerName("init")])
            m = ((id (*)(id, SEL))objc_msgSend)(a, sel_registerName("init"));
    }
    self.monitor = m;
    return m;
}

- (NSInteger)stateFor:(NSString *)bid {
    // 安全模式：跳过 BKSApplicationStateMonitor（该调用在部分环境下会 SIGSEGV）。
    // 一律按「后台」处理，让延迟计时照常推进，断网功能仍可用。
    if (access(kSafeMode, F_OK) == 0) return 16;
    id m = [self monitorObject];
    if (!m) return -1;
    id n = M1(m, "applicationStateForApplication:", bid);
    if ([n isKindOfClass:[NSNumber class]]) return [(NSNumber *)n integerValue];
    id info = M1(m, "applicationInfoForApplication:", bid);
    if (info) {
        id st = M1(info, "objectForKeyedSubscript:", @"state");
        if ([st isKindOfClass:[NSNumber class]]) return [(NSNumber *)st integerValue];
    }
    return -1;
}

- (void)rebuildCatalog {
    // 安全模式下仍然允许枚举（UUID 依赖它）；只有 monitor 是崩溃源时才需要跳过

    double now = [[NSDate date] timeIntervalSince1970];
    if (now - self.exeStamp < 300.0 && self.exeMap.count) return;
    self.exeStamp = now;
    Class ws = CL("LSApplicationWorkspace");
    id w = M0((id)ws, "defaultWorkspace");
    id apps = M0(w, "allApplications");
    if (![apps isKindOfClass:[NSArray class]]) return;
    [self.exeMap removeAllObjects];
    [self.nameMap removeAllObjects];
    for (id p in apps) {
        NSString *b = M0(p, "bundleIdentifier");
        if (![b isKindOfClass:[NSString class]] || !b.length) continue;
        id u = M0(p, "bundleURL");
        if (![u isKindOfClass:[NSURL class]]) continue;
        NSString *base = [(NSURL *)u path];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                              [base stringByAppendingPathComponent:@"Info.plist"]];
        NSString *exe = info[@"CFBundleExecutable"];
        if ([exe isKindOfClass:[NSString class]])
            self.exeMap[b] = [base stringByAppendingPathComponent:exe];
        NSString *ln = M0(p, "localizedName");
        if ([ln isKindOfClass:[NSString class]] && ln.length) self.nameMap[b] = ln;
        else self.nameMap[b] = info[@"CFBundleDisplayName"] ?: b;
    }
    L("catalog cached: %lu apps", (unsigned long)self.exeMap.count);
}

- (NSString *)nameFor:(NSString *)bid {
    if (access(kSafeMode, F_OK) == 0) return bid;
    if (!self.exeMap.count) [self rebuildCatalog];
    NSString *n = self.nameMap[bid];
    return n.length ? n : bid;
}

- (NSString *)uuidFor:(NSString *)bid {
    NSString *u0 = [self uuidForImpl:bid];
    if (!u0) L("    uuid FAIL %s", [bid UTF8String]);
    return u0;
}

- (NSString *)uuidForImpl:(NSString *)bid {
    double now = [[NSDate date] timeIntervalSince1970];
    NSNumber *ts = self.uuidStamp[bid];
    NSString *cached = self.uuidCache[bid];
    if (cached && ts && now - ts.doubleValue < UUID_CACHE_TTL) return cached;

    Class ni = CL("NEProcessInfo");
    if (!ni) { L("    NEProcessInfo MISSING"); return nil; }

    id uuids = C1(ni, "copyUUIDsForBundleID:", bid);
    L("    uuid[1] bundle=%s -> %lu", [bid UTF8String],
      [uuids isKindOfClass:[NSArray class]] ? (unsigned long)[(NSArray *)uuids count] : 0UL);
    if (![uuids isKindOfClass:[NSArray class]] || ![(NSArray *)uuids count]) {
        if (!self.exeMap.count) [self rebuildCatalog];
        NSString *exe = self.exeMap[bid];
        if (exe) {
            uuids = C1(ni, "copyUUIDsForExecutable:", exe);
            L("    uuid[2] exe=%s -> %lu", [exe UTF8String],
              [uuids isKindOfClass:[NSArray class]] ? (unsigned long)[(NSArray *)uuids count] : 0UL);
        } else {
            L("    uuid[2] no exe path for %s (catalog=%lu)", [bid UTF8String],
              (unsigned long)self.exeMap.count);
        }
    }
    // 回退 3：直接把 bundleID 当作 UUID（某些环境 effectiveApplication: 接受 bundle id）
    if (![uuids isKindOfClass:[NSArray class]] || ![(NSArray *)uuids count]) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
            @"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
            options:0 error:NULL];
        (void)re;
        if ([bid length] == 36) { uuids = @[bid]; L("    uuid[3] using bid as uuid"); }
    }
    NSString *out = nil;
    if ([uuids isKindOfClass:[NSArray class]] && [(NSArray *)uuids count]) {
        id u = [(NSArray *)uuids objectAtIndex:0];
        if ([u isKindOfClass:[NSUUID class]]) out = [(NSUUID *)u UUIDString];
        else if ([u isKindOfClass:[NSString class]]) out = u;
    }
    if (out) { self.uuidCache[bid] = out; self.uuidStamp[bid] = @(now); }
    return out;
}

- (id)policyForUUID:(NSString *)uuidString drop:(id)drop {
    Class cP = CL("NEPolicy"), cC = CL("NEPolicyCondition");
    if (!cP || !cC) return nil;
    id uuid = C1(CL("NSUUID"), "initWithUUIDString:", uuidString);
    if (!uuid) return nil;
    id cond = C1(cC, "effectiveApplication:", uuid);
    if (!cond) return nil;
    NSArray *conds = @[cond];
    SEL mk = sel_registerName("initWithOrder:result:conditions:");
    if ([cP instancesRespondToSelector:mk]) {
        id a = ((id (*)(id, SEL))objc_msgSend)((id)cP, sel_registerName("alloc"));
        if (a) return ((id (*)(id, SEL, int, id, id))objc_msgSend)(a, mk, 0, drop, conds);
    }
    id p = M0((id)cP, "new");
    if (p) { M1(p, "setResult:", drop); M1(p, "setConditions:", conds); }
    return p;
}

- (BOOL)syncTo:(NSSet<NSString *> *)target {
    L("    sync: sessionObject");
    id s = [self sessionObject];
    L("    sync: session=%p", s);
    if (!s) return NO;
    id drop = M0(CL("NEPolicyResult"), "drop");
    if (!drop) { self.err = @"NEPolicyResult.drop missing"; return NO; }

    NSMutableSet *toAdd = [target mutableCopy];
    [toAdd minusSet:self.applied];
    NSMutableSet *toDel = [self.applied mutableCopy];
    [toDel minusSet:target];

    if (toAdd.count > MAX_CHANGES_PER_TICK) {
        NSMutableSet *cut = [NSMutableSet set];
        int i = 0;
        for (NSString *u in toAdd) { if (i++ >= MAX_CHANGES_PER_TICK) break; [cut addObject:u]; }
        toAdd = cut;
    }

    NSUInteger changed = 0;
    for (NSString *uuid in toAdd) {
        id pol = [self policyForUUID:uuid drop:drop];
        if (!pol) continue;
        id r = M1(s, "addPolicy:", pol);
        if ([r isKindOfClass:[NSNumber class]] && [(NSNumber *)r longLongValue] > 0) {
            [self.applied addObject:uuid];
            changed++;
        }
    }

    if (toDel.count && changed == 0 && toDel.count * 2 >= self.applied.count) {
        double now = [[NSDate date] timeIntervalSince1970];
        if (now - self.lastRebuild > REBUILD_COOLDOWN) {
            self.lastRebuild = now;
            L("rebuild (drop %lu stale)", (unsigned long)toDel.count);
            M0(s, "removeAllPolicies");
            [self.applied removeAllObjects];
            return [self syncTo:target];
        }
    }
    if (changed == 0 && toAdd.count == 0) return YES;

    id rc = M0(s, "apply");
    long long code = [rc isKindOfClass:[NSNumber class]] ? [(NSNumber *)rc longLongValue] : 0;
    if (code != 0) {
        self.applyFails++;
        self.err = [NSString stringWithFormat:@"apply=%lld fails=%lld policies=%lu",
                    code, self.applyFails, (unsigned long)self.applied.count];
        L("apply failed %lld", code);
        double now = [[NSDate date] timeIntervalSince1970];
        if (now - self.lastRebuild > REBUILD_COOLDOWN) { self.lastRebuild = now; [self dropSession]; }
        return NO;
    }
    self.err = nil;
    if (changed) L("applied +%lu total %lu", (unsigned long)changed, (unsigned long)self.applied.count);
    return YES;
}

- (void)tick {
    @try {
        L("  tick: readPrefs");
        NSDictionary *cfg = readPrefs();
        BOOL enabled = B0(cfg[@"enabled"], "boolValue");
        id dv = cfg[@"delay"];
        double delay = [dv isKindOfClass:[NSNumber class]] ? [dv doubleValue] : 1.0;
        NSArray *apps = cfg[@"apps"];
        if (![apps isKindOfClass:[NSArray class]]) apps = @[];

        L("  tick: monitor state for %lu apps", (unsigned long)[apps count]);
        double now = [[NSDate date] timeIntervalSince1970];
        NSMutableSet *target = [NSMutableSet set];
        NSMutableSet *blocked = [NSMutableSet set];
        NSMutableArray *rows = [NSMutableArray array];

        for (NSString *bid in apps) {
            if (![bid isKindOfClass:[NSString class]]) continue;
            NSInteger st = [self stateFor:bid];
            BOOL fg = (st == 8 || st == 32);
            BOOL dead = (st <= 1);

            if (dead) {
                [self.since removeObjectForKey:bid];
                BOOL wasBlocked = [self.blocked containsObject:bid];
                if (wasBlocked) {
                    NSString *u = [self uuidFor:bid];
                    if (u) { [target addObject:u]; [blocked addObject:bid]; }
                }
                [rows addObject:@{@"id": bid, @"name": [self nameFor:bid], @"label": [self nameFor:bid],
                                  @"state": @"suspended", @"blocked": @(wasBlocked), @"remaining": @0}];
                continue;
            }
            if (fg) {
                [self.since removeObjectForKey:bid];
                [rows addObject:@{@"id": bid, @"name": [self nameFor:bid], @"label": [self nameFor:bid],
                                  @"state": @"foreground", @"blocked": @NO, @"remaining": @0}];
                continue;
            }
            NSNumber *s0 = self.since[bid];
            if (!s0) { s0 = @(now); self.since[bid] = s0; }
            double waited = now - s0.doubleValue;
            BOOL should = enabled && waited >= delay;
            if (should) {
                NSString *u = [self uuidFor:bid];
                if (u) { [target addObject:u]; [blocked addObject:bid]; }
            }
            [rows addObject:@{@"id": bid, @"name": [self nameFor:bid], @"label": [self nameFor:bid],
                              @"state": @"background", @"blocked": @(should),
                              @"remaining": @(MAX(0.0, delay - waited))}];
        }

        L("  tick: syncTo %lu uuids (want-block %lu)", (unsigned long)target.count,
          (unsigned long)blocked.count);
        self.lastRows = rows;
        if (target.count == 0 && blocked.count > 0) {
            L("  WARN: %lu apps want block but 0 uuids resolved", (unsigned long)blocked.count);
        }
        BOOL ok = [self syncTo:target];
        if (ok) self.blocked = blocked;

        NSMutableDictionary *o = [NSMutableDictionary dictionary];
        o[@"version"] = @VERSION_STR;
        o[@"updated"] = @([[NSDate date] timeIntervalSince1970]);
        o[@"engine"] = @"NEPolicySession(diff)";
        o[@"enabled"] = cfg[@"enabled"] ?: @NO;
        o[@"delay"] = cfg[@"delay"] ?: @0;
        o[@"apps"] = rows;
        NSMutableDictionary *names = [NSMutableDictionary dictionary];
        for (NSString *b in self.blocked) names[b] = [self nameFor:b];
        o[@"names"] = names;
        o[@"policies"] = @(self.applied.count);
        o[@"applyFails"] = @(self.applyFails);
        if (self.err) o[@"error"] = self.err;
        NSData *data = [NSJSONSerialization dataWithJSONObject:o options:0 error:nil];
        if (data) [data writeToFile:[NSString stringWithUTF8String:kEngineOut]
                            options:NSDataWritingAtomic error:NULL];
    } @catch (NSException *e) {
        L("tick exception: %s", [[e reason] UTF8String] ?: "?");
    }
}
@end

#pragma mark - 子进程：引擎

static void on_crash(int sig) {
    char buf[128];
    int n = snprintf(buf, sizeof buf, "CRASH signal=%d\n", sig);
    int fd = open(kLogPath, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd >= 0) { write(fd, buf, n); close(fd); }
    signal(sig, SIG_DFL);
    raise(sig);
}

static int engine_main(void) {
    signal(SIGSEGV, on_crash);
    signal(SIGABRT, on_crash);
    signal(SIGBUS, on_crash);
    signal(SIGILL, on_crash);
    L("engine up pid=%d", (int)getpid());
    L("step 1: preload");
    { extern void preload_fw(void); preload_fw(); }
    L("step 2: classes");

    const char *need[] = {"NEPolicySession", "NEPolicy", "NEPolicyCondition", "NEPolicyResult",
                          "NEProcessInfo", "BKSApplicationStateMonitor", "LSApplicationWorkspace", NULL};
    for (int i = 0; need[i]; i++)
        if (!CL(need[i])) L("class %s MISSING", need[i]);

    L("step 3: alloc BGN");
    BGN *d = [BGN new];
    L("step 4: first tick");
    int iter = 0;
    while (1) {
        L("tick %d begin", iter);
        @autoreleasepool { [d tick]; }
        L("tick %d end", iter);
        iter++;
        sleep(2);
    }
    return 0;
}

#pragma mark - 父进程：看门狗 + 状态镜像

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--engine") == 0) return engine_main();
        if (argc > 1 && strcmp(argv[1], "--mintest") == 0) {
            // 轻量自检：只验证类可见与 session 可建（由 root 运行才有意义）
            const char *need[] = {"NEPolicySession","NEPolicy","NEPolicyCondition","NEPolicyResult",
                                  "NEProcessInfo","BKSApplicationStateMonitor","NSUUID",NULL};
            for (int i = 0; need[i]; i++)
                printf("%-28s : %s\n", need[i], CL(need[i]) ? "OK" : "MISSING");
            BGN *dd = [BGN new];
            id ss = [dd sessionObject];
            printf("%-28s : %s\n", "session", ss ? "OK" : "FAIL");
            if (ss) {
                NSData *probe = [NSJSONSerialization dataWithJSONObject:minimal_status(nil) options:0 error:nil];
                printf("%-28s : %s\n", "status writable",
                       [probe writeToFile:@"/var/jb/var/lib/BGNetwork/status.json"
                                  options:NSDataWritingAtomic error:NULL] ? "OK" : "FAIL");
            }
            return 0;
        }

        if (argc > 1 && strcmp(argv[1], "--selftest") == 0) {
            const char *need[] = {"NEPolicySession","NEPolicy","NEPolicyCondition","NEPolicyResult",
                                  "NEProcessInfo","BKSApplicationStateMonitor","NSUUID",NULL};
            for (int i = 0; need[i]; i++)
                printf("%-28s : %s\n", need[i], CL(need[i]) ? "OK" : "MISSING");
            BGN *d = [BGN new];
            id s = [d sessionObject];
            printf("%-28s : %s\n", "session", s ? "OK" : "FAIL");
            printf("%-28s : %s\n", "drop", M0(CL("NEPolicyResult"), "drop") ? "OK" : "FAIL");
            if (s) { id r = M0(s, "apply"); printf("%-28s : %s\n", "apply(empty)", r ? [[r description] UTF8String] : "nil"); }
            printf("%-28s : %s\n", "monitor", [d monitorObject] ? "OK" : "FAIL");
            NSData *dd = [NSJSONSerialization dataWithJSONObject:minimal_status(nil) options:0 error:nil];
            printf("status.json writable  : %s\n",
                   [dd writeToFile:@"/var/jb/var/lib/BGNetwork/status.json" options:NSDataWritingAtomic error:NULL] ? "OK" : "FAIL");
            return 0;
        }

        if (argc > 1 && strcmp(argv[1], "--diag") == 0) {
            printf("pid=%d euid=%d\n", (int)getpid(), (int)geteuid());
            const char *cands[] = {"/var/jb/var/lib/BGNetwork/status.json",
                                   "/private/var/jb/var/lib/BGNetwork/status.json", NULL};
            for (int i = 0; cands[i]; i++) {
                NSString *p = [NSString stringWithUTF8String:cands[i]];
                BOOL ex = [[NSFileManager defaultManager] fileExistsAtPath:p];
                NSData *raw = [NSData dataWithContentsOfFile:p];
                id obj = raw ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL] : nil;
                printf("%-52s exists=%d", cands[i], ex);
                if ([obj isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *o = obj;
                    printf("  age=%.0fs apps=%lu policies=%@ err=%@",
                           [[NSDate date] timeIntervalSince1970] - [o[@"updated"] doubleValue],
                           (unsigned long)[o[@"apps"] count], o[@"policies"] ?: @"-", o[@"error"] ?: @"-");
                }
                printf("\n");
            }
            NSData *er = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:kEngineOut]];
            printf("engine.json: %s\n", er ? "present" : "missing");
            return 0;
        }

        if (geteuid() != 0) { fprintf(stderr, "requires root\n"); return 1; }
        mkdir("/var/jb/var/lib", 0755);
        mkdir(kStatusDir, 0755);
        L("=== watchdog " VERSION_STR " pid=%d ===", (int)getpid());

        NSData *boot = [NSJSONSerialization dataWithJSONObject:minimal_status(@"starting") options:0 error:nil];
        write_status_data(boot);

        int restarts = 0;
        while (1) {
            pid_t pid = fork();
            if (pid == 0) {
                // 子进程：只跑引擎
                _exit(engine_main());
            }
            if (pid < 0) {
                L("fork failed errno=%d", errno);
                sleep(3);
                continue;
            }
            L("engine spawned pid=%d", (int)pid);
            int status = 0;
            while (1) {
                @autoreleasepool {
                    NSData *raw = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:kEngineOut]];
                    id obj = raw ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL] : nil;
                    NSMutableDictionary *o = [obj isKindOfClass:[NSDictionary class]]
                        ? [obj mutableCopy] : [minimal_status(@"engine starting") mutableCopy];
                    o[@"updated"] = @([[NSDate date] timeIntervalSince1970]);
                    NSData *d2 = [NSJSONSerialization dataWithJSONObject:o options:0 error:nil];
                    write_status_data(d2);
                }
                for (int i = 0; i < 20; i++) {   // 2 秒，拆成 100ms 便于及时回收子进程
                    usleep(100 * 1000);
                    pid_t r = waitpid(pid, &status, WNOHANG);
                    if (r == pid) goto child_gone;
                }
            }
        child_gone:
            restarts++;
            L("engine exited status=%d signal=%d restarts=%d",
              WIFEXITED(status) ? WEXITSTATUS(status) : -1,
              WIFSIGNALED(status) ? WTERMSIG(status) : 0, restarts);
            sleep(1);
        }
    }
    return 0;
}
