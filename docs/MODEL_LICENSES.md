# 第三方模型与许可

## DETR ResNet-50 Semantic Segmentation (Core ML)

- 项目：`apple/coreml-detr-semantic-segmentation`
- 使用文件：`DETRResnet50SemanticSegmentationF16P6.mlpackage`
- 发布方：Apple（Hugging Face Core ML Gallery）
- 来源：https://huggingface.co/apple/coreml-detr-semantic-segmentation
- 上游模型：`facebook/detr-resnet-50-panoptic`
- 许可：Apache License 2.0
- 用途：离线逐像素场景语义分割；MasterCamera 当前只读取 `sky (other)` 类别生成天空蒙版。

模型文件保持原始 Core ML package 结构。MasterCamera 没有重新训练该模型，也不会把照片上传到模型服务。

Apache License 2.0 全文：https://www.apache.org/licenses/LICENSE-2.0
