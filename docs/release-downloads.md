## 下载

| | 桌面版 | 命令行版 |
|---|---|---|
| Linux x64 | `EObserver-*-linux-x86_64.AppImage`、`EObserver-*-linux-x64.tar.gz` | `eobserver-cli-*-linux-x64.tar.gz` |
| macOS（Apple 芯片） | `EObserver-*-mac-arm64.dmg` | `eobserver-cli-*-macos-arm64.tar.gz` |
| Windows x64 | `EObserver-*-win-x64.exe`（安装包）、`EObserver-*-win-x64.zip` | `eobserver-cli-*-windows-x64.zip` |

两种版本都自带 Erlang 运行时，不需要另外安装任何东西。命令行版用 `bin/eobs`（Windows 上是 `bin\eobs.cmd`）启动，会自动打开浏览器。

应用暂未签名。macOS 上如果提示「已损坏」，把应用拷到「应用程序」后执行 `xattr -cr /Applications/EObserver.app`。Windows 上如果 SmartScreen 拦截，点「更多信息」再点「仍要运行」。Linux 版需要 OpenSSL 3（`libssl3`），目前主流发行版都自带。

Windows 安装包和 Linux AppImage 可以在应用左下角一键更新，其余版本会打开下载页。`latest*.yml` 和 `*.blockmap` 是给自动更新用的，不需要下载。

`SHA256SUMS.txt` 里是所有文件的校验和。
