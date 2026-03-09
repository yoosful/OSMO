#!/usr/bin/env python3
"""Generate a standalone Nut Pouring cookbook reproduction report PPTX."""

from pptx import Presentation
from pptx.util import Inches, Pt
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN
from pptx.enum.shapes import MSO_SHAPE
import argparse
import os

# Theme
BG_DARK = RGBColor(0x14, 0x1B, 0x2D)
BG_MID = RGBColor(0x1E, 0x27, 0x3B)
NVIDIA_GREEN = RGBColor(0x76, 0xB9, 0x00)
TEXT_WHITE = RGBColor(0xF5, 0xF7, 0xFA)
TEXT_GRAY = RGBColor(0xC7, 0xCF, 0xDB)
ACCENT_BLUE = RGBColor(0x4F, 0xB3, 0xFF)
SUCCESS_GREEN = RGBColor(0x29, 0xCC, 0x7A)
WARNING_YELLOW = RGBColor(0xFF, 0xD1, 0x3D)

prs = Presentation()
prs.slide_width = Inches(13.333)
prs.slide_height = Inches(7.5)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
ASSETS_DIR = os.path.join(BASE_DIR, ".report_assets")
INPUT_FRAME = os.path.join(ASSETS_DIR, "input_demo0_rgb_frame.png")
COSMOS_FRAME = os.path.join(ASSETS_DIR, "output_demo0_rgb_frame_upscaled.png")
LEROBOT_FRAME = os.path.join(ASSETS_DIR, "lerobot_episode0_frame.png")
INPUT_VIDEO = os.path.join(ASSETS_DIR, "input_demo0_rgb.mp4")
COSMOS_VIDEO = os.path.join(ASSETS_DIR, "output_demo0_rgb.mp4")
LEROBOT_VIDEO = os.path.join(ASSETS_DIR, "lerobot_episode0.mp4")


def set_slide_bg(slide, color=BG_DARK):
    fill = slide.background.fill
    fill.solid()
    fill.fore_color.rgb = color


def add_text_box(
    slide,
    left,
    top,
    width,
    height,
    text,
    font_size=18,
    color=TEXT_WHITE,
    bold=False,
    alignment=PP_ALIGN.LEFT,
    font_name="Calibri",
):
    box = slide.shapes.add_textbox(Inches(left), Inches(top), Inches(width), Inches(height))
    tf = box.text_frame
    tf.word_wrap = True
    p = tf.paragraphs[0]
    p.text = text
    p.font.size = Pt(font_size)
    p.font.color.rgb = color
    p.font.bold = bold
    p.font.name = font_name
    p.alignment = alignment
    return tf


def add_paragraph(
    tf,
    text,
    font_size=14,
    color=TEXT_WHITE,
    bold=False,
    font_name="Calibri",
    alignment=PP_ALIGN.LEFT,
    space_before=Pt(2),
):
    p = tf.add_paragraph()
    p.text = text
    p.font.size = Pt(font_size)
    p.font.color.rgb = color
    p.font.bold = bold
    p.font.name = font_name
    p.alignment = alignment
    p.space_before = space_before
    return p


def add_panel(slide, left, top, width, height, title):
    shape = slide.shapes.add_shape(
        MSO_SHAPE.ROUNDED_RECTANGLE, Inches(left), Inches(top), Inches(width), Inches(height)
    )
    shape.fill.solid()
    shape.fill.fore_color.rgb = BG_MID
    shape.line.color.rgb = RGBColor(0x2F, 0x3A, 0x55)
    tf = shape.text_frame
    tf.clear()
    p = tf.paragraphs[0]
    p.text = title
    p.font.size = Pt(16)
    p.font.bold = True
    p.font.color.rgb = NVIDIA_GREEN
    p.font.name = "Calibri"
    return shape


def add_image_or_note(slide, image_path, left, top, width, height, note):
    if os.path.exists(image_path):
        slide.shapes.add_picture(image_path, Inches(left), Inches(top), Inches(width), Inches(height))
    else:
        tf = add_text_box(
            slide,
            left,
            top,
            width,
            height,
            note,
            12,
            TEXT_GRAY,
            False,
            PP_ALIGN.LEFT,
            "Consolas",
        )
        tf.vertical_anchor = 1


