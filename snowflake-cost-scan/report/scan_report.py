"""Build the free Snowflake Cost Scan PDF from the scan's CSV output.

Usage:
    python scan_report.py <scan.csv> "<Client name>" <out.pdf> [notes.txt]

notes.txt: up to 3 lines, your own observations, shown as "What stood out".
"""
import csv
import sys
from datetime import date

from reportlab.graphics.shapes import Drawing, Rect, String
from reportlab.lib import colors
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import inch
from reportlab.platypus import (KeepTogether, PageBreak, Paragraph, SimpleDocTemplate,
                                Spacer, Table, TableStyle)

NAVY = colors.HexColor("#0F1B2D")
PANEL = colors.HexColor("#EEF2F7")
GREEN = colors.HexColor("#2FAF8C")
BLUE = colors.HexColor("#3B82F6")
AMBER = colors.HexColor("#F0B450")
RED = colors.HexColor("#E86155")
MUTED = colors.HexColor("#5B6B80")
GRID = colors.HexColor("#D5DCE6")
BRAND = "Metricgrain"
WIDTH = 6.9 * inch

H1 = ParagraphStyle("H1", fontName="Helvetica-Bold", fontSize=22, leading=26, textColor=NAVY)
SUB = ParagraphStyle("SUB", fontName="Helvetica", fontSize=10.5, leading=14, textColor=MUTED)
H2 = ParagraphStyle("H2", fontName="Helvetica-Bold", fontSize=13, leading=16, textColor=NAVY, spaceBefore=10, spaceAfter=4)
BODY = ParagraphStyle("BODY", fontName="Helvetica", fontSize=9.5, leading=13.5, textColor=NAVY)
SMALL = ParagraphStyle("SMALL", fontName="Helvetica", fontSize=7.5, leading=10, textColor=MUTED)
CELL = ParagraphStyle("CELL", fontName="Helvetica", fontSize=8.5, leading=11, textColor=NAVY)
KPI_V = ParagraphStyle("KV", fontName="Helvetica-Bold", fontSize=17, leading=21, textColor=NAVY)
KPI_VG = ParagraphStyle("KVG", parent=KPI_V, textColor=GREEN)
KPI_L = ParagraphStyle("KL", fontName="Helvetica", fontSize=8, leading=10.5, textColor=MUTED)


def load(path):
    """Group CSV rows by section. Snowsight exports uppercase headers."""
    sections = {}
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            r = {k.lower(): v for k, v in row.items()}
            usd = r.get("usd_per_year") or ""
            r["usd"] = float(usd) if usd.strip() else None
            sections.setdefault(r["section"], []).append(r)
    for rows in sections.values():
        rows.sort(key=lambda r: int(r["rank"]))
    return sections


def k(x):
    if x is None:
        return "-"
    return f"${x / 1e6:.2f}M" if x >= 1e6 else f"${x / 1e3:,.0f}K"


def summary(s, item):
    return next(r for r in s["Summary"] if r["item"] == item)


def kpis(s):
    spend = summary(s, "Estimated annual Snowflake spend")["usd"]
    low = summary(s, "Estimated savings potential (low)")["usd"]
    high = summary(s, "Estimated savings potential (high)")["usd"]
    idle = summary(s, "Idle compute")
    growth = summary(s, "Spend growth")
    idle_pct = idle["detail"].split("%")[0]
    growth_pct = growth["detail"].split("%")[0]
    cells = [
        [Paragraph(t, KPI_L) for t in ("Annual spend", "Savings potential", "Idle compute", "Spend growth")],
        [Paragraph(k(spend), KPI_V), Paragraph(f"{k(low)}-{k(high)}", KPI_VG),
         Paragraph(f"{idle_pct}%", KPI_V), Paragraph(f"{growth_pct}%/mo", KPI_V)],
        [Paragraph("Last 30 days, annualized", KPI_L),
         Paragraph(f"per year ({100 * low / spend:.0f}-{100 * high / spend:.0f}% of spend)", KPI_L),
         Paragraph(f"{k(idle['usd'])}/yr billed with no query running", KPI_L),
         Paragraph("Compute & services, average over the last 6 months", KPI_L)],
    ]
    t = Table(cells, colWidths=[WIDTH / 4] * 4)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), PANEL), ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 10), ("RIGHTPADDING", (0, 0), (-1, -1), 6),
        ("TOPPADDING", (0, 0), (-1, 0), 9), ("BOTTOMPADDING", (0, -1), (-1, -1), 9),
        ("LINEAFTER", (0, 0), (2, -1), 1, colors.white),
    ]))
    return t


