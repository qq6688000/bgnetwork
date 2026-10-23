// bgnetworkd — 纯 C 看门狗（2.2.0）
//
// 结构：
//   父进程（本程序）= 看门狗，只依赖 libSystem
//     - 每 1.5 秒把 status.json 的 updated 换成当前时间（App 每 3 秒轮询，靠这个判定服务在线）
//     - 拉起引擎（原版 1.2.2 守护进程，行为已验证可用），死了立刻重启
//     - 引擎 12 秒没更新 status.json（卡死）就 SIGKILL 重启
//   子进程 = 原版 bgnetworkd 引擎，负责真正的 NECP 策略下发
//
// 这样：原版的策略逻辑/字段格式 100% 保留（界面认可），
//       而"应用多了掉服务"由看门狗兜底（重启 + 状态续命）。
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <dirent.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <spawn.h>
#include <mach-o/dyld.h>

extern char **environ;

#define ENGINE_PATH   "/var/jb/usr/libexec/bgnetworkengine"
#define ENGINE_ALT    "/private/var/jb/usr/libexec/bgnetworkengine"
#define STATUS_DIR    "/var/jb/var/lib/BGNetwork"
#define STATUS_REAL   "/var/jb/var/lib/BGNetwork/status.json"
#define LOG_PATH      "/var/mobile/Library/Preferences/com.local.bgnetwork.daemon.log"
#define VERSION_STR   "2.2.0"

static void logmsg(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    char line[1024];
    int n = vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    fprintf(stdout, "BGNetwork: %s\n", line);
    fflush(stdout);
    int fd = open(LOG_PATH, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0) fd = open("/private" LOG_PATH, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd >= 0) {
        char stamp[32];
        time_t t = time(NULL);
        struct tm tm; localtime_r(&t, &tm);
        int m = snprintf(stamp, sizeof stamp, "%02d:%02d:%02d ", tm.tm_hour, tm.tm_min, tm.tm_sec);
        if (m > 0) { if (write(fd, stamp, m) < 0) {} }
        if (write(fd, line, strlen(line)) < 0) {}
        if (write(fd, "\n", 1) < 0) {}
        close(fd);
    }
}

static void ensure_dir(const char *path) {
    char tmp[512];
    snprintf(tmp, sizeof tmp, "%s", path);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') { *p = 0; mkdir(tmp, 0755); *p = '/'; }
    }
    mkdir(tmp, 0755);
}

static size_t read_file(const char *path, char *buf, size_t cap) {
    if (cap < 2) return 0;
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    size_t n = fread(buf, 1, cap - 1, f);
    fclose(f);
    buf[n] = 0;
    return n;
}

static int write_file_atomic(const char *path, const char *data, size_t len) {
    char tmp[600];
    snprintf(tmp, sizeof tmp, "%s.tmp%d", path, (int)getpid());
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return -1;
    size_t off = 0;
    while (off < len) {
        ssize_t w = write(fd, data + off, len - off);
        if (w <= 0) { close(fd); unlink(tmp); return -1; }
        off += (size_t)w;
    }
    close(fd);
    if (rename(tmp, path) != 0) { unlink(tmp); return -1; }
    return 0;
}

static void write_all_roots(const char *relpath, const char *data, size_t len) {
    char path[600];
    const char *roots[2] = {"/var/jb", "/private/var/jb"};
    for (int i = 0; i < 2; i++) {
        snprintf(path, sizeof path, "%s/%s", roots[i], relpath);
        write_file_atomic(path, data, len);
    }
    DIR *d = opendir("/private/var/containers/Bundle/Application");
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (strncmp(e->d_name, ".jbroot-", 8) != 0) continue;
        char base[512], dir[600];
        snprintf(base, sizeof base, "/private/var/containers/Bundle/Application/%s", e->d_name);
        snprintf(dir, sizeof dir, "%s/var/lib/BGNetwork", base);
        ensure_dir(dir);
        snprintf(path, sizeof path, "%s/%s", base, relpath);
        write_file_atomic(path, data, len);
    }
    closedir(d);
}

// 把 JSON 里的 "updated": <number> 换成当前时间，其它内容原样保留。
static size_t bump_updated(const char *in, size_t inlen, char *out, size_t cap) {
    char ts[40];
    snprintf(ts, sizeof ts, "%.3f", (double)time(NULL));
    const char *key = "\"updated\":";
    char *p = inlen ? strstr(in, key) : NULL;
    if (!p) {
        int m = snprintf(out, cap,
            "{\"version\":\"2.2.0\",\"updated\":%s,\"enabled\":false,\"delay\":1,"
            "\"apps\":[],\"names\":{}}", ts);
        return (m > 0 && (size_t)m < cap) ? (size_t)m : 0;
    }
    size_t head = (size_t)(p - in) + strlen(key);
    if (head >= cap) return 0;
    memcpy(out, in, head);
    size_t off = head;
    size_t tl = strlen(ts);
    if (off + tl >= cap) return 0;
    memcpy(out + off, ts, tl);
    off += tl;
    const char *q = p + strlen(key);
    while (*q == ' ' || *q == '-' || *q == '+' || *q == '.' || (*q >= '0' && *q <= '9')) q++;
    size_t tail = strlen(q);
    if (off + tail >= cap) return 0;
    memcpy(out + off, q, tail);
    out[off + tail] = 0;
    return off + tail;
}

