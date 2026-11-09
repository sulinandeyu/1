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
| APPLE-VISION-03 | [Classifying images for categorization and search](https://developer.apple.com/documentation/vision/classifying-images-for-categorization-and-search) | 图像分类返回类别观察结果，不能据此假定存在对象定位、实例关系或摄影审美理解。 |
| APPLE-COREML-01 | [Integrating a Core ML model into your app](https://developer.apple.com/documentation/coreml/integrating-a-core-ml-model-into-your-app) | Core ML 模型必须作为真实资源接入并在目标设备验证输入输出、性能与兼容性；文件名或模型名称不能证明能力。 |
| APPLE-VISION-04 | [VNGenerateForegroundInstanceMaskRequest](https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest) | 前景实例蒙版可提供可选择实例，但必须在目标系统版本和真机上验证实例覆盖、边缘与耗时。 |
| APPLE-COREML-02 | [Using Core ML for semantic image segmentation](https://developer.apple.com/documentation/coreml/using-core-ml-for-semantic-image-segmentation) | 语义分割模型输出像素类别；模型类别集合、输入尺寸和输出映射决定它实际能识别什么，未知类别不能靠颜色补写。 |

## 本地未授权研究素材

| ID | 来源 | 本项目采用的信息 |
|---|---|---|
| TUTORIAL-LOCAL-01 | `D:\MasterCamera\网上教程`（当前 28 张网络教程截图，原发布链接与授权未核验） | 仅作本地研发与审美方向分析。秋季街道包含经 SHA-256 确认的 A/T 副本及同一抖音号公开的 iPhone 原生编辑参数截图；参数只作来源旁证，不直接映射到 Core Image。禁止打包 App、训练、上传第三方或复制为固定预设。逐图记录与反求结果见 `docs/PHOTOGRAPHY_TUTORIAL_ANALYSIS.md`、`docs/PHOTOGRAPHY_PARAMETER_INVERSE_SOLVING.md`。 |

## 公开研究论文

| ID | 来源 | 本项目采用的信息 |
|---|---|---|
| PAPER-CC-01 | [Barron, Convolutional Color Constancy, ICCV 2015](https://openaccess.thecvf.com/content_iccv_2015/html/Barron_Convolutional_Color_Constancy_ICCV_2015_paper.html) | 色恒常是欠约束问题；需要颜色统计与学习证据，不能仅凭全图均值断言照明颜色。 |
| PAPER-CC-02 | [Cheng et al., Effective Learning-Based Illuminant Estimation, CVPR 2015](https://openaccess.thecvf.com/content_cvpr_2015/html/Cheng_Effective_Learning-Based_Illuminant_2015_CVPR_paper.html) | Gray-world/white-patch 等简单假设有失败条件；缺少可靠证据时应保守。 |
| PAPER-CC-03 | [Afifi et al., When Color Constancy Goes Wrong, CVPR 2019](https://openaccess.thecvf.com/content_CVPR_2019/papers/Afifi_When_Color_Constancy_Goes_Wrong_Correcting_Improperly_White-Balanced_Images_CVPR_2019_paper.pdf) | 白平衡校正需要相机/显示域与真实参考数据，错误校正本身会产生明显色偏。 |
| PAPER-IQA-01 | [NIMA, 2017](https://arxiv.org/abs/1709.05424) | 美学模型应预测偏好分布；单一技术指标不能替代人工审美。 |
| PAPER-IQA-02 | [MUSIQ, 2021](https://arxiv.org/abs/2108.06858) | 无参考画质评价可提供感知质量信号，但仍需数据集适配和人工校准。 |
| PAPER-HDRNET-01 | [Deep Bilateral Learning for Real-Time Image Enhancement](https://groups.csail.mit.edu/graphics/hdrnet/) / [Google Research](https://research.google/pubs/deep-bilateral-learning-for-real-time-image-enhancement/) | 由低分辨率输入预测双边空间局部仿射变换，再边缘保持切片到全分辨率；可以学习逐图的局部、全局及内容相关变换，但需要合法输入—目标配对数据。 |

## 学习型模型与实现

| ID | 来源 | 核查结论 |
|---|---|---|
| MODEL-HDRNET-01 | [Google HDRNet 实现](https://github.com/google/hdrnet) | Apache-2.0 代码，仓库已归档；官方实现依赖 Python 2.7、旧 TensorFlow 和自定义 bilateral slicing 算子。代码许可不自动覆盖预训练权重与训练图像。 |
| MODEL-DEEPLPF-01 | [DeepLPF 官方作者实现](https://github.com/sjmoran/deeplpf-image-enhancement) | MIT 代码并提供可运行权重；公开 Adobe DPE 权重训练自 FiveK Expert C，因此本项目仅作本地研究，禁止打包 App/TestFlight 或商业训练。 |
| MODEL-DEEPLAB-01 | [Torchvision DeepLabV3-MobileNetV3](https://docs.pytorch.org/vision/main/models/generated/torchvision.models.segmentation.deeplabv3_mobilenet_v3_large.html) | 11,029,328 参数、42.3 MB，权重在 COCO 子集上训练且只输出 20 个 VOC 类。当前只作 Windows 语义能力探针；权重分发与源图许可未完成产品复核。 |

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
| DATA-DPED-01 | [DPED 官方代码/数据入口](https://github.com/aiff22/DPED) | 提供手机/DSLR 同时拍摄数据与模型代码，但仓库未确认独立 LICENSE 或允许商业训练及权重分发的明确条款；在取得书面许可前禁用。手机与 DSLR 也不是“同一底片专家修图”。 |
| DATA-HDRPLUS-01 | [HDR+ Dataset](https://hdrplusdata.org/dataset.html) | 包含 RAW 连拍、合并 DNG 与 Google 管线 JPEG，站点标记 CC BY-SA；它适合 ISP/影调研究但不是签约摄影师后期目标，ShareAlike、人物隐私和权重分发仍需法律复核。 |
| DATA-PAIRED-REVIEW-01 | `PhotographyDataset/licenses/paired-training-source-review.json` | 本项目逐来源的商业训练与模型分发准入记录。当前确认 5 对同画面旧算法样本、0 对专家样本、0 对产品训练合格样本。 |

具体准入、模型训练状态与逐文件记录见 `PhotographyDataset/licenses/` 和 `PhotographyDataset/manifests/`。

## 本项目参考特征使用边界

- `PhotographyDataset/manifests/*.jsonl` 是逐文件许可与来源事实来源；不能用“Wikimedia Commons”这一站点名称代替逐文件许可。
- 202 张 CC BY-SA 图片保持 `blocked_pending_legal_review`，不会进入 App 参考索引。
- 39 张参考集图片满足初步自动许可分层（PD/CC0/CC BY、允许特征分析/商业参考且未标记可识别人物），但其中 18 张 CC BY 图片当前没有 App 内署名展示且全部仍缺人工法律/内容复核，因此不能原样进入 TestFlight 分发包。
- TestFlight 内部诊断构建采用更保守的 `testflight-internal` 索引：仅包含 21 张 Public Domain/CC0 图片的数值特征；18 张 CC BY 和 202 张 CC BY-SA 图片均被排除。索引仍保持 `productionUseAllowed=false`、`modelTrainingAllowed=false`，不得用于正式算法或训练。
- App 仅包含 42,732 字节的数值特征与来源/许可摘要，不包含 250 张参考图片像素，也不包含要求署名或相同方式共享的图片数据。
- 当前数据都是单张优秀摄影作品，没有同底片专家修图配对和摄影师调整意图；因此只能校准目标关系，不能学习或复制“专家参数”。