def stacked(rows, palette):
    total = sum(r["usd"] or 0 for r in rows) or 1
    d = Drawing(WIDTH, 26)
    x = 0
    for r, col in zip(rows, palette):
        w = WIDTH * (r["usd"] or 0) / total
        d.add(Rect(x, 4, w, 20, fillColor=col, strokeColor=None))
        x += w
    legend = " &nbsp;·&nbsp; ".join(
        f'<font color="#{c.hexval()[2:]}">&#9632;</font> {r["item"]} {100 * (r["usd"] or 0) / total:.0f}% ({k(r["usd"])})'
        for r, c in zip(rows, palette))
    return [d, Paragraph(legend, SMALL)]


def bars(rows, color=GREEN, label_w=3.1 * inch, suffix="/yr"):
    rows = [r for r in rows if (r["usd"] or 0) > 0]
    row_h = 19
    d = Drawing(WIDTH, row_h * len(rows))
    top = max(r["usd"] for r in rows)
    bar_max = WIDTH - label_w - 0.9 * inch
    for i, r in enumerate(rows):
        y = (len(rows) - i - 1) * row_h + 4
        name = r["item"] if len(r["item"]) <= 52 else r["item"][:50] + "..."
        d.add(String(0, y + 3, name, fontName="Helvetica", fontSize=8.5, fillColor=NAVY))
        w = max(bar_max * r["usd"] / top, 2)
        d.add(Rect(label_w, y, w, 12, fillColor=color, strokeColor=None))
        d.add(String(label_w + w + 5, y + 3, f"{k(r['usd'])}{suffix}", fontName="Helvetica-Bold", fontSize=8.5, fillColor=NAVY))
    return d


def table(header, rows, widths):
    data = [header] + [[Paragraph(str(c), CELL) for c in row] for row in rows]
    t = Table(data, colWidths=widths, repeatRows=1)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), NAVY), ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"), ("FONTSIZE", (0, 0), (-1, 0), 8.5),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, PANEL]),
        ("GRID", (0, 0), (-1, -1), 0.4, GRID), ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (-1, -1), 6), ("TOPPADDING", (0, 0), (-1, -1), 3), ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
    ]))
    return t


def trend_table(rows):
    """Months across, one row of monthly spend: compact enough to keep the report at 2 pages."""
    if not rows:
        return Spacer(1, 0)
    n = len(rows)
    data = [[r["item"] for r in rows], [k(r["usd"] / 12) for r in rows]]
    t = Table(data, colWidths=[WIDTH / n] * n)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), NAVY), ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"), ("FONTNAME", (0, 1), (-1, 1), "Helvetica"),
        ("FONTSIZE", (0, 0), (-1, -1), 8.5), ("TEXTCOLOR", (0, 1), (-1, 1), NAVY),
        ("ALIGN", (0, 0), (-1, -1), "CENTER"), ("GRID", (0, 0), (-1, -1), 0.4, GRID),
        ("TOPPADDING", (0, 0), (-1, -1), 3), ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
    ]))
    return t


