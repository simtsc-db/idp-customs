// Typed client for the review API (server/routes/review-routes.ts).
import { z } from 'zod';

const num = z.coerce.number();
const numOrNull = z.union([z.coerce.number(), z.null()]);

export const Summary = z.object({
  packs: num,
  auto_cleared: num,
  needs_review: num,
  high_priority: num,
  fta_rule_packs: num,
  decided: num,
  drafted_at: z.string().nullable(),
});
export type Summary = z.infer<typeof Summary>;

export const PackRow = z.object({
  pack_id: z.string(),
  status: z.string(),
  priority: z.string(),
  exception_count: num,
  failed_checks: z.string().nullable(),
  importer_name: z.string().nullable(),
  exporter_name: z.string().nullable(),
  exporter_country: z.string().nullable(),
  preferential_scheme: z.string().nullable(),
  declared_value: numOrNull,
  currency: z.string().nullable(),
  min_field_confidence: numOrNull,
  last_decision: z.string().nullable(),
  decided_by: z.string().nullable(),
  decided_at: z.string().nullable(),
});
export type PackRow = z.infer<typeof PackRow>;

export const Check = z.object({
  check_code: z.string(),
  check_name: z.string(),
  category: z.string(),
  severity: z.string(),
  passed: z.boolean(),
  detail: z.string().nullable(),
});
export type Check = z.infer<typeof Check>;

export const Item = z.object({
  line_no: num,
  hs_code: z.string().nullable(),
  description: z.string().nullable(),
  quantity: numOrNull,
  unit: z.string().nullable(),
  unit_price: numOrNull,
  amount: numOrNull,
  currency: z.string().nullable(),
  origin_criterion: z.string().nullable(),
  rvc_percent: numOrNull,
  extraction_confidence: numOrNull,
});
export type Item = z.infer<typeof Item>;

export const Decision = z.object({
  decision: z.string(),
  corrected_field: z.string().nullable(),
  corrected_value: z.string().nullable(),
  note: z.string().nullable(),
  officer: z.string(),
  decided_at: z.string(),
});
export type Decision = z.infer<typeof Decision>;

export const Draft = z.object({
  pack_id: z.string(),
  status: z.string(),
  priority: z.string(),
  importer_name: z.string().nullable(),
  importer_uen: z.string().nullable(),
  exporter_name: z.string().nullable(),
  exporter_country: z.string().nullable(),
  invoice_number: z.string().nullable(),
  invoice_date: z.string().nullable(),
  incoterm: z.string().nullable(),
  currency: z.string().nullable(),
  declared_value: numOrNull,
  port_of_loading: z.string().nullable(),
  shipment_date: z.string().nullable(),
  preferential_scheme: z.string().nullable(),
  certificate_number: z.string().nullable(),
  origin_country: z.string().nullable(),
  min_field_confidence: numOrNull,
  invoice_file: z.string().nullable(),
  packing_list_file: z.string().nullable(),
  coo_file: z.string().nullable(),
});
export type Draft = z.infer<typeof Draft>;

export const PackDetail = z.object({
  draft: Draft,
  checks: z.array(Check),
  items: z.array(Item),
  decisions: z.array(Decision),
});
export type PackDetail = z.infer<typeof PackDetail>;

async function getJson<T>(url: string, schema: z.ZodType<T>): Promise<T> {
  const res = await fetch(url);
  if (!res.ok) {
    const body: unknown = await res.json().catch(() => null);
    const msg = z.object({ error: z.string() }).safeParse(body);
    throw new Error(msg.success ? msg.data.error : `Request failed (${res.status})`);
  }
  return schema.parse(await res.json());
}

export const api = {
  whoami: () => getJson('/api/whoami', z.object({ officer: z.string() })),
  summary: () => getJson('/api/summary', Summary),
  packs: (status: string) => getJson(`/api/packs?status=${encodeURIComponent(status)}`, z.array(PackRow)),
  pack: (id: string) => getJson(`/api/packs/${encodeURIComponent(id)}`, PackDetail),
  decide: async (id: string, body: { decision: string; note?: string; corrected_field?: string; corrected_value?: string }) => {
    const res = await fetch(`/api/packs/${encodeURIComponent(id)}/decision`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error('Could not save the decision');
    return Decision.parse(await res.json());
  },
};

/** Inline URL for a trader document stored in the UC volume (files plugin, volume key "files"). */
export function documentUrl(packId: string, fileName: string): string {
  return `/api/files/files/raw?path=${encodeURIComponent(`inbox/${packId}/${fileName}`)}`;
}
