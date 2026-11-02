# OfflineGuard for LiveContainer

**English** | [简体中文](README.zh-CN.md)

A tweak that blocks common network requests and makes common connectivity checks report offline inside a LiveContainer app. Useful for apps that enter their own offline mode only when no network is available.

**Requirements:** iOS / iPadOS 15+, arm64, and LiveContainer with TweakLoader enabled. No Theos or external Substrate installation is required.

## Download and install

Download **`OfflineGuard.dylib`** from this repository's **Releases** page, or build it locally.

1. Transfer the dylib to the Files app on your iPhone or iPad.
2. Open LiveContainer → **Tweaks** → `+` → **New Folder**, and name it `OfflineGuard`.
3. Open that folder and use **Import Tweak** to import the dylib.
4. In the target app's settings, select `OfflineGuard` as its **Tweak Folder**.
5. Ensure **Don't Inject TweakLoader / Don't Load TweakLoader** are disabled, then fully quit and relaunch the app.

The tweak activates when loaded. Putting it in the root Tweaks folder applies it to all apps that load global tweaks. LiveContainer re-signs it automatically; use **Sign** if needed.

**Update:** fully quit the app, remove the previous dylib, import the replacement, and relaunch. Load only one copy.

**Restore connectivity:** deselect the tweak folder or rename the file to `OfflineGuard.dylib.disabled`, then fully quit and relaunch the app. Removing the file while the process is running does not undo its hooks.

For shared apps with a read-only Tweak Folder setting, temporarily switch to private mode to configure it. See the [LiveContainer tweak guide](https://livecontainer.github.io/docs/guides/tweaks).

## How it works

| Area | Behavior |
| --- | --- |
| URLSession | Cancels tasks before resuming them, including common HTTP(S), upload, download, background and WebSocket tasks. Ordinary tasks usually receive `NSURLErrorCancelled`; WebSocket operations receive an asynchronous offline error. |
| URL Loading / NSURLConnection | Uses NSURLProtocol to return `NSURLErrorNotConnectedToInternet`. |
| BSD sockets / DNS | Blocks intercepted IPv4 / IPv6 socket creation, connection and sending with `ENETDOWN`, including TCP, UDP, LAN and loopback. IP address resolution through `getaddrinfo` returns `EAI_AGAIN`. |
| Network.framework | Cancels intercepted connection, connection-group and listener starts. |
| Reachability | Returns zero reachability flags and translates newly registered callbacks to offline while preserving their context lifecycle and delivery mechanism. |
| NWPath / Swift NWPathMonitor | Reports an unsatisfied path without DNS, IPv4, IPv6 or usable interfaces. Includes Swift-ABI-compatible accessor hooks. |
| Wi-Fi / cellular information | Hides `CNCopyCurrentNetworkInfo` results and selected `CTTelephonyNetworkInfo` radio-technology / data-service queries. |
| WKWebView | Strictly blocks content loading, history navigation and JavaScript execution entry points. **Local HTML is also blocked; web-based interfaces may appear blank.** |
| Local files / IPC | Preserves ordinary file access, pipes and UNIX sockets. |

This simulates offline status inside the process; it does not enable the device's airplane mode or turn off its actual radios. The system status bar and other processes retain their real network state.

## Build locally

Requires macOS, full Xcode with the iPhoneOS SDK, and Python 3.

```sh
# Read and accept the Xcode license on first use.
sudo xcodebuild -license accept
make
```

Output: **`build/OfflineGuard.dylib`**, ad-hoc signed for LiveContainer to re-sign. Local builds use the version `dev` by default.

```sh
make VERSION=1.0.0
make DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer
```

The version is embedded in the startup log. Changing `VERSION` automatically rebuilds the affected objects.

## Automated builds and releases

The [Build and Release workflow](.github/workflows/build-release.yml) runs tests and builds the iOS dylib on pushes to `main`, pull requests targeting `main`, manual runs, and version-tag pushes.

To publish a release, push a tag in **`vMAJOR.MINOR.PATCH`** format after pushing the project to GitHub:

```sh
git tag -a v1.0.0 -m "Release 1.0.0"
git push origin v1.0.0
```

For a tag push, the workflow automatically:

1. Derives the build version from the tag and runs the macOS tests.
2. Compiles and verifies the arm64 iOS dylib.
3. Creates a GitHub Release named `OfflineGuard v1.0.0` with generated release notes.
4. Uploads `OfflineGuard.dylib`, `VERSION.txt`, `SHA256SUMS.txt`, and `THIRD_PARTY_NOTICES.md`.

The asset name stays `OfflineGuard.dylib`; the Release tag, `VERSION.txt`, and embedded startup log identify its version. Re-running a tag build updates assets in an existing release. Branch, pull-request and manual builds produce downloadable Actions artifacts without publishing a release.

The workflow uses the repository's built-in `GITHUB_TOKEN` with `contents: write` only for publishing. No personal access token or Apple signing certificate is required. GitHub Actions must be enabled for the repository.

## Testing and troubleshooting

```sh
make test
# Use full Xcode instead of the default Command Line Tools for tests:
make test TEST_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Tests cover a real loopback HTTP baseline, blocked requests, cold startup, late-loaded libraries, local files / IPC, C and Swift network-state queries, and Reachability callback translation and lifetime. Callback changes are also tested with a controlled event source because the system does not guarantee an initial Reachability event.

Search device logs for **`[OfflineGuard`** to confirm loading and inspect the build version. Hook-registration success does not guarantee that every system symbol was writable. Wi-Fi / CoreTelephony hooks still require device-specific verification; macOS tests do not replace testing the target iOS app.

## Compatibility and scope

OfflineGuard is a process-level tweak, not a kernel firewall. Coverage is not guaranteed for other-process services, already-submitted background transfers, direct syscalls, cached or `dlsym`-resolved function pointers, protected shared-cache calls, private APIs, custom overrides, or hooks replaced by other tweaks. Requests made before loading are not undone.

Apps may also inspect actual airplane-mode state, other Wi-Fi / cellular APIs, interface information such as `getifaddrs`, or error codes that differ from cancellation. Entering an app's offline mode depends on its implementation. Strict WebView blocking may prevent a local HTML interface from working.

Hooks affect the whole host process, including other tweaks and host code in that process. Use an app-specific tweak folder to control where the library loads.

## Source and third-party notices

- `Sources/`: request blocking, connectivity-state hooks and Swift accessors.
- `Tests/`: macOS integration and callback tests.
- `Vendor/fishhook/`: pinned BSD-3-Clause symbol rebinder.
- `scripts/`: build-version generation.
- `.github/workflows/`: automated build and release publishing.

Include [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) when redistributing the dylib.
