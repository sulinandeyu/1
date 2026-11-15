#!/usr/bin/env python3
"""Generate local V2 evidence for the seven existing phone photographs.

This is deliberately a Windows *projection* of the public Core Image maths.  It
does not claim Vision, Core Image, or iPhone parity.  No target/reference image
is read and no scene name selects parameters.  The same measurement functions
and three intent bases are applied to every input.
"""

from __future__ import annotations

import hashlib
import html
import json
import math
import shutil
import sys
import types
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "PhotographyInverseSolver"))
# The existing OpenCV-only diagnostic venv intentionally has no SciPy/Pillow.
# The imported renderer uses neither in this projection path, but its research
# module imports both for optimization/report helpers. Reuse the already
# installed Pillow package and provide an explicit non-callable SciPy stub so
# this script never silently starts an optimizer.
sys.path.append(str(ROOT / "tmp" / "learning_training_env" / "Lib" / "site-packages"))
if "scipy.optimize" not in sys.modules:
    scipy_module = types.ModuleType("scipy")
    optimize_module = types.ModuleType("scipy.optimize")
    def _optimizer_not_available(*_args, **_kwargs):
        raise RuntimeError("SciPy optimizer is intentionally unavailable in the V2 projection")
    optimize_module.least_squares = _optimizer_not_available
    scipy_module.optimize = optimize_module
    sys.modules["scipy"] = scipy_module
    sys.modules["scipy.optimize"] = optimize_module

from inverse_solver import (  # noqa: E402
    GLOBAL_NEUTRAL,
    LOCAL_NEUTRAL,
    apply_local_controls,
    apply_measured_cool_cinematic_grade,
    render_global,
)

