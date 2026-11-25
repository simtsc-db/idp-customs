"""Synthetic permit packs (invoice + packing list + CoO) for the demo.

40 packs, 5 invoice layouts, ~10% Chinese/bilingual, ~10% scans, ~30% with planted
defects, plus ground truth. All entities are fictional; FTA rules are illustrative.
Job task: writes to /Volumes/<catalog>/<schema>/permit_packs; skips existing packs.
"""
import argparse, csv, json, random, shutil
from datetime import date, timedelta
from pathlib import Path

import pypdfium2 as pdfium
from PIL import Image, ImageFilter
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

pdfmetrics.registerFont(UnicodeCIDFont("STSong-Light"))
SEED = 20261125
N_PACKS = 40

# Reference data (fictional entities; real public HS codes)
IMPORTERS = [  # (name, synthetic UEN)
    ("Tanjong Halcyon Imports Pte Ltd", "T26LL0001A"),
    ("Pasir Marigold Trading Pte Ltd", "T26LL0002B"),
    ("Kranji Bluefin Distribution Pte Ltd", "T26LL0003C"),
    ("Seletar Orchid Supplies Pte Ltd", "T26LL0004D"),
    ("Bedok Lumen Electronics Pte Ltd", "T26LL0005E"),
    ("Changi Saffron Foods Pte Ltd", "T26LL0006F"),
]
SUPPLIERS = [  # (name, country code, city, port)
    ("Selangor Ironwood Manufacturing Sdn Bhd", "MY", "Shah Alam", "Port Klang"),
    ("Penang Kestrel Components Sdn Bhd", "MY", "Bayan Lepas", "Penang"),
    ("Rayong Silverleaf Industries Co., Ltd.", "TH", "Rayong", "Laem Chabang"),
    ("Binh Duong Lotus Garment JSC", "VN", "Thu Dau Mot", "Cat Lai"),
    ("Surabaya Teakline Furniture PT", "ID", "Surabaya", "Tanjung Perak"),
    ("Ningbo Hailan Electrical Co., Ltd.", "CN", "Ningbo", "Ningbo"),
]
CN_NAMES = {"Ningbo Hailan Electrical Co., Ltd.": "宁波海澜电器有限公司"}
COUNTRY = {"MY": "Malaysia", "TH": "Thailand", "VN": "Viet Nam", "ID": "Indonesia",
           "CN": "China", "US": "United States", "SG": "Singapore", "IN": "India"}
PORT_COUNTRY = {"Port Klang": "MY", "Penang": "MY", "Laem Chabang": "TH", "Cat Lai": "VN",
                "Tanjung Perak": "ID", "Ningbo": "CN", "Shanghai": "CN", "Chennai": "IN"}

PRODUCTS = {  # by supplier country: (hs6, description, unit, unit price range USD, zh)
    "MY": [("8504.40", "Static converters (power supply units)", "PCS", (18, 40), None),
           ("8708.30", "Brake pads for motor vehicles", "SET", (22, 55), None),
           ("1511.90", "Refined palm olein, bulk", "MT", (850, 990), None)],
    "TH": [("4011.10", "New pneumatic radial tyres for cars", "PCS", (38, 70), None),
           ("8415.10", "Wall-mounted split air conditioners", "UNIT", (210, 340), None),
           ("2106.90", "Food preparations, instant noodle seasoning", "CTN", (14, 26), None)],
    "VN": [("6109.10", "Cotton knitted T-shirts", "PCS", (2.2, 4.8), None),
           ("6203.42", "Men's cotton trousers", "PCS", (5.5, 9.0), None)],
    "ID": [("9403.60", "Wooden dining tables, teak", "PCS", (120, 260), None),
           ("4818.10", "Toilet paper in rolls", "CTN", (9, 16), None)],
    "CN": [("8516.60", "Electric rice cookers", "PCS", (16, 30), "电饭煲"),
           ("8509.40", "Food grinders and mixers", "PCS", (12, 24), "食品搅拌机"),
           ("8414.51", "Table and floor fans", "PCS", (9, 18), "台式及落地电风扇")],
}