def build(csv_path, client, out, notes_path=None):
    s = load(csv_path)
    notes = []
    if notes_path:
        notes = [l.strip() for l in open(notes_path) if l.strip()][:3]
    prices = summary(s, "Prices used")["detail"]
    low = summary(s, "Estimated savings potential (low)")["usd"]

    def footer(canvas, doc):
        canvas.saveState()
        canvas.setFont("Helvetica", 7.5)
        canvas.setFillColor(MUTED)
        canvas.drawString(0.8 * inch, 0.45 * inch, f"{BRAND} · Snowflake Cost Scan · Read-only usage metadata, no business data accessed")
        canvas.drawRightString(letter[0] - 0.8 * inch, 0.45 * inch, f"Page {doc.page}")
        canvas.restoreState()

    story = [
        Paragraph("Snowflake Cost Scan", H1),
        Paragraph(f"Prepared for: {client} &nbsp;·&nbsp; {date.today():%B %-d, %Y}", SUB),
        Spacer(1, 10),
        kpis(s),
        Paragraph("Where your money goes", H2),
        *stacked(s["Spend mix"], [BLUE, AMBER, GREEN]),
        Paragraph("Who spends it", H2),
        Paragraph("Query compute by tool, last 30 days annualized.", SMALL),
        Spacer(1, 3),
        bars([r for r in s["By tool"] if (r["usd"] or 0) >= 1000][:8], BLUE),
        Spacer(1, 6),
        Paragraph("Query compute by environment.", SMALL),
        Spacer(1, 2),
        *stacked(s["By environment"], [NAVY, AMBER, RED]),
        Paragraph("Where the savings are", H2),
        bars(s["Focus areas"], GREEN),
    ]
    if notes:
        story += [Paragraph("What stood out", H2)] + [Paragraph(f"&bull; {n}", BODY) for n in notes]

    story += [
        PageBreak(),
        Paragraph("Top 10 most expensive dbt models", H2),
        table(["#", "Model", "Runs (30 days)", "Cost per year"],
              [[r["rank"], r["item"], r["detail"].split(" ")[0], k(r["usd"])] for r in s.get("Top dbt models", [])],
              [0.35 * inch, 4.2 * inch, 1.15 * inch, 1.2 * inch]),
        Paragraph("Top 5 warehouses by idle cost", H2),
        table(["#", "Warehouse", "Idle cost per year"],
              [[r["rank"], r["item"], k(r["usd"])] for r in s.get("Top idle warehouses", [])],
              [0.35 * inch, 5.35 * inch, 1.2 * inch]),
        Paragraph("Monthly compute & services spend", H2),
        trend_table(s.get("Trend", [])),
        Paragraph("What the full audit adds", H2),
        KeepTogether([
            table(["Free scan (this report)", "Full cost audit"], [
                ["Where the money goes", "Why it goes there, for every warehouse, model and query"],
                ["Savings range by focus area", "Every fix priced in $/yr and ranked by payback"],
                ["Top models and warehouses", "Step-by-step fix plan, plus up to 3 quick wins applied"],
                ["-", "Serverless features, unused tables, commitment fit"],
            ], [3.45 * inch, 3.45 * inch]),
            Spacer(1, 8),
            Paragraph(
                f"This scan already points to <b>{k(low)}+ a year</b> in savings. The full audit turns it into a "
                f"ranked, step-by-step plan. Questions: hello@metricgrain.com", BODY),
        ]),
        Spacer(1, 10),
        Paragraph(
            f"Method: last 30 full days of SNOWFLAKE.ACCOUNT_USAGE, annualized; trend from the last 6 full months. "
            f"Prices: {prices}. Tools are detected from query comments, users and client applications; environments from "
            "dbt targets and warehouse, role and user names. Savings assumptions: 30% of short-suspend idle time recoverable "
            "by consolidation; 25% of query credits on qualifying oversized warehouses; 30% of CI & dev spend; 20% of the "
            "top 10 dbt models' spend; half of Time Travel / Fail-safe storage. The high end of the range adds 5% of "
            "warehouse spend for query tuning. Estimates are for prioritization, not guaranteed invoice reductions.", SMALL),
    ]

    doc = SimpleDocTemplate(out, pagesize=letter, leftMargin=0.8 * inch, rightMargin=0.8 * inch,
                            topMargin=0.5 * inch, bottomMargin=0.65 * inch, title="Snowflake Cost Scan")
    doc.build(story, onFirstPage=footer, onLaterPages=footer)


if __name__ == "__main__":
    build(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else None)
    print(sys.argv[3])
