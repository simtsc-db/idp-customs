# Permit Pack Check: intelligent document processing for trade permits

Reference demo for a customs authority's trade permit review (synthetic data only).

## 1. Business problem and KPIs

Trade officers re-key trader permit packs (commercial invoice, packing list,
Certificate of Origin) and check them by eye against each other and against
FTA origin rules. Invoices arrive in every layout, some scanned, some bilingual.

| KPI | Baseline | Target | Demo result |
|---|---|---|---|
| Field extraction accuracy | manual | >= 97% (business target) | 99.80% on 2,016 fields |
| Officer time per pack | 15 min (assumption) | 5 min (assumption) | 60% of packs auto-cleared, no re-keying |
| Planted mismatches / rule breaches caught | n/a | >= 95% | 100% (14 of 14) |
| GenAI cost per pack | unknown | measured | from `system.billing` (pending billing lag) |

Value (assumption, to validate): 50,000 packs/yr x 15 min = 12,500 officer-hours,
about S$750K/yr at S$60/hr. Cutting to 5 min saves about 8,300 hours, about S$500K/yr.

## 2. Architecture

```
trader PDFs/scans -> UC Volume -> Lakeflow SDP (medallion)
   bronze_documents      ai_parse_document v2 (OCR + layout)
   silver_documents      ai_classify  (invoice | packing list | CoO)
   silver_<doc type>     ai_extract v2.1 (value + confidence + citations)
   gold_pack_checks      11 checks: cross-document + FTA rules (ref_fta_rules owned by Trade)
   gold_permit_drafts    auto-populated permit, AUTO_CLEARED | NEEDS_REVIEW
        |-> Lakebase synced tables -> Databricks App "permit-review" (officer decisions -> Lakebase)
        |-> Genie space "Permit Pack Check - Trade Division"
        |-> MLflow scorecard (accuracy vs ground truth, cost per pack)
```

| Component | Where |
|---|---|
| Synthetic data generator (serverless job task) | [src/00_generate_data.py](src/00_generate_data.py) |
| Lakeflow SDP pipeline (one dataset per file) | [src/01_pipeline/transformations/](src/01_pipeline/transformations/) |
| Governance (tags, Genie column comments) | [src/02_governance.sql](src/02_governance.sql) |
| Lakebase snapshot refresh | [src/03_refresh_lakebase.py](src/03_refresh_lakebase.py) |
| Accuracy and cost scorecard | [src/04_eval/evaluate.py](src/04_eval/evaluate.py) |
| Genie space definition | [src/05_genie/permit_review.genie.json](src/05_genie/permit_review.genie.json) |
| Officer review app (AppKit, Lakebase, Files) | [app/](app/) |
| Bundle resources (job, pipeline, Lakebase, app, Genie, experiment) | [resources/](resources/) |

## 3. Setup

Prereqs: Databricks CLI >= 1.20, a CLI profile for your workspace (`<profile>`), Node 22, Python 3,
and your organisation's package mirrors in `PIP_INDEX_URL` and `NPM_REGISTRY`.
Defaults assume catalog `sg_pubsec_catalog` and a warehouse named "Serverless Starter Warehouse";
override with `--var catalog=<catalog>` / `--var warehouse_id=<id>`.

```bash
scripts/stage_wheels.sh <profile>               # once: datagen wheels from the PyPI mirror -> UC volume
scripts/build_app.sh                            # AppKit app -> self-contained app_dist/ (npm mirror only)
databricks bundle validate --strict -p <profile>
databricks bundle deploy -p <profile>
databricks bundle run permit_idp_demo -p <profile>   # ~6 min first run, ~5 min after
databricks bundle run permit_review_app -p <profile>
# once, as Lakebase project owner: grant the app SP read on synced tables
SP=$(databricks apps get permit-review -p <profile> -o json | jq -r .service_principal_client_id)
databricks psql --project customs-permit-idp -p <profile> -- -c \
  "GRANT USAGE ON SCHEMA customs_permit_idp TO \"$SP\"; GRANT SELECT ON ALL TABLES IN SCHEMA customs_permit_idp TO \"$SP\";"
python3 scripts/genie_check.py <genie_space_id> <profile>   # writes evidence/genie_qa.md
```

Notes on dependencies: in the build environment, serverless jobs and the Apps build
could not use the internal package mirrors, and public registries were not allowed. The datagen
task therefore installs pinned wheels from a UC volume, and the app ships as
a prebuilt bundle with no runtime dependencies (`tsdown.deploy.config.ts`).

## 4. Demo script (10 min, outcome first)

1. **App (4 min)**: open the review queue. 24 of 40 packs auto-cleared. Open
   **PP-0017**: ATIGA claim for Malaysian goods, but loaded in Shanghai (R04)
   and RVC 34% < 40% (R02). Show the source CoO PDF next to the extracted
   permit and confidence. Record "Request info from trader".
2. **Genie (2 min)**: "Which importers had the most FTA origin-rule exceptions
   in the last 90 days?", "What share of permit packs were auto-cleared?"
3. **Scorecard (2 min)**: MLflow experiment `permit_idp_eval`: 99.80% field
   accuracy, 98.67% on scans, 100% defect recall; the 4 wrong fields and why.
4. **How (2 min, if asked)**: pipeline graph, UC lineage from PDF to permit,
   rules table owned by Trade.

## 5. Real vs simulated, limitations

- Real: every pipeline run, extraction, check and accuracy metric is produced by the job (scorecard in `eval_scorecard` + MLflow); `scripts/genie_check.py` records Genie answers locally.
- Simulated: all traders, documents, UENs, certificate numbers. FTA rules are simplified and illustrative, not legal guidance. KPI baselines and S$ value are assumptions.
- Region: demo runs in us-east-1. In ap-southeast-1, `ai_parse_document` / `ai_extract` v2 process within the Asia geo (Japan, South Korea or Singapore); pay-per-token Foundation Model APIs need cross-geography routing. Validate against your data classification requirements.
- Chinese accuracy is from a small sample (4 packs); the docs note `ai_parse_document` may underperform on non-Latin text in images.
- Cost per pack is pending until billing rows land; re-run the `evaluate_accuracy_and_cost` task.
- Lakebase synced tables use SNAPSHOT mode (sources are materialized views) and are refreshed by the job.
- Excel input is not parsed by `ai_parse_document`; it is out of scope for this demo.