# Illustrative FTA rules (simplified for the demo; not legal guidance)
FTA_RULES = [
    {"fta_code": "ATIGA", "fta_name": "ASEAN Trade in Goods Agreement", "coo_form": "Form D",
     "member_countries": "SG|MY|TH|VN|ID|PH|BN|KH|LA|MM", "rvc_threshold_pct": 40,
     "max_days_issue_after_shipment": 3, "requires_direct_consignment": True},
    {"fta_code": "CSFTA", "fta_name": "China-Singapore FTA", "coo_form": "CSFTA CoO",
     "member_countries": "SG|CN", "rvc_threshold_pct": 40,
     "max_days_issue_after_shipment": 3, "requires_direct_consignment": True},
    {"fta_code": "RCEP", "fta_name": "Regional Comprehensive Economic Partnership",
     "coo_form": "RCEP Form", "member_countries": "SG|MY|TH|VN|ID|PH|BN|KH|LA|MM|CN|JP|KR|AU|NZ",
     "rvc_threshold_pct": 40, "max_days_issue_after_shipment": 3,
     "requires_direct_consignment": True},
]

# Planted defects (pack number -> list of defect codes). PP-0017 is the hero.
DEFECTS = {
    3: ["qty_mismatch"], 6: ["hs_mismatch"], 9: ["coo_issued_late"],
    11: ["consignee_mismatch"], 14: ["value_mismatch"],
    17: ["not_direct_consignment", "rvc_below_threshold"],
    20: ["origin_not_fta_member"], 23: ["qty_mismatch"], 26: ["rvc_below_threshold"],
    29: ["hs_mismatch"], 32: ["value_mismatch"], 35: ["origin_not_fta_member"],
    38: ["coo_issued_late"],
}
CHINESE_PACKS = {5, 15, 25, 36}
SCANNED = {2: {"invoice", "packing_list", "coo"}, 12: {"invoice", "coo"},
           19: {"invoice", "packing_list", "coo"}, 27: {"invoice"}, 31: {"coo"},
           39: {"invoice", "packing_list"}}

# Invoice layouts: label vocabulary + date format + look
LAYOUTS = {
    "L1_classic": dict(title="COMMERCIAL INVOICE", inv="Invoice No.", dt="Invoice Date",
                       seller="Seller / Exporter", buyer="Buyer / Consignee", fmt="%d %b %Y",
                       head=colors.HexColor("#1F3B57"), font="Helvetica"),
    "L2_banded": dict(title="Tax Invoice / Commercial Invoice", inv="Inv #", dt="Date",
                      seller="From", buyer="Bill To", fmt="%d/%m/%Y",
                      head=colors.HexColor("#B5472B"), font="Helvetica"),
    "L3_mono": dict(title="INVOICE", inv="REF", dt="ISSUED", seller="SHIPPER",
                    buyer="SOLD TO", fmt="%Y-%m-%d", head=colors.black, font="Courier"),
    "L4_twocol": dict(title="Commercial Invoice", inv="Document Number", dt="Document Date",
                      seller="Exporter of Record", buyer="Importer of Record", fmt="%B %d, %Y",
                      head=colors.HexColor("#2E6B3F"), font="Times-Roman"),
    "L5_grid": dict(title="PROFORMA / COMMERCIAL INVOICE", inv="Invoice Ref", dt="Inv. Date",
                    seller="Vendor", buyer="Customer", fmt="%d-%m-%Y",
                    head=colors.HexColor("#5A4A8A"), font="Helvetica"),
}
ZH_LAYOUT = dict(title="商业发票 COMMERCIAL INVOICE", inv="发票号 Invoice No.",
                 dt="日期 Date", seller="卖方 Seller", buyer="买方 Buyer", fmt="%Y年%m月%d日",
                 head=colors.HexColor("#8B1E1E"), font="STSong-Light")


