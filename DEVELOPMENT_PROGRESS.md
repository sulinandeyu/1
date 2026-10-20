# MasterCamera 开发进度

更新时间：2026-10-20

## 当前阶段

MasterCamera 已完成 Phase 1–13 的 MVP 主链路原型，包括相机拍摄、本地照片分析、摄影决策、Core Image 自动成片、人脸局部补光、质量检查、安全回退、预览对比、相册保存状态和诊断面板。

Phase 14 TestFlight 发布链路已完成。Apple Distribution 证书、App Store Provisioning Profile、App Store Connect API Key 和 7 个 GitHub Secrets 已完成配置；`TestFlight Release #4` 已成功完成真实签名归档、IPA 导出并上传到 App Store Connect。当前等待 Apple Processing，随后进入内部 TestFlight 真机验证。Phase 15 高级光照尚未开始。

## 本轮完成

### TestFlight 真实签名接入

- 已注册显式 App ID `com.sulinandeyu.mastercamera` 并创建对应的 App Store Connect App 记录。
- 已创建 Apple Distribution 证书与 `MasterCamera AppStore` Provisioning Profile；本地验证 Team ID、Bundle ID、证书公钥和有效期全部匹配。
- 已创建 Developer 权限的 App Store Connect Team API Key，并验证 `.p8` 私钥格式。
- GitHub 仓库已配置 workflow 所需的 7 个 Repository Secrets。
- `TestFlight Release #2` 已通过 Secrets、P12、API Key 和 Provisioning Profile 安装及一致性检查。
- 首次 Archive 暴露工程自动签名默认选择 `iOS Development`；发布 workflow 现已明确覆盖 `CODE_SIGN_IDENTITY=Apple Distribution`。
- `TestFlight Release #3` 已成功使用 Apple Distribution 证书和 App Store Profile 完成编译签名，但 Archive 校验发现自定义 `Info.plist` 缺少标准 Bundle 元数据。
- `Info.plist` 已补齐 Bundle Identifier、可执行文件、版本、包类型、启动配置和 iPhone/iPad 支持方向，以满足归档与后续 App Store 校验。
- `TestFlight Release #4` 已成功完成 Archive、Export IPA 和 App Store Connect 上传，build number 为 `4`。

### TestFlight 签名材料预检

- 发布前检查 7 个必需 GitHub Secrets 是否存在，但不输出任何 Secret 内容。
- Provisioning Profile 解码后检查 Bundle ID 和 Team Identifier 是否与发布配置一致。
- 发布日志会显示 Profile 名称和过期时间，便于定位失效材料。
- `.p12` 导入过程继续作为证书内容和密码的实际校验。

### TestFlight 自动 build number

- `TestFlight Release` 默认使用 GitHub Actions `run_number` 覆盖归档的 `CURRENT_PROJECT_VERSION`。
- workflow 支持可选的纯数字 build number 手动覆盖，以兼容 App Store Connect 中已经存在的更大编号。
- 发布开始前会验证 build number，并在日志中输出 Bundle ID 和最终编号。
- 发布文档已补充自动编号、手动覆盖和重新运行规则。

### AppIcon 与资源目录

