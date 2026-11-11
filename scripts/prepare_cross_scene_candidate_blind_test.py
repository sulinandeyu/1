#!/usr/bin/env python3
"""Prepare a direct-open seven-photo blind session from real iOS evidence.

This script never renders or invents a candidate. It verifies source SHA-256,
finds matching XiaoSuCamera diagnostic ZIPs, extracts only true D/E1/E2 images,
preserves their technical states, and writes one self-contained HTML file.
Missing Core Image outputs remain explicit instead of being replaced with old
or Windows-generated images.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import html
import json
import shutil
import zipfile
from pathlib import Path
from typing import Any

from audit_cross_scene_preference_validation import metrics

ROOT = Path(__file__).resolve().parents[1]
SPLIT = ROOT / "PhoneValidationDataset" / "cross_scene_split.json"
DEFAULT_OUTPUT = ROOT / "output" / "cross_scene_candidate_blind_test"
EXPECTED = {
    "D": "images/D_automatic_diagnostic.jpg",
    "E1": "images/E1_spatial_emphasis.jpg",
    "E2": "images/E2_restrained_depth.jpg",
}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def resolve(relative: str) -> Path:
    return (SPLIT.parent / relative).resolve()


def data_url(data: bytes, suffix: str = ".jpg") -> str:
    mime = "image/png" if suffix.lower() == ".png" else "image/jpeg"
    return f"data:{mime};base64,{base64.b64encode(data).decode('ascii')}"


def zip_records(search_roots: list[Path]) -> dict[str, list[Path]]:
    matches: dict[str, list[Path]] = {}
    visited: set[Path] = set()
    for root in search_roots:
        if not root.exists():
            continue
        for archive in root.rglob("XiaoSuCamera_Diagnostic_*.zip"):
            archive = archive.resolve()
            if archive in visited:
                continue
            visited.add(archive)
            try:
                with zipfile.ZipFile(archive) as bundle:
                    manifest = json.loads(bundle.read("manifest.json"))
                source_hash = str(manifest.get("sourceSha256", "")).lower()
                if source_hash:
                    matches.setdefault(source_hash, []).append(archive)
            except (KeyError, OSError, ValueError, zipfile.BadZipFile, json.JSONDecodeError):
                continue
    for archives in matches.values():
        archives.sort(key=lambda item: item.stat().st_mtime, reverse=True)
    return matches


def technical_status(record: dict[str, Any] | None) -> str:
    if not record:
        return "unknown"
    text = str(record.get("qualityStatus") or "").lower()
    states = {str(item).lower() for item in record.get("states", [])}
    if "rejected" in states or "failed" in text:
        return "failed"
    if "warning" in text:
        return "warning"
    if "passed" in text:
        return "passed"
    return "unknown"


def read_bundle(archive: Path, source_hash: str) -> dict[str, Any]:
    with zipfile.ZipFile(archive) as bundle:
        manifest = json.loads(bundle.read("manifest.json"))
        if str(manifest.get("sourceSha256", "")).lower() != source_hash:
            raise ValueError("diagnostic source hash mismatch")
        records = json.loads(bundle.read("evidence/candidate_states_and_parameters.json"))
        by_id = {str(item.get("identifier")): item for item in records}
        candidates: list[dict[str, Any]] = []
        for identifier, member in EXPECTED.items():
            record = by_id.get(identifier)
            states = set(record.get("states", [])) if record else set()
            if "executed" not in states or "unavailable" in states or member not in bundle.namelist():
                candidates.append({
                    "id": identifier,
                    "available": False,
                    "technicalStatus": technical_status(record),
                    "record": record,
                })
                continue
            payload = bundle.read(member)
            candidates.append({
                "id": identifier,
                "available": True,
                "technicalStatus": technical_status(record),
                "image": data_url(payload),
                "sha256": hashlib.sha256(payload).hexdigest(),
                "record": record,
                "bytes": payload,
                "member": member,
            })
        return {
            "archive": str(archive),
            "manifest": manifest,
            "candidates": candidates,
        }


def generation_status(candidates: list[dict[str, Any]]) -> str:
    available = [item for item in candidates if item.get("available")]
    if len(available) != 3:
        return "incomplete_render_evidence"
    eligible = [item for item in available if item.get("technicalStatus") in {"passed", "warning"}]
    if not eligible:
        return "candidate_generation_failed_technical"
    return "preference_pending"


def write_case_files(destination: Path, source: Path, bundle: dict[str, Any] | None) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination / "A_original.jpg")
    if not bundle:
        (destination / "MISSING_CANDIDATES.txt").write_text(
            "No matching iPhone diagnostic ZIP was found. D/E1/E2 remain unverified; no substitute image was generated.\n",
            encoding="utf-8",
        )
        return
    for candidate in bundle["candidates"]:
        if candidate.get("available"):
            (destination / f"{candidate['id']}_core_image.jpg").write_bytes(candidate["bytes"])
    evidence = {
        "sourceArchive": bundle["archive"],
        "manifest": bundle["manifest"],
        "candidates": [
            {key: value for key, value in item.items() if key not in {"bytes", "image"}}
            for item in bundle["candidates"]
        ],
    }
    (destination / "candidate_evidence.json").write_text(
        json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8"
    )


def make_html(cases: list[dict[str, Any]]) -> str:
    session = json.dumps(cases, ensure_ascii=False, separators=(",", ":"))
    return f"""<!doctype html>
