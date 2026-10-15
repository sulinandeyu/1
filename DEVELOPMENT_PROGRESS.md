# MasterCamera 开发进度

更新时间：2026-10-15

## 当前阶段

MasterCamera 已完成 Phase 1–13 的 MVP 主链路原型，包括相机拍摄、本地照片分析、摄影决策、Core Image 自动成片、人脸局部补光、质量检查、安全回退、预览对比、相册保存状态和诊断面板。

Phase 14 TestFlight 发布准备已在本地提交中开始，但尚未完成远端 CI、签名归档、App Store 上传和真机验证。Phase 15 高级光照尚未开始。

## 本轮完成

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
- Xcode 编译：当前 Windows 主机没有 `xcodebuild`，尚未执行；需要在 GitHub Actions 或 Mac 上补充验证。

## 重要技术决策

- 只有分析、初次渲染或初次质量检查无法完成时，整次照片处理才视为失败。
- 安全回退属于质量优化步骤；回退失败不应覆盖或丢弃已经成功生成的初版成片。
- UI 层负责呈现处理错误，图像处理管线不再通过返回原始照片隐藏错误。
- 保持现有 MVVM、Service 和 Engine 分层，不在当前模块中同时重构配置、方向或存储系统。

## 已知问题

- 当前本地提交比 `origin/main` 领先，TestFlight workflow 尚未经过远端 CI 验证。
- 照片 EXIF 方向、Vision 人脸框和 Core Image mask 坐标尚未通过真机验证。
- `ProcessingConfiguration` 尚未接入分析、决策和质量检查模块，阈值仍为硬编码。
- 原图保存通过 `UIImage` 写入相册，尚不能保证原始 JPEG 字节和完整元数据不变。
- 尚无 XCTest target、单元测试或固定样张回归测试。
- 当前 Windows 环境没有 `xcodebuild`，需要通过 GitHub Actions 或 Mac 执行真实编译。

## 下一步计划

1. 在当前 HEAD 上执行一次 Xcode/GitHub Actions 编译，修复本轮可能暴露的 Swift 并发或类型错误。
2. 检查并补齐其余 TestFlight 发布元数据和自动递增 build number。
3. 在真实 iPhone 上验证相机权限、拍摄方向、人脸补光位置和相册保存。
4. 将 `ProcessingConfiguration` 注入分析、决策和质量检查模块。
5. 增加处理管线和决策规则的自动化测试。
