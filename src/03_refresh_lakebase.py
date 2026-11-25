"""Job task: re-snapshot the gold tables synced to Lakebase and wait until online."""
import argparse
import time

from databricks.sdk import WorkspaceClient

ap = argparse.ArgumentParser()
ap.add_argument("--catalog", required=True)
ap.add_argument("--schema", default="customs_permit_idp")
a = ap.parse_args()

w = WorkspaceClient()
TABLES = ["lb_gold_permit_drafts", "lb_gold_pack_checks", "lb_gold_permit_items"]


def synced(name):
    return w.api_client.do("GET", f"/api/2.0/postgres/synced_tables/{a.catalog}.{a.schema}.{name}")


pipelines = {}
for t in TABLES:
    pid = synced(t)["status"]["pipeline_id"]
    pipelines[t] = pid
    w.pipelines.start_update(pipeline_id=pid, full_refresh=False)
    print(f"started refresh {t} -> pipeline {pid}")

deadline = time.time() + 30 * 60
pending = set(TABLES)
while pending and time.time() < deadline:
    time.sleep(20)
    for t in list(pending):
        state = synced(t)["status"].get("detailed_state", "")
        if state == "SYNCED_TABLE_ONLINE_NO_PENDING_UPDATE":
            print(f"{t}: {state}")
            pending.discard(t)
        elif "FAILED" in state or "OFFLINE" in state:
            raise RuntimeError(f"{t} sync failed: {state}")
if pending:
    raise TimeoutError(f"synced tables still refreshing: {sorted(pending)}")
print("all synced tables online")