- 新增 `Assets.xcassets`，并将其加入 MasterCamera target 的 Resources Build Phase。
- 新增 Xcode 16 通用 iOS AppIcon set，提供不透明的 1024 × 1024 App Store 主图。
- Debug 和 Release 配置均指定 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`。
- 图标采用无文字的镜头光圈与冷暖光线视觉，避免系统裁切前预制圆角。

### 照片处理错误传播

- `PhotoProcessingPipeline.process` 改为抛出分析、初次渲染和初次质量检查错误，不再静默返回原始照片。
- `CameraViewModel` 捕获处理错误、结束处理状态并向相机页显示中文错误信息。
- 处理失败时不再进入预览页，也不会把未经处理的原图标记为“AI 成片”。
- 如果初版成片已经生成，但安全回退渲染失败，保留带质量诊断的初版成片，而不是丢弃整个处理结果。
- 用户重新拍照时会清除上一次处理错误，避免旧错误遮罩干扰新的拍摄流程。

## 验证记录

- `git diff --check`：通过。
- 处理管线调用点检查：通过，当前唯一调用点已显式处理抛出的错误。
- Xcode 工程引用检查：通过，修改的两个 Swift 文件仍在 Sources Build Phase 中。
- AppIcon 文件检查：1024 × 1024、24-bit RGB、不含 Alpha 通道。
- Asset Catalog JSON 解析检查：通过。
- AppIcon target 引用检查：通过，已进入 Resources Build Phase，Debug/Release 均指定 `AppIcon`。
- GitHub Actions `iOS Build #5`：通过；提交 `e14739e` 已完成 iOS Simulator Debug 构建。
- GitHub Actions `iOS Build #8`：通过；提交 `31a1a0f` 的签名预检 workflow 修改未影响应用编译。
- `TestFlight Release #1`：预检按设计失败；仓库尚未配置 7 个必需 GitHub Secrets，因此归档、导出和上传均被安全跳过。
- `TestFlight Release #2`：签名材料安装与 Profile 一致性检查通过；Archive 因 Xcode 默认查找 `iOS Development` 证书失败，已定位并修复为明确使用 `Apple Distribution`。
- `TestFlight Release #3`：Apple Distribution 编译与签名通过；Archive 因自定义 `Info.plist` 缺少 `CFBundleIdentifier` 失败，已补齐标准 Bundle 元数据。
- `iOS Build #11`：通过；补齐标准 Bundle 元数据后模拟器 Debug 编译正常。
- `TestFlight Release #4`：通过；真实 Apple Distribution 归档、IPA 导出与 TestFlight 上传全部成功。
- 本地 Xcode 编译：当前 Windows 主机没有 `xcodebuild`；云端真实归档已通过，仍需在 iPhone 上完成真机验证。

## 重要技术决策

- 只有分析、初次渲染或初次质量检查无法完成时，整次照片处理才视为失败。
- 安全回退属于质量优化步骤；回退失败不应覆盖或丢弃已经成功生成的初版成片。
- UI 层负责呈现处理错误，图像处理管线不再通过返回原始照片隐藏错误。
- 保持现有 MVVM、Service 和 Engine 分层，不在当前模块中同时重构配置、方向或存储系统。
- TestFlight build number 由发布 workflow 在归档时注入，工程中的默认值继续保留为本地开发基线。
- 签名材料必须在归档前完成存在性和身份一致性检查，避免在较晚的 archive/export 阶段才暴露配置错误。

## 已知问题

- TestFlight build `1.0 (4)` 已上传，尚待 Apple Processing 完成并在 App Store Connect 中处理可能出现的出口合规提示。
- 照片 EXIF 方向、Vision 人脸框和 Core Image mask 坐标尚未通过真机验证。
- `ProcessingConfiguration` 尚未接入分析、决策和质量检查模块，阈值仍为硬编码。
- 原图保存通过 `UIImage` 写入相册，尚不能保证原始 JPEG 字节和完整元数据不变。
- 尚无 XCTest target、单元测试或固定样张回归测试。
- 当前 Windows 环境没有 `xcodebuild`，需要通过 GitHub Actions 或 Mac 执行真实编译。

## 下一步计划

1. 等待 TestFlight build `1.0 (4)` 完成 Apple Processing，并处理出口合规提示。
2. 将 build `1.0 (4)` 加入内部 TestFlight 测试组并邀请测试账号。
3. 在真实 iPhone 上验证相机权限、拍摄方向、人脸补光位置、图像处理和相册保存。
4. 将 `ProcessingConfiguration` 注入分析、决策和质量检查模块。
5. 增加处理管线和决策规则的自动化测试。