def add_movie_or_note(slide, movie_path, poster_path, left, top, width, height, note):
    if os.path.exists(movie_path):
        poster = poster_path if os.path.exists(poster_path) else None
        slide.shapes.add_movie(
            movie_path,
            Inches(left),
            Inches(top),
            Inches(width),
            Inches(height),
            poster_frame_image=poster,
            mime_type="video/mp4",
        )
    else:
        add_image_or_note(slide, "", left, top, width, height, note)


def add_footer_line(slide):
    line = slide.shapes.add_shape(
        MSO_SHAPE.RECTANGLE, Inches(0), Inches(7.18), Inches(13.333), Inches(0.05)
    )
    line.fill.solid()
    line.fill.fore_color.rgb = NVIDIA_GREEN
    line.line.fill.background()


def fmt_duration(seconds):
    sec = int(round(float(seconds)))
    minutes, rem = divmod(sec, 60)
    hours, minutes = divmod(minutes, 60)
    if hours > 0:
        return f"{hours}h {minutes}m {rem}s"
    return f"{minutes}m {rem}s"


def fmt_gib(bytes_value):
    return f"{bytes_value / (1024**3):.2f} GiB"


def add_step_slide(
    step_number,
    step_title,
    workflow,
    start_time,
    end_time,
    duration_seconds,
    input_dataset,
    input_example,
    output_dataset,
    output_example,
    details,
    input_image=None,
    output_image=None,
    input_note="",
    output_note="",
):
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    set_slide_bg(slide)

    add_text_box(
        slide,
        0.6,
        0.2,
        12.2,
        0.6,
        f"Step {step_number}: {step_title}",
        30,
        TEXT_WHITE,
        True,
    )

    meta = add_text_box(
        slide,
        0.6,
        0.82,
        12.2,
        0.65,
        f"Workflow: {workflow}   |   Duration: {fmt_duration(duration_seconds)}   |   Status: COMPLETED",
        14,
        ACCENT_BLUE,
        True,
        font_name="Consolas",
    )
    add_paragraph(
        meta,
        f"Run window: {start_time} to {end_time}",
        12,
        TEXT_GRAY,
        False,
        "Consolas",
        space_before=Pt(0),
    )

    add_panel(slide, 0.6, 1.55, 6.1, 3.45, "Input Example")
    add_panel(slide, 6.65, 1.55, 6.1, 3.45, "Output Example")

    input_tf = add_text_box(slide, 0.85, 1.9, 5.6, 1.0, f"Dataset: {input_dataset}", 13, TEXT_WHITE, True)
    add_paragraph(input_tf, f"Artifact: {input_example}", 12, TEXT_GRAY, False, "Consolas")
    add_image_or_note(
        slide,
        input_image if input_image else "",
        0.85,
        2.78,
        5.6,
        1.95,
        input_note if input_note else "No image artifact captured for this input.",
    )

    output_tf = add_text_box(slide, 6.9, 1.9, 5.6, 1.0, f"Dataset: {output_dataset}", 13, TEXT_WHITE, True)
    add_paragraph(output_tf, f"Artifact: {output_example}", 12, TEXT_GRAY, False, "Consolas")
    add_image_or_note(
        slide,
        output_image if output_image else "",
        6.9,
        2.78,
        5.6,
        1.95,
        output_note if output_note else "No image artifact captured for this output.",
    )

    detail_shape = slide.shapes.add_shape(
        MSO_SHAPE.ROUNDED_RECTANGLE, Inches(0.6), Inches(5.15), Inches(12.15), Inches(1.9)
    )
    detail_shape.fill.solid()
    detail_shape.fill.fore_color.rgb = BG_MID
    detail_shape.line.color.rgb = RGBColor(0x2F, 0x3A, 0x55)

    detail_tf = detail_shape.text_frame
    detail_tf.clear()
    p = detail_tf.paragraphs[0]
    p.text = "Run details"
    p.font.size = Pt(16)
    p.font.color.rgb = NVIDIA_GREEN
    p.font.bold = True
    p.font.name = "Calibri"

    for item in details:
        add_paragraph(detail_tf, f"- {item}", 13, TEXT_WHITE)

    add_footer_line(slide)


