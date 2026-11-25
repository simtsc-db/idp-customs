// Review API: reads synced gold tables, writes officer decisions to review_app.
import { z } from 'zod';
import type { Application, Request } from 'express';

interface AppKitWithLakebase {
  lakebase: {
    query(text: string, params?: unknown[]): Promise<{ rows: Record<string, unknown>[] }>;
  };
  server: {
    extend(fn: (app: Application) => void): void;
  };
}

const SYNCED = 'customs_permit_idp';

const SETUP_SQL = [
  `CREATE SCHEMA IF NOT EXISTS review_app`,
  `CREATE TABLE IF NOT EXISTS review_app.officer_decisions (
     id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
     pack_id TEXT NOT NULL,
     decision TEXT NOT NULL CHECK (decision IN ('approved', 'rejected', 'info_requested')),
     corrected_field TEXT,
     corrected_value TEXT,
     note TEXT,
     officer TEXT NOT NULL,
     decided_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
   )`,
  `CREATE INDEX IF NOT EXISTS idx_decisions_pack ON review_app.officer_decisions (pack_id, decided_at DESC)`,
];

const DecisionBody = z.object({
  decision: z.enum(['approved', 'rejected', 'info_requested']),
  note: z.string().max(2000).optional(),
  corrected_field: z.string().max(100).optional(),
  corrected_value: z.string().max(500).optional(),
});

const PackId = z.string().regex(/^PP-\d{4}$/);

function officer(req: Request): string {
  // Injected by the Databricks Apps proxy; falls back for local development.
  return req.header('x-forwarded-email') ?? req.header('x-forwarded-user') ?? 'local-dev@example.com';
}

export async function setupReviewRoutes(appkit: AppKitWithLakebase) {
  try {
    for (const stmt of SETUP_SQL) await appkit.lakebase.query(stmt);
    console.log('[review] schema review_app ready');
  } catch (err) {
    console.error('[review] schema setup failed:', (err as Error).message);
  }

  appkit.server.extend((app) => {
    app.get('/api/whoami', (req, res) => {
      res.json({ officer: officer(req) });
    });

    app.get('/api/summary', async (_req, res) => {
      try {
        const { rows } = await appkit.lakebase.query(`
          SELECT count(*)::int                                            AS packs,
                 count(*) FILTER (WHERE status = 'AUTO_CLEARED')::int     AS auto_cleared,
                 count(*) FILTER (WHERE status = 'NEEDS_REVIEW')::int     AS needs_review,
                 count(*) FILTER (WHERE priority = 'high')::int           AS high_priority,
                 count(*) FILTER (WHERE fta_rule_exceptions > 0)::int     AS fta_rule_packs,
                 max(drafted_at)                                          AS drafted_at,
                 (SELECT count(DISTINCT pack_id)::int FROM review_app.officer_decisions) AS decided
          FROM ${SYNCED}.lb_gold_permit_drafts`);
        res.json(rows[0]);
      } catch (err) {
        console.error('summary failed', err);
        res.status(500).json({ error: 'Could not load summary from Lakebase' });
      }
    });

    app.get('/api/packs', async (req, res) => {
      const status = z.enum(['NEEDS_REVIEW', 'AUTO_CLEARED', 'ALL']).catch('NEEDS_REVIEW').parse(req.query.status);
      try {
        const { rows } = await appkit.lakebase.query(
          `SELECT d.pack_id, d.status, d.priority, d.exception_count, d.failed_checks, d.importer_name,
                  d.exporter_name, d.exporter_country, d.preferential_scheme, d.declared_value, d.currency,
                  d.min_field_confidence, ld.decision AS last_decision, ld.officer AS decided_by, ld.decided_at
           FROM ${SYNCED}.lb_gold_permit_drafts d
           LEFT JOIN LATERAL (
             SELECT decision, officer, decided_at FROM review_app.officer_decisions o
             WHERE o.pack_id = d.pack_id ORDER BY decided_at DESC LIMIT 1) ld ON true
           WHERE ($1 = 'ALL' OR d.status = $1)
           ORDER BY CASE d.priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 WHEN 'low' THEN 2 ELSE 3 END, d.pack_id
           LIMIT 200`,
          [status],
        );
        res.json(rows);
      } catch (err) {
        console.error('packs failed', err);
        res.status(500).json({ error: 'Could not load the review queue' });
      }
    });

    app.get('/api/packs/:packId', async (req, res) => {
      const id = PackId.safeParse(req.params.packId);
      if (!id.success) {
        res.status(400).json({ error: 'Invalid pack id' });
        return;
      }
      try {
        const [draft, checks, items, decisions] = await Promise.all([
          appkit.lakebase.query(`SELECT * FROM ${SYNCED}.lb_gold_permit_drafts WHERE pack_id = $1`, [id.data]),
          appkit.lakebase.query(
            `SELECT check_code, check_name, category, severity, passed, detail
             FROM ${SYNCED}.lb_gold_pack_checks WHERE pack_id = $1
             ORDER BY passed, CASE severity WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, check_code`,
            [id.data],
          ),
          appkit.lakebase.query(
            `SELECT line_no, hs_code, description, quantity, unit, unit_price, amount, currency,
                    origin_criterion, rvc_percent, extraction_confidence
             FROM ${SYNCED}.lb_gold_permit_items WHERE pack_id = $1 ORDER BY line_no`,
            [id.data],
          ),
          appkit.lakebase.query(
            `SELECT decision, corrected_field, corrected_value, note, officer, decided_at
             FROM review_app.officer_decisions WHERE pack_id = $1 ORDER BY decided_at DESC`,
            [id.data],
          ),
        ]);
        if (draft.rows.length === 0) {
          res.status(404).json({ error: 'Pack not found' });
          return;
        }
        res.json({ draft: draft.rows[0], checks: checks.rows, items: items.rows, decisions: decisions.rows });
      } catch (err) {
        console.error('pack detail failed', err);
        res.status(500).json({ error: 'Could not load pack detail' });
      }
    });

    app.post('/api/packs/:packId/decision', async (req, res) => {
      const id = PackId.safeParse(req.params.packId);
      const body = DecisionBody.safeParse(req.body);
      if (!id.success || !body.success) {
        res.status(400).json({ error: 'Invalid decision' });
        return;
      }
      try {
        const { rows } = await appkit.lakebase.query(
          `INSERT INTO review_app.officer_decisions (pack_id, decision, corrected_field, corrected_value, note, officer)
           VALUES ($1, $2, $3, $4, $5, $6)
           RETURNING decision, corrected_field, corrected_value, note, officer, decided_at`,
          [id.data, body.data.decision, body.data.corrected_field ?? null, body.data.corrected_value ?? null,
           body.data.note ?? null, officer(req)],
        );
        res.status(201).json(rows[0]);
      } catch (err) {
        console.error('decision failed', err);
        res.status(500).json({ error: 'Could not save the decision' });
      }
    });
  });
}
