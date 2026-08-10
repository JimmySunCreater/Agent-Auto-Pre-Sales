#!/usr/bin/env python3
"""
split_manual.py — 把 Tank 500 用户手册（单个大 markdown）切分成若干 KB 文档。

手册特征（docs/design.md §5.1）：
  - 约 10,000+ 行、1,400+ 个 `# ` 标题，且全部是同级 h1（PDF 转换产物），
    WARNING / CAUTION / NOTICE 等提示块也是 h1；
  - 存在 OCR 噪音（如 "0odification"）——刻意保留不清洗，作为评估阶段的
    天然"脏数据"；
  - 内容按七大主章节组织：Operation / Driving / Audiovisual system /
    Safety / Emergency / Maintenance / Technical data，
    文档开头有一段 Table of contents 把这些名字各列了一遍。

切分策略：
  1. 定位 TOC 结束位置（TOC 区域里 "# Index" 的首次出现）；
  2. 在 TOC 之后按顺序找七大主章节的真实起始标题，得到章节边界；
     "Table of contents" 之前的引言合并为 "overview" 文档；
     TOC 区域本身（纯标题列表，含全部关键词，会成为高召回的垃圾 chunk）
     与末尾的 "# Index"（页码索引）一并丢弃——OCR 噪音保留、结构性冗余剔除；
  3. 章节内部按 `# ` 标题聚合，每个输出文档 ≈ MAX_CHARS 字符，
     标题组不跨文档截断；
  4. 每个输出文档头部注入章节路径上下文（检索时随 chunk 一起返回，
     帮助 LLM 判断内容出处）。

用法：
  python3 split_manual.py <manual.md> [output_dir]
"""

import re
import sys
from pathlib import Path

MAJOR_SECTIONS = [
    "Operation",
    "Driving",
    "Audiovisual system",
    "Safety",
    "Emergency",
    "Maintenance",
    "Technical data",
]

MAX_CHARS = 12000  # 单个输出文档的目标大小（约 3k tokens），标题组不截断
HEADING_RE = re.compile(r"^#\s+(.*\S)\s*$")


