# PT-LEARN Apple ORACLE 与首批专业数据闭环

日期：2026-11-28

基线：`835bd78c0ac4073eec4a90d0bc222bfc8036f10a`

适用规则：`PT-LEARN-007`、`PT-TRAIN-004`

## 状态结论

| 项目 | 状态 | 证据 |
|---|---|---|
| Windows ORACLE 接近秋季道路 T | `VERIFIED_OFFLINE` | 全分辨率 RGB MAE `0.0619818`；道路与植被亮度关系由 A 的 `+0.1282` 变为 R 的 `-0.1415`，T 为 `-0.1196` |
| Apple 程序化夹具与 Windows 合同一致性 | `APPLE_CI_PENDING_THIS_CHANGE` | 已增加生产 `CoreImageRenderer.renderManualEdit` 端到端测试；不含私人像素 |
| Apple 真实秋季道路复现 | `IPHONE_RENDER_PENDING` | 已实现内部本机 A/T 入口与证据 ZIP；当前没有获准的新 TestFlight 上传，也没有本会话可控制的真实 iPhone |
| 合格独立专业 A/T | `0` 对 | 现有五对是旧算法/管线 smoke pair，不是独立专业 T |
| A-only 可信训练 | `NOT_READY` | 首批 5 对尚缺 5 对；最低程序实验门槛 20 对且必须按拍摄内容隔离 |
| 未知照片自动调色人工认可 | `PENDING` | ORACLE 使用已知 T，仅证明表达能力，不证明 A-only 预测能力 |

## Apple ORACLE 诊断合同

内部构建入口显示为“PT-LEARN ORACLE：依次选择 A、T”。A 是照片分析、蒙版和渲染的唯一输入；T 在渲染结束后才交给本地 ZIP 导出器。参数顺序固定为：

1. extended-linear sRGB 曝光；
2. encoded-sRGB 总七锚点曲线；
3. encoded-sRGB 独立 RGB 七锚点曲线；
4. perceptual HSL 八色域；
5. 阴影/中间调/高光三段分级；
6. 可靠区域蒙版上的线性曝光、对比与饱和度。

ORACLE 参数不进入正式 B、自动目标选择或训练目标准入。ORACLE 质量失败时保留原参数和失败像素证据，不进行静默安全修正。ZIP 中的 `evidence/PTLEARN_ORACLE_VALIDATION_STATUS.json` 记录 A/T 隔离、参数标识、算子顺序、区域执行、技术质量和人工评价待定状态。

## 数据导入安全边界

`PhotographyDataset/tools/import_authorized_pairs.py` 现在实际执行 Draft 2020-12 JSON Schema，并要求：

- A/T 字节不同且存在超过编码噪声的实际编辑；
- 同源血缘由资产 ID + 编辑历史、RAW sidecar + 导出记录，或拍摄会话 + 人工配准记录核验；结构相关性仅作为辅助错配检查；
- 独立编辑者身份经过核验，逐项记录操作、目的和工具；
- 权利持有人声明与授权核验分离，授权必须由签署合同、签署 release 或有文档的许可支持；
- 文件 SHA-256 和 256-bit 灰度结构指纹共同阻止同一内容重编码后跨 train/validation/test 泄漏；
- ORACLE、旧 B、算法输出和网络参考不得作为独立专业 T。

本地图片、合同和 manifest 均放在 Git 忽略的 `PhotographyDataset/private/`。可提交的模板默认使用 `pending`，因此不会被误计为合格样本。

## 首批五对采集缺口

需要五个独立拍摄内容，优先覆盖自然、街道、建筑、室内和人物。每对都需要用户拥有 A 的训练权，T 是针对该 A 的独立专业后期，并取得商业训练、模型/权重分发和必要隐私/肖像/物业授权。当前没有满足这些条件的 T，未创建虚假样本。

## 真机继续位置

后续只有在获得内部构建上传授权后，才能把本次源码制作成可安装包。在 iPhone 内依次选择本地 A、T，系统会以固定合同生成全分辨率 R-I 并通过系统分享菜单导出 ZIP。产品负责人再比较本地 Windows ORACLE、T 与 Apple R-I，重点检查道路紫灰/中性、白车等中性色、植被暖色和区域对比。该审片结果不能由 CI 色卡代替。