# Slide 1: Title
slide = prs.slides.add_slide(prs.slide_layouts[6])
set_slide_bg(slide)
add_text_box(slide, 0.8, 0.5, 12, 0.6, "NVIDIA OSMO", 16, NVIDIA_GREEN, True)
add_text_box(slide, 0.8, 1.3, 12, 1.1, "Physical AI Nut Pouring", 44, TEXT_WHITE, True)
add_text_box(slide, 0.8, 2.35, 12, 0.7, "Cookbook Reproduction Report", 34, TEXT_WHITE, True)
meta = add_text_box(
    slide,
    0.8,
    3.35,
    12,
    2.4,
    "Standalone report for full Step 1 to Step 6 execution",
    20,
    TEXT_GRAY,
)
add_paragraph(meta, "Environment: OSMO v6.0.0 on AWS/EKS", 17, TEXT_GRAY)
add_paragraph(meta, "Date: 2026-02-25", 17, TEXT_GRAY)
add_paragraph(meta, "Result: all six steps completed with validated outputs", 19, SUCCESS_GREEN, True)
add_footer_line(slide)


# Slide 2: Scope
slide = prs.slides.add_slide(prs.slide_layouts[6])
set_slide_bg(slide)
add_text_box(slide, 0.8, 0.3, 12, 0.6, "Report Scope", 32, TEXT_WHITE, True)
scope = add_text_box(slide, 0.8, 1.0, 12, 5.9, "This document is a complete standalone execution report.", 20, NVIDIA_GREEN, True)
add_paragraph(scope, "What is covered:", 16, TEXT_WHITE, True)
add_paragraph(scope, "- One end-to-end cookbook execution path for nut_pouring", 15, TEXT_WHITE)
add_paragraph(scope, "- Per-step runtime and workflow IDs", 15, TEXT_WHITE)
add_paragraph(scope, "- Input and output artifact examples for each step", 15, TEXT_WHITE)
add_paragraph(scope, "- Final dataset lineage and cost cleanup status", 15, TEXT_WHITE)
add_paragraph(scope, "Execution note:", 16, TEXT_WHITE, True)
add_paragraph(scope, "- All workflows shown in this report are in COMPLETED state.", 15, SUCCESS_GREEN)
add_paragraph(scope, "- HF gated model access is required for Cosmos and GR00T model pulls.", 15, WARNING_YELLOW)
add_footer_line(slide)


# Slide 3: End-to-end status
slide = prs.slides.add_slide(prs.slide_layouts[6])
set_slide_bg(slide)
add_text_box(slide, 0.8, 0.3, 12, 0.6, "End-to-End Workflow Status", 32, TEXT_WHITE, True)
tf = add_text_box(slide, 0.8, 1.0, 12, 6.1, "Step summary", 18, TEXT_GRAY)
add_paragraph(tf, "Step  Workflow ID                       Duration    Status", 15, NVIDIA_GREEN, True, "Consolas")
add_paragraph(tf, "--------------------------------------------------------------", 13, TEXT_GRAY, False, "Consolas")
rows = [
    ("1", "mimic-gen-nutpour-2", fmt_duration(1558.210012), "COMPLETED"),
    ("2", "hdf5-to-mp4-nutpour-2", fmt_duration(655.071413), "COMPLETED"),
    ("3", "cosmos_transfer_augmentation-23", fmt_duration(889.088467), "COMPLETED"),
    ("4", "mp4_to_hdf5_conversion-6", fmt_duration(117.246848), "COMPLETED"),
    ("5", "dataset_conversion_augmented-3", fmt_duration(201.335118), "COMPLETED"),
    ("6", "groot_finetune_nut_pouring-10", fmt_duration(659.885931), "COMPLETED"),
]
for step, wf, dur, st in rows:
    add_paragraph(tf, f"{step:<5} {wf:<33} {dur:<10} {st}", 14, SUCCESS_GREEN, False, "Consolas")
add_paragraph(tf, "", 8, TEXT_GRAY)
add_paragraph(tf, "Dataset chain:", 16, TEXT_WHITE, True)
add_paragraph(tf, "PhysAI-InputMimic:1 -> PhysAI-MimicGen:1 -> PhysAI-MP4Videos:1", 14, TEXT_WHITE, False, "Consolas")
add_paragraph(tf, "-> PhysAI-CosmosAugmentedMP4:11 -> PhysAI-CosmosAugmentedHDF5:6", 14, TEXT_WHITE, False, "Consolas")
add_paragraph(tf, "-> PhysAI-LeRobotDataset:3 -> PhysAI-GR00T-Finetuned:4", 14, TEXT_WHITE, False, "Consolas")
add_footer_line(slide)