def slugify(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def parse_headings(lines):
    """返回 [(line_idx, heading_text), ...]"""
    out = []
    for i, line in enumerate(lines):
        m = HEADING_RE.match(line)
        if m:
            out.append((i, m.group(1)))
    return out


def locate_sections(lines):
    """
    定位七大主章节的真实边界。
    返回 [(section_name, start_line, end_line_exclusive), ...]，
    以及引言结束行（= 第一个真实章节的起始行）。
    """
    headings = parse_headings(lines)

    # TOC 区域：文档前部连续列出七大章节名 + Index。
    # 找到 "Index" 标题的首次出现，视为 TOC 结束锚点。
    toc_end_idx = None
    for i, (line_idx, text) in enumerate(headings):
        if text == "Index":
            toc_end_idx = line_idx
            break
    if toc_end_idx is None:
        # 没有 TOC（手册变体），从头开始找
        toc_end_idx = -1

    # TOC 之后按顺序找每个主章节的首次出现
    boundaries = []  # (name, start_line)
    search_from = toc_end_idx + 1
    for name in MAJOR_SECTIONS:
        found = None
        for line_idx, text in headings:
            if line_idx >= search_from and text == name:
                found = line_idx
                break
        if found is None:
            print(f"⚠️  章节 '{name}' 未找到（TOC 之后），跳过")
            continue
        boundaries.append((name, found))
        search_from = found + 1

    if not boundaries:
        raise RuntimeError("没有找到任何主章节边界——手册格式与预期不符？")

    # 引言只取到 "Table of contents" 为止；TOC 标题列表本身丢弃
    toc_start_idx = None
    for line_idx, text in headings:
        if text.lower() == "table of contents":
            toc_start_idx = line_idx
            break

    # 文档末尾的真实 Index 章节（若有）作为最后一个章节的结束
    doc_end = len(lines)
    for line_idx, text in headings:
        if text == "Index" and line_idx > boundaries[-1][1]:
            doc_end = line_idx
            break

    sections = []
    for i, (name, start) in enumerate(boundaries):
        end = boundaries[i + 1][1] if i + 1 < len(boundaries) else doc_end
        sections.append((name, start, end))
    intro_end = toc_start_idx if toc_start_idx is not None else boundaries[0][1]
    return sections, intro_end


def group_by_size(lines, start, end):
    """
    把 [start, end) 的行按 `# ` 标题分组后聚合，每组 ≈ MAX_CHARS。
    返回 [[line, ...], ...]（每个元素是一个输出文档的行列表）。
    """
    # 先切成标题块（一个标题 + 其后的内容为一块）
    blocks = []
    cur = []
    for i in range(start, end):
        if HEADING_RE.match(lines[i]) and cur:
            blocks.append(cur)
            cur = []
        cur.append(lines[i])
    if cur:
        blocks.append(cur)

    # 聚合标题块到目标大小
    docs = []
    cur_doc, cur_size = [], 0
    for block in blocks:
        block_size = sum(len(l) + 1 for l in block)
        if cur_doc and cur_size + block_size > MAX_CHARS:
            docs.append(cur_doc)
            cur_doc, cur_size = [], 0
        cur_doc.extend(block)
        cur_size += block_size
    if cur_doc:
        docs.append(cur_doc)
    return docs


def first_headings(doc_lines, n=3):
    """取该文档内前 n 个标题，用于文件头的内容概览。"""
    out = []
    for line in doc_lines:
        m = HEADING_RE.match(line)
        if m and m.group(1) not in ("WARNING", "CAUTION", "NOTICE"):
            out.append(m.group(1))
            if len(out) >= n:
                break
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    manual_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).parent / "output"

    text = manual_path.read_text(encoding="utf-8")
    lines = text.splitlines()
    print(f"手册: {manual_path} ({len(lines)} 行, {len(text)} 字符)")

    sections, intro_end = locate_sections(lines)
    print("章节边界:")
    for name, s, e in sections:
        print(f"  {name:<20} lines {s}-{e} ({e - s} 行)")

    out_dir.mkdir(parents=True, exist_ok=True)
    # 清空旧输出，保证幂等
    for old in out_dir.glob("*.md"):
        old.unlink()

    total = 0

    def write_doc(seq, section_name, part, part_total, doc_lines):
        nonlocal total
        slug = slugify(section_name)
        fname = f"{seq:02d}-{slug}-part{part}.md"
        topics = first_headings(doc_lines)
        header = [
            f"# Tank 500 Owner's Manual — {section_name} (Part {part}/{part_total})",
            "",
            f"> Source: GWM Tank 500 owner's manual, section \"{section_name}\".",
            f"> Topics in this part: {'; '.join(topics) if topics else 'n/a'}",
            "",
        ]
        (out_dir / fname).write_text("\n".join(header + doc_lines) + "\n", encoding="utf-8")
        total += 1

    seq = 0
    # 引言（Overview / Vehicle statement / Tips for safety 等）
    intro_docs = group_by_size(lines, 0, intro_end)
    for p, doc_lines in enumerate(intro_docs, 1):
        write_doc(seq, "Overview", p, len(intro_docs), doc_lines)
    seq += 1

    for name, s, e in sections:
        docs = group_by_size(lines, s, e)
        for p, doc_lines in enumerate(docs, 1):
            write_doc(seq, name, p, len(docs), doc_lines)
        seq += 1

    print(f"\n✅ 输出 {total} 个 KB 文档到 {out_dir}/")
    sizes = sorted(f.stat().st_size for f in out_dir.glob("*.md"))
    if sizes:
        print(f"   大小分布: min {sizes[0]}, median {sizes[len(sizes)//2]}, max {sizes[-1]} 字符")


if __name__ == "__main__":
    main()
