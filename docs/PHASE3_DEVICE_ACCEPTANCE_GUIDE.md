# MasterCamera Phase 3 真机出片验收操作说明

- 准备日期：2026-10-24（Asia/Shanghai）
- 代码基线：`281bf65591a92d7897a33a7d4aba955fdfae8356` 加当前未提交的 Phase 2 修改
- 本阶段范围：只准备测试入口、记录格式、安全检查和真机流程；未调整摄影算法或后期参数

## 1. 当前状态不能混用

| 状态 | 判定含义 | 当前结论 |
|---|---|---|
| 代码已实现 | 静态代码存在且调用链连通 | 是；等待 macOS 编译复核 |
| 自动测试已通过 | 对应测试在当前提交实际执行并通过 | 否；当前 Windows 无 `swift`，新增 Phase 2 测试尚未运行 |
| iOS 端到端已通过 | 原图在 iPhone 上真实经过 Vision、Core ML、Core Image、质检、JPEG 保存和重新读取 | 否 |
| 真实视觉质量已验收 | 人工对同一张原图/成片进行场景和人物真实性检查并签字 | 否 |

补充边界：`Package.swift` 的自动测试只覆盖摄影决策核心，明确排除了 `PhotoAnalyzer`、Core ML 分割、Core Image renderer、质量检查、保存和界面。Xcode 的共享 `MasterCamera` Scheme 当前没有 Testable target；因此 Xcode Build 成功也不能写成端到端或视觉验收通过。

## 2. 所需设备与软件

- 一台能够运行当前工程的 Mac 和匹配 iOS 17+ SDK 的 Xcode。
- 一台 iOS 17 或更高版本的真实 iPhone；不能只用 Simulator 代替相机、Vision/Core ML 性能和相册保存验收。
- Xcode 中配置有效的 Development Team；工程当前 `DEVELOPMENT_TEAM` 为空，需要测试人员选择自己的签名团队。
- iPhone 与 Mac 建立信任，可读取 Xcode Console；设备至少预留 2 GB 空间。
- 允许 App 使用相机，以及向照片图库添加照片。
- 五类未经截图、未经社交软件二次压缩的手机原始 JPEG/HEIC。相同文件在整个回归周期内不得替换。

## 3. 现有真机测试入口

实际调用链：

`CameraView.样片复测` → `PhotosPicker` → `CameraViewModel.processImportedPhotoData` → `PhotoProcessingPipeline.process` → `PhotoAnalyzer`（Vision + Core ML）→ `PhotographyDecisionEngine` → `CoreImageRenderer` → `QualityCheckService` → JPEG → `PhotoPreviewView` → `PhotoLibraryManager.savePhotos`

可观察证据：

- 预览右上角信息按钮：场景识别状态/置信度、语义标签、分割状态/原因、五类蒙版覆盖率、配方、局部执行回执、降级原因、各阶段耗时、质检结果和像素差异。
- Xcode Console：过滤 subsystem `com.sulinandeyu.mastercamera`、category `ImageEngine`，保存完整日志。
- 预览版本切换：Original、AI 成片、5 倍差异图和逐阶段预览。
- 保存按钮：在系统照片图库产生两个独立资源：
  - `MasterCamera_<timestamp>_Original.jpg`
  - `MasterCamera_<timestamp>_AI_Edited.jpg`

## 4. 五类素材清单

| Case ID | 场景 | 当前素材 | 当前状态 | 关键检查点 |
|---|---|---|---|---|
| MC-SKY-01 | 天空或风景 | 无 | 缺失，不得执行假验收 | 云层/天空和地面关系、高光、色偏、蒙版边界 |
| MC-VEG-01 | 植被或乡间道路 | 无 | 缺失，不得执行假验收 | 植被覆盖、道路纵深、黄绿关系、光晕 |
| MC-INDOOR-01 | 室内 | `真实图片/44be3f7cea3f221e8ae069dfcbda1fef.jpg` | 待真机 | 混合光、灯具高光、墙面中性色、家具材质 |
| MC-NIGHT-01 | 城市夜景 | `真实图片/d591c944ab71c641ab655b4740ca1287.jpg` | 待真机 | 点光源裁切、死黑、暗部噪声、建筑层次 |
| MC-PERSON-01 | 人物+室内 | `真实图片/ddfb7fb8bd03582cbee6a7c9a1ac3282.jpg` | 待真机 | 人脸身份、五官、脸型、皮肤纹理及人物/背景相对变化 |

