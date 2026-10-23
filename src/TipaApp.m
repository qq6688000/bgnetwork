// BGNetwork TIPA 版 — 首次启动自安装守护进程 + 应用开关列表
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <spawn.h>
#import <stdio.h>
#import <stdlib.h>

extern char **environ;
extern int notify_post(const char *name);

static int run_shell(const char *cmd) {
    pid_t pid = -1;
    char *argv[] = { (char *)"/bin/sh", (char *)-1, (char *)cmd, NULL };
    argv[1] = (char *)"-c";
    int rc = posix_spawn(&pid, "/bin/sh", NULL, NULL, argv, environ);
    if (rc != 0) return -1;
    int st = 0;
    waitpid(pid, &st, 0);
    return st;
}

static NSString *const kPrefPath   = @"/var/mobile/Library/Preferences/com.local.bgnetwork.plist";
static NSString *const kStatusA    = @"/var/jb/var/lib/BGNetwork/status.json";
static NSString *const kStatusB    = @"/var/mobile/Library/BGNetwork/status.json";
static NSString *const kNotiName   = @"com.local.bgnetwork.changed";

static id M0(id o, const char *s) {
    if (!o) return nil; SEL x = sel_registerName(s);
    return [o respondsToSelector:x] ? ((id (*)(id, SEL))objc_msgSend)(o, x) : nil;
}
static BOOL MB(id o, const char *s) {
    if (!o) return NO; SEL x = sel_registerName(s);
    return [o respondsToSelector:x] ? ((BOOL (*)(id, SEL))objc_msgSend)(o, x) : NO;
}

#pragma mark - 安装器

@interface BGNInstaller : NSObject
+ (NSString *)daemonRoot;
+ (BOOL)isInstalled;
+ (BOOL)isRunning;
+ (BOOL)install;
+ (NSString *)hint;
@end

@implementation BGNInstaller

+ (NSString *)daemonRoot {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:@"/var/jb" isDirectory:&isDir] && isDir) return @"/var/jb";
    return @"/var/mobile/Library/BGNetwork";
}

+ (BOOL)isInstalled {
    return [[NSFileManager defaultManager] fileExistsAtPath:
            [[self daemonRoot] stringByAppendingPathComponent:@"usr/libexec/bgnetworkd"]];
}

+ (BOOL)isRunning {
    FILE *f = popen("launchctl list 2>/dev/null | grep -c com.local.bgnetworkd", "r");
    if (!f) return NO;
    char buf[64] = {0};
    if (fread(buf, 1, sizeof buf - 1, f) == 0) { /* ignore */ }
    pclose(f);
    return atoi(buf) > 0;
}

+ (NSString *)hint {
    NSString *root = [self daemonRoot];
    if ([root isEqualToString:@"/var/jb"]) {
        return @"写入 /var/jb 需要 root。请任选其一：\n"
               @"1) 终端 su 后执行：\n"
               @"   cp -a /var/mobile/Library/BGNetwork/usr/libexec/* /var/jb/usr/libexec/\n"
               @"   launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.local.bgnetworkd.plist\n"
               @"2) 或直接安装 deb 版本。";
    }
    return @"请重启设备，LaunchAgent 会随 SpringBoard 登录自动加载。";
}