# Step slides
add_step_slide(
    step_number="1",
    step_title="MimicGen Data Generation",
    workflow="mimic-gen-nutpour-2",
    start_time="2026-02-19T15:41:57",
    end_time="2026-02-19T16:07:55",
    duration_seconds=1558.210012,
    input_dataset="PhysAI-InputMimic:1",
    input_example="dataset_annotated_gr1_nut_pouring.hdf5 (60.0 MiB)",
    output_dataset="PhysAI-MimicGen:1",
    output_example="generated_dataset_gr1_nut_pouring.hdf5 (2.35 GiB)",
    details=[
        "Task embodiment: GR1 nut pouring demonstration generation.",
        "Output HDF5 becomes source for video conversion in Step 2.",
        "Run completed without manual retries in this chain.",
    ],
    input_note=(
        "Non-visual artifact (HDF5)\\n\\n"
        "PhysAI-InputMimic:1/\\n"
        "  dataset_annotated_gr1_nut_pouring.hdf5\\n"
        "  size: 62,916,978 B (60.0 MiB)"
    ),
    output_note=(
        "Non-visual artifact (HDF5)\\n\\n"
        "PhysAI-MimicGen:1/\\n"
        "  generated_dataset_gr1_nut_pouring.hdf5\\n"
        "  size: 2,522,203,750 B (2.35 GiB)"
    ),
)

add_step_slide(
    step_number="2",
    step_title="HDF5 to MP4 Conversion",
    workflow="hdf5-to-mp4-nutpour-2",
    start_time="2026-02-19T23:40:02",
    end_time="2026-02-19T23:50:58",
    duration_seconds=655.071413,
    input_dataset="PhysAI-MimicGen:1",
    input_example="generated_dataset_gr1_nut_pouring.hdf5",
    output_dataset="PhysAI-MP4Videos:1",
    output_example="demo_0_robot_pov_cam.mp4 + depth pair",
    details=[
        "Generated MP4 artifacts for each demo and camera stream.",
        "Output naming uses demo_<id>_robot_pov_cam(.mp4/_depth.mp4).",
        "Produced the direct video input set for Cosmos transfer.",
    ],
    output_image=INPUT_FRAME,
    input_note=(
        "Non-visual artifact (HDF5)\\n\\n"
        "PhysAI-MimicGen:1/\\n"
        "  generated_dataset_gr1_nut_pouring.hdf5\\n"
        "  size: 2,522,203,750 B (2.35 GiB)"
    ),
)

add_step_slide(
    step_number="3",
    step_title="Cosmos Transfer Augmentation",
    workflow="cosmos_transfer_augmentation-23",
    start_time="2026-02-22T08:09:40",
    end_time="2026-02-22T08:24:29",
    duration_seconds=889.088467,
    input_dataset="PhysAI-MP4Videos:1",
    input_example="demo_0_robot_pov_cam.mp4",
    output_dataset="PhysAI-CosmosAugmentedMP4:11",
    output_example="demo_0_robot_pov_cam.mp4",
    details=[
        "Model path: Cosmos transfer workflow with HF gated checkpoints.",
        "Output selection keeps generated MP4 and excludes control artifacts.",
        "Produced the augmented video set consumed by Step 4.",
    ],
    input_image=INPUT_FRAME,
    output_image=COSMOS_FRAME,
)

add_step_slide(
    step_number="4",
    step_title="MP4 to HDF5 Conversion",
    workflow="mp4_to_hdf5_conversion-6",
    start_time="2026-02-22T08:28:12",
    end_time="2026-02-22T08:30:09",
    duration_seconds=117.246848,
    input_dataset="PhysAI-CosmosAugmentedMP4:11",
    input_example="demo_0_robot_pov_cam.mp4",
    output_dataset="PhysAI-CosmosAugmentedHDF5:6",
    output_example="cosmos_augmented_dataset.hdf5 (2.40 GiB)",
    details=[
        "Converter maps nut-pouring schema keys (robot_pov_cam + eef states).",
        "Run created augmented demo_50 and total demonstrations = 51.",
        "This HDF5 output feeds the LeRobot conversion step.",
    ],
    input_image=COSMOS_FRAME,
    output_note=(
        "Non-visual artifact (HDF5)\\n\\n"
        "PhysAI-CosmosAugmentedHDF5:6/\\n"
        "  cosmos_augmented_dataset.hdf5\\n"
        "  size: 2,576,345,050 B (2.40 GiB)"
    ),
)

