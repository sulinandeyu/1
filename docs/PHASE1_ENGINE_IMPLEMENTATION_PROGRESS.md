# Phase 1 摄影引擎实施进度

更新时间：2026-11-20
当前分支：`codex/automatic-photography-director-v2-20261114`
实施基线：`50d545777712eafec95232d6eea617d3248c5685`

## Task 1：原图安全保存闭环

状态：**SOURCE_IMPLEMENTED / APPLE_EXECUTION_PENDING**

已完成的代码行为：

- AVFoundation 得到有效 JPEG 后创建稳定 `captureID`，原始 JPEG 字节不重编码。
- 普通拍照在进入 `PhotoProcessingPipeline` 前，先写入 App 私有 Application Support 目录；临时文件经 SHA-256 校验后原子改名。
- manifest 独立采用临时写入、解码校验及替换；启动协调会恢复“图片已完成但 manifest 未完成”的孤立原图。
- 同一 `captureID` 和相同哈希重复暂存/保存不会创建额外副本；哈希冲突会拒绝覆盖。
- Photos 写入前持久化 `committing`。若 App 在 Photos 成功与本地 receipt 确认之间中断，重启后转为 `needsReconciliation`，在 `.addOnly` 权限下不会静默重试。
- 后期成功时仅保存通过质量检查的正式 B；后期失败时只展示和保存原图，不创建与原图相同的假 AI 成片。
- 私有暂存失败时停止 AI 后期，保留内存抢救路径，并明确说明该路径不具备跨崩溃 exactly-once 保证。
- App 重启后可发现待恢复原图，主界面提供最小恢复入口。
- `isDiagnosticImport == true` 不进入新拍摄原图暂存；诊断导入仍仅在用户明确点击保存时写入相册。
- 未自动删除任何尚未确认保存成功的原图。
- 冷启动协调与日常 UI 刷新已分离：只有 `reconcileAfterColdLaunch()` 会处理上个进程遗留的 committing；日常 `recoverySnapshot()` 只读，不会干扰当前 Photos 事务。
- manifest 损坏时保留原始损坏副本；可校验 JPEG 恢复为 `needsReconciliation`，不再自动降级为 `staged`。
- Photos 写入前重新以 manifest、capture ID、外部 receipt、待保存字节和私有暂存文件执行完整 SHA-256 交叉校验；Photos 使用重新读取的权威暂存字节。
- 已确认保存且超过 30 天的本地原图可在冷启动后清理；未保存、等待权限、保存失败、committing、needsReconciliation 均永久排除在自动清理之外。

## 状态流

`JPEG received → staged → committingToPhotoLibrary → committedToPhotoLibrary`

异常分支：

- 权限拒绝：`staged → awaitingPhotoLibraryPermission`
- Photos 明确失败：`committing → saveFailed`，原图仍可恢复
- Photos 结果未知或确认 manifest 写入失败：`committing → needsReconciliation`（启动协调后）
- 私有存储失败：`memoryOnly`，仅允许显式的当前进程抢救
- manifest 中断：扫描完整 `.jpg` 文件名、capture ID、时间和哈希后重建索引

## 修改范围

- `MasterCamera/Storage/OriginalPhotoRetentionStore.swift`：新增持久存储 actor、manifest、恢复协调、Photos 幂等提交协调器及可注入接口。
- `MasterCamera/Camera/PhotoCaptureService.swift`、`CameraManager.swift`：稳定 capture ID 和采集时间传递。
- `MasterCamera/Models/CapturedPhoto.swift`、`SaveState.swift`：retention receipt 与原图/成片分离状态。
- `MasterCamera/ViewModels/CameraViewModel.swift`：先暂存、后处理；失败保留原图；重启恢复。
- `MasterCamera/Storage/PhotoLibraryManager.swift`：正常拍照和诊断保存隔离；原图/B 独立提交和幂等状态。
- `MasterCamera/Views/CameraView.swift`、`PhotoPreviewView.swift`：最小恢复入口及原图-only 失败状态。
- `MasterCamera/Processing/PhotoProcessingPipeline.swift`：只透传 capture ID/receipt；摄影参数与正式 B 输出逻辑未修改。
- `Package.swift`、`MasterCamera.xcodeproj/project.pbxproj`：纳入新文件和纯 Swift 测试。
- `MasterCameraDecisionCoreTests/OriginalPhotoRetentionStoreTests.swift`：新增故障注入测试。

