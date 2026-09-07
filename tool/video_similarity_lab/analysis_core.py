from __future__ import annotations

import csv
import html
import math
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import cv2
import numpy as np


VARIANTS = (
    ("mirror", "水平镜像"),
    ("noise", "轻度随机噪声（研究预设）"),
    ("static_overlay", "低透明度静态覆盖（研究预设）"),
    ("dynamic_overlay", "低透明度动态覆盖（研究预设）"),
)


@dataclass(frozen=True)
class SimilarityResult:
    key: str
    label: str
    ssim: float
    phash: float
    flip_aware_phash: float
    visual_vector: float
    audio_fingerprint: float | None
    sampled_frames: int


def _resize_for_analysis(frame: np.ndarray, max_width: int = 640) -> np.ndarray:
    height, width = frame.shape[:2]
    if width <= max_width:
        return frame
    scale = max_width / float(width)
    return cv2.resize(
        frame,
        (max_width, max(1, round(height * scale))),
        interpolation=cv2.INTER_AREA,
    )


def apply_variant(frame: np.ndarray, key: str, frame_index: int) -> np.ndarray:
    if key == "mirror":
        return cv2.flip(frame, 1)

    if key == "noise":
        rng = np.random.default_rng(20260903 + frame_index)
        noise = rng.normal(0.0, 4.0, frame.shape).astype(np.float32)
        return np.clip(frame.astype(np.float32) + noise, 0, 255).astype(np.uint8)

    height, width = frame.shape[:2]
    yy, xx = np.mgrid[0:height, 0:width]
    if key == "static_overlay":
        pattern = np.zeros_like(frame)
        pattern[:, :, 0] = ((xx // 28) % 2 * 180 + 40).astype(np.uint8)
        pattern[:, :, 1] = ((yy // 28) % 2 * 120 + 60).astype(np.uint8)
        pattern[:, :, 2] = (((xx + yy) // 40) % 2 * 150 + 50).astype(np.uint8)
        return cv2.addWeighted(frame, 0.96, pattern, 0.04, 0)

    if key == "dynamic_overlay":
        phase = frame_index * 11
        pattern = np.zeros_like(frame)
        pattern[:, :, 0] = ((xx + phase) % 256).astype(np.uint8)
        pattern[:, :, 1] = ((yy * 2 + phase) % 256).astype(np.uint8)
        pattern[:, :, 2] = (((xx + yy) // 2 + phase * 2) % 256).astype(np.uint8)
        return cv2.addWeighted(frame, 0.96, pattern, 0.04, 0)

    raise ValueError(f"unknown variant: {key}")


def ssim_score(left: np.ndarray, right: np.ndarray) -> float:
    a = cv2.cvtColor(left, cv2.COLOR_BGR2GRAY).astype(np.float64)
    b = cv2.cvtColor(right, cv2.COLOR_BGR2GRAY).astype(np.float64)
    c1 = (0.01 * 255) ** 2
    c2 = (0.03 * 255) ** 2
    mu_a = cv2.GaussianBlur(a, (11, 11), 1.5)
    mu_b = cv2.GaussianBlur(b, (11, 11), 1.5)
    sigma_a = cv2.GaussianBlur(a * a, (11, 11), 1.5) - mu_a * mu_a
    sigma_b = cv2.GaussianBlur(b * b, (11, 11), 1.5) - mu_b * mu_b
    sigma_ab = cv2.GaussianBlur(a * b, (11, 11), 1.5) - mu_a * mu_b
    numerator = (2 * mu_a * mu_b + c1) * (2 * sigma_ab + c2)
    denominator = (mu_a * mu_a + mu_b * mu_b + c1) * (
        sigma_a + sigma_b + c2
    )
    score = np.divide(
        numerator,
        denominator,
        out=np.ones_like(numerator),
        where=np.abs(denominator) > 1e-12,
    )
    return float(np.clip(np.mean(score), -1.0, 1.0))


def phash_bits(frame: np.ndarray) -> np.ndarray:
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    small = cv2.resize(gray, (32, 32), interpolation=cv2.INTER_AREA)
    dct = cv2.dct(small.astype(np.float32))[:8, :8]
    values = dct.flatten()[1:]
    return values > np.median(values)


def phash_similarity(left: np.ndarray, right: np.ndarray) -> float:
    a = phash_bits(left)
    b = phash_bits(right)
    return float(1.0 - np.count_nonzero(a != b) / a.size)


def visual_vector(frame: np.ndarray) -> np.ndarray:
    resized = cv2.resize(frame, (160, 90), interpolation=cv2.INTER_AREA)
    hsv = cv2.cvtColor(resized, cv2.COLOR_BGR2HSV)
    gray = cv2.cvtColor(resized, cv2.COLOR_BGR2GRAY)

    hue = cv2.calcHist([hsv], [0], None, [24], [0, 180]).flatten()
    sat = cv2.calcHist([hsv], [1], None, [16], [0, 256]).flatten()
    val = cv2.calcHist([hsv], [2], None, [16], [0, 256]).flatten()
    edges = cv2.Canny(gray, 60, 140)
    edge_grid = []
    for row in np.array_split(edges, 4, axis=0):
        for cell in np.array_split(row, 4, axis=1):
            edge_grid.append(float(np.mean(cell)) / 255.0)

    vector = np.concatenate([hue, sat, val, np.asarray(edge_grid)])
    norm = np.linalg.norm(vector)
    return vector / norm if norm > 1e-12 else vector


def cosine_similarity(left: np.ndarray, right: np.ndarray) -> float:
    denominator = float(np.linalg.norm(left) * np.linalg.norm(right))
    if denominator <= 1e-12:
        return 1.0
    return float(np.clip(np.dot(left, right) / denominator, -1.0, 1.0))


def _preview_grid(original: np.ndarray, variants: dict[str, np.ndarray]) -> np.ndarray:
    cards = [("ORIGINAL", original)]
    labels = {
        "mirror": "MIRROR",
        "noise": "NOISE",
        "static_overlay": "STATIC OVERLAY",
        "dynamic_overlay": "DYNAMIC OVERLAY",
    }
    cards.extend((labels[key], variants[key]) for key, _ in VARIANTS)
    target_width = 360
    rendered: list[np.ndarray] = []
    for label, image in cards:
        scale = target_width / image.shape[1]
        resized = cv2.resize(
            image,
            (target_width, max(1, round(image.shape[0] * scale))),
            interpolation=cv2.INTER_AREA,
        )
        canvas = cv2.copyMakeBorder(
            resized, 34, 4, 4, 4, cv2.BORDER_CONSTANT, value=(32, 35, 42)
        )
        cv2.putText(
            canvas,
            label,
            (12, 24),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.58,
            (240, 240, 240),
            1,
            cv2.LINE_AA,
        )
        rendered.append(canvas)

    blank = np.zeros_like(rendered[0])
    while len(rendered) < 6:
        rendered.append(blank.copy())
    return np.vstack([np.hstack(rendered[:3]), np.hstack(rendered[3:6])])


def analyze_video(
    video_path: str,
    output_dir: str,
    max_seconds: int = 60,
    sample_fps: float = 2.0,
    progress: Callable[[float, str], None] | None = None,
) -> tuple[list[SimilarityResult], dict[str, str]]:
    source = Path(video_path)
    if not source.is_file():
        raise FileNotFoundError(video_path)
    target = Path(output_dir)
    target.mkdir(parents=True, exist_ok=True)

    capture = cv2.VideoCapture(str(source))
    if not capture.isOpened():
        raise ValueError("无法打开视频，请确认格式可由本机 OpenCV/FFmpeg 解码")
    fps = capture.get(cv2.CAP_PROP_FPS)
    if not math.isfinite(fps) or fps <= 0:
        fps = 25.0
    total_frames = int(capture.get(cv2.CAP_PROP_FRAME_COUNT))
    duration = total_frames / fps if total_frames > 0 else float(max_seconds)
    analyzed_seconds = min(float(max_seconds), duration)
    sample_count = max(1, int(math.ceil(analyzed_seconds * sample_fps)))

    accumulators = {
        key: {"ssim": [], "phash": [], "flip": [], "vector": []}
        for key, _ in VARIANTS
    }
    first_original: np.ndarray | None = None
    first_variants: dict[str, np.ndarray] = {}
    sampled = 0

    try:
        for index in range(sample_count):
            timestamp_ms = index * 1000.0 / sample_fps
            capture.set(cv2.CAP_PROP_POS_MSEC, timestamp_ms)
            ok, frame = capture.read()
            if not ok or frame is None:
                break
            frame = _resize_for_analysis(frame)
            base_vector = visual_vector(frame)
            for key, _ in VARIANTS:
                changed = apply_variant(frame, key, index)
                accumulators[key]["ssim"].append(ssim_score(frame, changed))
                accumulators[key]["phash"].append(phash_similarity(frame, changed))
                accumulators[key]["flip"].append(
                    max(
                        phash_similarity(frame, changed),
                        phash_similarity(frame, cv2.flip(changed, 1)),
                    )
                )
                accumulators[key]["vector"].append(
                    cosine_similarity(base_vector, visual_vector(changed))
                )
                if index == 0:
                    first_variants[key] = changed.copy()
            if index == 0:
                first_original = frame.copy()
            sampled += 1
            if progress:
                progress((index + 1) / sample_count, f"正在分析第 {index + 1}/{sample_count} 个采样帧")
    finally:
        capture.release()

    if sampled == 0 or first_original is None:
        raise ValueError("没有从视频中读取到有效画面")

    audio_fingerprint = _audio_fingerprint(str(source), max_seconds)
    audio_similarity = (
        cosine_similarity(audio_fingerprint, audio_fingerprint)
        if audio_fingerprint is not None
        else None
    )
    results = []
    for key, label in VARIANTS:
        values = accumulators[key]
        results.append(
            SimilarityResult(
                key=key,
                label=label,
                ssim=float(np.mean(values["ssim"])),
                phash=float(np.mean(values["phash"])),
                flip_aware_phash=float(np.mean(values["flip"])),
                visual_vector=float(np.mean(values["vector"])),
                audio_fingerprint=audio_similarity,
                sampled_frames=sampled,
            )
        )

    preview_path = target / "preview_grid.png"
    cv2.imwrite(str(preview_path), _preview_grid(first_original, first_variants))
    csv_path = target / "similarity_results.csv"
    _write_csv(csv_path, results)
    html_path = target / "similarity_report.html"
    _write_html(
        html_path,
        source,
        results,
        preview_path.name,
        analyzed_seconds,
        sampled,
        audio_fingerprint is not None,
    )
    return results, {
        "report": str(html_path),
        "csv": str(csv_path),
        "preview": str(preview_path),
    }


def _audio_fingerprint(path: str, max_seconds: int) -> np.ndarray | None:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return None
    try:
        completed = subprocess.run(
            [
                ffmpeg,
                "-v",
                "error",
                "-i",
                path,
                "-t",
                str(max_seconds),
                "-vn",
                "-ac",
                "1",
                "-ar",
                "8000",
                "-f",
                "s16le",
                "pipe:1",
            ],
            capture_output=True,
            timeout=max(20, max_seconds + 10),
            check=True,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        samples = np.frombuffer(completed.stdout, dtype=np.int16).astype(np.float32)
        if samples.size < 2048:
            return None
        samples /= 32768.0
        window_size = 2048
        hop = 1024
        window = np.hanning(window_size).astype(np.float32)
        fingerprints = []
        for start in range(0, samples.size - window_size + 1, hop):
            spectrum = np.abs(np.fft.rfft(samples[start : start + window_size] * window))[1:]
            bands = [float(np.mean(part)) for part in np.array_split(spectrum, 32)]
            fingerprints.append(np.log1p(bands))
        if not fingerprints:
            return None
        vector = np.concatenate(
            [
                np.mean(fingerprints, axis=0),
                np.std(fingerprints, axis=0),
            ]
        ).astype(np.float64)
        norm = np.linalg.norm(vector)
        return vector / norm if norm > 1e-12 else None
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def _write_csv(path: Path, results: list[SimilarityResult]) -> None:
    with path.open("w", newline="", encoding="utf-8-sig") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "实验变换",
                "SSIM",
                "pHash相似度",
                "翻转归一pHash",
                "视觉向量余弦",
                "音频指纹（音频未修改）",
                "采样帧数",
            ]
        )
        for result in results:
            writer.writerow(
                [
                    result.label,
                    f"{result.ssim:.6f}",
                    f"{result.phash:.6f}",
                    f"{result.flip_aware_phash:.6f}",
                    f"{result.visual_vector:.6f}",
                    "N/A"
                    if result.audio_fingerprint is None
                    else f"{result.audio_fingerprint:.6f}",
                    result.sampled_frames,
                ]
            )


def _bar(value: float, color: str) -> str:
    width = max(0.0, min(100.0, value * 100.0))
    return (
        '<div class="bar"><span style="width:'
        f'{width:.1f}%;background:{color}"></span></div>'
        f'<small>{value * 100:.1f}%</small>'
    )


def _write_html(
    path: Path,
    source: Path,
    results: list[SimilarityResult],
    preview_name: str,
    analyzed_seconds: float,
    sampled: int,
    audio_present: bool,
) -> None:
    rows = []
    for result in results:
        audio = "N/A" if result.audio_fingerprint is None else _bar(result.audio_fingerprint, "#7c3aed")
        rows.append(
            "<tr>"
            f"<td>{html.escape(result.label)}</td>"
            f"<td>{_bar(result.ssim, '#2563eb')}</td>"
            f"<td>{_bar(result.phash, '#0891b2')}</td>"
            f"<td>{_bar(result.flip_aware_phash, '#059669')}</td>"
            f"<td>{_bar(result.visual_vector, '#ea580c')}</td>"
            f"<td>{audio}</td>"
            "</tr>"
        )

    document = f"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>视频相似度离线实验报告</title>
<style>
body{{font-family:"Microsoft YaHei UI",sans-serif;background:#f5f7fb;color:#172033;margin:0}}
main{{max-width:1180px;margin:32px auto;padding:0 24px}}
.card{{background:white;border:1px solid #e5e7eb;border-radius:14px;padding:22px;margin:16px 0;box-shadow:0 4px 20px #1720330d}}
h1{{margin:0 0 8px}} .muted{{color:#64748b}} img{{max-width:100%;border-radius:10px}}
table{{width:100%;border-collapse:collapse}} th,td{{padding:12px 9px;border-bottom:1px solid #e5e7eb;text-align:left;vertical-align:middle}}
th{{font-size:13px;color:#475569}} td:first-child{{min-width:190px;font-weight:600}}
.bar{{width:130px;height:9px;background:#e5e7eb;border-radius:20px;overflow:hidden;display:inline-block;margin-right:7px}}
.bar span{{display:block;height:100%;border-radius:20px}} small{{color:#475569}}
.notice{{border-left:4px solid #2563eb;padding:12px 16px;background:#eff6ff}}
</style></head><body><main>
<div class="card"><h1>视频相似度离线实验报告</h1>
<p class="muted">文件：{html.escape(source.name)} ｜ 分析前 {analyzed_seconds:.1f} 秒 ｜ {sampled} 个采样帧</p>
<div class="notice">本报告用于研究相似度算法鲁棒性。分数越高仅表示本工具中的算法认为越相似，不代表任何平台的规则或阈值，也不提供规避建议。</div></div>
<div class="card"><h2>结果</h2><table><thead><tr>
<th>固定实验变换</th><th>SSIM</th><th>pHash</th><th>翻转归一 pHash</th><th>视觉向量</th><th>音频指纹</th>
</tr></thead><tbody>{''.join(rows)}</tbody></table>
<p class="muted">音频列：这些实验只改变抽样画面，不改变原音轨，因此有音频时标记为 100%。这用于说明仅改变画面不会改变声音身份。</p></div>
<div class="card"><h2>首帧预览</h2><img src="{html.escape(preview_name)}" alt="实验预览"></div>
<div class="card"><h2>如何理解</h2><ul>
<li>SSIM 偏向局部像素结构，对镜像等几何变化较敏感。</li>
<li>普通 pHash 比较固定方向；“翻转归一”同时比较反向版本，用于演示检测器做数据增强后的差异。</li>
<li>视觉向量综合颜色直方图和边缘分布，比逐像素比较更能容忍压缩和轻微覆盖。</li>
<li>这些指标不是平台模型，也不能推断平台判定阈值。</li>
</ul></div>
</main></body></html>"""
    path.write_text(document, encoding="utf-8")