add_step_slide(
    step_number="5",
    step_title="LeRobot Dataset Conversion",
    workflow="dataset_conversion_augmented-3",
    start_time="2026-02-25T01:34:24",
    end_time="2026-02-25T01:37:45",
    duration_seconds=201.335118,
    input_dataset="PhysAI-CosmosAugmentedHDF5:6",
    input_example="cosmos_augmented_dataset.hdf5",
    output_dataset="PhysAI-LeRobotDataset:3",
    output_example="nut_pouring_task/lerobot/videos/.../episode_000000.mp4",
    details=[
        "Converted and exported 51/51 episodes to LeRobot format.",
        "Uploaded dataset version 3 with checksum a8d3942cacf7922527be216fb95d1fa8.",
        "LeRobot output is the direct training input for Step 6.",
    ],
    output_image=LEROBOT_FRAME,
    input_note=(
        "Non-visual artifact (HDF5)\\n\\n"
        "PhysAI-CosmosAugmentedHDF5:6/\\n"
        "  cosmos_augmented_dataset.hdf5\\n"
        "  size: 2,576,345,050 B (2.40 GiB)"
    ),
)

add_step_slide(
    step_number="6",
    step_title="GR00T Fine-Tuning",
    workflow="groot_finetune_nut_pouring-10",
    start_time="2026-02-25T01:40:33",
    end_time="2026-02-25T01:51:33",
    duration_seconds=659.885931,
    input_dataset="PhysAI-LeRobotDataset:3",
    input_example="nut_pouring_task/lerobot (51 episodes)",
    output_dataset="PhysAI-GR00T-Finetuned:4",
    output_example="checkpoint/model safetensors + trainer artifacts",
    details=[
        "Training run executed with max_steps=1 for reproducibility check.",
        "Observed train_runtime=24.33s and successful artifact packaging/upload.",
        "Uploaded version 4 checksum 0746c8114144510942dd449b0982da59.",
    ],
    input_image=LEROBOT_FRAME,
    output_note=(
        "Non-visual artifact (model checkpoint set)\\n\\n"
        "PhysAI-GR00T-Finetuned:4/\\n"
        "  model-00001-of-00002.safetensors  4.66 GiB\\n"
        "  model-00002-of-00002.safetensors  2.41 GiB\\n"
        "  checkpoint-1/optimizer.pt         9.51 GiB\\n"
        "  config.json, trainer_state.json, training_args.bin\\n\\n"
        "Total dataset size: 25,381,936,120 B (23.64 GiB)"
    ),
)


# Slide 10: Embedded videos
slide = prs.slides.add_slide(prs.slide_layouts[6])
set_slide_bg(slide)
add_text_box(slide, 0.8, 0.3, 12, 0.6, "Embedded Video Artifacts", 32, TEXT_WHITE, True)
add_text_box(slide, 0.8, 0.95, 12, 0.5, "Double-click a clip in slideshow mode to play.", 14, TEXT_GRAY)
add_panel(slide, 0.6, 1.45, 4.15, 4.95, "Step 2 Output (Input to Step 3)")
add_panel(slide, 4.85, 1.45, 4.15, 4.95, "Step 3 Output")
add_panel(slide, 9.1, 1.45, 3.65, 4.95, "Step 5 Output")
add_movie_or_note(
    slide,
    INPUT_VIDEO,
    INPUT_FRAME,
    0.83,
    1.95,
    3.7,
    3.7 * 176 / 320,
    "Step 2 video not found in .report_assets.",
)
add_movie_or_note(
    slide,
    COSMOS_VIDEO,
    COSMOS_FRAME,
    5.08,
    1.95,
    3.7,
    3.7 * 176 / 320,
    "Step 3 video not found in .report_assets.",
)
add_movie_or_note(
    slide,
    LEROBOT_VIDEO,
    LEROBOT_FRAME,
    9.33,
    1.95,
    3.2,
    3.2 * 176 / 320,
    "Step 5 video not found in .report_assets.",
)
vmeta = add_text_box(slide, 0.8, 5.1, 12.0, 1.6, "Clip mapping", 16, NVIDIA_GREEN, True)
add_paragraph(vmeta, "- Left: PhysAI-MP4Videos:1 / demo_0_robot_pov_cam.mp4", 13, TEXT_WHITE, False, "Consolas")
add_paragraph(vmeta, "- Middle: PhysAI-CosmosAugmentedMP4:11 / demo_0_robot_pov_cam.mp4", 13, TEXT_WHITE, False, "Consolas")
add_paragraph(vmeta, "- Right: PhysAI-LeRobotDataset:3 / episode_000000.mp4", 13, TEXT_WHITE, False, "Consolas")
add_footer_line(slide)


