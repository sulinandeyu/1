# 小苏相机专业摄影数据集执行报告

更新时间：2026-10-27

## 结果摘要

- 建立 `PhotographyDataset`，未创建平行摄影引擎，未修改拍照和保存功能。
- 通过 Wikimedia Commons 官方 MediaWiki API 导入 250 张 Featured Pictures。
- 数据分割：参考集 220，隔离验证集 30；ID、来源 URL 与本地 SHA256 无交叉。
- 逐图特征：250/250 完成。
- 本地图片字节：220,715,849 bytes，全部位于 Git 忽略目录。
- 自动筛选拒绝：1,516 条，逐条记录原因。
- 官方原图—专家成片配对：0；未用不同照片伪装前后对照。
- 模型训练：未启动。

## 来源核查

1. MIT-Adobe FiveK：提供同一 RAW 的五位专家成片，是高价值研究数据；但两份官方许可均限定自身研究并排除商业优势/金钱报酬用途，因此登记为商业禁用，未下载。
2. Unsplash Lite：Dataset Terms 允许为内部业务训练 ML，但数据许可不可转移/再许可，且禁止披露、发布、转移、再分发。下载即表示接受条款，本轮没有代替项目权利主体接受，也没有下载。
3. Unsplash Full：仅非商业，使用或处理该数据训练的模型也不得商用，因此禁用。
4. Wikimedia Commons：逐文件许可可由官方 API 获取，允许按每张文件的条件复用。本轮只允许 PD/CC0/CC BY/CC BY-SA，保留作者、许可名、许可 URL、来源页和哈希；另外排除明显人物、艺术品、商标和扫描件风险。
5. Open Images：适合识别/分割，但不是专家摄影后期库；官方还要求自行复核每张图片许可，本轮未导入。

完整链接与条款摘要见 `PhotographyDataset/licenses/SOURCE_LICENSE_MATRIX.md`。

## 许可统计

| 状态 | 数量 | 当前允许 |
|---|---:|---|
| `candidate_after_legal_review` | 48 | 内部参考与特征分析；正式商业训练前仍需法务/内容复核 |
| `blocked_pending_legal_review` | 202 | 内部参考与特征分析；因 CC BY-SA 等要求禁止直接进入商业模型训练 |

逐许可：CC BY-SA 4.0 155、CC BY-SA 3.0 45、CC BY-SA 2.5 2、CC0 14、Public Domain 14、CC BY 4.0 11、CC BY 3.0 6、CC BY 2.0 3。

## 数据结构

每条记录包含：

- 数据角色和 split。
- 来源数据集、标题、来源页、下载 URL、作者、说明、源 SHA1。
- 许可名、许可 URL、署名/ShareAlike 要求、证据页。
- 商业参考、特征分析、模型训练和再分发状态。
- 人物/商标/艺术作品风险状态。
- 本地相对路径、SHA256、Git 忽略状态。
- 尺寸、MIME、类别/主体/光照元数据及导入溯源。
- 配对 ID 和配对验证字段；本轮所有记录明确为非配对。

Schema：`PhotographyDataset/schemas/photo-record.schema.json`。

## 实际特征分析

250 张均完成缩小 sRGB 像素测量：

- 亮度均值、标准差、P05/P25/P50/P75/P95。
- 阴影、高光、纯黑、纯白和中间调占比。
- RGB 均值、平均饱和度、12 段色相直方图。
- 暖色/冷色像素比、中性色覆盖与中性色均值。
- 梯度能量、4×4 网格局部对比及离散度。
- 中心与边缘亮度/饱和度关系。

中心/边缘结果明确标为构图代理，并非主体识别。所有记录的 `renderedByCoreImage=false`、`iphoneValidated=false`、`aestheticJudgment=not_performed`。

总体实测：平均亮度 0.434772、平均饱和度 0.315939、平均网格局部对比 0.125010。影调分布为 broad/balanced 170、low-key 54、compressed 22、high-key 4。

## 视觉抽查

用 5 张联系表检查全部 250 张缩略图。样本覆盖自然、野生动物、农业、建筑、城市、夜景、天文和风景，具有明确的构图、光影和色彩差异。天文图中包含科学/窄带成像，建筑中包含细节记录图；这些记录不会被当作普通手机照片的直接目标，应在未来检索时通过测量域和适用边界隔离。

视觉抽查不是法务复核，也不能证明每张作品适合训练；Featured 身份也不等于拥有 Lightroom 调整记录。

## 与现有引擎对接结论

不增加场景预设。未来实验接入点限定为：

`PhotoAnalyzer 当前实测` → `连续特征近邻检索` → `稳健目标分布` → `AdaptivePhotographyTargetGenerator` 软约束 → `AdaptivePhotographyParameterSolver` → `CoreImageRenderer` 真实渲染 → `QualityCheckService` 技术门控 → 人工偏好。

参考作品只提供目标统计范围，不提供固定参数。人物保护、混合光、噪声和高光安全规则优先。近邻不足或许可状态不合格时退回现有实测求解器并显式记录原因。

## 已运行命令

```powershell
pwsh -NoProfile -File scripts/Import-WikimediaPhotographyDataset.ps1 -TargetCount 250 -ValidationCount 30 -MaximumApiPages 100
pwsh -NoProfile -File scripts/Measure-PhotographyDataset.ps1
pwsh -NoProfile -File scripts/Test-PhotographyDataset.ps1
```

最终完整性结果：`passed`；参考 220、验证 30、split leakage false、duplicate pixels false、assets ignored by Git true、original/expert pairs 0。

## 尚未完成与下一门槛

- 未获得可用于商业产品的同底片原图—专家成片配对及摄影师调整目的。
- 48 张候选仍需要正式法务/内容风险复核；202 张 CC BY-SA 不进入训练。
- 30 张验证集是公开真实摄影作品，但不是普通用户手机原图。正式验收仍需另外准备至少 30 张自有/明确授权的普通手机原图，并与本参考库隔离。
- 还没有基于该库训练或微调模型。
- 还没有将参考检索写入生产评分，避免未经人工偏好校准的数据改变出片。
- 当前 Windows 无 Xcode/Core Image/Vision；没有 iPhone 真机出片结论。

未经用户确认，本轮没有提交、推送或发布。