## 测试证据

已编写但尚未在 Apple/Swift 环境执行的 **28 项**测试覆盖：

1. 正常暂存、原始字节与 SHA-256 一致。
2. 同 capture ID 暂存幂等。
3. 后期失败后原图及重启恢复。
4. Photos 权限拒绝。
5. Photos 明确写入失败。
6. 重复点击保存、B 资产幂等及原图/B 字节原样传递。
7. 并发保存请求合并。
8. Photos 成功但 receipt 未确认。
9. Photos writer 返回未知确认状态。
10. 私有存储/空间写入失败。
11. manifest 写入中断后的孤立文件恢复。
12. 真实文件持久层跨实例字节一致。
13. 诊断导入不进入普通拍照暂存策略。
14. 延迟 Photos writer 下，日常刷新不改变正在提交的原图状态。
15. 延迟 Photos writer 下，日常刷新不改变正在提交的正式 B 状态。
16. manifest 损坏前原图已 committed 的保守恢复。
17. manifest 损坏前正式 B 已 committed 的保守恢复。
18. manifest 损坏时 Photos 正在 committing 的保守恢复。
19. 待保存原图字节与 manifest 哈希不一致时拒绝 Photos 写入。
20. 伪造 capture ID/receipt 不能绕过权威 manifest。
21. 私有暂存 JPEG 损坏时拒绝标记保存成功。
22. 自动清理只删除过期且已确认提交的本地原图。
23. 损坏 manifest 副本及原始 JPEG 均被保留。
24. 等待授权及正式 B 待协调状态的本地原图不会被自动清理。
25. 同 capture ID、不同原图 SHA-256 的并发请求不会共享 active save。
26. 同 capture ID、不同正式 B SHA-256 的并发请求不会共享 active save。
27. 已确认 Photos 原图清理本地缓存后不会重建原图资产，且仍可保存正式 B。
28. 未提交原图缺少私有暂存文件时仍严格拒绝 Photos 写入。

Windows 当前验证：

- `git diff --check`：通过（仅存在工作区行尾提示，无空白错误）。
- Xcode 工程已引用新增 Swift 文件。
- 禁止修改的摄影决策、分析、Core Image 参数文件没有本轮差异。
- 当前 Windows 环境没有 `swift` / `xcodebuild`，因此 **Swift 编译、XCTest、Photos 事务和 iPhone 重启恢复均未执行，不能标记为通过**。
- `.github/workflows/ios-build.yml` 已包含 `swift test`，会发现 `MasterCameraDecisionCoreTests/OriginalPhotoRetentionStoreTests.swift`；随后执行 iOS Simulator `xcodebuild build`。本轮无需改动工作流。

## 尚待 Apple/iPhone 验证

- macOS `swift test` 编译并执行新增故障注入测试。
- iOS Simulator 编译，确认 Swift 并发检查和 Photos API 可用性。
- 真机验证 Data Protection、低存储、强制终止、重启恢复、权限拒绝和连续点击保存。
- 使用真实拍照验证原始 JPEG 哈希、正式 B 像素与基线一致。
- `.addOnly` 下的 `needsReconciliation` 用户提示流程；不扩大照片读取权限。

## 对正式 B 的影响

正式 B 的摄影决策、参数、Core Image 算子和质量门槛未修改。管线只增加 capture ID 与 retention receipt 的透传。正式 B 像素不变仍需 Apple 环境回归测试确认，当前不能声称已真机通过。

## 回滚边界

可按文件撤销 Task 1 修改并从 Xcode/Package 移除新增文件；App 私有目录中的既有原图和 manifest 不应随代码回滚自动删除。回滚前必须先为仍处于 recoverable/needsReconciliation 的原图保留恢复工具。

## 下一任务入口（未开始）

Task 2 从 `CoreImageRenderer.swift`、`AutomaticEditingRecipe.swift` 与 `CinematicImagingEngines.swift` 的隔离渲染表达能力验证开始。不得在 Task 1 未完成 Apple 编译与真机存储验收前切换正式 B。