天空和植被样片补齐前，五场景验收状态必须保持“不完整”。参考图、界面截图、合成图、FFmpeg 替代图和人工构造参数都不能填补这两个 Case。

## 5. 每次真机运行步骤

1. 保留当前工作区，先记录 `git rev-parse HEAD`、`git status --short`、Xcode 版本、App build、设备型号和 iOS 版本。
2. 在 Mac 上先运行 `swift test`。它只证明决策核心自动测试状态，不能证明 iOS 图像管线。
3. 运行一次真机 Debug Build；推荐命令：`xcodebuild -project MasterCamera.xcodeproj -scheme MasterCamera -configuration Debug -destination 'platform=iOS,name=<设备名>' build`。也可在 Xcode 中选择真实设备后 Build & Run。
4. 打开 Console 日志并按 `com.sulinandeyu.mastercamera` / `ImageEngine` 过滤。每张照片单独保存日志，避免多张结果混在一起。
5. 在 App 相机页点击“样片复测”，只选择当前 Case 的原始文件。等待处理完成；若出现错误，记录错误并把状态写成 FAIL，不得继续把原图登记为成片。
6. 在预览页打开信息面板，按 `DEVICE_TEST_RECORD_TEMPLATE.md` 逐字段记录；对长内容分段截图，必须包含识别状态、置信度、覆盖率、执行回执、耗时和质检。
7. 切换 Original、AI 成片、差异图和逐阶段预览，检查处理步骤与视觉区域是否对应。参数或像素有差异不等于视觉质量通过。
8. 点击保存，确认照片图库新增两个资源；检查时间戳配对、尺寸、方向，并重新打开 AI 成片确认可解码且不是旧照片。
9. 导出原图、AI 成片、Console 日志、信息面板截图和填写完成的记录。建议保存到：
   `真机验收结果/<日期>-<build>/<Case-ID>/`
10. 关闭预览返回相机页后再测下一张，避免把上一张预览或时间戳误记到下一 Case。

## 6. 人物专项安全验收

静态检查未发现瘦脸、瘦身、美白、祛痘祛斑、五官重建或生成式人脸模型。最终人物保护会把 `faceExposureEV` 归零，质量门会检查人脸相对背景的亮度、颜色和纹理变化。但这些代码证据不能替代真机人工检查。

人物 Case 必须在 Original 与 AI 成片上以相同缩放检查：

- 眼、鼻、嘴、下颌线、脸宽、身体轮廓和人物身份不得变化。
- 毛孔、皱纹、发丝和真实皮肤纹理不得出现平滑、涂抹、重建或局部锐化异常。
- 不得出现仅面部美白、提亮或改变肤色；允许全画面白平衡和环境光影同步变化。
- 人脸边缘、头发和皮肤附近不得有蒙版光晕、断层或色边。
- 若人物分割失败，记录区域处理的跳过原因；安全跳过优于误伤人物。
- 任一项目异常即为 FAIL，不能用“整体更好看”覆盖人物真实性失败。

## 7. 通过标准

单张照片只有同时满足以下条件，才能把“iOS 端到端”写成 PASS：

- Vision 状态、置信度和标签有真实记录；失败/不确定状态没有被伪装为可靠识别。
- Core ML 分割状态和覆盖率有记录；空或不可靠蒙版没有被写成局部处理成功。
- 预期处理步骤与局部执行回执一致；跳过原因可解释。
- 输出 JPEG 可重新读取，方向和尺寸正确，且与本次输入配对。
- 质量检查不是 failed；没有不必要高光裁切、死黑、异常色偏、过饱和、噪声放大、过度锐化或蒙版边界异常。

“真实视觉质量”只有在上述端到端通过后，再由人工确认主体、光影、色彩和空间关系合理，才能单独标记 PASS。人物照片还必须通过第 6 节全部检查。

## 8. 结果归档

每个 Case 的目录至少包含：

- `record.md`：从模板复制并填写，不得删除未通过字段。
- `Original.jpg` 或原始 HEIC。
- `AI_Edited.jpg`。
- `console.log`。
- `diagnostics-01.png` 等信息面板截图。
- 必要时保存逐阶段预览截图和失败错误截图。

大型照片和日志默认作为测试产物保存，不应在未确认仓库策略前直接提交 Git。
