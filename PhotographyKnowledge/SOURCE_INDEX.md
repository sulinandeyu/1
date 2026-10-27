# 来源索引

以下资料已实际访问。知识库只做摘要和工程转译，不复制受版权保护的长篇内容。

## Adobe 官方

| ID | 来源 | 本项目采用的信息 |
|---|---|---|
| ADOBE-TONE-01 | [Lightroom：Light 调整](https://helpx.adobe.com/lightroom/web/edit-photos/apply-effects/adjust-light.html) | Exposure 控制整体亮度；Highlights/Shadows 作用于亮暗区域；Whites/Blacks 建立端点；调整存在联动。 |
| ADOBE-TONE-02 | [Lightroom Classic：Tone Control Adjustment](https://helpx.adobe.com/lightroom-classic/desktop/help/tone-control-adjustment.html) | 直方图区间可用于区分中间调、高光、阴影和黑白端点；具体幅度依照片、光照、相机和偏好而变，不能照搬固定滑块。 |
| ADOBE-MASK-01 | [Lightroom Classic：Masking](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/masking.html) | 亮度范围、颜色范围、主体/天空选择与羽化用于限制局部调整范围。 |
| ADOBE-DETAIL-01 | [Lightroom：Adjust Details](https://helpx.adobe.com/uk/lightroom/web/edit-photos/apply-effects/adjust-details.html) | 锐化应受半径、细节和边缘蒙版约束；亮度/色彩降噪会损失细节。 |
| ADOBE-DETAIL-02 | [Lightroom Classic：Retouch Photos](https://helpx.adobe.com/in/lightroom-classic/desktop/process-and-develop-photos/retouch-photos.html) | 100% 检查锐化与噪声；过大半径和过强降噪会制造边缘或抹除纹理。 |
| ADOBE-ACR-01 | [Adobe Camera Raw：Introduction](https://helpx.adobe.com/camera-raw/desktop/get-started/overview-and-setup/introduction-camera-raw.html) | RAW 保留传感器数据与元数据，白平衡、影调、饱和度和锐化是可重处理的解释步骤；JPEG 已经过机内处理。 |
| ADOBE-PS-01 | [Photoshop：Adjust image color and tone](https://helpx.adobe.com/photoshop/desktop/adjust-color/color-corrections/adjust-image-color-and-tone.html) | 调整层和蒙版支持非破坏、局部的颜色/影调处理；Camera Raw 与局部蒙版服务于不同工作流。 |

## Apple 官方

| ID | 来源 | 本项目采用的信息 |
|---|---|---|
| APPLE-CI-01 | [Core Image workingColorSpace](https://developer.apple.com/documentation/coreimage/cicontextoption/workingcolorspace) | Core Image 会在输入、工作和输出色彩空间间转换；默认是扩展线性 sRGB，必须显式管理输出色彩空间。 |
| APPLE-CI-02 | [CITemperatureAndTint](https://developer.apple.com/documentation/coreimage/citemperatureandtint) | `neutral` 表示源白点，`targetNeutral` 表示目标白点；不能把 Lightroom 滑块值直接当滤镜向量。 |
| APPLE-VISION-01 | [Vision Saliency](https://developer.apple.com/documentation/vision/cropping-images-using-saliency) | 显著性可辅助构图和视觉优先级，但不等于物体身份识别。 |
| APPLE-VISION-02 | [Person Segmentation](https://developer.apple.com/documentation/vision/applying-matte-effects-to-people-in-images-and-video) | 人物蒙版有不同质量/性能档位；局部处理前仍需检查覆盖率与边界可靠性。 |
| APPLE-CI-03 | [CISharpenLuminance](https://developer.apple.com/documentation/coreimage/cisharpenluminance) | 亮度锐化可减少直接色彩放大，但仍需噪声与人物纹理安全上限。 |

## 公开研究论文

| ID | 来源 | 本项目采用的信息 |
|---|---|---|
| PAPER-CC-01 | [Barron, Convolutional Color Constancy, ICCV 2015](https://openaccess.thecvf.com/content_iccv_2015/html/Barron_Convolutional_Color_Constancy_ICCV_2015_paper.html) | 色恒常是欠约束问题；需要颜色统计与学习证据，不能仅凭全图均值断言照明颜色。 |
| PAPER-CC-02 | [Cheng et al., Effective Learning-Based Illuminant Estimation, CVPR 2015](https://openaccess.thecvf.com/content_cvpr_2015/html/Cheng_Effective_Learning-Based_Illuminant_2015_CVPR_paper.html) | Gray-world/white-patch 等简单假设有失败条件；缺少可靠证据时应保守。 |
| PAPER-CC-03 | [Afifi et al., When Color Constancy Goes Wrong, CVPR 2019](https://openaccess.thecvf.com/content_CVPR_2019/papers/Afifi_When_Color_Constancy_Goes_Wrong_Correcting_Improperly_White-Balanced_Images_CVPR_2019_paper.pdf) | 白平衡校正需要相机/显示域与真实参考数据，错误校正本身会产生明显色偏。 |
| PAPER-IQA-01 | [NIMA, 2017](https://arxiv.org/abs/1709.05424) | 美学模型应预测偏好分布；单一技术指标不能替代人工审美。 |
| PAPER-IQA-02 | [MUSIQ, 2021](https://arxiv.org/abs/2108.06858) | 无参考画质评价可提供感知质量信号，但仍需数据集适配和人工校准。 |

## 来源边界

- Adobe 的工作流概念用于划分摄影问题，不复制其滑块数值到 Core Image。
- Apple 文档用于确认 API 语义、色彩管理与 Vision 能力边界。
- 论文用于确认算法局限和未来模型路线；当前项目没有这些论文模型时，不宣称已实现。

## 摄影数据集与许可来源

| ID | 来源 | 核查结论 |
|---|---|---|
| DATA-FIVEK-01 | [MIT-Adobe FiveK](https://data.csail.mit.edu/graphics/fivek/) / [Adobe license](https://data.csail.mit.edu/graphics/fivek/legal/LicenseAdobe.txt) / [Adobe-MIT license](https://data.csail.mit.edu/graphics/fivek/legal/LicenseAdobeMIT.txt) | 真实 RAW—五位专家成片配对，但官方两份许可都限制为自身研究且禁止商业优势/报酬用途；小苏相机商业训练禁用。 |
| DATA-UNSPLASH-01 | [Unsplash Dataset](https://unsplash.com/data) / [Dataset Terms](https://github.com/unsplash/datasets/blob/master/TERMS.md) | Lite 允许内部商业机器学习，但数据不可披露、发布、转移或再分发；必须单独接受条款并在仓库外使用。Full 及其模型仅限非商业。普通网页图片许可不能替代 Dataset 的 ML 授权。 |
| DATA-COMMONS-01 | [Commons 复用说明](https://commons.wikimedia.org/wiki/Commons:Reusing_content_outside_Wikimedia) / [MediaWiki imageinfo API](https://www.mediawiki.org/wiki/API:Imageinfo) | 文件逐项开放许可，需逐项保留作者、许可和来源；人物权、商标、隐私等不由版权许可自动解决。当前首批样本通过官方 API 导入且像素不进入 Git。 |
| DATA-OPENIMAGES-01 | [Open Images V7 Licenses](https://storage.googleapis.com/openimages/web/factsfigures_v7.html#licenses) | 注释 CC BY 4.0，图片列为 CC BY 2.0，但官方要求逐图片核实且不保证状态；适合识别/分割研究，不等于专业审美或专家后期数据。 |

具体准入、模型训练状态与逐文件记录见 `PhotographyDataset/licenses/` 和 `PhotographyDataset/manifests/`。

## 本项目参考特征使用边界

- `PhotographyDataset/manifests/*.jsonl` 是逐文件许可与来源事实来源；不能用“Wikimedia Commons”这一站点名称代替逐文件许可。
- 202 张 CC BY-SA 图片保持 `blocked_pending_legal_review`，不会进入 App 参考索引。
- 39 张参考集图片满足初步自动许可分层（PD/CC0/CC BY、允许特征分析/商业参考且未标记可识别人物），但其中 18 张 CC BY 图片当前没有 App 内署名展示且全部仍缺人工法律/内容复核，因此不能原样进入 TestFlight 分发包。
- TestFlight 内部诊断构建采用更保守的 `testflight-internal` 索引：仅包含 21 张 Public Domain/CC0 图片的数值特征；18 张 CC BY 和 202 张 CC BY-SA 图片均被排除。索引仍保持 `productionUseAllowed=false`、`modelTrainingAllowed=false`，不得用于正式算法或训练。
- App 仅包含 42,732 字节的数值特征与来源/许可摘要，不包含 250 张参考图片像素，也不包含要求署名或相同方式共享的图片数据。
- 当前数据都是单张优秀摄影作品，没有同底片专家修图配对和摄影师调整意图；因此只能校准目标关系，不能学习或复制“专家参数”。
