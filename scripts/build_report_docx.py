#!/usr/bin/env python3
"""Build the official-template design report DOCX from docs/DESIGN-REPORT.md.

The script intentionally uses a small Markdown subset:
  # title
  ## subtitle (only the first one starting with "——")
  ## / ### / #### / ##### headings
  > meta lines
  paragraphs, - bullets
  [TABLE] caption  followed by a pipe table
  ![caption](path)
  ``` fenced code blocks

It preserves the template's headers/footers/styles and rebuilds the body with
report-specific styles.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.table import WD_ALIGN_VERTICAL, WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_LINE_SPACING
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
MD = ROOT / "docs" / "DESIGN-REPORT.md"
TEMPLATE = Path(r"C:\Users\lenovo\Desktop\作品模板.docx")
OUT = ROOT / "build" / "LGT-S1-作品报告.docx"

INK = RGBColor(0x1F, 0x3A, 0x4D)
BLUE = RGBColor(0x1F, 0x4E, 0x79)
MID_BLUE = RGBColor(0x2F, 0x5D, 0x8A)
GREY = RGBColor(0x59, 0x59, 0x59)
LIGHT_GREY = RGBColor(0x7F, 0x7F, 0x7F)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)


# ---------------------------------------------------------------------------
# Markdown parsing
# ---------------------------------------------------------------------------
def parse_markdown(text: str):
    lines = text.splitlines()
    blocks = []
    i = 0
    buf = []
    table_caption = None

    def flush_para():
        nonlocal buf
        if buf:
            blocks.append({"type": "para", "text": " ".join(x.strip() for x in buf)})
            buf = []

    while i < len(lines):
        raw = lines[i]
        line = raw.rstrip()
        stripped = line.strip()

        # fenced code
        if stripped.startswith("```"):
            flush_para()
            i += 1
            code = []
            while i < len(lines) and not lines[i].strip().startswith("```"):
                code.append(lines[i].rstrip("\n"))
                i += 1
            i += 1
            blocks.append({"type": "code", "lines": code})
            continue

        # table caption marker
        if stripped.startswith("[TABLE]"):
            flush_para()
            table_caption = stripped[len("[TABLE]"):].strip()
            i += 1
            continue

        # table rows
        if stripped.startswith("|"):
            flush_para()
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                s = lines[i].strip()
                cells = [c.strip() for c in s.strip("|").split("|")]
                if not all(re.fullmatch(r":?-{3,}:?", c.replace(" ", "")) for c in cells):
                    rows.append(cells)
                i += 1
            blocks.append({"type": "table", "caption": table_caption, "rows": rows})
            table_caption = None
            continue

        # image
        m = re.fullmatch(r"!\[(.*?)\]\((.*?)\)", stripped)
        if m:
            flush_para()
            blocks.append({"type": "image", "caption": m.group(1).strip(), "path": m.group(2).strip()})
            i += 1
            continue

        # headings
        if stripped.startswith("##### "):
            flush_para()
            blocks.append({"type": "h4", "text": stripped[6:].strip()})
        elif stripped.startswith("#### "):
            flush_para()
            blocks.append({"type": "h3", "text": stripped[5:].strip()})
        elif stripped.startswith("### "):
            flush_para()
            blocks.append({"type": "h2", "text": stripped[4:].strip()})
        elif stripped.startswith("## "):
            flush_para()
            text = stripped[3:].strip()
            if text.startswith("——"):
                blocks.append({"type": "subtitle", "text": text})
            else:
                blocks.append({"type": "h1", "text": text})
        elif stripped.startswith("# "):
            flush_para()
            blocks.append({"type": "title", "text": stripped[2:].strip()})
        elif stripped.startswith(">"):
            flush_para()
            meta = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                meta.append(lines[i].strip()[1:].strip())
                i += 1
            blocks.append({"type": "meta", "lines": meta})
            continue
        elif stripped.startswith("- "):
            flush_para()
            blocks.append({"type": "bullet", "text": stripped[2:].strip()})
        elif stripped == "":
            flush_para()
        else:
            buf.append(line)
        i += 1

    flush_para()
    return blocks


# ---------------------------------------------------------------------------
# DOCX helpers
# ---------------------------------------------------------------------------
def set_run_font(run, ascii_font="Times New Roman", east_font="宋体", size=None, bold=None, color=None):
    run.font.name = ascii_font
    rpr = run._element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = OxmlElement("w:rFonts")
        rpr.append(rfonts)
    rfonts.set(qn("w:ascii"), ascii_font)
    rfonts.set(qn("w:hAnsi"), ascii_font)
    rfonts.set(qn("w:eastAsia"), east_font)
    rfonts.set(qn("w:cs"), ascii_font)
    if size is not None:
        run.font.size = Pt(size)
    if bold is not None:
        run.bold = bold
    if color is not None:
        run.font.color.rgb = color


def add_inline(paragraph, text, size=12, color=INK, bold=False):
    """Add text with **bold** and `code` inline markup."""
    tokens = re.split(r"(\*\*.+?\*\*|`[^`]+`)", text)
    for token in tokens:
        if not token:
            continue
        if token.startswith("**") and token.endswith("**"):
            run = paragraph.add_run(token[2:-2])
            set_run_font(run, size=size, bold=True, color=color)
        elif token.startswith("`") and token.endswith("`"):
            run = paragraph.add_run(token[1:-1])
            set_run_font(run, ascii_font="Consolas", east_font="宋体", size=max(size - 1, 8), color=MID_BLUE)
        else:
            run = paragraph.add_run(token)
            set_run_font(run, size=size, bold=bold, color=color)


def add_style(doc, name, size, bold=False, color=INK, ascii_font="Times New Roman",
              east_font="宋体", align=WD_ALIGN_PARAGRAPH.JUSTIFY, line=1.5,
              before=0, after=0, first_line=None, left_indent=None, keep_next=False,
              border=None):
    from docx.enum.style import WD_STYLE_TYPE

    styles = doc.styles
    st = styles.add_style(name, WD_STYLE_TYPE.PARAGRAPH)
    st.base_style = styles["Normal"]
    st.font.name = ascii_font
    st.font.size = Pt(size)
    st.font.bold = bold
    st.font.color.rgb = color
    rpr = st.element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = OxmlElement("w:rFonts")
        rpr.append(rfonts)
    rfonts.set(qn("w:ascii"), ascii_font)
    rfonts.set(qn("w:hAnsi"), ascii_font)
    rfonts.set(qn("w:eastAsia"), east_font)
    rfonts.set(qn("w:cs"), ascii_font)
    pf = st.paragraph_format
    pf.alignment = align
    pf.line_spacing = line
    pf.space_before = Pt(before)
    pf.space_after = Pt(after)
    pf.keep_with_next = keep_next
    pf.widow_control = True
    if first_line is not None:
        pf.first_line_indent = Pt(first_line)
    if left_indent is not None:
        pf.left_indent = Cm(left_indent)
    if border:
        ppr = st.element.get_or_add_pPr()
        pbdr = OxmlElement("w:pBdr")
        edge = OxmlElement(f"w:{border['edge']}")
        edge.set(qn("w:val"), border.get("val", "single"))
        edge.set(qn("w:sz"), str(border.get("sz", 8)))
        edge.set(qn("w:space"), str(border.get("space", 4)))
        edge.set(qn("w:color"), border.get("color", "1F4E79"))
        pbdr.append(edge)
        ppr.append(pbdr)
    return st


def set_cell_shading(cell, fill):
    tc_pr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), fill)
    tc_pr.append(shd)


def set_cell_margins(cell, top=40, bottom=40, left=70, right=70):
    tc_pr = cell._tc.get_or_add_tcPr()
    mar = OxmlElement("w:tcMar")
    for edge, val in (("top", top), ("bottom", bottom), ("left", left), ("right", right)):
        e = OxmlElement(f"w:{edge}")
        e.set(qn("w:w"), str(val))
        e.set(qn("w:type"), "dxa")
        mar.append(e)
    tc_pr.append(mar)


def set_table_borders(table, color="BFBFBF", sz=4):
    tbl = table._tbl
    tbl_pr = tbl.tblPr
    borders = OxmlElement("w:tblBorders")
    for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
        e = OxmlElement(f"w:{edge}")
        e.set(qn("w:val"), "single")
        e.set(qn("w:sz"), str(sz))
        e.set(qn("w:space"), "0")
        e.set(qn("w:color"), color)
        borders.append(e)
    tbl_pr.append(borders)


def set_table_fixed_layout(table):
    tbl = table._tbl
    tbl_pr = tbl.tblPr
    layout = OxmlElement("w:tblLayout")
    layout.set(qn("w:type"), "fixed")
    tbl_pr.append(layout)
    width = OxmlElement("w:tblW")
    width.set(qn("w:w"), "5000")
    width.set(qn("w:type"), "pct")
    tbl_pr.append(width)


def ratios_for(caption, n):
    c = caption or ""
    if "表 1-1" in c:
        return [0.28, 0.72]
    if "表 3-1" in c:
        return [0.18, 0.22, 0.60]
    if "表 3-2" in c:
        return [0.12, 0.18, 0.42, 0.28]
    if "表 3-3" in c:
        return [0.20, 0.40, 0.40]
    if "表 2-4" in c:
        return [0.25, 0.25, 0.25, 0.25]
    if n == 2:
        return [0.30, 0.70]
    if n == 3:
        return [0.24, 0.36, 0.40]
    if n == 4:
        return [0.22, 0.26, 0.30, 0.22]
    if n == 5:
        return [0.20] * 5
    return [1.0 / n] * n


def add_table(doc, rows, caption):
    if not rows:
        return
    # normalize column count
    ncol = max(len(r) for r in rows)
    rows = [r + [""] * (ncol - len(r)) for r in rows]

    if caption:
        p = doc.add_paragraph(style="ReportTableCaption")
        add_inline(p, caption, size=10.5, color=INK, bold=True)

    table = doc.add_table(rows=len(rows), cols=ncol)
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = False
    set_table_fixed_layout(table)
    set_table_borders(table)

    available = 14.6
    ratios = ratios_for(caption, ncol)
    widths = [Cm(available * r) for r in ratios]

    for j, w in enumerate(widths):
        table.columns[j].width = w

    for i, row in enumerate(rows):
        tr = table.rows[i]
        tr.height = Cm(0.55)
        tr_pr = tr._tr.get_or_add_trPr()
        cant = OxmlElement("w:cantSplit")
        tr_pr.append(cant)
        if i == 0:
            header = OxmlElement("w:tblHeader")
            header.set(qn("w:val"), "true")
            tr_pr.append(header)

        for j, text in enumerate(row):
            cell = tr.cells[j]
            cell.width = widths[j]
            cell.vertical_alignment = WD_ALIGN_VERTICAL.CENTER
            set_cell_margins(cell)
            if i == 0:
                set_cell_shading(cell, "D9E2F3")
            elif i % 2 == 0:
                set_cell_shading(cell, "F7F9FC")
            p = cell.paragraphs[0]
            p.paragraph_format.space_before = Pt(0)
            p.paragraph_format.space_after = Pt(0)
            p.paragraph_format.line_spacing = 1.0
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER if (i == 0 or j == 0 or len(text) <= 10) else WD_ALIGN_PARAGRAPH.LEFT
            add_inline(p, text, size=9, color=INK, bold=(i == 0))

    # small spacer
    sp = doc.add_paragraph()
    sp.paragraph_format.space_before = Pt(0)
    sp.paragraph_format.space_after = Pt(2)


def add_image(doc, path, caption):
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.paragraph_format.space_before = Pt(4)
    p.paragraph_format.space_after = Pt(2)
    p.paragraph_format.keep_with_next = True
    full = Path(path)
    if not full.is_absolute():
        full = ROOT / path
    if not full.exists():
        run = p.add_run(f"[缺少图片：{path}]")
        set_run_font(run, size=10.5, color=RGBColor(0xC0, 0x00, 0x00))
    else:
        w, h = Image.open(full).size
        if "placeholder" in full.name:
            width_cm = 10.5
        else:
            width_cm = 15.5
        # cap height
        if width_cm * h / w > 13.0:
            width_cm = 13.0 * w / h
        run = p.add_run()
        run.add_picture(str(full), width=Cm(width_cm))

    if caption:
        cp = doc.add_paragraph(style="ReportCaption")
        add_inline(cp, caption, size=10.5, color=GREY)


def add_code(doc, lines):
    p = doc.add_paragraph(style="ReportCode")
    p.paragraph_format.space_before = Pt(4)
    p.paragraph_format.space_after = Pt(8)
    # shading
    ppr = p._p.get_or_add_pPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), "F2F2F2")
    ppr.append(shd)
    for idx, line in enumerate(lines):
        run = p.add_run(line)
        set_run_font(run, ascii_font="Consolas", east_font="宋体", size=9, color=RGBColor(0x33, 0x33, 0x33))
        if idx != len(lines) - 1:
            run.add_break()


def add_meta(doc, lines):
    p = doc.add_paragraph(style="ReportMeta")
    for idx, line in enumerate(lines):
        run = p.add_run(line)
        set_run_font(run, size=10.5, color=GREY)
        if idx != len(lines) - 1:
            run.add_break()


def add_title_block(doc, title, subtitle, meta):
    p = doc.add_paragraph(style="ReportTitle")
    add_inline(p, title, size=22, color=BLUE, bold=True)

    if subtitle:
        sp = doc.add_paragraph(style="ReportSubtitle")
        add_inline(sp, subtitle, size=14, color=GREY)

    # colored rule
    rule = doc.add_paragraph()
    rule.paragraph_format.space_before = Pt(2)
    rule.paragraph_format.space_after = Pt(8)
    ppr = rule._p.get_or_add_pPr()
    pbdr = OxmlElement("w:pBdr")
    bottom = OxmlElement("w:bottom")
    bottom.set(qn("w:val"), "single")
    bottom.set(qn("w:sz"), "18")
    bottom.set(qn("w:space"), "1")
    bottom.set(qn("w:color"), "00A9BE")
    pbdr.append(bottom)
    ppr.append(pbdr)

    if meta:
        add_meta(doc, meta)


def build():
    text = MD.read_text(encoding="utf-8")
    blocks = parse_markdown(text)

    doc = Document(str(TEMPLATE))

    # remove body content, keep the final sectPr (headers/footers/page setup)
    body = doc.element.body
    for child in list(body):
        if child.tag != qn("w:sectPr"):
            body.remove(child)

    # page setup (match template A4 / 2.54 / 3.17 cm)
    section = doc.sections[0]
    section.page_width = Cm(21.0)
    section.page_height = Cm(29.7)
    section.top_margin = Cm(2.54)
    section.bottom_margin = Cm(2.54)
    section.left_margin = Cm(3.17)
    section.right_margin = Cm(3.17)
    section.header_distance = Cm(1.5)
    section.footer_distance = Cm(1.75)

    # core properties
    doc.core_properties.title = "LGT-S1 校园/园区多媒体信息终端 作品报告"
    doc.core_properties.subject = "2026 嵌入式芯片与系统设计竞赛 FPGA 创新设计赛道 安路选题一"
    doc.core_properties.author = "LGT-S1 作品组"
    doc.core_properties.keywords = "FPGA; EG4S20; 数字标牌; HDMI; FAT32; OSD"

    # styles
    add_style(doc, "ReportTitle", 22, bold=True, color=BLUE,
              align=WD_ALIGN_PARAGRAPH.CENTER, line=1.2, before=0, after=2)
    add_style(doc, "ReportSubtitle", 14, bold=False, color=GREY,
              align=WD_ALIGN_PARAGRAPH.CENTER, line=1.2, before=0, after=4)
    add_style(doc, "ReportMeta", 10.5, bold=False, color=GREY,
              align=WD_ALIGN_PARAGRAPH.LEFT, line=1.35, before=2, after=2,
              left_indent=0.3, border={"edge": "left", "sz": 18, "space": 6, "color": "00A9BE"})
    add_style(doc, "ReportH1", 16, bold=True, color=BLUE,
              align=WD_ALIGN_PARAGRAPH.LEFT, line=1.2, before=18, after=10,
              keep_next=True, border={"edge": "bottom", "sz": 8, "space": 4, "color": "1F4E79"})
    add_style(doc, "ReportH2", 14, bold=True, color=BLUE,
              align=WD_ALIGN_PARAGRAPH.LEFT, line=1.2, before=14, after=6, keep_next=True)
    add_style(doc, "ReportH3", 12, bold=True, color=MID_BLUE,
              align=WD_ALIGN_PARAGRAPH.LEFT, line=1.2, before=10, after=4, keep_next=True)
    add_style(doc, "ReportH4", 11.5, bold=True, color=MID_BLUE,
              align=WD_ALIGN_PARAGRAPH.LEFT, line=1.2, before=8, after=3, keep_next=True)
    add_style(doc, "ReportBody", 12, bold=False, color=INK,
              align=WD_ALIGN_PARAGRAPH.JUSTIFY, line=1.5, before=0, after=0, first_line=24)
    add_style(doc, "ReportBullet", 12, bold=False, color=INK,
              align=WD_ALIGN_PARAGRAPH.JUSTIFY, line=1.5, before=0, after=0,
              left_indent=0.74)
    add_style(doc, "ReportTableCaption", 10.5, bold=True, color=INK,
              align=WD_ALIGN_PARAGRAPH.CENTER, line=1.2, before=6, after=3, keep_next=True)
    add_style(doc, "ReportCaption", 10.5, bold=False, color=GREY,
              align=WD_ALIGN_PARAGRAPH.CENTER, line=1.2, before=4, after=12)
    add_style(doc, "ReportCode", 9, bold=False, color=RGBColor(0x33, 0x33, 0x33),
              ascii_font="Consolas", align=WD_ALIGN_PARAGRAPH.LEFT, line=1.0,
              before=4, after=8, left_indent=0.4)
    add_style(doc, "ReportNote", 10.5, bold=False, color=GREY,
              align=WD_ALIGN_PARAGRAPH.LEFT, line=1.3, before=2, after=2, left_indent=0.4)

    # title / subtitle / meta
    title = next((b["text"] for b in blocks if b["type"] == "title"), "LGT-S1 作品报告")
    subtitle = next((b["text"] for b in blocks if b["type"] == "subtitle"), "")
    meta = next((b["lines"] for b in blocks if b["type"] == "meta"), [])
    add_title_block(doc, title, subtitle, meta)

    first_h1 = True
    for b in blocks:
        t = b["type"]
        if t in ("title", "subtitle", "meta"):
            continue
        if t == "h1":
            p = doc.add_paragraph(style="ReportH1")
            if not first_h1 and b["text"].startswith("第一部分"):
                p.paragraph_format.page_break_before = True
            add_inline(p, b["text"], size=16, color=BLUE, bold=True)
            first_h1 = False
        elif t == "h2":
            p = doc.add_paragraph(style="ReportH2")
            if b["text"].startswith("附录 E"):
                p.paragraph_format.page_break_before = True
            add_inline(p, b["text"], size=14, color=BLUE, bold=True)
        elif t == "h3":
            p = doc.add_paragraph(style="ReportH3")
            add_inline(p, b["text"], size=12, color=MID_BLUE, bold=True)
        elif t == "h4":
            p = doc.add_paragraph(style="ReportH4")
            add_inline(p, b["text"], size=11.5, color=MID_BLUE, bold=True)
        elif t == "para":
            p = doc.add_paragraph(style="ReportBody")
            add_inline(p, b["text"], size=12, color=INK)
        elif t == "bullet":
            p = doc.add_paragraph(style="ReportBullet")
            p.paragraph_format.first_line_indent = Pt(-18)
            add_inline(p, "• " + b["text"], size=12, color=INK)
        elif t == "code":
            add_code(doc, b["lines"])
        elif t == "table":
            add_table(doc, b["rows"], b["caption"])
        elif t == "image":
            add_image(doc, b["path"], b["caption"])

    OUT.parent.mkdir(parents=True, exist_ok=True)
    doc.save(str(OUT))
    print(f"wrote {OUT}")
    print(f"blocks={len(blocks)} tables={sum(1 for b in blocks if b['type']=='table')} images={sum(1 for b in blocks if b['type']=='image')}")


if __name__ == "__main__":
    build()
