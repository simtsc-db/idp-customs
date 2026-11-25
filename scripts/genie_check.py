"""Ask the Genie space its sample questions and write evidence/genie_qa.md.

Usage: python3 scripts/genie_check.py <space_id> <profile>
Uses the Databricks CLI (Genie Conversation API); prints question, status,
generated SQL and the first result rows for each question.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

space = sys.argv[1]
prof = sys.argv[2]
spec = json.loads(Path(__file__).parent.parent.joinpath("src/05_genie/permit_review.genie.json").read_text())
questions = [q["question"][0] for q in spec["config"]["sample_questions"]]


def cli(*args):
    out = subprocess.run(["databricks", *args, "-p", prof, "-o", "json"], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip()[:500])
    return json.loads(out.stdout) if out.stdout.strip() else {}


lines = ["# Genie Q&A evidence", "", f"Space `{space}` (warehouse-backed, synthetic data). Generated {time.strftime('%Y-%m-%d %H:%M')}.", ""]
for q in questions:
    msg = cli("genie", "start-conversation", space, q, "--no-wait")
    conv, mid = msg["conversation_id"], msg.get("message_id") or msg.get("id")
    for _ in range(60):
        m = cli("genie", "get-message", space, conv, mid)
        if m.get("status") in ("COMPLETED", "FAILED", "CANCELLED"):
            break
        time.sleep(5)
    lines += [f"## {q}", "", f"Status: **{m.get('status')}**", ""]
    for att in m.get("attachments", []) or []:
        if att.get("text"):
            lines += [att["text"].get("content", "").strip(), ""]
        if att.get("query"):
            lines += ["```sql", att["query"].get("query", "").strip(), "```", ""]
            res = cli("genie", "get-message-attachment-query-result", space, conv, mid, att["attachment_id"])
            sr = res.get("statement_response", {})
            cols = [c["name"] for c in sr.get("manifest", {}).get("schema", {}).get("columns", [])]
            rows = (sr.get("result", {}) or {}).get("data_array", []) or []
            if cols:
                lines += ["| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
                lines += ["| " + " | ".join("" if v is None else str(v) for v in r) + " |" for r in rows[:8]]
                lines += ["", f"_{len(rows)} row(s)_", ""]
    print(q, "->", m.get("status"))

out = Path(__file__).parent.parent / "evidence" / "genie_qa.md"
# House style: no en/em dashes in demo content; this is the only change made to Genie output.
out.write_text("\n".join(lines).replace("\u2014", "--").replace("\u2013", "--"))
print("wrote", out)
