# Permit Pack Check

Intelligent document processing for customs trade permits, on synthetic data.
Officers review exceptions instead of re-keying every invoice, packing list and
Certificate of Origin.

## Results (40 synthetic packs, 120 documents)

| KPI | Target | Result |
|---|---|---|
| Field extraction accuracy | >= 97% | 99.80% (98.67% on scans) |
| Planted defects caught | >= 95% | 100% (14 of 14) |
| Packs auto-cleared | n/a | 60% (24 of 40) |
| Cost per pack | measured | from `system.billing` once billing rows land |

Value (assumption): 50,000 packs/yr x 15 min = 12,500 h (~S$750K at S$60/h);
at 5 min per pack, ~8,300 h (~S$500K) saved.

## Architecture

```
PDFs/scans -> UC Volume -> Lakeflow SDP
  bronze  ai_parse_document (OCR + layout)
  silver  ai_classify, ai_extract (value, confidence, citations)
  gold    11 cross-document + FTA rule checks -> permit drafts
     -> Lakebase -> Databricks App (officer review, decisions)
     -> Genie space
     -> MLflow scorecard
```

| Path | Contents |
|---|---|
| `src/00_generate_data.py` | Synthetic packs + ground truth (job task) |
| `src/01_pipeline/transformations/` | Pipeline, one dataset per file |
| `src/02_governance.sql` | Tags and Genie column comments |
| `src/03_refresh_lakebase.py` | Lakebase synced-table refresh |
| `src/04_eval/evaluate.py` | Accuracy and cost scorecard |
| `app/` | AppKit review app (Lakebase, Files) |
| `resources/` | Bundle resources, incl. the Genie space definition |

## Setup

Needs Databricks CLI >= 1.20, Node 22, Python 3, a CLI profile, and package
mirrors in `PIP_INDEX_URL` and `NPM_REGISTRY`. The catalog is required
(`--var catalog=<catalog>` or `.databricks/bundle/dev/variable-overrides.json`).

```bash
scripts/stage_wheels.sh <profile> <catalog>    # once: datagen wheels -> UC volume
scripts/build_app.sh                           # app -> app_dist/
databricks bundle deploy -p <profile> --var catalog=<catalog>
databricks bundle run permit_idp_demo -p <profile> --var catalog=<catalog>
databricks bundle run permit_review_app -p <profile> --var catalog=<catalog>
# once, as Lakebase owner: let the app read the synced tables
SP=$(databricks apps get permit-review -p <profile> -o json | jq -r .service_principal_client_id)
databricks psql --project customs-permit-idp -p <profile> -- -c \
  "GRANT USAGE ON SCHEMA customs_permit_idp TO \"$SP\"; GRANT SELECT ON ALL TABLES IN SCHEMA customs_permit_idp TO \"$SP\";"
```

Serverless jobs and the Apps build could not reach our package mirrors, so the
datagen task installs wheels from a UC volume and the app ships prebuilt with
no runtime dependencies.

## Demo (10 min)

1. **App**: open pack PP-0017. The ATIGA claim fails two rules: loaded in Shanghai (R04) and RVC 34% < 40% (R02). Request info from the trader.
2. **Genie**: "Which importers had the most FTA origin-rule exceptions in the last 90 days?"
3. **Scorecard**: MLflow experiment `permit_idp_eval`, including the 4 wrong fields.

## Limitations

- Data, traders and FTA rules are synthetic or simplified; value figures are assumptions.
- Demo runs in us-east-1. In ap-southeast-1, `ai_parse_document` / `ai_extract` process in the Asia geo; pay-per-token models need cross-geography routing.
- Chinese accuracy rests on 4 packs only. Excel input is out of scope.
- Synced tables use SNAPSHOT mode; the job refreshes them.
