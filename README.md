# BGNetwork — 后台断网 (iOS 15.5 ~ 17.x)

Per-app background network blocking for jailbroken iOS. Works on iPhone 15 Pro Max / iOS 17.3.1 / Dopamine rootless (hidden root).

## 架构

```
/var/jb/usr/libexec/bgnetworkd      纯 C 看门狗（只依赖 libSystem）
   ├─ 每 1.5 秒刷新 status.json 的 updated 字段
   ├─ posix_spawn 拉起引擎，死了立刻重启
   └─ 引擎 12 秒不更新状态就 SIGKILL 重启

/var/jb/usr/libexec/bgnetworkengine  原版 1.2.2 守护进程（NEPolicySession 策略引擎）
```

看门狗与引擎分离后，引擎崩溃不再导致界面"掉服务"。

## 源文件

| 文件 | 说明 |
|---|---|
| `src/watchdog.c` | 纯 C 看门狗（状态续命 + 引擎重启 + 多路径写入） |
| `src/engine.m` | ObjC 引擎（NEPolicySession 单会话 + 差分下发 + 300s 缓存） |
| `src/TipaApp.m` | TIPA 版 App（首次启动自安装守护进程 + 开关列表） |
| `build_wd.sh` | 编译看门狗（纯 C，只链接 libSystem） |
| `build_engine.sh` | 编译引擎（链接 Foundation/NetworkExtension/BackBoardServices 等） |

## 编译

需要 Alpine Linux + clang 19 + ld64.lld + compiler-rt + iOS SDK。

```sh
apk add clang lld compiler-rt
# SDK 放到 /opt/ios-sdks/iPhoneOS16.5.sdk

./build_wd.sh      # → bgnetworkd-wd2 (看门狗)
./build_engine.sh  # → bgnetworkengine (引擎)
```

## 安装

### deb 版（推荐）

```
com.local.bgnetwork_1.2.2-2.2.0_iphoneos-arm64.deb
```

### TIPA 版（TrollStore）

```
BGNetwork.tipa
```

App 首次启动会自动把守护进程写入 `/var/jb/usr/libexec/` 并尝试 launchctl 加载。

## 配置

```
/var/mobile/Library/Preferences/com.local.bgnetwork.plist
{
  enabled = true;
  apps = ("com.tencent.mqq", ...);
  delay = 1;  // 秒
}
```

## 状态

```
/var/jb/var/lib/BGNetwork/status.json
/var/jb/var/lib/BGNetwork/heartbeat.json
/var/mobile/Library/Preferences/com.local.bgnetwork.daemon.log
```

## 诊断

```sh
bgnetworkd --diag      # 查看状态文件 age/size
bgnetworkd --selftest  # 验证私有类可见性 + session 创建
```
