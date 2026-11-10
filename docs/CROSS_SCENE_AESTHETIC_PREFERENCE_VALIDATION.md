# 小苏相机跨场景摄影目标与人工偏好验证

日期：2026-11-10
分支：`codex/build33-intent-root-cause-20261110`

## 结论先行

现有规则系统**没有证据支持它能够自动选择专业摄影目标**。它具备逐图测量、动态参数、Core Image 区域渲染和技术质量保护，但目标选择与候选排序仍由人工数学规则和工程代理分数组成。项目内真实人工偏好记录为 **0 条**；因此高分候选只能称为“工程代理选择”，不能称为“审美优胜”。

本轮没有增加秋季道路规则、没有替换正式 B、没有上传 Build 34。已把技术状态、摄影目标判断和人工偏好拆成三个独立字段，并建立开发/盲测样本隔离和通用 X/Y 离线盲测工具。

远程 Apple 验证：提交 `6463a56f4373054444d0908a65d67f0c7143cc8c` 的 [iOS Build run 42837545990](https://github.com/sulinandeyu/1/actions/runs/42837545990) 已完成；90/90 项 Swift 测试通过、0 失败，iOS Simulator `BUILD SUCCEEDED`。这只证明代码与诊断契约可编译运行，不是摄影审美通过。

## 1. 样本隔离

清单：`PhoneValidationDataset/cross_scene_split.json`

- 开发集：室内混合光、夜间建筑、阴天建筑，共 3 张。
- 盲测集：室内环境人物、车内自拍、道路车辆人物、阴天植被，共 4 张。
- 7 张原图均完成 SHA-256 复核，无跨集哈希重复。
- 已知目标 T、反求参数和秋季街道专属实验不得进入自动 D。
- 3 张项目手机原图仍缺当前 D 的 iPhone 全分辨率导出；状态保持 `pending_device_export`，没有用 Windows 图片冒充 Core Image 成片。

## 2. 当前规划器与选择器审计

### 摄影意图

`AestheticPhotographyPlanner` 使用亮度、反差、饱和度、黄色/绿色比例、区域覆盖、蒙版可靠度、噪声和端点风险等连续测量。它不是简单的“场景名 → LUT”，但目标函数和权重全部是人工编写的固定数学规则，没有真实摄影师偏好标签参与校准。

### 参数求解

`AdaptivePhotographyParameterSolver` 与区域求解器会把目标转成实际曝光、曲线、HSL 和区域处理。该层能够动态响应照片测量，且已有真机执行证据；本轮不重构它。

### 候选排序

`PhotoProcessingPipeline.evaluateCandidates` 当前把以下量加权成一个分数：

- 摄影问题改善：32
- 目标达成：26
- 保真：16
- “主体改善”工程代理：13
- “区域协调”工程代理：13
- 技术问题、颜色风险和弱改善惩罚

`PhotographyCandidateSelector` 在技术未拒绝的候选中取总分最高者，分数接近时再偏向保真；所有候选失败时回退自然方案或最高保真方案。这能控制风险，却没有人类偏好证据，仍可能让最接近原图的候选占优势。

本轮新增：

- `PhotographyPreferenceEvidenceStatus`：`notEvaluated / humanSupported / humanRejected / inconclusive`
- `PhotographySelectionBasis`：`engineeringProxyOnly / humanPreferenceCalibrated`
- 当前所有自动候选默认明确记录 `engineeringProxyOnly + notEvaluated`。
- 诊断页面和 ZIP 将自动分数显示为“工程代理”，不再把它写成审美结论。

## 3. 真实图片证据

### 3.1 跨场景历史真机成片

实际图片：`output/cross_scene_preference_validation/historical_actual_cross_scene_pairs.jpg`

它包含四组用户确认的“原图 / V8.1 真机成片”。这些图片证明渲染器能够针对不同输入产生明显差异，但不代表当前 D，也没有人工偏好结论。

Windows 同源诊断（仅用于发现风险，不等于 iOS 技术质检）：

| 场景 | RGB MAE | 亮度变化 | 饱和度变化 | 主要观察 |
|---|---:|---:|---:|---|
| 车内自拍 | 0.0559 | +0.0447 | -0.0072 | 变化明显，但肤色偏橙且暗部被大幅抬起；人物真实性需单独真机检查 |
| 阴天建筑 | 0.0491 | -0.0394 | +0.0994 | 天空和窗面明显偏青，饱和度增幅过大 |
| 道路车辆人物 | 0.0766 | -0.0452 | +0.0101 | 白车和中性色整体变暗，天空端点被明显压缩 |
| 阴天植被 | 0.0670 | -0.0332 | +0.0113 | 有空间变化，但天空偏青、地面偏黄绿，综合色彩关系未获人工支持 |

上述候选的 `technicalAcceptance` 全部标记为 `not_determined_on_windows`，人工偏好全部为 `not_evaluated`。

### 3.2 Build 33 同图真实 iPhone 候选

实际图片：`output/cross_scene_preference_validation/build33_actual_candidate_grid.jpg`

顺序为 A、B、D、E1、E2、M。它证明同一张图已有不同影调表达，但只覆盖一个被长期调试的秋季案例，不能作为跨场景泛化或专业审美证据。完整 Windows 诊断位于 `output/cross_scene_preference_validation/evidence.json`；它不替代 ZIP 中的真实 iOS 质检。

## 4. 三层验收已经分离

1. **技术质量**：裁切、死黑、肤色/中性色、噪声、锐化、蒙版边缘等；由真实 Core Image 输出质检决定。
2. **摄影目标合理性**：目标是否适合当前照片；允许合理、不合理、不确定、未评价。
3. **人工摄影偏好**：左更好、右更好、两者都不好、差异不明显。

离线工具：`PhoneValidationDataset/evaluation/blind-compare.html`。它现在支持任意 X/Y 候选标识，不再限定 B/C；随机左右位置，并把两张图的技术状态、目标判断和人工选择分开保存。结果结构：`PhoneValidationDataset/evaluation/preference-result.schema.json`。

目前人工偏好记录数：**0**。没有伪造摄影师或用户选择。

## 5. 最小可行目标排序器校准方案

在没有真实标签前，不应继续给规则堆权重。满足以下条件后，可实现一个轻量排序器作为候选排序的实验层：

### 数据

- 第一阶段至少 100 张用户自有或明确授权的手机原图，覆盖人物、室内、夜景、建筑、自然、逆光和混合光。
- 每图至少 3 个由当前动态目标系统独立求解并真实渲染的技术安全候选，不使用固定预设，不复制 T 或反求参数。
- 每图至少 3 个成对比较；形成 300–600 条有效选择。
- 20% 图片由至少 3 位评价者重复，用于测量一致性；“两者都不好”和“差异不明显”必须保留，不能强迫选边。
- 按原图 SHA-256 分组做 60/20/20 开发、校准、盲测隔离，任何同源裁剪或重编码不能跨集。

合法来源只使用用户自有/明确授权的手机原图及本 App 生成候选。MIT-Adobe FiveK 研究许可数据、未复核 Wikimedia 参考、网络教程图和目标 T 均不得进入商业排序器训练。

### 模型

- 首选可解释的 Bradley–Terry 或带正则的成对逻辑回归，不先引入大型审美模型。
- 输入只使用当前系统已经可追溯的图像测量、目标关系、实际渲染后区域变化和技术余量；不输入场景名对应的固定风格参数。
- 技术质检先独立拒绝，排序器不能覆盖技术失败。
- 输出偏好概率与不确定度；低于校准阈值时弃权，保留诊断候选，不宣称自动选美成功。

### 通过门槛

- 在按原图隔离的盲测集上显著优于“总选最接近原图”和当前规则分数基线。
- 人物子集必须保持真实肤色、纹理与外貌；技术安全全通过后再看偏好。
- 最终仍以真实 iPhone 成片的盲测胜率和问题标签验收，而不是训练损失或像素差异。

## 6. 当前未完成项

- 当前 D 的跨场景全分辨率 iPhone 候选尚未导出，不能声称当前 D 已经完成跨场景验证。
- 真实人工盲测尚未发生，任何候选都没有 `humanSupported` 证据。
- 当前规则评分能排除部分技术错误，但没有证明可预测专业摄影偏好。
- 本轮没有上传 Build 34、没有替换 B、没有合并正式分支。

## 7. 可重复执行

运行：

```powershell
python scripts/audit_cross_scene_preference_validation.py
```

输出：

- `output/cross_scene_preference_validation/evidence.json`
- `output/cross_scene_preference_validation/historical_actual_cross_scene_pairs.jpg`
- `output/cross_scene_preference_validation/build33_actual_candidate_grid.jpg`

脚本只分析已有真实 JPEG，不生成调色成片。Windows 指标固定标记为非 Core Image 验收。