+ (BOOL)install {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [self daemonRoot];
    NSString *bundle = [[NSBundle mainBundle] bundlePath];
    BOOL rootless = [root isEqualToString:@"/var/jb"];

    NSString *execDir = [root stringByAppendingPathComponent:@"usr/libexec"];
    NSString *ldDir   = [root stringByAppendingPathComponent:
                         (rootless ? @"Library/LaunchDaemons" : @"Library/LaunchAgents")];
    NSError *err = nil;
    [fm createDirectoryAtPath:execDir withIntermediateDirectories:YES attributes:nil error:&err];
    [fm createDirectoryAtPath:ldDir withIntermediateDirectories:YES attributes:nil error:&err];
    [fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"var/lib/BGNetwork"]
        withIntermediateDirectories:YES attributes:nil error:&err];

    NSString *srcExec = [bundle stringByAppendingPathComponent:@"bgnetworkd"];
    NSString *dstExec = [execDir stringByAppendingPathComponent:@"bgnetworkd"];
    if (![fm fileExistsAtPath:srcExec]) return NO;
    [fm removeItemAtPath:dstExec error:NULL];
    if (![fm copyItemAtPath:srcExec toPath:dstExec error:&err]) {
        NSLog(@"copy failed: %@", err);
        return NO;
    }
    chmod([dstExec fileSystemRepresentation], 0755);

    NSString *plistPath = [ldDir stringByAppendingPathComponent:@"com.local.bgnetworkd.plist"];
    NSDictionary *pl = @{
        @"Label": @"com.local.bgnetworkd",
        @"ProgramArguments": @[dstExec],
        @"RunAtLoad": @YES,
        @"KeepAlive": @YES,
        @"ThrottleInterval": @30,
        @"ProcessType": @"Interactive"
    };
    if (![pl writeToFile:plistPath atomically:YES]) return NO;
    chmod([plistPath fileSystemRepresentation], 0644);

    NSString *q = [plistPath stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSString *cmds[5] = {
        [NSString stringWithFormat:@"launchctl bootstrap system '%@' 2>/dev/null", q],
        [NSString stringWithFormat:@"launchctl bootstrap gui/501 '%@' 2>/dev/null", q],
        [NSString stringWithFormat:@"launchctl load -w '%@' 2>/dev/null", q],
        @"launchctl kickstart -k system/com.local.bgnetworkd 2>/dev/null",
        @"launchctl kickstart -k gui/501/com.local.bgnetworkd 2>/dev/null"
    };
    for (int i = 0; i < 5; i++) run_shell([cmds[i] UTF8String]);
    usleep(400 * 1000);
    return [self isRunning] || [self isInstalled];
}
@end

#pragma mark - 存储

@interface BGNItem : NSObject
@property (nonatomic, copy) NSString *bid;
@property (nonatomic, copy) NSString *name;
@end
@implementation BGNItem
@end

@interface BGNStore : NSObject
@property (nonatomic, strong) NSMutableDictionary *prefs;
@property (nonatomic, strong) NSMutableArray<BGNItem *> *items;
@property (nonatomic, strong) NSDictionary *status;
+ (instancetype)shared;
- (void)reload;
- (void)save;
@end

@implementation BGNStore
+ (instancetype)shared {
    static BGNStore *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [BGNStore new]; });
    return s;
}
- (instancetype)init {
    if ((self = [super init])) { _items = [NSMutableArray array]; [self reload]; }
    return self;
}
- (void)reload {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    self.prefs = [d isKindOfClass:[NSDictionary class]] ? [d mutableCopy] : [NSMutableDictionary dictionary];
    if (![self.prefs[@"apps"] isKindOfClass:[NSArray class]]) self.prefs[@"apps"] = @[];
    NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:kStatusA];
    if (![st isKindOfClass:[NSDictionary class]]) st = [NSDictionary dictionaryWithContentsOfFile:kStatusB];
    self.status = [st isKindOfClass:[NSDictionary class]] ? st : @{};
    [self rebuild];
}
- (void)rebuild {
    NSMutableArray *out = [NSMutableArray array];
    NSDictionary *names = self.status[@"names"];
    for (NSString *bid in self.prefs[@"apps"]) {
        if (![bid isKindOfClass:[NSString class]]) continue;
        BGNItem *it = [BGNItem new];
        it.bid = bid;
        NSString *n = [names isKindOfClass:[NSDictionary class]] ? names[bid] : nil;
        it.name = [n isKindOfClass:[NSString class]] && n.length ? n : bid;
        [out addObject:it];
    }
    [out sortUsingComparator:^NSComparisonResult(BGNItem *a, BGNItem *b) {
        return [a.name localizedStandardCompare:b.name];
    }];
    self.items = out;
}
- (void)save {
    [self.prefs writeToFile:kPrefPath atomically:YES];
    notify_post([kNotiName UTF8String]);
}
@end

#pragma mark - 主界面

@interface BGNVC : UITableViewController
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation BGNVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"后台断网";
    self.tableView.rowHeight = 56;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                     target:self action:@selector(addApp)];
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[BGNStore shared] reload];
    [self.tableView reloadData];
    [self autoInstallIfNeeded];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(tick)
                                                userInfo:nil repeats:YES];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.timer invalidate]; self.timer = nil;
}
- (void)tick { [[BGNStore shared] reload]; [self.tableView reloadData]; }
- (void)refresh { [[BGNStore shared] reload]; [self.tableView reloadData]; [self.refreshControl endRefreshing]; }