# Pack model
def build_pack(n, rng):
    pack_id = f"PP-{n:04d}"
    defects = DEFECTS.get(n, [])
    chinese = n in CHINESE_PACKS
    sup = SUPPLIERS[5] if chinese else rng.choice(SUPPLIERS[:5])
    if n == 17:  # hero: Malaysian supplier, goods loaded in Shanghai
        sup = SUPPLIERS[0]
    imp = IMPORTERS[(n * 7) % len(IMPORTERS)]
    s_name, s_cc, s_city, s_port = sup
    fta = "CSFTA" if (chinese and n % 2) else ("RCEP" if chinese or n % 5 == 0 else "ATIGA")

    ship = date(2026, 9, 1) + timedelta(days=rng.randint(0, 75))
    inv_date = ship - timedelta(days=rng.randint(1, 6))
    currency = "CNY" if chinese else ("SGD" if n % 6 == 0 else "USD")
    fx = {"USD": 1.0, "SGD": 1.34, "CNY": 7.1}[currency]

    items = []
    for hs, desc, unit, (lo, hi), zh in rng.sample(PRODUCTS[s_cc], k=min(len(PRODUCTS[s_cc]), rng.randint(1, 3))):
        qty = rng.choice([20, 40, 50, 80, 100, 120, 200, 240, 500, 1000]) if unit != "MT" else rng.choice([18, 22, 25])
        price = round(rng.uniform(lo, hi) * fx, 2)
        items.append(dict(hs_code=hs, description=desc, description_zh=zh, unit=unit,
                          quantity=qty, unit_price=price, amount=round(qty * price, 2)))
    total = round(sum(i["amount"] for i in items), 2)

    port_of_loading = "Shanghai" if "not_direct_consignment" in defects else s_port
    invoice = dict(invoice_number=f"{s_cc}-INV-{rng.randint(10000, 99999)}",
                   invoice_date=inv_date.isoformat(), seller_name=s_name,
                   seller_country=s_cc, buyer_name=imp[0], buyer_uen=imp[1],
                   currency=currency, incoterm=rng.choice(["FOB", "CIF", "CFR"]),
                   port_of_loading=port_of_loading, port_of_discharge="Singapore",
                   shipment_date=ship.isoformat(), vessel=f"MV {rng.choice(['Straits', 'Andaman', 'Riau', 'Lumut', 'Sunda'])} {rng.choice(['Star', 'Pearl', 'Dawn', 'Wave'])}",
                   line_items=items, total_amount=total)

    pl_items = []
    for it in items:
        q = it["quantity"]
        if "qty_mismatch" in defects and it is items[0]:
            q = q - max(1, q // 10)
        pkgs = max(1, q // rng.choice([10, 20, 25, 50])) if it["unit"] != "MT" else 1
        pl_items.append(dict(hs_code=it["hs_code"], description=it["description"],
                             quantity=q, unit=it["unit"], packages=pkgs,
                             gross_weight_kg=round(q * rng.uniform(0.4, 9.0) if it["unit"] != "MT" else q * 1000 * 1.02, 1)))
    packing_list = dict(packing_list_number=f"PL-{invoice['invoice_number'][-5:]}",
                        invoice_reference=invoice["invoice_number"], shipper=s_name,
                        consignee=imp[0], line_items=pl_items,
                        total_packages=sum(p["packages"] for p in pl_items),
                        total_gross_weight_kg=round(sum(p["gross_weight_kg"] for p in pl_items), 1))

    origin_cc = s_cc
    if "origin_not_fta_member" in defects:
        origin_cc = "US" if fta == "ATIGA" else "IN"
    coo_items = []
    for it in items:
        hs = it["hs_code"]
        if "hs_mismatch" in defects and it is items[0]:
            hs = hs[:5] + ("9" if hs[-1] != "9" else "1")
        crit_rvc = rng.choice([None, 45, 52, 61])
        if "rvc_below_threshold" in defects and it is items[0]:
            crit_rvc = rng.choice([28, 31, 34])
        coo_items.append(dict(hs_code=hs, description=it["description"], quantity=it["quantity"],
                              origin_criterion=("RVC" if crit_rvc else rng.choice(["WO", "CTH"])),
                              rvc_percent=crit_rvc))
    issue = ship + timedelta(days=rng.randint(-2, 2))
    if "coo_issued_late" in defects:
        issue = ship + timedelta(days=rng.randint(9, 20))
    fob = total
    if "value_mismatch" in defects:
        fob = round(total * rng.choice([0.82, 1.21]), 2)
    consignee = imp[0]
    if "consignee_mismatch" in defects:
        consignee = IMPORTERS[(n * 7 + 3) % len(IMPORTERS)][0]
    coo = dict(certificate_number=f"{fta[:2]}{origin_cc}{ship.year}{rng.randint(100000, 999999)}",
               fta=fta, form=[r for r in FTA_RULES if r["fta_code"] == fta][0]["coo_form"],
               exporter=s_name, consignee=consignee, origin_country=origin_cc,
               invoice_reference=invoice["invoice_number"], invoice_value=fob,
               currency=currency, issue_date=issue.isoformat(),
               port_of_loading=port_of_loading, line_items=coo_items)

    layout = "ZH_bilingual" if chinese else list(LAYOUTS)[n % 5]
    return dict(pack_id=pack_id, defects=defects, layout=layout, chinese=chinese,
                invoice=invoice, packing_list=packing_list, coo=coo)


# Rendering
def _styles(font):
    return (ParagraphStyle("t", fontName=font, fontSize=16, leading=20),
            ParagraphStyle("b", fontName=font, fontSize=9, leading=12))


def _fmt(d, f):
    return date.fromisoformat(d).strftime(f)


def _grid(font, head):
    return TableStyle([("FONTNAME", (0, 0), (-1, -1), font), ("FONTSIZE", (0, 0), (-1, -1), 8.5),
                       ("BACKGROUND", (0, 0), (-1, 0), head), ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
                       ("GRID", (0, 0), (-1, -1), 0.4, colors.grey), ("VALIGN", (0, 0), (-1, -1), "TOP")])


def render_invoice(p, path):
    inv = p["invoice"]
    L = ZH_LAYOUT if p["chinese"] else LAYOUTS[p["layout"]]
    T, B = _styles(L["font"])
    seller = inv["seller_name"] + (f"<br/>{CN_NAMES[inv['seller_name']]}" if p["chinese"] else "")
    party = [[Paragraph(f"<b>{L['seller']}</b><br/>{seller}<br/>{COUNTRY[inv['seller_country']]}", B),
              Paragraph(f"<b>{L['buyer']}</b><br/>{inv['buyer_name']}<br/>UEN {inv['buyer_uen']}<br/>Singapore", B)]]
    if p["layout"] == "L4_twocol":
        party = [[party[0][1], party[0][0]]]  # importer first
    meta = [[f"{L['inv']}: {inv['invoice_number']}", f"{L['dt']}: {_fmt(inv['invoice_date'], L['fmt'])}"],
            [f"Incoterm: {inv['incoterm']}", f"Currency: {inv['currency']}"],
            [f"Port of Loading: {inv['port_of_loading']}", f"Vessel: {inv['vessel']}"],
            [f"Shipment / ETD: {_fmt(inv['shipment_date'], L['fmt'])}", f"Discharge: {inv['port_of_discharge']}"]]
    hdr = ["HS Code", "Description", "Qty", "Unit", "Unit Price", "Amount"]
    if p["chinese"]:
        hdr = ["税号 HS", "品名 Description", "数量 Qty", "单位", "单价 Price", "金额 Amount"]
    if p["layout"] == "L3_mono":
        hdr = ["TARIFF", "GOODS", "QTY", "UOM", "RATE", "VALUE"]
    rows = [hdr]
    for it in inv["line_items"]:
        d = it["description"] + (f" / {it['description_zh']}" if it["description_zh"] else "")
        rows.append([it["hs_code"], Paragraph(d, B), f"{it['quantity']:,}", it["unit"],
                     f"{it['unit_price']:,.2f}", f"{it['amount']:,.2f}"])
    total_lbl = {"L2_banded": "Amount Due", "L3_mono": "TOTAL VALUE", "L5_grid": "Grand Total"}.get(p["layout"], "Total")
    if p["chinese"]:
        total_lbl = "合计 Total"
    rows.append(["", "", "", "", total_lbl, f"{inv['currency']} {inv['total_amount']:,.2f}"])
    t = Table(rows, colWidths=[22 * mm, 70 * mm, 18 * mm, 14 * mm, 24 * mm, 30 * mm])
    t.setStyle(_grid(L["font"], L["head"]))
    story = [Paragraph(L["title"], T), Spacer(1, 6),
             Table(party, colWidths=[89 * mm, 89 * mm]), Spacer(1, 6),
             Table(meta, colWidths=[89 * mm, 89 * mm], style=[("FONTNAME", (0, 0), (-1, -1), L["font"]), ("FONTSIZE", (0, 0), (-1, -1), 8.5)]),
             Spacer(1, 8), t, Spacer(1, 14),
             Paragraph("We certify this invoice is true and correct. Authorised signatory: ________", B)]
    SimpleDocTemplate(str(path), pagesize=A4, topMargin=16 * mm, bottomMargin=16 * mm).build(story)


def render_packing_list(p, path):
    pl, inv = p["packing_list"], p["invoice"]
    font = "STSong-Light" if p["chinese"] else "Helvetica"
    T, B = _styles(font)
    title = "装箱单 PACKING LIST" if p["chinese"] else "PACKING LIST"
    rows = [["HS Code", "Description", "Quantity", "Unit", "Packages", "Gross Wt (kg)"]]
    for it in pl["line_items"]:
        rows.append([it["hs_code"], Paragraph(it["description"], B), f"{it['quantity']:,}", it["unit"],
                     str(it["packages"]), f"{it['gross_weight_kg']:,.1f}"])
    rows.append(["", "TOTAL", "", "", str(pl["total_packages"]), f"{pl['total_gross_weight_kg']:,.1f}"])
    t = Table(rows, colWidths=[22 * mm, 72 * mm, 20 * mm, 14 * mm, 20 * mm, 30 * mm])
    t.setStyle(_grid(font, colors.HexColor("#44546A")))
    story = [Paragraph(title, T), Spacer(1, 6),
             Paragraph(f"Packing List No: {pl['packing_list_number']} &nbsp;&nbsp; Invoice Ref: {pl['invoice_reference']}", B),
             Paragraph(f"Shipper: {pl['shipper']}", B), Paragraph(f"Consignee: {pl['consignee']}", B),
             Paragraph(f"Port of Loading: {inv['port_of_loading']} &nbsp;&nbsp; Vessel: {inv['vessel']}", B),
             Spacer(1, 8), t]
    SimpleDocTemplate(str(path), pagesize=A4, topMargin=16 * mm).build(story)


def render_coo(p, path):
    c = p["coo"]
    font = "STSong-Light" if p["chinese"] else "Times-Roman"
    T, B = _styles(font)
    title = f"CERTIFICATE OF ORIGIN ({c['form']})"
    if p["chinese"]:
        title = f"原产地证书 {title}"
    boxes = [[Paragraph(f"1. Exporter<br/>{c['exporter']}", B), Paragraph(f"Reference No.<br/><b>{c['certificate_number']}</b>", B)],
             [Paragraph(f"2. Consignee<br/>{c['consignee']}, Singapore", B), Paragraph(f"Issued under: {c['fta']}<br/>Country of origin: {COUNTRY[c['origin_country']]}", B)],
             [Paragraph(f"3. Means of transport: by sea, port of loading {c['port_of_loading']}", B), Paragraph(f"Invoice: {c['invoice_reference']}<br/>Invoice value: {c['currency']} {c['invoice_value']:,.2f}", B)]]
    bt = Table(boxes, colWidths=[100 * mm, 78 * mm])
    bt.setStyle(TableStyle([("BOX", (0, 0), (-1, -1), 0.8, colors.black), ("INNERGRID", (0, 0), (-1, -1), 0.4, colors.black)]))
    rows = [["Item", "HS Code", "Description of goods", "Quantity", "Origin criterion"]]
    for i, it in enumerate(c["line_items"], 1):
        crit = f"RVC {it['rvc_percent']}%" if it["origin_criterion"] == "RVC" else it["origin_criterion"]
        rows.append([str(i), it["hs_code"], Paragraph(it["description"], B), f"{it['quantity']:,}", crit])
    t = Table(rows, colWidths=[12 * mm, 22 * mm, 82 * mm, 24 * mm, 38 * mm])
    t.setStyle(_grid(font, colors.HexColor("#3A3A3A")))
    story = [Paragraph(title, T), Spacer(1, 6), bt, Spacer(1, 8), t, Spacer(1, 12),
             Paragraph(f"Certification: issued on {_fmt(c['issue_date'], '%d %B %Y')} by the issuing authority of {COUNTRY[c['origin_country'] if c['origin_country'] in COUNTRY else 'SG']}. Signature and stamp: ________", B)]
    SimpleDocTemplate(str(path), pagesize=A4, topMargin=16 * mm).build(story)


def to_scan(pdf_path, png_path, rng):
    """Rasterise page 1, then add rotation, blur, and noise like a phone/desk scan."""
    pdf = pdfium.PdfDocument(str(pdf_path))
    img = pdf[0].render(scale=110 / 72).to_pil().convert("L")
    pdf.close()
    img = img.rotate(rng.uniform(-2.2, 2.2), expand=True, fillcolor=235).filter(ImageFilter.GaussianBlur(0.6))
    px = img.load()
    for _ in range(img.size[0] * img.size[1] // 60):
        x, y = rng.randrange(img.size[0]), rng.randrange(img.size[1])
        px[x, y] = rng.choice([90, 160, 255])
    img.save(png_path, optimize=True)
    pdf_path.unlink()


def main(out, overwrite=False):
    rng = random.Random(SEED)
    scan_rng = random.Random(SEED + 1)  # separate stream: skipping a pack never shifts the data
    out = Path(out)
    if overwrite:
        for sub in ("inbox", "reference", "ground_truth"):
            shutil.rmtree(out / sub, ignore_errors=True)
    for sub in ("inbox", "reference", "ground_truth"):
        (out / sub).mkdir(parents=True, exist_ok=True)
    manifest, truths, written = [], [], 0
    for n in range(1, N_PACKS + 1):
        p = build_pack(n, rng)
        pdir = out / "inbox" / p["pack_id"]
        exists = pdir.exists() and len(list(pdir.iterdir())) == 3
        pdir.mkdir(exist_ok=True)
        for doc_type, fn in [("invoice", render_invoice), ("packing_list", render_packing_list), ("coo", render_coo)]:
            scanned = doc_type in SCANNED.get(n, set())
            pdf = pdir / f"{p['pack_id']}_{doc_type}.pdf"
            final = pdf.with_suffix(".png") if scanned else pdf
            if not exists:
                # render to local disk first; volumes are not ideal for in-place edits
                tmp = Path("/tmp") / pdf.name
                fn(p, tmp)
                if scanned:
                    to_scan(tmp, tmp.with_suffix(".png"), scan_rng)
                    tmp = tmp.with_suffix(".png")
                shutil.copyfile(tmp, final); tmp.unlink()
                written += 1
            manifest.append(dict(pack_id=p["pack_id"], doc_type=doc_type, file_name=final.name,
                                 layout=p["layout"] if doc_type == "invoice" else f"{doc_type}_std",
                                 language="zh-en" if p["chinese"] else "en", is_scanned=scanned))
        truths.append(dict(pack_id=p["pack_id"], defects=p["defects"], invoice=p["invoice"],
                           packing_list=p["packing_list"], coo=p["coo"]))
    with open(out / "ground_truth" / "packs.jsonl", "w") as f:
        for t in truths:
            f.write(json.dumps(t, ensure_ascii=False) + "\n")
    with open(out / "ground_truth" / "documents.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(manifest[0]))
        w.writeheader(); w.writerows(manifest)
    with open(out / "reference" / "fta_rules.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(FTA_RULES[0]))
        w.writeheader(); w.writerows(FTA_RULES)
    with open(out / "reference" / "ports.csv", "w", newline="") as f:
        w = csv.writer(f); w.writerow(["port_name", "country_code"])
        for port, cc in PORT_COUNTRY.items(): w.writerow([port, cc])
        w.writerow(["Singapore", "SG"])
    with open(out / "reference" / "traders.csv", "w", newline="") as f:
        w = csv.writer(f); w.writerow(["trader_name", "uen", "role", "country"])
        for nm, uen in IMPORTERS: w.writerow([nm, uen, "importer", "SG"])
        for nm, cc, _, _ in SUPPLIERS: w.writerow([nm, "", "supplier", cc])
    n_def = sum(1 for t in truths if t["defects"])
    print(f"written={written} packs={len(truths)} docs={len(manifest)} scanned={sum(m['is_scanned'] for m in manifest)} "
          f"chinese_packs={len(CHINESE_PACKS)} defect_packs={n_def}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", required=True)
    ap.add_argument("--schema", default="customs_permit_idp")
    ap.add_argument("--out", default=None, help="override output dir (e.g. local test)")
    ap.add_argument("--overwrite", action="store_true")
    a = ap.parse_args()
    main(a.out or f"/Volumes/{a.catalog}/{a.schema}/permit_packs", a.overwrite)
