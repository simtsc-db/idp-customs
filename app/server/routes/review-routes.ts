// Review API: reads gold tables through the SQL warehouse (Unity Catalog permissions apply)
// and keeps officer decisions in Lakebase (schema review_app).
import { sql } from '@databricks/appkit';
import { z } from 'zod';
import type { Application, Request } from 'express';

type Row = Record<string, unknown>;
type SqlParam = ReturnType<typeof sql.string>;

interface ReviewAppKit {
  analytics: { query(text: string, params?: Record<string, SqlParam>): Promise<{ data?: Row[] }> };
  lakebase: { query(text: string, params?: unknown[]): Promise<{ rows: Row[] }> };
  server: { extend(fn: (app: Application) => void): void };
}

const IDENT = /^[A-Za-z_][A-Za-z0-9_]*$/;
const CATALOG = process.env.PERMIT_CATALOG ?? '';
const SCHEMA = process.env.PERMIT_SCHEMA ?? 'customs_permit_idp';
if (!IDENT.test(CATALOG) || !IDENT.test(SCHEMA)) {
  throw new Error('PERMIT_CATALOG and PERMIT_SCHEMA must be set to valid identifiers');
}
const T = (table: string) => `\`${CATALOG}\`.\`${SCHEMA}\`.\`${table}\``;

const NUMERIC = new Set([
  'exception_count', 'fta_rule_exceptions', 'cross_document_exceptions', 'declared_value',
  'min_field_confidence', 'item_count', 'line_no', 'quantity', 'unit_price', 'amount', 'rvc_percent',
  'extraction_confidence', 'packs', 'auto_cleared', 'needs_review', 'high_priority', 'fta_rule_packs',
]);
const BOOLEAN = new Set(['passed']);

// The warehouse returns JSON_ARRAY values as strings; restore numbers and booleans.
function typed(rows: Row[] | undefined): Row[] {
  return (rows ?? []).map((r) =>
    Object.fromEntries(
      Object.entries(r).map(([k, v]) => {
        if (v === null || v === undefined) return [k, null];
        if (NUMERIC.has(k)) return [k, Number(v)];
        if (BOOLEAN.has(k)) return [k, v === true || v === 'true'];
        return [k, v];
      }),
    ),
  );
}

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

export async function setupReviewRoutes(appkit: ReviewAppKit) {
  try {
    for (const stmt of SETUP_SQL) await appkit.lakebase.query(stmt);
    console.log('[review] schema review_app ready');
  } catch (err) {
    console.error('[review] schema setup failed:', (err as Error).message);
  }

  const gold = async (text: string, params?: Record<string, SqlParam>) =>
    typed((await appkit.analytics.query(text, params)).data);

  appkit.server.extend((app) => {
    app.get('/api/whoami', (req, res) => {
      res.json({ officer: officer(req) });
    });

    app.get('/api/summary', async (_req, res) => {
      try {
        const [rows, decided] = await Promise.all([
          gold(`SELECT count(*)                                AS packs,
                       count_if(status = 'AUTO_CLEARED')       AS auto_cleared,
                       count_if(status = 'NEEDS_REVIEW')       AS needs_review,
                       count_if(priority = 'high')             AS high_priority,
                       count_if(fta_rule_exceptions > 0)       AS fta_rule_packs,
                       max(drafted_at)                         AS drafted_at
                FROM ${T('gold_permit_drafts')}`),
          appkit.lakebase.query('SELECT count(DISTINCT pack_id)::int AS decided FROM review_app.officer_decisions'),
        ]);
        res.json({ ...rows[0], decided: decided.rows[0]?.decided ?? 0 });
      } catch (err) {
        console.error('summary failed', err);
        res.status(500).json({ error: 'Could not load the summary' });
      }
    });

    app.get('/api/packs', async (req, res) => {
      const status = z.enum(['NEEDS_REVIEW', 'AUTO_CLEARED', 'ALL']).catch('NEEDS_REVIEW').parse(req.query.status);
      try {
        const [packs, latest] = await Promise.all([
          gold(
            `SELECT pack_id, status, priority, exception_count, failed_checks, importer_name, exporter_name,
                    exporter_country, preferential_scheme, declared_value, currency, min_field_confidence
             FROM ${T('gold_permit_drafts')}
             WHERE :status = 'ALL' OR status = :status
             ORDER BY CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 WHEN 'low' THEN 2 ELSE 3 END, pack_id
             LIMIT 200`,
            { status: sql.string(status) },
          ),
          appkit.lakebase.query(
            `SELECT DISTINCT ON (pack_id) pack_id, decision, officer, decided_at
             FROM review_app.officer_decisions ORDER BY pack_id, decided_at DESC`,
          ),
        ]);
        const byPack = new Map(latest.rows.map((d) => [d.pack_id as string, d]));
        res.json(
          packs.map((p) => {
            const d = byPack.get(p.pack_id as string);
            return { ...p, last_decision: d?.decision ?? null, decided_by: d?.officer ?? null, decided_at: d?.decided_at ?? null };
          }),
        );
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
      const p = { pack_id: sql.string(id.data) };
      try {
        const [draft, checks, items, decisions] = await Promise.all([
          gold(`SELECT * FROM ${T('gold_permit_drafts')} WHERE pack_id = :pack_id`, p),
          gold(
            `SELECT check_code, check_name, category, severity, passed, detail
             FROM ${T('gold_pack_checks')} WHERE pack_id = :pack_id
             ORDER BY passed, CASE severity WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, check_code`,
            p,
          ),
          gold(
            `SELECT line_no, hs_code, description, quantity, unit, unit_price, amount, currency,
                    origin_criterion, rvc_percent, extraction_confidence
             FROM ${T('gold_permit_items')} WHERE pack_id = :pack_id ORDER BY line_no`,
            p,
          ),
          appkit.lakebase.query(
            `SELECT decision, corrected_field, corrected_value, note, officer, decided_at
             FROM review_app.officer_decisions WHERE pack_id = $1 ORDER BY decided_at DESC`,
            [id.data],
          ),
        ]);
        if (draft.length === 0) {
          res.status(404).json({ error: 'Pack not found' });
          return;
        }
        res.json({ draft: draft[0], checks, items, decisions: decisions.rows });
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