<html lang=\"zh-CN\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">
<title>小苏相机七图候选生成/选择盲测</title>
<style>:root{{color-scheme:dark;font-family:system-ui;background:#09090b;color:#fafafa}}body{{max-width:1500px;margin:auto;padding:22px}}button,select,input{{padding:10px;border-radius:9px;border:1px solid #444;background:#18181b;color:white}}.meta{{white-space:pre-wrap;color:#cbd5e1}}.grid{{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}}.card{{background:#151518;padding:10px;border-radius:14px}}img{{width:100%;height:54vh;object-fit:contain;background:#050505}}.bad{{color:#fda4af}}.ok{{color:#86efac}}.actions{{display:flex;gap:8px;flex-wrap:wrap;margin:16px 0}}@media(max-width:900px){{.grid{{grid-template-columns:1fr}}img{{height:45vh}}}}</style></head>
<body><h1>小苏相机七图候选生成/选择盲测</h1><p>页面直接包含本地原图和已找到的真实 iPhone Core Image 候选。缺图不会以 Windows 图或旧版成片替代。技术通过不等于好看。</p>
<label>案例 <select id=\"caseSelect\"></select></label><div id=\"meta\" class=\"meta\"></div><h2>A 原图</h2><div class=\"card\"><img id=\"original\"></div><h2>盲化候选</h2><div id=\"candidates\" class=\"grid\"></div>
<div class=\"actions\"><button data-choice=\"first\">第一张最好</button><button data-choice=\"second\">第二张最好</button><button data-choice=\"third\">第三张最好</button><button data-choice=\"all_bad\">全部不好</button><button data-choice=\"difference_not_obvious\">差异不明显</button><button id=\"export\">导出评价 JSON</button></div>
<label>问题 <input id=\"issues\" size=\"80\" placeholder=\"偏色、暗部损伤、肤色异常、表达过弱等\"></label><p id=\"status\"></p>
<script>const cases={session};const $=id=>document.getElementById(id);let current=null,order=[];const results=JSON.parse(localStorage.getItem('xiaosu-seven-case-preference-v1')||'[]');
function shuffle(a){{a=[...a];for(let i=a.length-1;i>0;i--){{const j=crypto.getRandomValues(new Uint32Array(1))[0]%(i+1);[a[i],a[j]]=[a[j],a[i]]}}return a}}
function render(){{current=cases.find(x=>x.id===$('caseSelect').value);$('original').src=current.originalImage;const available=current.candidates.filter(x=>x.available&&x.technicalStatus!=='failed');order=shuffle(available);$('candidates').innerHTML='';if(order.length!==3){{$('candidates').innerHTML='<p class=\"bad\">缺少三个技术可评价的真实 Core Image 候选，当前不能进行生成/选择盲测。</p>';}}else{{order.forEach((c,i)=>{{const el=document.createElement('div');el.className='card';el.innerHTML=`<h3>候选 ${{i+1}}</h3><img src=\"${{c.image}}\"><p>技术状态：${{c.technicalStatus}}</p>`;$('candidates').appendChild(el)}})}}$('meta').textContent=`分组：${{current.group}}\nSHA-256：${{current.sha256}}\n生成状态：${{current.generationStatus}}\n自动排序：${{current.automaticRankingResult}}\n证据：${{current.evidenceNote}}`;}}
cases.forEach(c=>{{const o=document.createElement('option');o.value=c.id;o.textContent=`${{c.id}} · ${{c.generationStatus}}`;$('caseSelect').appendChild(o)}});$('caseSelect').onchange=render;render();
document.querySelectorAll('[data-choice]').forEach(b=>b.onclick=()=>{{if(order.length!==3){{$('status').textContent='真实三候选证据不完整，不能记录伪评价。';return}}const choice=b.dataset.choice;const winner=choice==='first'?order[0].id:choice==='second'?order[1].id:choice==='third'?order[2].id:null;const entry={{schemaVersion:1,caseId:current.id,sourceSha256:current.sha256,recordedAt:new Date().toISOString(),blindOrder:order.map(x=>x.id),choice,winner,humanPreferenceStatus:choice==='difference_not_obvious'?'inconclusive':'evaluated',candidateGenerationOutcome:choice==='all_bad'?'candidate_generation_failed':(winner?'human_supported_candidate_available':'preference_pending'),issues:$('issues').value.trim(),source:'direct_open_cross_scene_blind_session'}};results.push(entry);localStorage.setItem('xiaosu-seven-case-preference-v1',JSON.stringify(results));$('status').textContent=`已记录 ${{results.length}} 条；揭盲：${{order.map((x,i)=>`${{i+1}}=${{x.id}}`).join('，')}}`;render()}});
$('export').onclick=()=>{{const blob=new Blob([JSON.stringify({{schemaVersion:1,exportedAt:new Date().toISOString(),results}},null,2)],{{type:'application/json'}}),a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='xiaosu-seven-case-preferences.json';a.click()}};</script></body></html>"""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--diagnostic-root", action="append", type=Path, default=[])
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    split = json.loads(SPLIT.read_text(encoding="utf-8"))
    search_roots = [ROOT / "tmp", ROOT / "PhoneValidationDataset" / "evaluation" / "diagnostic_zips"]
    search_roots.extend(path.resolve() for path in args.diagnostic_root)
    bundles = zip_records(search_roots)
    cases: list[dict[str, Any]] = []
    seen: set[str] = set()
    for group in ("development", "blind"):
        for item in split[group]:
            source = resolve(item["path"])
            actual = digest(source)
            expected = str(item["sha256"]).lower()
            if actual != expected:
                raise SystemExit(f"SHA-256 mismatch for {item['id']}")
            if actual in seen:
                raise SystemExit(f"split leakage for {item['id']}")
            seen.add(actual)
            archive = bundles.get(actual, [None])[0]
            bundle = read_bundle(archive, actual) if archive else None
            candidates = bundle["candidates"] if bundle else [
                {"id": identifier, "available": False, "technicalStatus": "unknown"}
                for identifier in EXPECTED
            ]
            write_case_files(output / "cases" / item["id"], source, bundle)
            cases.append({
                "id": item["id"],
                "group": group,
                "sha256": actual,
                "sceneEvidence": item.get("sceneEvidence", []),
                "originalMetricsWindowsDiagnosticOnly": metrics(source),
                "originalImage": data_url(source.read_bytes(), source.suffix),
                "candidates": [
                    {key: value for key, value in candidate.items() if key not in {"bytes", "record", "member"}}
                    for candidate in candidates
                ],
                "generationStatus": generation_status(candidates),
                "automaticRankingResult": "not_run_for_D_E1_E2_diagnostic_hypotheses",
                "evidenceNote": str(archive) if archive else "No matching diagnostic ZIP; no candidate was fabricated.",
            })
    (output / "index.html").write_text(make_html(cases), encoding="utf-8")
    evidence = {
        "schemaVersion": 1,
        "caseCount": len(cases),
        "realCoreImageThreeCandidateCaseCount": sum(
            case["generationStatus"] != "incomplete_render_evidence" for case in cases
        ),
        "humanPreferenceRecordCount": 0,
        "cases": [
            {key: value for key, value in case.items() if key not in {"originalImage", "candidates"}}
            | {"candidateStates": [
                {key: value for key, value in candidate.items() if key != "image"}
                for candidate in case["candidates"]
            ]}
            for case in cases
        ],
        "claim": "No photographic candidate-generation or selection success is claimed without real Core Image images and human votes.",
    }
    (output / "evidence.json").write_text(
        json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps({
        "output": str(output),
        "cases": len(cases),
        "completeThreeCandidateCases": evidence["realCoreImageThreeCandidateCaseCount"],
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
