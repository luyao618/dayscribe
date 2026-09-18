# 发布预编译应用

用户下载 DMG 后将 Scriber 拖进「应用程序」即可安装，也可选择 ZIP。当前支持 Apple Silicon、macOS 26+；应用本身不需要 Xcode、Python 或 FFmpeg。

## 构建发布包

维护者需要 Apple Silicon Mac、Xcode 26+、Git 和 `rg`。先退出 Scriber，并提交应用源码变更，然后运行：

```sh
./scripts/package-release.sh
```

版本取自 `App/Info.plist`。脚本从当前提交导出 `App`、`Sources`、`Tests`、`Package.swift` 和构建脚本，在临时目录编译 Release；不覆盖本机 `build/Scriber.app`。SwiftPM 在构建时也需要解析测试目标的目录。未提交的源码或构建改动会被拒绝，文档改动不影响导出的代码。临时目录自动清理。

输出位于 `build/releases/<版本>/`：

- `Scriber-<版本>-macOS-arm64.dmg`：应用、Applications 快捷入口、中英文安装提示。
- `Scriber-<版本>-macOS-arm64.zip`：只包含 `Scriber.app`。
- `SHA256SUMS`：上述文件与 `BUILD.txt` 的 SHA256。
- `BUILD.txt`：源码提交、架构、最低系统、签名、公证状态及 Xcode 版本。

输出目录存在时会拒绝覆盖。可通过唯一参数指定另一个新目录，例如 `./scripts/package-release.sh build/releases/0.1.0-review`。

## 签名与首次打开

当前预览包采用 **ad-hoc 签名，尚未 Apple 公证**。脚本明确使用这一方式，不自动使用开发者电脑中的 Apple Development 证书。有效的代码签名校验不代表通过 Gatekeeper 或 Apple 公证。

从网络下载后，macOS 可能阻止首次打开。对于来自本仓库且用户信任的文件，可先尝试打开，再在「系统设置 → 隐私与安全性」选择 Scriber 的「仍要打开」。不要要求用户关闭 Gatekeeper 或移除全局安全检查。发布说明必须标明这个额外步骤。

要实现正常通过 Gatekeeper 的分发，需要项目所有者提供用于该产品的 Developer ID Application 签名身份，再接入 hardened runtime、Apple notarization 和 stapling；这些不包含在当前预览打包脚本中。不要上传私钥或凭据。

## 发布前检查

1. 按小 PR 流程检查、自审并合并源码，从干净的最新 `main` 构建。
2. 解压 ZIP、只读挂载 DMG，核对应用结构、`/Applications` 链接、签名、架构和版本；对解出的应用做独立进程启动／语言检查，确认资源来自包内。
3. 校验 `SHA256SUMS`，确认只包含应用及公开发布元数据，没有录制、测试素材、开发签名身份或本地个人路径。
4. 对构建来源提交创建签名版本标签。建立 GitHub Release 草稿，上传四个文件和中英文说明，检查后发布为预览版。已发布的版本不覆盖；有改动时提升版本并重新发布。
5. 下载远端资产复核哈希，并同步两份 README 的下载入口。保留本地详细证据，长测与硬件验收继续以原有验收记录为准。

`package-release.sh` 只构建本地文件，不创建标签、上传或发布 Release。

## 首次打包验证（2026-09-18）

已实际从隔离源码编译并生成 DMG／ZIP。ZIP 解压、DMG 只读挂载与复制出的应用文件逐项一致，arm64／最低系统／ad-hoc 签名及校验和通过。两种安装来源各完成英、中、未支持语言回退的独立进程启动检查，资源均来自包内；本机开发应用与个人历史未变。重复使用输出目录被拒绝，已有包哈希不变。证据保留在本地 `artifacts/releases/package-check-p_k99sqk/verified.json`。

Gatekeeper 评估明确拒绝该未公证预览，符合当前发布限制；未实际执行用户首次打开的「仍要打开」流程，也没有修改任何系统安全设置。此次验证不代表换签名后的真实录制权限、完整交互或硬件验收通过。
