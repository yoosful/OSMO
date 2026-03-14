#!/usr/bin/env python3
"""Build a stage evidence pack for the nut-pouring report."""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
from pathlib import Path
from typing import Any

import cv2
import numpy as np
from PIL import Image, ImageDraw

try:
    import h5py
except ImportError:
    h5py = None

try:
    import yaml
except ImportError as error:  # pragma: no cover
    raise SystemExit("PyYAML is required. Install with: pip install pyyaml") from error


def resolve_path(path_value: str | None, manifest_dir: Path) -> Path | None:
    if not path_value:
        return None
    path = Path(path_value).expanduser()
    if not path.is_absolute():
        path = manifest_dir / path
    return path.resolve()


def copy_if_exists(src: Path | None, dest: Path) -> str | None:
    if src is None or not src.exists():
        return None
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)
    return str(dest)


def read_first_frame(video_path: Path) -> np.ndarray | None:
    capture = cv2.VideoCapture(str(video_path))
    ok, frame = capture.read()
    capture.release()
    if not ok:
        return None
    return cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)


def save_side_by_side(input_image: Path | None, output_image: Path | None, dest: Path, label: str) -> str | None:
    if input_image is None and output_image is None:
        return None
    frames = []
    for image_path in [input_image, output_image]:
        if image_path and image_path.exists():
            frames.append(Image.open(image_path).convert("RGB"))
        else:
            placeholder = Image.new("RGB", (640, 360), color=(20, 27, 45))
            draw = ImageDraw.Draw(placeholder)
            draw.text((20, 20), "missing asset", fill=(245, 247, 250))
            frames.append(placeholder)
    width = max(frame.width for frame in frames)
    height = max(frame.height for frame in frames)
    canvas = Image.new("RGB", (width * 2, height + 40), color=(20, 27, 45))
    titles = ["input", "output"]
    for index, frame in enumerate(frames):
        resized = frame.resize((width, height))
        canvas.paste(resized, (index * width, 40))
        draw = ImageDraw.Draw(canvas)
        draw.text((index * width + 10, 10), f"{label} {titles[index]}", fill=(245, 247, 250))
    dest.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(dest)
    return str(dest)


def summarize_hdf5(path: Path) -> dict[str, Any]:
    if h5py is None or not path.exists():
        return {}
    with h5py.File(path, "r") as handle:
        data_group = handle.get("data")
        if data_group is None:
            return {"datasets": list(handle.keys())[:25]}
        demo_names = [key for key in data_group.keys() if key.startswith("demo_")]
        summary: dict[str, Any] = {"demo_count": len(demo_names), "sample_demos": demo_names[:3]}
        if demo_names:
            obs_group = data_group[demo_names[0]].get("obs")
            if obs_group is not None:
                summary["obs_keys"] = list(obs_group.keys())[:20]
        return summary


def collect(manifest_path: Path, output_dir: Path) -> Path:
    manifest = yaml.safe_load(manifest_path.read_text(encoding="utf-8"))
    manifest_dir = manifest_path.parent
    output_dir.mkdir(parents=True, exist_ok=True)
    evidence: dict[str, Any] = {
        "title": manifest["report_title"],
        "artifact_pack_dir": str(output_dir),
        "instances": manifest["instances"],
        "stages": [],
    }

    for raw_stage in manifest["stages"]:
        stage_dir = output_dir / f"step_{raw_stage['number']}_{raw_stage['workflow']}"
        stage_dir.mkdir(parents=True, exist_ok=True)
        stage_record: dict[str, Any] = {
            "number": raw_stage["number"],
            "title": raw_stage["title"],
            "workflow": raw_stage["workflow"],
            "status": raw_stage.get("status", "COMPLETED"),
            "samples": [],
        }
        for index, pair in enumerate(raw_stage.get("sample_pairs", []), start=1):
            input_image = resolve_path(pair["input"].get("image"), manifest_dir)
            output_image = resolve_path(pair["output"].get("image"), manifest_dir)
            input_video = resolve_path(pair["input"].get("video"), manifest_dir)
            output_video = resolve_path(pair["output"].get("video"), manifest_dir)
            input_hdf5 = resolve_path(pair["input"].get("hdf5"), manifest_dir)
            output_hdf5 = resolve_path(pair["output"].get("hdf5"), manifest_dir)
            sample_dir = stage_dir / f"sample_{index:02d}"
            sample_dir.mkdir(exist_ok=True)
            copied_input_image = copy_if_exists(input_image, sample_dir / "input.png")
            copied_output_image = copy_if_exists(output_image, sample_dir / "output.png")
            copied_input_video = copy_if_exists(input_video, sample_dir / "input.mp4")
            copied_output_video = copy_if_exists(output_video, sample_dir / "output.mp4")
            if input_image is None and input_video is not None and input_video.exists():
                frame = read_first_frame(input_video)
                if frame is not None:
                    Image.fromarray(frame).save(sample_dir / "input.png")
                    copied_input_image = str((sample_dir / "input.png").resolve())
            if output_image is None and output_video is not None and output_video.exists():
                frame = read_first_frame(output_video)
                if frame is not None:
                    Image.fromarray(frame).save(sample_dir / "output.png")
                    copied_output_image = str((sample_dir / "output.png").resolve())
            comparison = save_side_by_side(
                Path(copied_input_image) if copied_input_image else None,
                Path(copied_output_image) if copied_output_image else None,
                sample_dir / "comparison.png",
                pair["input"]["label"],
            )
            stage_record["samples"].append(
                {
                    "label": pair["input"]["label"],
                    "input_artifact": pair["input"]["artifact"],
                    "output_artifact": pair["output"]["artifact"],
                    "input_image": copied_input_image,
                    "output_image": copied_output_image,
                    "input_video": copied_input_video,
                    "output_video": copied_output_video,
                    "comparison_image": comparison,
                    "input_hdf5_summary": summarize_hdf5(input_hdf5) if input_hdf5 else {},
                    "output_hdf5_summary": summarize_hdf5(output_hdf5) if output_hdf5 else {},
                }
            )
        evidence["stages"].append(stage_record)

    output_manifest = output_dir / "evidence_manifest.json"
    output_manifest.write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    return output_manifest


def main():
    parser = argparse.ArgumentParser(description="Collect nut-pouring evidence assets")
    parser.add_argument("-m", "--manifest", required=True, help="Input report manifest YAML")
    parser.add_argument("-o", "--output-dir", required=True, help="Output artifact-pack directory")
    args = parser.parse_args()
    output_manifest = collect(Path(args.manifest).expanduser().resolve(), Path(args.output_dir).expanduser().resolve())
    print(f"Evidence pack written to: {output_manifest.parent}")
    print(f"Manifest: {output_manifest}")


if __name__ == "__main__":
    main()