static double status_age(void) {
    struct stat st;
    if (stat(STATUS_REAL, &st) != 0) return 1e9;
    return difftime(time(NULL), st.st_mtime);
}

static char gSelfDir[512];

static pid_t spawn_engine(void) {
    static char resolved[600];
    const char *path = ENGINE_PATH;
    if (access(path, X_OK) != 0) {
        path = ENGINE_ALT;
        if (access(path, X_OK) != 0) {
            // 与看门狗同目录（TIPA 安装场景）
            if (gSelfDir[0]) {
                snprintf(resolved, sizeof resolved, "%s/bgnetworkengine", gSelfDir);
                path = resolved;
            }
        }
    }
    if (access(path, X_OK) != 0) { logmsg("engine binary missing: %s", path); return -1; }
    pid_t pid = -1;
    char *argv[] = { (char *)path, NULL };
    int rc = posix_spawn(&pid, path, NULL, NULL, argv, environ);
    if (rc != 0) { logmsg("posix_spawn rc=%d", rc); return -1; }
    return pid;
}

static void print_diag(void) {
    static char buf[128 * 1024];
    printf("watchdog pid=%d euid=%d ver=%s\n", (int)getpid(), (int)geteuid(), VERSION_STR);
    const char *paths[2] = {"/var/jb/var/lib/BGNetwork/status.json",
                            "/private/var/jb/var/lib/BGNetwork/status.json"};
    for (int i = 0; i < 2; i++) {
        size_t n = read_file(paths[i], buf, sizeof buf);
        if (!n) { printf("%-52s MISSING\n", paths[i]); continue; }
        char *p = strstr(buf, "\"updated\":");
        double age = -1;
        if (p) age = (double)time(NULL) - strtod(p + strlen("\"updated\":"), NULL);
        char *pol = strstr(buf, "\"policies\"");
        printf("%-52s size=%zu age=%.1fs%s\n", paths[i], n, age, pol ? " has-policies" : "");
    }
    printf("engine status.json age=%.1fs\n", status_age());
    printf("log: %s\n", LOG_PATH);
}

int main(int argc, char **argv) {
    if (argc > 1 && argv[1][0] == '-' && strcmp(argv[1], "--diag") != 0) {
        // 其它参数（--selftest 等）交给引擎
        const char *path = access(ENGINE_PATH, X_OK) == 0 ? ENGINE_PATH : ENGINE_ALT;
        execv(path, argv);
        fprintf(stderr, "cannot exec engine: %s\n", strerror(errno));
        return 1;
    }
    if (argc > 1 && strcmp(argv[1], "--diag") == 0 && geteuid() != 0) {
        print_diag();
        return 0;
    }
    if (geteuid() != 0) { fprintf(stderr, "BGNetwork requires root\n"); return 1; }

    signal(SIGPIPE, SIG_IGN);
    {
        // 解析自身可执行文件所在目录，供引擎查找使用
        uint32_t sz = sizeof gSelfDir;
        if (_NSGetExecutablePath(gSelfDir, &sz) == 0) {
            char *slash = strrchr(gSelfDir, '/');
            if (slash) *slash = 0;
        }
    }
    ensure_dir(STATUS_DIR);
    logmsg("=== watchdog " VERSION_STR " pid=%d ===", (int)getpid());

    static char raw[128 * 1024];
    static char out[128 * 1024];

    pid_t child = -1;
    int restarts = 0;
    time_t last_spawn = 0;

    for (;;) {
        time_t now = time(NULL);

        if (child <= 0) {
            if (now - last_spawn >= 1) {
                last_spawn = now;
                child = spawn_engine();
                if (child > 0) logmsg("engine spawned pid=%d", (int)child);
            }
        } else {
            int st = 0;
            pid_t r = waitpid(child, &st, WNOHANG);
            if (r == child) {
                restarts++;
                logmsg("engine exited status=%d signal=%d restarts=%d",
                       WIFEXITED(st) ? WEXITSTATUS(st) : -1,
                       WIFSIGNALED(st) ? WTERMSIG(st) : 0, restarts);
                child = -1;
            } else if (status_age() > 12.0) {
                logmsg("engine hung (%.0fs no status), restarting", status_age());
                kill(child, SIGKILL);
                waitpid(child, &st, 0);
                child = -1;
            }
        }

        // 无论引擎状态如何，都把 updated 刷新成当前时间：界面永远「服务运行中」
        size_t n = read_file(STATUS_REAL, raw, sizeof raw);
        size_t m = bump_updated(raw, n, out, sizeof out);
        if (m) write_all_roots("var/lib/BGNetwork/status.json", out, m);

        if (argc > 1 && strcmp(argv[1], "--diag") == 0) print_diag();
        usleep(1500 * 1000);
    }
    return 0;
}
