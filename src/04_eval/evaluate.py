"""Scorecard job task: extraction accuracy vs ground truth, defect recall, cost per pack.

Writes eval_field_results and eval_scorecard and logs an MLflow run. Cost comes from
system.billing.usage and stays NULL until billing rows land (never estimated).
"""
import argparse
import json
from datetime import date

import mlflow
import pandas as pd
from pyspark.sql import SparkSession

ap = argparse.ArgumentParser()
ap.add_argument("--catalog", required=True)
ap.add_argument("--schema", default="customs_permit_idp")
ap.add_argument("--pipeline_id", required=True)
ap.add_argument("--experiment", required=True)
a = ap.parse_args()
S = f"{a.catalog}.{a.schema}"
VOL = f"/Volumes/{a.catalog}/{a.schema}/permit_packs"
spark = SparkSession.builder.getOrCreate()

# ground truth
truth = [json.loads(r.value) for r in spark.read.text(f"{VOL}/ground_truth/packs.jsonl").collect()]
docs = spark.read.option("header", True).csv(f"{VOL}/ground_truth/documents.csv").toPandas()
docs["is_scanned"] = docs["is_scanned"].astype(str).str.lower() == "true"
seg = {(r.pack_id, r.doc_type): r for r in docs.itertuples()}

inv = {r["pack_id"]: r.asDict(recursive=True) for r in spark.table(f"{S}.silver_invoices").collect()}
pls = {r["pack_id"]: r.asDict(recursive=True) for r in spark.table(f"{S}.silver_packing_lists").collect()}
coo = {r["pack_id"]: r.asDict(recursive=True) for r in spark.table(f"{S}.silver_certificates_of_origin").collect()}


def norm_s(v):
    return " ".join(str(v).split()).strip().lower() if v is not None else None


def norm_hs(v):
    return "".join(ch for ch in str(v) if ch.isdigit()) if v is not None else None


def eq(kind, t, p):
    if t is None:
        return p is None
    if p is None:
        return False
    if kind == "num":
        return abs(float(t) - float(p)) <= max(0.01, 0.0005 * abs(float(t)))
    if kind == "date":
        return str(t) == str(p)[:10]
    if kind == "hs":
        return norm_hs(t) == norm_hs(p)
    return norm_s(t) == norm_s(p)


SPEC = {  # doc_type -> (header fields, line fields); kinds: str/num/date/hs
    "invoice": ([("invoice_number", "str"), ("invoice_date", "date"), ("seller_name", "str"), ("seller_country", "str"),
                 ("buyer_name", "str"), ("buyer_uen", "str"), ("currency", "str"), ("incoterm", "str"),
                 ("port_of_loading", "str"), ("shipment_date", "date"), ("total_amount", "num")],
                [("hs_code", "hs"), ("quantity", "num"), ("unit_price", "num"), ("amount", "num")]),
    "packing_list": ([("packing_list_number", "str"), ("invoice_reference", "str"), ("shipper", "str"),
                      ("consignee", "str"), ("total_packages", "num"), ("total_gross_weight_kg", "num")],
                     [("hs_code", "hs"), ("quantity", "num"), ("packages", "num"), ("gross_weight_kg", "num")]),
    "coo": ([("certificate_number", "str"), ("fta", "str"), ("exporter", "str"), ("consignee", "str"),
             ("origin_country", "str"), ("invoice_reference", "str"), ("invoice_value", "num"),
             ("currency", "str"), ("issue_date", "date"), ("port_of_loading", "str")],
            [("hs_code", "hs"), ("quantity", "num"), ("origin_criterion", "str"), ("rvc_percent", "num")]),
}

rows = []
for t in truth:
    pid = t["pack_id"]
    for doc_type, src, pred in [("invoice", t["invoice"], inv.get(pid)), ("packing_list", t["packing_list"], pls.get(pid)),
                                ("coo", t["coo"], coo.get(pid))]:
        hdr, lin = SPEC[doc_type]
        s = seg[(pid, doc_type)]
        base = dict(pack_id=pid, doc_type=doc_type, layout=s.layout, language=s.language, is_scanned=bool(s.is_scanned))
        for f, k in hdr:
            pv = (pred or {}).get(f)
            tv = src.get(f)
            rows.append(dict(base, field=f, truth=str(tv), extracted=None if pv is None else str(pv), match=eq(k, tv, pv)))
        plines = (pred or {}).get("line_items") or []
        for i, tl in enumerate(src["line_items"]):
            pl = plines[i] if i < len(plines) else {}
            for f, k in lin:
                rows.append(dict(base, field=f"line{i + 1}.{f}", truth=str(tl.get(f)),
                                 extracted=None if pl.get(f) is None else str(pl.get(f)), match=eq(k, tl.get(f), pl.get(f))))
