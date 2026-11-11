# 小苏相机自有手机原图验证集

该目录只记录用户自行拍摄或明确授权的手机原图，不复制公开参考库，也不把第三方作品伪装成手机随拍验证集。

当前已登记 3 张。像素文件仍保存在 `../真实图片/`，该目录受 `.gitignore` 保护；清单只保存哈希、尺寸、来源声明和测试条件。现有素材覆盖室内、夜景建筑、室内混合光/人物环境；仍缺少 27 张，尤其是纯人物、自然风景、日间建筑、逆光、阴天等独立样本。

验证流程：

1. 在 iPhone 的诊断导入入口选择同一张原图。
2. 记录 A 原图、B 当前正式算法，以及 D/E1/E2 三个由当前照片测量独立求解的诊断候选；C 受许可限制时必须保持 unavailable。
3. 确认诊断页包含目标、参数、局部计划、Core Image 回执、质检结果，以及 `candidate_generation_and_selection.json`。
4. 运行 `python scripts/prepare_cross_scene_candidate_blind_test.py`，直接打开 `output/cross_scene_candidate_blind_test/index.html`；它只接受同源、真实、全分辨率的 D/E1/E2，缺图时拒绝投票。
5. 只有真实人工评价才能写入结果；当前仓库没有预填偏好结论。

Windows 只能校验清单、哈希、原图指标和参数方向，不能生成或替代 iPhone Core Image 成片验收。

可重复运行的清单检查：`./scripts/Test-PhoneValidationDataset.ps1`。它会验证每条记录的文件、SHA-256、尺寸、来源/授权字段，并如实统计尚未完成的 iPhone B/C 导出和人工评价数量。
