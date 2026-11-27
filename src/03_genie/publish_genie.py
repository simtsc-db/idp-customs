"""Job task: create or update the Genie space once the gold tables exist (matched by title)."""
import argparse
import json
from pathlib import Path

from databricks.sdk import WorkspaceClient

ap = argparse.ArgumentParser()
ap.add_argument("--catalog", required=True)
ap.add_argument("--schema", required=True)
ap.add_argument("--warehouse_id", required=True)
ap.add_argument("--parent_path", required=True)
ap.add_argument("--spec", required=True, help="path to permit_review.genie.json")
ap.add_argument("--title", default="Permit Pack Check - Trade Division")
a = ap.parse_args()

spec = Path(a.spec).read_text().replace("__CATALOG__", a.catalog).replace("__SCHEMA__", a.schema)
body = {
    "title": a.title,
    "description": "Ask about trader permit packs: auto-clear rate, FTA origin-rule exceptions, "
                   "failing checks, high-priority packs. Synthetic demo data.",
    "warehouse_id": a.warehouse_id,
    "serialized_space": json.dumps(json.loads(spec)),
}

w = WorkspaceClient()
existing, token = None, None
while existing is None:
    page = w.api_client.do("GET", "/api/2.0/genie/spaces", query={"page_token": token} if token else None)
    existing = next((s for s in page.get("spaces", []) if s.get("title") == a.title), None)
    token = page.get("next_page_token")
    if not token:
        break

if existing:
    space_id = existing["space_id"]
    w.api_client.do("PATCH", f"/api/2.0/genie/spaces/{space_id}", body=body)
    print(f"updated Genie space {space_id}")
else:
    space_id = w.api_client.do("POST", "/api/2.0/genie/spaces", body={**body, "parent_path": a.parent_path})["space_id"]
    print(f"created Genie space {space_id}")
print(f"{w.config.host}/genie/rooms/{space_id}")
