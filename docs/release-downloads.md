
## Downloads

| | Desktop app | Command line release |
|---|---|---|
| Linux x64 | `EObserver-*-linux-x86_64.AppImage`, `EObserver-*-linux-x64.tar.gz` | `eobserver-cli-*-linux-x64.tar.gz` |
| macOS (Apple silicon) | `EObserver-*-mac-arm64.dmg` | `eobserver-cli-*-macos-arm64.tar.gz` |
| Windows x64 | `EObserver-*-win-x64.exe` (installer), `EObserver-*-win-x64.zip` | `eobserver-cli-*-windows-x64.zip` |

Both bundle the Erlang runtime; nothing else needs to be installed. The command line release starts with `bin/eobs` (`bin\eobs.cmd` on Windows) and opens your browser.

The apps are not signed yet. On macOS, run `xattr -cr /Applications/EObserver.app` after copying the app if macOS says it is damaged. On Windows, choose "More info" and "Run anyway" in SmartScreen. The Linux builds need OpenSSL 3 (`libssl3`), which current distributions ship.

`SHA256SUMS.txt` lists the checksums of every file.
