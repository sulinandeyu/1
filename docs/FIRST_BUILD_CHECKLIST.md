# MasterCamera 第一轮真机编译检查清单

## 目标

第一轮不要追求效果好看，先确认：

- Xcode 工程能打开。
- Swift 能编译。
- App 能安装到 iPhone。
- 相机能打开。
- 能拍照并进入预览页。

## 准备

需要：

- 一台 Mac 或云 Mac。
- Xcode。
- 一台真实 iPhone。
- Apple ID。
- USB 连接线，或同一网络下的无线调试。

## 第一步：复制项目

把整个项目目录复制到 Mac。

当前项目目录：

```text
D:\MasterCamera
```

复制到 Mac 后建议路径：

```text
~/Projects/MasterCamera
```

## 第二步：打开工程

用 Xcode 打开：

```text
MasterCamera.xcodeproj
```

不要只打开某个 Swift 文件。

## 第三步：设置签名

在 Xcode 左侧选择项目：

```text
MasterCamera
```

然后选择 target：

```text
MasterCamera
```

进入：

```text
Signing & Capabilities
```

设置：

- Team：选择你的 Apple ID / Developer Team。
- Bundle Identifier：改成你自己的唯一值。

例如：

```text
com.yourname.mastercamera
```

## 第四步：选择真机

顶部设备选择你的 iPhone。

不要优先用模拟器，因为模拟器不能完整验证相机。

## 第五步：先 Build

先按：

```text
Command + B
```

如果这里报错，先不要运行。

把 Xcode 左侧 Issue Navigator 里的第一批红色错误复制回来。

## 第六步：再 Run

如果 Build 通过，再按：

```text
Command + R
```

第一次运行时重点看：

- 是否弹出相机权限。
- 是否能看到实时取景。
- 是否能切换前后摄。
- 是否能拍照。
- 拍完是否显示处理中。
- 是否进入成片预览页。

## 第七步：拍第一张测试照片

建议第一张拍：

- 室内人像或自拍。
- 光线不要太极端。
- 画面里有人脸。

拍完检查：

- 原图 / AI 成片切换是否正常。
- 长按是否能临时查看原图。
- 信息按钮是否能展开分析信息。
- 保存按钮是否进入“正在保存”。
- 相册里是否出现两张照片。

## 如果编译失败

请把以下内容发回来：

1. Xcode 报错截图，或复制红色错误文本。
2. 报错文件名。
3. 报错行号。
4. Xcode 版本。
5. iPhone iOS 版本。

优先发第一屏错误，不需要一次性发全部日志。

## 第一轮最可能需要修的地方

- Xcode 工程配置。
- Swift 并发隔离。
- Core Image API 名称。
- AVFoundation 照片输出配置。
- Vision 人脸框方向。
- 相册权限分支。