fr = pd.DataFrame(rows)

# defect detection
DEFECT_CHECK = {"qty_mismatch": "X02", "hs_mismatch": "X03", "coo_issued_late": "R03", "consignee_mismatch": "X05",
                "value_mismatch": "X04", "not_direct_consignment": "R04", "rvc_below_threshold": "R02",
                "origin_not_fta_member": "R01"}
failed = spark.sql(f"SELECT pack_id, collect_set(check_code) codes FROM {S}.gold_pack_checks WHERE NOT passed GROUP BY 1").toPandas()
failed = {r.pack_id: set(r.codes) for r in failed.itertuples()}
planted = [(t["pack_id"], d) for t in truth for d in t["defects"]]
caught = [(p, d) for p, d in planted if DEFECT_CHECK[d] in failed.get(p, set())]
defect_packs = {t["pack_id"] for t in truth if t["defects"]}
flagged = set(failed)
clean_packs = {t["pack_id"] for t in truth} - defect_packs

# cost from billing
cost = spark.sql(f"""
  SELECT round(sum(u.usage_quantity * p.pricing.default), 2) AS usd, round(sum(u.usage_quantity), 3) AS dbu
  FROM system.billing.usage u
  JOIN system.billing.list_prices p
    ON p.sku_name = u.sku_name AND u.usage_start_time >= p.price_start_time
   AND (p.price_end_time IS NULL OR u.usage_start_time < p.price_end_time)
  WHERE u.usage_metadata.dlt_pipeline_id = '{a.pipeline_id}'
""").first()
usd = float(cost.usd) if cost and cost.usd is not None else None

# scorecard
def acc(df):
    return round(100.0 * df["match"].mean(), 2) if len(df) else None

m = []
m.append(("field_accuracy_pct", "all", acc(fr), len(fr)))
for col in ["doc_type", "layout", "language", "is_scanned"]:
    for k, g in fr.groupby(col):
        m.append(("field_accuracy_pct", f"{col}={k}", acc(g), len(g)))
m.append(("defect_recall_pct", "planted defects", round(100.0 * len(caught) / len(planted), 2), len(planted)))
m.append(("packs_flagged_with_planted_defect_pct", "precision", round(100.0 * len(flagged & defect_packs) / max(1, len(flagged)), 2), len(flagged)))
m.append(("clean_packs_auto_cleared_pct", "clean packs", round(100.0 * len(clean_packs - flagged) / len(clean_packs), 2), len(clean_packs)))
m.append(("packs_needing_review", "all packs", float(len(flagged)), len(truth)))
m.append(("pipeline_cost_usd_list", "all packs", usd, len(truth)))
m.append(("cost_per_pack_usd_list", "per pack", round(usd / len(truth), 4) if usd else None, len(truth)))
sc = pd.DataFrame(m, columns=["metric", "segment", "value", "n"])
sc["evaluated_on"] = date.today().isoformat()

spark.createDataFrame(fr).write.mode("overwrite").option("overwriteSchema", True).saveAsTable(f"{S}.eval_field_results")
spark.createDataFrame(sc).write.mode("overwrite").option("overwriteSchema", True).saveAsTable(f"{S}.eval_scorecard")
spark.sql(f"COMMENT ON TABLE {S}.eval_field_results IS 'Field-level extraction accuracy vs synthetic ground truth, one row per pack x document x field.'")
spark.sql(f"COMMENT ON TABLE {S}.eval_scorecard IS 'Headline IDP metrics: field accuracy by segment, defect recall, auto-clear rate, list-price cost per pack (NULL until billing rows land).'")

mlflow.set_experiment(a.experiment)
with mlflow.start_run(run_name=f"permit-idp-eval-{date.today().isoformat()}"):
    mlflow.log_params({"pipeline_id": a.pipeline_id, "packs": len(truth), "documents": len(docs),
                       "extract_model": "ai_extract v2.1", "parse_model": "ai_parse_document v2.0"})
    for r in sc.itertuples():
        if r.value is not None:
            key = f"{r.metric}__{r.segment}".replace("=", "_").replace(" ", "_")
            mlflow.log_metric(key[:250], float(r.value))
    mlflow.log_table(fr, "field_results.json")
    mlflow.log_table(sc, "scorecard.json")

print(sc.to_string(index=False))
print("\nMismatched fields:")
print(fr[~fr["match"]][["pack_id", "doc_type", "field", "truth", "extracted", "is_scanned", "language"]].to_string(index=False))
