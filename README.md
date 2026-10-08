# MasterCamera

MasterCamera 是一款 AI 自动摄影师相机 App 原型。

核心目标：用户只负责构图和按快门，App 自动分析照片、制定摄影后期方案，并同时保留原图和 AI 成片。

当前已完成：

- SwiftUI App 入口
- AVFoundation 相机预览
- 相机权限处理
- 前后摄像头切换
- 静态照片拍摄
- 原图 / AI 成片预览
- 保存原图和 AI 成片到相册
- 本地照片分析：曝光、对比、色偏、人脸
- PhotographerAI 决策层
- Core Image 自动成片
- 人脸区域轻微局部补光
- 成片质量检查
- 失败成片安全回退
- 拍照后处理状态遮罩
- 长按对比原图
- 保存中 / 保存成功 / 保存失败状态
- 成片分析信息默认收起，可手动展开
- 调参配置骨架

当前页面图：

- [相机页](docs/mockups/camera-page.svg)
- [成片预览页](docs/mockups/photo-preview-page.svg)

阶段开发需求见：[docs/DEVELOPMENT_REQUIREMENTS.md](docs/DEVELOPMENT_REQUIREMENTS.md)

整体开发进度见：[docs/PROJECT_STATUS.md](docs/PROJECT_STATUS.md)

编译指南见：[docs/BUILD_ON_MAC.md](docs/BUILD_ON_MAC.md)

没有 Mac 的编译方案见：[docs/NO_MAC_BUILD.md](docs/NO_MAC_BUILD.md)

第一轮真机编译检查清单见：[docs/FIRST_BUILD_CHECKLIST.md](docs/FIRST_BUILD_CHECKLIST.md)