# Slide 11: Common pitfalls
slide = prs.slides.add_slide(prs.slide_layouts[6])
set_slide_bg(slide)
add_text_box(slide, 0.8, 0.3, 12, 0.6, "Common Pitfalls", 32, TEXT_WHITE, True)
pit = add_text_box(slide, 0.8, 1.0, 12, 5.9, "Frequent setup issues to check first:", 20, NVIDIA_GREEN, True)
add_paragraph(pit, "- Missing HF gated approvals for Cosmos/GR00T models.", 16, WARNING_YELLOW)
add_paragraph(pit, "- Incorrect Step 3 output selection (must keep generated robot camera MP4).", 16, WARNING_YELLOW)
add_paragraph(pit, "- Step 4 schema mismatch if converter assumes generic table_cam/eef_pos keys.", 16, WARNING_YELLOW)
add_paragraph(pit, "- Attempting aggressive multi-GPU settings before baseline single-GPU verification.", 16, WARNING_YELLOW)
add_paragraph(pit, "- Leaving GPU nodegroups up after run if idle autoscaler is not enabled.", 16, WARNING_YELLOW)
add_footer_line(slide)


# Slide 12: Cost control
slide = prs.slides.add_slide(prs.slide_layouts[6])
set_slide_bg(slide)
add_text_box(slide, 0.8, 0.3, 12, 0.6, "Resource and Cost Control", 32, TEXT_WHITE, True)
auto = add_text_box(slide, 0.8, 1.0, 12, 5.9, "Idle scale-down is automated for this environment.", 20, SUCCESS_GREEN, True)
add_paragraph(auto, "Automation script: deployments/scripts/aws/auto-scale-idle.sh", 15, ACCENT_BLUE, False, "Consolas")
add_paragraph(
    auto,
    "Cron: */5 * * * * .../auto-scale-idle.sh --once --cluster osmo --region us-west-2 --osmo-namespace osmo-minimal --idle-minutes 20 --cpu-desired 1",
    13,
    ACCENT_BLUE,
    False,
    "Consolas",
)
add_paragraph(auto, "One-shot cleanup executed after workflow completion:", 15, TEXT_WHITE, True)
add_paragraph(auto, "- osmo-groot nodegroup desired=0", 15, SUCCESS_GREEN)
add_paragraph(auto, "- osmo-gpu nodegroup desired=0", 15, SUCCESS_GREEN)
add_paragraph(auto, "- osmo-nodes baseline desired=1", 15, SUCCESS_GREEN)
add_paragraph(auto, "Final node state: only CPU baseline node remains in cluster.", 15, SUCCESS_GREEN, True)
add_footer_line(slide)


# Slide 13: Final summary
slide = prs.slides.add_slide(prs.slide_layouts[6])
set_slide_bg(slide)
add_text_box(slide, 0.8, 0.3, 12, 0.6, "Final Summary", 32, TEXT_WHITE, True)
summary = add_text_box(slide, 0.8, 1.0, 12, 5.9, "Full nut_pouring cookbook pipeline reproduced successfully.", 22, SUCCESS_GREEN, True)
add_paragraph(summary, "1) All six workflows are completed with verified artifact outputs.", 17, SUCCESS_GREEN)
add_paragraph(summary, "2) Dataset lineage ends at PhysAI-GR00T-Finetuned:4.", 17, SUCCESS_GREEN)
add_paragraph(summary, "3) Per-step runtime and I/O examples are captured in this report.", 17, SUCCESS_GREEN)
add_paragraph(summary, "4) GPU resources are cleaned automatically via idle scale-down automation.", 17, SUCCESS_GREEN)
add_footer_line(slide)


# Save
parser = argparse.ArgumentParser(description="Generate Nut Pouring pipeline report PPTX")
parser.add_argument(
    "-o",
    "--output",
    default="Nut_Pouring_Pipeline_Report.pptx",
    help="Output PPTX path",
)
args = parser.parse_args()

output_path = os.path.abspath(os.path.expanduser(args.output))
os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
prs.save(output_path)
print(f"Report saved to: {output_path}")
print(f"Slides: {len(prs.slides)}")