MANIFEST = ROOT / "output" / "auto_enhancement_benchmark_v1" / "input_manifest.json"
OUTPUT = ROOT / "output" / "automatic_photography_director_v2"
BASES = (
    ("V2-1", "自然纪实"),
    ("V2-2", "空间层次"),
    ("V2-3", "氛围电影"),
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_rgb(path: Path) -> np.ndarray:
    data = np.fromfile(str(path), np.uint8)
    bgr = cv2.imdecode(data, cv2.IMREAD_COLOR)
    if bgr is None:
        raise RuntimeError(f"cannot decode {path}")
    return cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0


def write_rgb(path: Path, rgb: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    bgr = cv2.cvtColor(np.clip(rgb * 255.0 + 0.5, 0, 255).astype(np.uint8), cv2.COLOR_RGB2BGR)
    ok, encoded = cv2.imencode(".jpg", bgr, [cv2.IMWRITE_JPEG_QUALITY, 95])
    if not ok:
        raise RuntimeError(f"cannot encode {path}")
    encoded.tofile(str(path))


def luma(rgb: np.ndarray) -> np.ndarray:
    return np.sum(rgb * np.array([0.2126, 0.7152, 0.0722], np.float32), axis=-1)


def soft_mask(binary: np.ndarray, sigma: float) -> np.ndarray:
    value = binary.astype(np.float32)
    if value.max() <= 0:
        return value
    kernel = np.ones((5, 5), np.uint8)
    value = cv2.morphologyEx(value, cv2.MORPH_OPEN, kernel)
    value = cv2.morphologyEx(value, cv2.MORPH_CLOSE, kernel)
    return np.clip(cv2.GaussianBlur(value, (0, 0), sigma), 0, 1)


def load_person_mask(path: str | None, shape: tuple[int, int]) -> np.ndarray:
    if not path or not Path(path).exists():
        return np.zeros(shape, np.float32)
    data = np.fromfile(path, np.uint8)
    raw = cv2.imdecode(data, cv2.IMREAD_GRAYSCALE)
    if raw is None:
        return np.zeros(shape, np.float32)
    raw = cv2.resize(raw, (shape[1], shape[0]), interpolation=cv2.INTER_LINEAR)
    return np.clip(raw.astype(np.float32) / 255.0, 0, 1)


def measured_masks(rgb: np.ndarray, person: np.ndarray) -> dict[str, np.ndarray]:
    """Build color/position proxies without claiming semantic identities."""
    height, width = rgb.shape[:2]
    hsv = cv2.cvtColor(rgb.astype(np.float32), cv2.COLOR_RGB2HSV)
    hue, sat, val = hsv[..., 0] / 360.0, hsv[..., 1], hsv[..., 2]
    yy = np.linspace(0, 1, height, dtype=np.float32)[:, None]
    sky = (yy < 0.64) & (val > 0.54) & (sat < 0.34)
    green = (hue > 0.17) & (hue < 0.47) & (sat > 0.13)
    yellow = (hue > 0.085) & (hue < 0.18) & (sat > 0.16)
    vegetation = (green | yellow) & (val > 0.10)
    ground = (yy > 0.34) & ~sky & ~vegetation & (person < 0.12)
    neutral_structure = (sat < 0.20) & (yy > 0.18) & ~sky & (person < 0.12)
    masks = {
        "sky": soft_mask(sky, 3.0),
        "vegetation": soft_mask(vegetation, 2.5),
        "ground": soft_mask(ground, 3.5),
        "architecture": soft_mask(neutral_structure, 2.5),
    }
    # Overlap resolution matches the safety intent: sky/person are protected;
    # architecture is only a low-confidence color/position proxy.
    occupied = np.maximum(masks["sky"], person)
    masks["vegetation"] *= 1 - occupied
    occupied = np.maximum(occupied, masks["vegetation"])
    masks["ground"] *= 1 - occupied
    occupied = np.maximum(occupied, masks["ground"])
    masks["architecture"] *= 1 - occupied
    return masks


def region_stats(rgb: np.ndarray, mask: np.ndarray) -> dict[str, float | None]:
    valid = mask > 0.18
    coverage = float(valid.mean())
    if valid.sum() < 32:
        return {"coverage": coverage, "luminance": None, "saturation": None, "p05": None, "p95": None}
    lum = luma(rgb)[valid]
    hsv = cv2.cvtColor(rgb.astype(np.float32), cv2.COLOR_RGB2HSV)
    return {
        "coverage": coverage,
        "luminance": float(np.average(luma(rgb)[valid], weights=mask[valid])),
        "saturation": float(np.average(hsv[..., 1][valid], weights=mask[valid])),
        "p05": float(np.quantile(lum, 0.05)),
        "p95": float(np.quantile(lum, 0.95)),
    }


def measure(rgb: np.ndarray, masks: dict[str, np.ndarray], person: np.ndarray) -> dict:
    lum = luma(rgb)
    hsv = cv2.cvtColor(rgb.astype(np.float32), cv2.COLOR_RGB2HSV)
    neutral = (hsv[..., 1] < 0.10) & (lum > 0.20) & (lum < 0.92)
    neutral_rgb = rgb[neutral].mean(axis=0) if neutral.any() else np.array([0, 0, 0], np.float32)
    return {
        "luminance": float(lum.mean()),
        "p01": float(np.quantile(lum, 0.01)),
        "p05": float(np.quantile(lum, 0.05)),
        "p50": float(np.quantile(lum, 0.50)),
        "p95": float(np.quantile(lum, 0.95)),
        "p99": float(np.quantile(lum, 0.99)),
        "shadow_ratio": float((lum < 0.08).mean()),
        "highlight_ratio": float((lum > 0.94).mean()),
        "contrast_range": float(np.quantile(lum, 0.95) - np.quantile(lum, 0.05)),
        "saturation": float(hsv[..., 1].mean()),
        "neutral_rgb": [float(x) for x in neutral_rgb],
        "person_coverage": float((person > 0.18).mean()),
        "regions": {name: region_stats(rgb, mask) for name, mask in masks.items()},
    }


def clamp(value: float, lower: float, upper: float) -> float:
    return max(lower, min(upper, value))


def ev(source: float | None, target: float) -> float:
    if source is None or source <= 0.015:
        return 0.0
    return math.log2(max(0.015, target) / source)


@dataclass
class Plan:
    identifier: str
    title: str
    intent: str
    global_params: list[float]
    local_params: list[float]
    grade: dict[str, float]
    targets: dict[str, dict[str, float]]
    protection: list[str]


def make_plan(identifier: str, title: str, metrics: dict, contains_person: bool) -> Plan:
    basis = int(identifier[-1])
    avg = metrics["luminance"]
    shadows, highlights = metrics["shadow_ratio"], metrics["highlight_ratio"]
    contrast_range, saturation = metrics["contrast_range"], metrics["saturation"]
    technical = clamp(0.50 + max(0, shadows - 0.18) * 0.10 - max(0, highlights - 0.08) * 0.14, 0.40, 0.60)
    global_target = technical if basis == 1 else clamp(technical - (0.018 if basis == 2 else (0.035 if avg > 0.46 else 0.005)), 0.36, 0.58)
    params = GLOBAL_NEUTRAL.copy()
    target_mix = global_target * 0.45 + avg * 0.55
    params[0] = clamp(ev(avg, target_mix), -0.24, 0.28)
    flatness = max(0.0, 0.58 - contrast_range)
    params[2] = clamp(1.0 + flatness * 0.17, 1.0, 1.075)
    params[4] = 0.08 if basis == 1 else (0.18 if basis == 2 else 0.25)
    params[5] = -clamp((0.05 if basis == 1 else 0.10) + flatness * 0.10, 0, 0.16)
    params[6] = -clamp((0.015 if basis == 1 else 0.045) + flatness * 0.04, 0, 0.08)
    params[7] = clamp((0.012 if basis == 1 else 0.035) + flatness * 0.05, 0, 0.08)
    params[8] = 0.12 if basis == 3 else 0.06
    params[9] = 0.985 if basis == 3 else 1.0
    params[10] = clamp((0.975 if basis == 3 else 1.0) - max(0, saturation - 0.42) * 0.18, 0.96, 1.02)
    if contains_person:
        # The Windows proxy has no Core Image skin-texture processor. Keep its
        # global curve deliberately mild instead of pretending a body mask can
        # protect skin color from an aggressive whole-frame transform.
        params[0] = clamp(params[0], -0.08, 0.10)
        params[2] = min(params[2], 1.025)
        params[4:9] *= np.float32(0.22)
        params[9] = 1.0
        params[10] = 1.0

    color_headroom = clamp((0.46 - saturation) / 0.46, 0, 1)
    separation = color_headroom * (0.12 if basis == 1 else (0.32 if basis == 2 else 0.42))
    veg = metrics["regions"]["vegetation"]
    warm = clamp((veg["coverage"] * 1.8) * color_headroom * (0.18 if basis == 1 else 0.42), 0, 0.22)
    if not contains_person:
        params[15] = clamp(warm * 0.32, 0, 0.12)  # yellow saturation
        params[16] = clamp(warm * 0.08, 0, 0.035)
        params[18] = -clamp(separation * 0.12, 0, 0.055)

    local = LOCAL_NEUTRAL.copy()
    targets: dict[str, dict[str, float]] = {}
    regional_strength = (0.32, 0.68, 0.56 if not contains_person else 0.38)[basis - 1]
    for index, region in enumerate(("ground", "vegetation", "sky", "architecture")):
        source = metrics["regions"][region]["luminance"]
        if source is None:
            continue
        relation = source - avg
        desired = global_target + relation * (1 - regional_strength * 0.42)
        if basis == 2 and region == "ground" and source > avg + 0.035:
            desired -= min(0.10, (source - avg) * 0.42)
        if basis == 3 and region in {"ground", "architecture"}:
            desired -= min(0.075, source * 0.09)
        if basis == 3 and region == "sky":
            desired = min(desired, max(global_target + 0.16, 0.65))
        desired = clamp(desired, 0.16, 0.88)
        local[index * 3] = clamp(ev(source, desired), -0.52, 0.30)
        local[index * 3 + 1] = clamp(1.0 + max(0, 0.57 - contrast_range) * (0.04 if basis == 1 else 0.12), 1.0, 1.10)
        local[index * 3 + 2] = 1.0 if basis == 1 else (0.985 if basis == 2 else 0.965)
        targets[region] = {"source_luminance": source, "target_luminance": desired}

    grade = {
        "intensity": 0.0,
        "shadow_cool": 0.0,
        "midtone_cool": 0.0,
        "highlight_warm": 0.0,
        "neutral_highlight_protection": 0.78,
        "color_contrast": 0.0,
    }
    if basis == 3 and not contains_person:
        grade.update({
            "intensity": clamp(separation * 0.28, 0, 0.09),
            "shadow_cool": clamp(separation * 0.22, 0, 0.075),
            "midtone_cool": clamp(separation * 0.12, 0, 0.04),
            "highlight_warm": clamp(warm * 0.16, 0, 0.035),
            "color_contrast": clamp(separation * 0.16, 0, 0.055),
        })
    intent = (
        "修正测量到的技术问题并保留现场关系" if basis == 1 else
        "以可靠区域相对亮度建立空间层次" if basis == 2 else
        "以中间调结构、克制冷暖分离与柔和高光形成氛围"
    )
    protection = ["高亮低色度端点", "暗部细节", "未知语义不作对象声明"]
    if contains_person:
        protection += ["人物肤色相对原图", "真实皮肤纹理与五官", "禁用局部人脸调色及电影色彩分级"]
    return Plan(identifier, title, intent, params.tolist(), local.tolist(), grade, targets, protection)


def render(rgb: np.ndarray, plan: Plan, masks: dict[str, np.ndarray]) -> np.ndarray:
    output = render_global(rgb, np.asarray(plan.global_params, np.float32))
    if plan.grade["intensity"] > 0:
        output = apply_measured_cool_cinematic_grade(output, **plan.grade)
    return apply_local_controls(output, np.asarray(plan.local_params, np.float32), masks)


def technical_status(before: dict, after: dict, before_rgb: np.ndarray, after_rgb: np.ndarray, person: np.ndarray) -> tuple[str, list[str]]:
    reasons: list[str] = []
    if after["shadow_ratio"] > before["shadow_ratio"] + 0.055:
        reasons.append("暗部裁切增加超过 5.5%")
    if after["highlight_ratio"] > before["highlight_ratio"] + 0.035:
        reasons.append("高光裁切增加超过 3.5%")
    neutral_before = np.asarray(before["neutral_rgb"])
    neutral_after = np.asarray(after["neutral_rgb"])
    if np.max(np.abs((neutral_after - neutral_after.mean()) - (neutral_before - neutral_before.mean()))) > 0.040:
        reasons.append("中性色通道偏移超过 4%")
    if person.max() > 0.18:
        valid = person > 0.35
        person_delta = float(np.mean(np.abs(after_rgb[valid] - before_rgb[valid]))) if valid.any() else 0.0
        if person_delta > 0.075:
            reasons.append(f"人物区域平均变化 {person_delta:.3f} 超过诊断保护线")
        if valid.any():
            before_opponent = before_rgb[valid] - before_rgb[valid].mean(axis=1, keepdims=True)
            after_opponent = after_rgb[valid] - after_rgb[valid].mean(axis=1, keepdims=True)
            chroma_shift = float(np.mean(np.abs(after_opponent - before_opponent)))
            if chroma_shift > 0.025:
                reasons.append(f"人物区域综合色度漂移 {chroma_shift:.3f} 超过诊断保护线")
    return ("rejected" if reasons else "passed", reasons)


def provisional_score(before: dict, after: dict, plan: Plan) -> float:
    clipping = max(0, after["shadow_ratio"] - before["shadow_ratio"]) + max(0, after["highlight_ratio"] - before["highlight_ratio"])
    target_error = []
    for region, target in plan.targets.items():
        measured = after["regions"].get(region, {}).get("luminance")
        if measured is not None:
            target_error.append(abs(measured - target["target_luminance"]))
    alignment = 1.0 - min(1.0, (sum(target_error) / max(1, len(target_error))) * 3.0)
    return alignment - clipping * 2.5


def contact_sheet(scene_outputs: list[tuple[str, Path]], destination: Path) -> None:
    thumbs = []
    for label, path in scene_outputs:
        image = read_rgb(path)
        scale = min(500 / image.shape[1], 500 / image.shape[0], 1.0)
        resized = cv2.resize(image, (max(1, int(image.shape[1] * scale)), max(1, int(image.shape[0] * scale))), interpolation=cv2.INTER_AREA)
        canvas = np.full((560, 520, 3), 17, np.uint8)
        x = (520 - resized.shape[1]) // 2
        y = 42 + (500 - resized.shape[0]) // 2
        canvas[y:y + resized.shape[0], x:x + resized.shape[1]] = np.clip(resized * 255 + 0.5, 0, 255).astype(np.uint8)
        # OpenCV's built-in font cannot reliably draw Chinese. Candidate IDs
        # remain visible; the full localized titles live in evidence.json.
        cv2.putText(canvas, label.encode("ascii", "ignore").decode()[:48], (16, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 1, cv2.LINE_AA)
        thumbs.append(canvas.astype(np.float32) / 255.0)
    cols = 3
    rows = math.ceil(len(thumbs) / cols)
    sheet = np.full((rows * 560, cols * 520, 3), 0.02, np.float32)
    for index, thumb in enumerate(thumbs):
        y = (index // cols) * 560
        x = (index % cols) * 520
        sheet[y:y + 560, x:x + 520] = thumb
    write_rgb(destination, sheet)


def write_blind_page(records: list[dict]) -> None:
    cards = []
    for record in records:
        scene = html.escape(record["scene_id"])
        options = []
        for candidate in record["blind_order"]:
            path = f"{scene}/{candidate['file']}"
            options.append(f'<label class="option"><img src="{path}" alt="候选"><input type="radio" name="{scene}" value="{candidate["id"]}">选择这张</label>')
        options.append(f'<label><input type="radio" name="{scene}" value="all_bad">全部不好</label>')
        options.append(f'<label><input type="radio" name="{scene}" value="no_difference">差异不明显</label>')
        cards.append(f'<section data-scene="{scene}"><h2>{html.escape(record["label"])}</h2><div class="grid">{"".join(options[:-2])}</div>{"".join(options[-2:])}</section>')
    page = f"""<!doctype html><meta charset="utf-8"><title>V2 本地盲评</title>
<style>body{{font-family:system-ui;background:#111;color:#eee;margin:24px}}section{{margin:32px 0;padding:18px;background:#1b1b1b;border-radius:14px}}.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:14px}}.option img{{width:100%;max-height:480px;object-fit:contain;background:#000}}label{{display:block;padding:8px}}button{{padding:14px 24px}}</style>
<h1>Automatic Photography Director V2 — 本地盲评</h1><p>这些图片是 Windows 数学投影，不是 Apple Core Image 或 iPhone 验收。页面不会自动填写任何偏好。</p>{''.join(cards)}
<button onclick="download()">导出人工选择 JSON</button><script>
function download(){{const result={{created_at:new Date().toISOString(),source:'human_manual_review',votes:{{}}}};document.querySelectorAll('section').forEach(s=>{{const x=s.querySelector('input:checked');result.votes[s.dataset.scene]=x?x.value:null;}});const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([JSON.stringify(result,null,2)],{{type:'application/json'}}));a.download='v2-human-preferences.json';a.click();}}
</script>"""
    (OUTPUT / "blind-compare.html").write_text(page, encoding="utf-8")


def write_comparison_page(records: list[dict]) -> None:
    sections = []
    for record in records:
        images = "".join(
            f'<figure><img src="{html.escape(record["scene_id"] + "/" + item["file"])}"><figcaption>{html.escape(item["label"])}</figcaption></figure>'
            for item in record["comparison"]
        )
        sections.append(
            f'<section><h2>{html.escape(record["label"])}</h2><p>候选生成判定：{html.escape(record["generation_status"])}</p><div class="grid">{images}</div></section>'
        )
    page = f"""<!doctype html><meta charset="utf-8"><title>V2 七图对照</title>
<style>body{{font-family:system-ui;background:#101010;color:#eee;margin:24px}}section{{margin:28px 0;padding:18px;background:#191919;border-radius:14px}}.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:14px}}figure{{margin:0;background:#090909;padding:8px}}img{{width:100%;height:460px;object-fit:contain}}figcaption{{padding:8px 2px}}</style>
<h1>Automatic Photography Director V2 — 七图本地对照</h1><p>所有 V2 图片均为本轮从原图重新计算的 Windows 数学投影，不是 Apple Core Image/iPhone 证据。OLD 若存在，仅是历史版本，不冒充当前正式 B。</p>{''.join(sections)}"""
    (OUTPUT / "comparison.html").write_text(page, encoding="utf-8")


def main() -> int:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    OUTPUT.mkdir(parents=True)
    records = []
    all_images: list[tuple[str, Path]] = []
    for item in manifest["images"]:
        scene_id = item["scene_id"]
        scene_dir = OUTPUT / scene_id
        source_path = Path(item["source_path"])
        rgb = read_rgb(source_path)
        person = load_person_mask(item.get("person_mask"), rgb.shape[:2])
        masks = measured_masks(rgb, person)
        before = measure(rgb, masks, person)
        original_path = scene_dir / "A_original.jpg"
        write_rgb(original_path, rgb)
        evidence = {
            "scene_id": scene_id,
            "label": item["label"],
            "source_path": str(source_path),
            "source_sha256": sha256(source_path),
            "evidence_kind": "windows_projection_not_core_image",
            "input_measurements": before,
            "candidates": [],
        }
        scene_images = [("A 原图", original_path)]
        comparison = [{"label": "A 原图", "file": original_path.name}]
        baseline = item.get("baseline")
        if baseline and baseline.get("normalized_path") and Path(baseline["normalized_path"]).exists():
            historical_path = scene_dir / "OLD_historical_not_current_B.jpg"
            shutil.copyfile(baseline["normalized_path"], historical_path)
            scene_images.append(("OLD historical", historical_path))
            comparison.append({"label": "OLD 历史输出（不是当前 B）", "file": historical_path.name})
        plans = [make_plan(identifier, title, before, before["person_coverage"] > 0.01) for identifier, title in BASES]
        eligible = []
        rendered_arrays: dict[str, np.ndarray] = {}
        for plan in plans:
            candidate = render(rgb, plan, masks)
            after = measure(candidate, masks, person)
            status, reasons = technical_status(before, after, rgb, candidate, person)
            path = scene_dir / f"{plan.identifier}.jpg"
            write_rgb(path, candidate)
            score = provisional_score(before, after, plan)
            record = {
                "identifier": plan.identifier,
                "title": plan.title,
                "status": status,
                "reasons": reasons,
                "plan": asdict(plan),
                "output_measurements": after,
                "rgb_mae_from_original": float(np.mean(np.abs(candidate - rgb))),
                "changed_pixel_ratio_2pct": float((np.max(np.abs(candidate - rgb), axis=-1) > 0.02).mean()),
                "provisional_engineering_score": score,
                "human_aesthetic_status": "pending_human_review",
                "file": path.name,
            }
            evidence["candidates"].append(record)
            rendered_arrays[plan.identifier] = candidate
            scene_images.append((f"{plan.identifier} {plan.title} [{status}]", path))
            comparison.append({"label": f"{plan.identifier} {plan.title} [{status}]", "file": path.name})
            if status == "passed":
                eligible.append((score, plan.identifier, path))
        pairwise = {}
        for left_index, (left_id, left_rgb) in enumerate(rendered_arrays.items()):
            for right_id, right_rgb in list(rendered_arrays.items())[left_index + 1:]:
                pairwise[f"{left_id}_vs_{right_id}"] = float(np.mean(np.abs(left_rgb - right_rgb)))
        evidence["candidate_pairwise_rgb_mae"] = pairwise
        minimum_pairwise = min(pairwise.values(), default=0.0)
        evidence["candidate_generation_status"] = (
            "generated_distinct_candidates" if minimum_pairwise >= 0.012
            else "candidate_generation_failed_difference_too_small"
        )
        selected = max(eligible, default=None)
        if selected:
            auto_path = scene_dir / "V2_AUTO_provisional.jpg"
            shutil.copyfile(selected[2], auto_path)
            evidence["auto"] = {"identifier": selected[1], "provisional": True, "file": auto_path.name, "human_aesthetic_status": "pending_human_review"}
            scene_images.append((f"V2-AUTO 暂定 {selected[1]}", auto_path))
            comparison.append({"label": f"V2-AUTO 暂定 {selected[1]}", "file": auto_path.name})
        else:
            evidence["auto"] = {"identifier": None, "provisional": True, "status": "no_safe_candidate"}
        # Persist proxy masks for traceability. They are not claimed as Vision masks.
        mask_dir = scene_dir / "masks"
        mask_dir.mkdir(parents=True, exist_ok=True)
        for name, mask in masks.items():
            cv2.imencode(".png", np.clip(mask * 255, 0, 255).astype(np.uint8))[1].tofile(str(mask_dir / f"{name}_proxy.png"))
        if person.max() > 0:
            cv2.imencode(".png", np.clip(person * 255, 0, 255).astype(np.uint8))[1].tofile(str(mask_dir / "person_existing.png"))
        (scene_dir / "evidence.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8")
        contact_sheet(scene_images, scene_dir / "comparison.jpg")
        all_images.append((item["label"], scene_dir / "comparison.jpg"))
        blind = [{"id": x["identifier"], "file": x["file"]} for x in evidence["candidates"]]
        # Deterministic order independent of engine score; still concealed in UI.
        blind.sort(key=lambda x: hashlib.sha256(f"{scene_id}:{x['id']}".encode()).hexdigest())
        records.append({
            "scene_id": scene_id,
            "label": item["label"],
            "blind_order": blind,
            "auto": evidence["auto"],
            "generation_status": evidence["candidate_generation_status"],
            "comparison": comparison,
        })
    contact_sheet(all_images, OUTPUT / "ALL_SCENES_CONTACT_SHEET.jpg")
    (OUTPUT / "manifest.json").write_text(json.dumps({
        "created_at": datetime.now(timezone.utc).isoformat(),
        "warning": "Windows projection only; not Core Image, Vision or iPhone evidence.",
        "source_manifest": str(MANIFEST),
        "scenes": records,
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    write_blind_page(records)
    write_comparison_page(records)
    print(OUTPUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