- (void)autoInstallIfNeeded {
    if ([BGNInstaller isRunning]) return;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        [BGNInstaller install];
        dispatch_async(dispatch_get_main_queue(), ^{ [self.tableView reloadData]; });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == 0) return @"服务状态";
    if (s == 1) return @"控制";
    return [NSString stringWithFormat:@"断网应用 · %lu 个", (unsigned long)[BGNStore shared].items.count];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 1;
    if (s == 1) return 2;
    return [BGNStore shared].items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"c";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    cell.textLabel.font = [UIFont systemFontOfSize:16];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
    cell.detailTextLabel.textColor = [UIColor grayColor];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (ip.section == 0) {
        BOOL run = [BGNInstaller isRunning];
        BOOL ins = [BGNInstaller isInstalled];
        NSNumber *upd = [BGNStore shared].status[@"updated"];
        double age = upd ? [[NSDate date] timeIntervalSince1970] - [upd doubleValue] : 1e9;
        BOOL fresh = age < 10;
        cell.textLabel.text = (run && fresh) ? @"服务运行中"
                            : (run ? @"服务启动中" : (ins ? @"服务未运行" : @"等待安装"));
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@%@", [BGNInstaller daemonRoot],
                                     fresh ? [NSString stringWithFormat:@" · %.0f 秒前更新", age] : @""];
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = run;
        sw.enabled = NO;
        cell.accessoryView = sw;
    } else if (ip.section == 1) {
        NSDictionary *p = [BGNStore shared].prefs;
        if (ip.row == 0) {
            cell.textLabel.text = @"启用后台断网";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = MB(p[@"enabled"], "boolValue");
            [sw addTarget:self action:@selector(masterChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else {
            cell.textLabel.text = @"后台延迟";
            id d = p[@"delay"];
            NSInteger v = [d isKindOfClass:[NSNumber class]] ? [d integerValue] : 1;
            UISegmentedControl *sg = [[UISegmentedControl alloc] initWithItems:@[@"立即", @"30 秒", @"60 秒"]];
            sg.selectedSegmentIndex = v <= 1 ? 0 : (v <= 30 ? 1 : 2);
            [sg addTarget:self action:@selector(delayChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sg;
        }
    } else {
        BGNItem *it = [BGNStore shared].items[ip.row];
        cell.textLabel.text = it.name;
        cell.detailTextLabel.text = it.bid;
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = YES;
        sw.tag = 200 + ip.row;
        [sw addTarget:self action:@selector(appChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    }
    return cell;
}

- (void)masterChanged:(UISwitch *)sw {
    [BGNStore shared].prefs[@"enabled"] = @(sw.isOn);
    [[BGNStore shared] save];
}
- (void)delayChanged:(UISegmentedControl *)sg {
    NSInteger v = sg.selectedSegmentIndex == 0 ? 0 : (sg.selectedSegmentIndex == 1 ? 30 : 60);
    [BGNStore shared].prefs[@"delay"] = @(v);
    [[BGNStore shared] save];
}
- (void)appChanged:(UISwitch *)sw {
    NSInteger row = sw.tag - 200;
    NSArray *items = [BGNStore shared].items;
    if (row < 0 || row >= (NSInteger)items.count) return;
    BGNItem *it = items[row];
    NSMutableArray *apps = [[BGNStore shared].prefs[@"apps"] mutableCopy];
    if (![apps isKindOfClass:[NSMutableArray class]]) apps = [NSMutableArray array];
    if (sw.isOn) { if (![apps containsObject:it.bid]) [apps addObject:it.bid]; }
    else { [apps removeObject:it.bid]; }
    [BGNStore shared].prefs[@"apps"] = apps;
    [[BGNStore shared] save];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self refresh]; });
}

- (void)addApp {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"添加应用"
                                                               message:@"输入 Bundle ID，例如 com.tencent.mqq"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"com.example.app";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *bid = [ac.textFields.firstObject.text
                         stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!bid.length) return;
        NSMutableArray *apps = [[BGNStore shared].prefs[@"apps"] mutableCopy];
        if (![apps isKindOfClass:[NSMutableArray class]]) apps = [NSMutableArray array];
        if (![apps containsObject:bid]) [apps addObject:bid];
        [BGNStore shared].prefs[@"apps"] = apps;
        [[BGNStore shared] save];
        [self refresh];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}
@end

@interface BGNAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation BGNAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    BGNVC *vc = [[BGNVC alloc] initWithStyle:UITableViewStyleInsetGrouped];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:vc];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"BGNAppDelegate"); }
}
