# 真实失败照片回归清单

这些文件是已有真实输入/旧版成片，不是本阶段新 Core Image 输出。它们用于下一次 iPhone 构建后的同图回归，不能被标记为本次视觉验收通过。

| 案例 | 原图 | 旧成片 | 核心回归目标 |
|---|---|---|---|
| 人物自拍 | `TestPhotos/V8_2_FourScenes/A_selfie_original.jpg` | `A_selfie_v81.jpg` | 肤色不偏橙红；白衣和灰衣不染黄/绿；脸部结构与纹理不变。 |
| 阴天建筑 | `TestPhotos/V8_2_FourScenes/B_building_original.jpg` | `B_building_v81.jpg` | 灰白天空不青蓝化；建筑白/灰表面中性；高光不过曝。 |
| 人物与白色车辆 | `TestPhotos/V8_2_FourScenes/C_vehicle_person_original.jpg` | `C_vehicle_person_v81.jpg` | 白车不偏黄绿；人物肤色与黑衣不被全局白平衡污染。 |
| 阴天树木 | `TestPhotos/V8_2_FourScenes/D_trees_original.jpg` | `D_trees_v81.jpg` | 天空保持阴天氛围；植被不荧光；黑位有锚点但不堵塞。 |
| 柿子树 | `TestPhotos/V8_Persimmon/original.jpg` | `v8_build22_ai_edited.jpg` | 橙色主体不得被误当全局暖色偏；白/灰背景和天空不因主体颜色被反向校正。 |

## 每次真机回归必须保存

1. Build 号和同一原始文件哈希。
2. 原图、最终成片和 5 倍差异图。
3. `NeutralColorStatistics`：样本数、覆盖率、空间覆盖、RGB、偏差、置信度、可靠性。
4. temperature/tint 对应的知识规则 ID、输入、目标、实际值和执行状态。
5. Vision 蒙版覆盖率、候选选择、质量回退原因和最终文件标识。
6. 100% 查看下的人物纹理、白色中性、天空色偏、黑位与噪声人工结论。

## 通过标准

- 无可靠中性色证据：temperature/tint 必须为 0 或明确记录其他经验证证据来源；不得使用全图 RGB 均值猜测。
- 有可靠中性色证据：修正方向应使中性色偏差减小；混合光下幅度应更小。
- 人物：不得出现美颜、几何变化、皮肤纹理抹除或明显橙红/黄绿漂移。
- 视觉结论必须由用户在 iPhone 实际成片上确认；Windows 指标仅为辅助。
