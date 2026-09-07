# 视频相似度离线实验室

用于自有或已获授权视频的算法鲁棒性研究。工具不会连接直播平台，也不会输出用于重新推流的变换视频。

固定实验项目：

- 水平镜像
- 轻度随机噪声（固定研究预设）
- 低透明度静态覆盖（固定研究预设）
- 低透明度动态覆盖（固定研究预设）

输出内容：

- `similarity_report.html`：可视化实验报告
- `similarity_results.csv`：原始分数
- `preview_grid.png`：首帧变换预览

指标包括 SSIM、pHash、翻转归一 pHash、颜色/边缘视觉向量余弦相似度，以及实际从音轨生成的频谱指纹。这些指标不代表任何平台模型或阈值。

## 构建

```powershell
powershell -ExecutionPolicy Bypass -File tool\video_similarity_lab\build.ps1
```

产物：`dist\video-similarity-lab.exe`
