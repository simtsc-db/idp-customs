"""Dev helper: run one SQL statement on a SQL warehouse via the Databricks CLI (Statement Execution API) and print rows as JSON lines. Usage: python3 scripts/sql.py "<sql>" | file.sql"""
import json, subprocess, sys, time
import os
prof = os.environ["DATABRICKS_CONFIG_PROFILE"]  # your CLI profile
wh = os.environ["WAREHOUSE_ID"]               # a serverless SQL warehouse id
q = open(sys.argv[1]).read() if sys.argv[1].endswith(".sql") else sys.argv[1]
def api(method, path, body=None):
    cmd = ["databricks", "api", method, path, "-p", prof]
    if body: cmd += ["--json", json.dumps(body)]
    return json.loads(subprocess.check_output(cmd))
r = api("post", "/api/2.0/sql/statements", {"statement": q, "warehouse_id": wh, "wait_timeout": "50s", "on_wait_timeout": "CONTINUE", "format": "JSON_ARRAY", "disposition": "INLINE"})
while r["status"]["state"] in ("PENDING", "RUNNING"):
    time.sleep(5); r = api("get", f"/api/2.0/sql/statements/{r['statement_id']}")
if r["status"]["state"] != "SUCCEEDED":
    print("STATE", r["status"]); sys.exit(1)
cols = [c["name"] for c in r.get("manifest", {}).get("schema", {}).get("columns", [])]
if not cols:
    print("OK"); sys.exit(0)
for row in r.get("result", {}).get("data_array", []) or []:
    print(json.dumps(dict(zip(cols, row)), ensure_ascii=False))
