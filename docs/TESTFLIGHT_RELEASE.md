# MasterCamera TestFlight 发布指南

## 当前目标

在没有本地 Mac 的情况下，用 GitHub Actions 完成：

```text
云端归档
云端签名
上传 App Store Connect
TestFlight 安装到 iPhone
```

## 当前 Bundle ID

项目当前使用：

```text
com.sulinandeyu.mastercamera
```

Apple Developer、App Store Connect、Provisioning Profile 和 Xcode 工程里的 Bundle ID 必须完全一致。

## Apple 侧需要准备

### 1. 创建 App ID

进入 Apple Developer：

```text
Certificates, Identifiers & Profiles -> Identifiers
```

创建 App ID：

```text
com.sulinandeyu.mastercamera
```

### 2. 创建 App Store Connect App

进入 App Store Connect：

```text
My Apps -> New App
```

Bundle ID 选择：

```text
com.sulinandeyu.mastercamera
```

App 名称可以先用：

```text
MasterCamera
```

### 3. 创建 App Store Connect API Key

进入 App Store Connect：

```text
Users and Access -> Integrations -> App Store Connect API
```

创建 API Key 后，记录：

```text
Key ID
Issuer ID
AuthKey_XXXXXX.p8 文件
```

`.p8` 文件只能下载一次，保存好。

### 4. 创建 iOS Distribution 证书

进入 Apple Developer：

```text
Certificates, Identifiers & Profiles -> Certificates
```

创建：

```text
Apple Distribution
```

导出成 `.p12` 文件，并设置密码。

如果你没有 Mac，证书创建这一步可以后续用云 Mac 完成；GitHub Actions 只能使用已经准备好的 `.p12`。

### 5. 创建 App Store Provisioning Profile

进入 Apple Developer：

```text
Certificates, Identifiers & Profiles -> Profiles
```

创建：

```text
App Store
```

选择：

```text
App ID: com.sulinandeyu.mastercamera
Certificate: 上一步的 Apple Distribution 证书
```

下载 `.mobileprovision` 文件。

## GitHub Secrets

进入 GitHub 仓库：

```text
Settings -> Secrets and variables -> Actions -> New repository secret
```

添加以下 secrets：

```text
APPLE_TEAM_ID
APP_STORE_CONNECT_API_KEY_ID
APP_STORE_CONNECT_API_ISSUER_ID
APP_STORE_CONNECT_API_KEY_BASE64
IOS_DISTRIBUTION_CERTIFICATE_BASE64
IOS_DISTRIBUTION_CERTIFICATE_PASSWORD
IOS_APPSTORE_PROFILE_BASE64
```

## Windows 上生成 Base64

### .p8 API Key

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\to\AuthKey_XXXXXX.p8")) | Set-Clipboard
```

粘贴到：

```text
APP_STORE_CONNECT_API_KEY_BASE64
```

### .p12 证书

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\to\distribution.p12")) | Set-Clipboard
```

粘贴到：

```text
IOS_DISTRIBUTION_CERTIFICATE_BASE64
```

证书密码填到：

```text
IOS_DISTRIBUTION_CERTIFICATE_PASSWORD
```

### .mobileprovision

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\to\MasterCamera_AppStore.mobileprovision")) | Set-Clipboard
```

粘贴到：

```text
IOS_APPSTORE_PROFILE_BASE64
```

## 运行发布 workflow

进入 GitHub：

```text
Actions -> TestFlight Release -> Run workflow
```

成功后，App 会上传到 App Store Connect。

随后进入：

```text
App Store Connect -> My Apps -> MasterCamera -> TestFlight
```

等待 Apple 处理构建，然后把你的 Apple ID 加为测试者。

## 注意

第一次 TestFlight 通常最容易卡在：

- Bundle ID 不一致。
- 证书不是 Apple Distribution。
- Provisioning Profile 不是 App Store 类型。
- GitHub Secrets 复制时漏字符。
- App Store Connect App 还没创建。
- 版本号或 build number 重复。

