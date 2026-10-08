# MasterCamera 项目进度报告

更新时间：2026-10-08

## 总体状态

当前项目已经完成从“相机基础工程”到“AI 自动成片 MVP 主链路”的第一轮搭建。

目前代码已经具备完整的理论流程：

```text
打开相机
拍照
生成原图数据
分析照片
生成摄影决策
渲染 AI 成片
局部人脸补光
质量检查
必要时安全回退
预览原图 / AI 成片
保存两张照片
```

当前仍未进行 Xcode 编译和真机验证，因为本机环境是 Windows，没有 `swift` / `xcodebuild`。

## 已完成阶段

### Phase 1：相机基础层

已完成：

- SwiftUI App 入口
- AVFoundation 拍摄会话
- 相机权限流程
- 后置摄像头默认启动
- 前后摄切换
- 实时相机预览
- 拍照并生成 JPEG 数据
- 点击对焦 / 曝光
- 保存到相册的基础能力

主要文件：

- `MasterCamera/Camera/CameraManager.swift`
- `MasterCamera/Camera/CameraPreview.swift`
- `MasterCamera/Camera/PhotoCaptureService.swift`
- `MasterCamera/Camera/CameraPermissionManager.swift`

### Phase 2：第一版图像引擎

已完成：

- Core Image 自动成片管线
- 曝光、高光阴影、对比、饱和、vibrance、降噪、锐化
- 原图数据保持不变
- 输出独立 AI 成片数据

主要文件：

- `MasterCamera/ImageEngine/CoreImageRenderer.swift`
- `MasterCamera/ImageEngine/AutomaticEditingRecipe.swift`

### Phase 3：本地照片分析

已完成：

- 平均亮度分析
- 对比范围分析
- RGB 色彩倾向分析
- 色偏判断
- Vision 人脸检测
- 人脸区域保存

主要文件：

- `MasterCamera/Analysis/PhotoAnalyzer.swift`
- `MasterCamera/Analysis/PhotoAnalysis.swift`

### Phase 4：PhotographerAI 决策层

已完成：

- 场景策略选择
- 摄影意图生成
- 决策动作列表
- 从分析结果生成修图配方

主要文件：

- `MasterCamera/PhotographerAI/PhotographyDecisionEngine.swift`
- `MasterCamera/PhotographerAI/PhotographyDecision.swift`
- `MasterCamera/PhotographerAI/SceneStrategy.swift`

### Phase 5：局部调整

已完成：

- 保存人脸区域
- 根据人像策略请求局部补光
- 使用 Core Image mask 做轻微人脸局部曝光提升

主要文件：

- `MasterCamera/ImageEngine/LocalAdjustmentProcessor.swift`

### Phase 6：质量检查

已完成：

- 渲染后重新分析 AI 成片
- 判断过暗、过亮、层次偏平、对比过强、成片未变化
- 保存质量检查结果

主要文件：

- `MasterCamera/QualityControl/QualityCheckService.swift`
- `MasterCamera/QualityControl/QualityCheckResult.swift`

### Phase 7：安全回退

已完成：

- 初次成片失败时使用保守配方重渲染
- 只有安全成片质量更好时才替换初版结果
- 标记是否使用安全成片

主要文件：

- `MasterCamera/Processing/PhotoProcessingPipeline.swift`
- `MasterCamera/ImageEngine/AutomaticEditingRecipe.swift`

### Phase 8：处理管线抽离

已完成：

- 将分析、决策、渲染、质量检查、回退集中到 `PhotoProcessingPipeline`
- `CameraViewModel` 只负责 UI 状态协调

主要文件：

- `MasterCamera/Processing/PhotoProcessingPipeline.swift`
- `MasterCamera/ViewModels/CameraViewModel.swift`

### Phase 9：处理状态 UI

已完成：

- 拍照后显示处理状态
- 分析中 / 生成 AI 成片 / 完成处理中
- 处理期间禁用快门和切换摄像头

主要文件：

- `MasterCamera/Models/ProcessingState.swift`
- `MasterCamera/Views/CameraView.swift`

### Phase 10：成片对比体验

已完成：

- 默认展示 AI 成片
- 支持长按临时查看原图
- 保留原图 / AI 成片分段切换

主要文件：

- `MasterCamera/Views/PhotoPreviewView.swift`

### Phase 11：保存状态体验

已完成：

- 保存中状态
- 保存成功状态
- 保存失败状态
- 保存中防重复点击

主要文件：

- `MasterCamera/Models/SaveState.swift`
- `MasterCamera/Views/PhotoPreviewView.swift`
- `MasterCamera/ViewModels/CameraViewModel.swift`

### Phase 12：预览页调试信息开关

已完成：

- 分析 / 决策 / 质量信息默认收起
- 通过信息按钮展开或隐藏
- 默认预览页更接近真实用户体验

主要文件：

- `MasterCamera/Views/PhotoPreviewView.swift`

### 调参配置骨架

已完成：

- 分析阈值配置
- 质量检查阈值配置
- 人像补光默认参数配置

主要文件：

- `MasterCamera/Configuration/ProcessingConfiguration.swift`

## 当前页面图

- `docs/mockups/camera-page.svg`
- `docs/mockups/photo-preview-page.svg`

## 当前架构

```text
App
Camera
Views
ViewModels
Models
Analysis
PhotographerAI
ImageEngine
QualityControl
Processing
Storage
Utilities
```

核心链路：

```text
CameraManager
PhotoCaptureService
CameraViewModel
PhotoProcessingPipeline
PhotoAnalyzer
PhotographyDecisionEngine
CoreImageRenderer
QualityCheckService
PhotoPreviewView
PhotoLibraryManager
```

## 当前未验证风险

这些内容需要 Xcode / iPhone 真机验证：

- Xcode 工程文件是否完全可打开和编译
- AVFoundation 会话配置是否符合当前 Xcode / iOS 版本
- 真机相机权限流程
- 实时预览方向、比例、裁切
- 拍照方向和 EXIF 方向
- Vision 人脸框坐标与 Core Image 坐标是否对齐
- 人脸局部补光 mask 位置是否正确
- Core Image 滤镜参数在真实照片上的观感
- 相册写入权限和保存流程
- Swift 并发隔离是否需要根据 Xcode 编译结果微调

## 什么时候必须编译

现在还可以继续做：

- UI 结构
- 中文文案
- 文档
- mockup
- 非真机依赖的架构整理
- 配方配置结构
- 开发调试辅助工具

但从以下任务开始，就应该进入 Mac / Xcode / 真机验证：

- Phase 13 高级光照
- 更复杂的人脸 / 天空 / 主体 mask
- 人脸补光强度调参
- 输出效果审美调参
- 任何和相机预览方向、照片方向、真实保存结果有关的任务

结论：

继续写结构还可以，但如果要让“AI 成片效果”真正可靠，下一大步应该准备编译环境。

## 下一步建议

建议下一步先做：

1. 增加开发调参配置结构。
2. 让配方参数集中管理，方便真机后快速调参。
3. 准备云 Mac / Mac mini / GitHub Actions macOS 编译方案。

不建议现在继续深入复杂高级光照，因为没有真机样张验证，很容易写出“代码上成立、视觉上不对”的功能。

