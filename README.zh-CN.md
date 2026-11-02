# OfflineGuard for LiveContainer

[English](README.md) | **简体中文**

一个用于 LiveContainer 的 tweak：阻止常见网络请求，并让常见联网检测接口报告离线，帮助只在无网络时才进入离线模式的 App 使用自身的离线功能。

**运行要求：**iOS / iPadOS 15+、arm64、启用 TweakLoader 的 LiveContainer。无需 Theos 或额外安装 Substrate。

## 下载与安装

从本仓库的 **Releases** 页面下载 **`OfflineGuard.dylib`**，或自行编译。

1. 将 dylib 传到 iPhone / iPad 的「文件」App。
2. 打开 LiveContainer → **Tweaks / 插件** → `+` → **新建文件夹**，命名为 `OfflineGuard`。
3. 进入文件夹，通过 **Import Tweak / 导入插件** 导入 dylib。
4. 在目标 App 设置中，将 **Tweak Folder / 插件文件夹** 设为 `OfflineGuard`。
5. 确保 **Don't Inject TweakLoader / Don't Load TweakLoader** 未开启，然后完全退出并重新启动 App。

插件加载后立即生效。放在 Tweaks 根目录会作用于所有加载全局插件的 App。LiveContainer 会自动重新签名，必要时可点击 **Sign**。

**更新插件：**完全退出 App，删除原 dylib，导入替换文件，再重新启动。只加载一份插件。

**恢复联网：**取消插件文件夹选择，或将文件改名为 `OfflineGuard.dylib.disabled`，然后完全退出并重新启动 App。运行中移除文件不会撤销已安装的 Hook。

共享 App 的插件文件夹若不可修改，可暂时转为私有模式进行配置。详见 [LiveContainer 官方插件指南](https://livecontainer.github.io/docs/guides/tweaks)。

## 工作原理

| 范围 | 行为 |
| --- | --- |
| URLSession | 在任务恢复前先取消，涵盖常见 HTTP(S)、上传、下载、后台及 WebSocket 任务。普通任务通常收到 `NSURLErrorCancelled`；WebSocket 操作异步收到断网错误。 |
| URL Loading / NSURLConnection | 使用 NSURLProtocol 返回 `NSURLErrorNotConnectedToInternet`。 |
| BSD sockets / DNS | 拒绝经过拦截入口的 IPv4 / IPv6 socket 创建、连接及发送，返回 `ENETDOWN`，包含 TCP、UDP、局域网和回环地址。通过 `getaddrinfo` 进行的 IP 地址解析返回 `EAI_AGAIN`。 |
| Network.framework | 将经过拦截入口的连接、连接组和监听器启动转换为取消。 |
| Reachability | 返回零可达性标志，并将新注册回调的状态转换为离线，保留上下文生命周期及回调机制。 |
| NWPath / Swift NWPathMonitor | 报告无可用网络路径、DNS、IPv4、IPv6 或接口，包含匹配 Swift ABI 的访问器 Hook。 |
| Wi-Fi / 蜂窝信息 | 隐藏 `CNCopyCurrentNetworkInfo` 结果及部分 `CTTelephonyNetworkInfo` 无线接入技术、数据服务查询结果。 |
| WKWebView | 严格阻止内容加载、历史导航和 JavaScript 执行入口。**本地 HTML 也被阻止，网页型界面可能显示空白。** |
| 本地文件 / IPC | 保留普通文件访问、管道和 UNIX sockets。 |

插件在进程内模拟离线状态，不会真正打开设备的飞行模式或关闭无线网络。系统状态栏和其他进程仍保持真实网络状态。

## 本地编译

需要 macOS、包含 iPhoneOS SDK 的完整 Xcode，以及 Python 3。

```sh
# Read and accept the Xcode license on first use.
sudo xcodebuild -license accept
make
```

产物为 **`build/OfflineGuard.dylib`**，构建时进行 ad-hoc 签名，导入后由 LiveContainer 重新签名。本地构建的默认版本为 `dev`。

```sh
make VERSION=1.0.0
make DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer
```

版本号会写入启动日志。修改 `VERSION` 后，构建系统会自动重新编译受影响的对象文件。

## 自动构建与发布

[Build and Release 工作流](.github/workflows/build-release.yml) 在推送到 `main`、向 `main` 提交 Pull Request、手动运行，以及推送版本标签时执行测试并构建 iOS dylib。

将项目推送到 GitHub 后，推送 **`v主版本.次版本.修订版本`** 格式的标签即可发布：

```sh
git tag -a v1.0.0 -m "Release 1.0.0"
git push origin v1.0.0
```

版本标签推送会自动触发以下流程：

1. 从标签提取构建版本号，运行 macOS 测试。
2. 编译 arm64 iOS dylib，校验架构和签名。
3. 创建名为 `OfflineGuard v1.0.0` 的 GitHub Release，自动生成发布说明。
4. 上传 `OfflineGuard.dylib`、`VERSION.txt`、`SHA256SUMS.txt` 和 `THIRD_PARTY_NOTICES.md`。

附件始终命名为 `OfflineGuard.dylib`；Release 标签、`VERSION.txt` 和内嵌启动日志标识其版本。重新运行标签构建会更新已有 Release 的附件。普通分支、Pull Request 和手动构建只提供可下载的 Actions 构建产物，不发布 Release。

工作流使用仓库内置的 `GITHUB_TOKEN`，仅发布任务具有 `contents: write` 权限。无需个人访问令牌或 Apple 签名证书。仓库需启用 GitHub Actions。

## 测试与排查

```sh
make test
# Use full Xcode instead of the default Command Line Tools for tests:
make test TEST_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

测试覆盖真实回环 HTTP 基线、请求拦截、冷启动、后加载动态库、本地文件 / IPC、C 与 Swift 网络状态查询，以及 Reachability 回调转换和生命周期。系统不保证发送初始 Reachability 事件，因此也使用可控事件源验证回调变化。

在设备日志中搜索 **`[OfflineGuard`**，可确认插件是否加载及其构建版本。Hook 注册成功不代表每个系统符号都可修改。Wi-Fi / CoreTelephony Hook 仍需在具体设备验证；macOS 测试不能代替目标 iOS App 的真机测试。

## 兼容性与作用范围

OfflineGuard 是进程级 tweak，并非内核防火墙。其他进程代发请求、已提交的后台传输、直接系统调用、已缓存或通过 `dlsym` 获取的函数指针、受保护的共享缓存调用、私有 API、自定义覆盖及其他插件再次修改的 Hook，均不保证完整覆盖。加载前已发生的请求无法撤销。

App 也可能检测真实飞行模式、其他 Wi-Fi / 蜂窝 API、`getifaddrs` 等接口信息，或区分断网与取消错误。能否进入自身离线模式取决于 App 的实现。严格 WebView 拦截可能影响本地 HTML 界面运行。

Hook 作用于整个宿主进程，包括同进程的其他插件与宿主代码。请通过 App 专属插件文件夹控制加载范围。

## 源码与第三方声明

- `Sources/`：请求拦截、网络状态 Hook 和 Swift 访问器。
- `Tests/`：macOS 集成测试和回调测试。
- `Vendor/fishhook/`：固定版本的 BSD-3-Clause 符号重绑定库。
- `scripts/`：构建版本号生成。
- `.github/workflows/`：自动构建与 Release 发布。

分发 dylib 时请一并提供 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
