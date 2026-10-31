# 小苏相机视觉理解与审美规划调用链审计

日期：2026-10-31
范围：当前工作区静态审计与代码改造；Windows 未执行 Vision/Core ML/Core Image。

## 1. 当前真实模型与能力

| 能力 | 实际 API/模型 | 真实输出 | 不能证明的能力 |
|---|---|---|---|
| 场景分类 | `VNClassifyImageRequest`，`PhotoAnalyzer.classifyScene` | 多标签 identifier 与 confidence | 不定位对象，不理解摄影意图，不直接给后期参数 |
| 人脸定位 | `VNDetectFaceRectanglesRequest` | 人脸矩形与背景测光排除范围 | 不识别人身份，不允许据此美颜或修改五官 |
| 人物分割 | `VNGeneratePersonSegmentationRequest(.balanced)` | 人物 matte | 不提供肤色美学结论；边缘和覆盖仍需真机检查 |
| 通用显著性 | `VNGenerateAttentionBasedSaliencyImageRequest` | 视觉注意区域 | 显著性不是对象身份，不能把橙色显著区直接叫“柿子” |
| 场景语义分割 | 内置 `DETRResnet50SemanticSegmentationF16P6.mlpackage` | 448×448 class ID map `semanticPredictions` | 类级区域不是实例检测，不理解主体/背景摄影作用 |

内置 DETR 包体实测 32,386,655 字节（约 30.9 MiB），模型元数据声明 CoreML7、Apache 2、源模型 `facebook/detr-resnet-50-panoptic`。现有部署目标为 iOS 17，因此资源格式与工程平台设置一致；具体设备推理耗时、峰值内存和老设备表现尚无本轮真机数据，不能写成已通过。

新增类级区域的编号已直接对照该模型内嵌 `com.apple.coreml.model.preview.params.labels`：人物 1，车辆 2/3/4/6/7/8/9，动物 16–25，食物/果实 52–61/122/196，人工光源 10/130，道路/铺装引导 147/149/191。未把杯/餐具 47–51 伪称为食物，也未把 playingfield 145 或 sand 154 伪称为灯光/道路。

Apple 官方文档已实际访问：图像分类、人物 matte、显著性和 Core ML 模型集成页面均可访问，但自动页面主体需要 JavaScript。能力边界继续以 API 实际返回类型和本地调用代码为准，不根据产品名称扩大解释。

## 2. 整改前的真实断点

1. `SkySegmentationService` 已加载 DETR，但只保留天空、地面、植被、水面、建筑五组 mask；人物、车辆、动物、食物/果实、道路、工作区与人工光源 class ID 被丢弃。
2. `PhotoAnalysis` 有全局和五组区域测量，但没有统一的结构化视觉理解结果，未知内容未集中呈现。
3. `PhotographyReferenceMatcher` 能生成 `PhotographyTargetProfile`，`PhotoProcessingPipeline.evaluateReferenceCandidate` 也确实把 C 方案送入 `CoreImageRenderer`，不是只生成 JSON。
4. `PhotographyDecisionEngine.makeDecision` 在整改前把所有结果的 `aestheticTarget` 写为 `.neutral`；不存在 `AestheticPhotographyPlanner`。
5. `AdaptivePhotographyParameterSolver` 能做逐图技术参数求解，但参考目标只轻微影响亮度、反差和主体差；色彩分级仍主要依据全图通道差，不能解释主体/环境审美关系。
6. 正式 B、诊断 C 和保存链路没有发现“新模块完全未调用”的保存断点；核心缺口在 C 的审美目标表达和语义证据利用，而不是 Core Image 完全未执行。

## 3. 本阶段实际改造调用链

`原图数据`

→ `PhotoAnalyzer` 执行像素统计、Vision 分类/人脸/人物/显著性、DETR panoptic

→ `SkySegmentationService.semanticObjectMasks` 从同一模型额外暴露人物、车辆、动物、食物/果实、工作区、人工光源、道路类级蒙版

→ `PhotoAnalyzer` 对每个通过质量门控的蒙版测量亮度、反差、RGB、饱和度、阴影/高光并写入 `SemanticObjectRegion`

→ `PhotoAnalysis.visualSceneUnderstanding` 生成 `VisualSceneUnderstandingResult`，记录主体候选、视觉中心、光源证据、颜色关系、保护项和未知项

→ C 诊断路径的 `AestheticPhotographyPlanner` 根据当前图残差生成视觉层级、局部反差、颜色分离、保护与风险目标

→ 同一个 `AdaptivePhotographyParameterSolver` 读取规划结果；不创建独立渲染引擎

→ 现有 `CoreImageRenderer` 全分辨率渲染

→ `QualityCheckService` 技术质检

→ A/B/C 诊断记录显示视觉理解、审美规划、实际参数、区域执行和质检结果。

正式 B 的入口未改变，规划器只在 `targetProfile.referenceApplied == true` 的 C 诊断验证路径启用。

## 4. 场景与固定参数隔离

- 场景标签仍可参与语义检索和氛围/安全边界，但不会选择 LUT、固定曲线或固定 HSL。
- 新的主体优先级来自类级蒙版质量、覆盖、区域统计或通用显著性；无法可靠定位时进入 `globalHarmony`。
- 同一场景标签下，亮度、反差、阴影、高光、噪声、混合光和区域统计变化会生成不同目标。
- 新颜色分离要求混合光与高亮源证据同时存在；人物时进一步降低上限，证据不足为 0。
- 本地网络教程没有进入包资源、参考索引、训练数据或参数表。

## 5. 尚未满足的能力

- DETR 当前输出是类级语义图，不提供多个同类对象的独立实例关系，也不理解“哪个对象是摄影主体”。规划器只能结合覆盖、显著性和区域分离形成候选。
- 当前没有经本项目真实手机照片和人工偏好校准的移动端审美模型，因此不能声称自动评分等同专业摄影师。
- 没有新的模型选型必要性证据：现有模型仍有大量未利用类别，优先复用并真机验证更符合包体、许可和性能约束。若真实样片证明类级分割不足，再单独评估实例/视觉编码模型。
- Windows 缺少 Swift、Xcode、Vision/Core ML/Core Image；本轮新增代码必须在获得提交/推送确认后走既有远程 macOS 构建，再由 iPhone 完成 A/B/C 验收。

## 6. 验收证据要求

1. 远程 `swift test` 与 iOS Simulator build 均通过。
2. iPhone 诊断详情包含 `结构化视觉理解=` 和 `摄影审美规划=`，C 有真实 Core Image 输出文件。
3. 至少人物、阴天风景、室内混合光、夜景、道路/植被五组原图执行 A/B/C。
4. 检查语义 mask 覆盖与实际区域一致；错误区域不得参与局部编辑。
5. 人物检查源图相对肤色、纹理、五官和体型；任何美颜或重建均为失败。
6. 由人工盲测记录 A/B/C 偏好；像素变化或技术质检通过不能替代审美结论。
