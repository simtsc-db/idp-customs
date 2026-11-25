import { useEffect, useState } from 'react';
import {
  Alert,
  AlertDescription,
  AlertTitle,
  Badge,
  Button,
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
  Empty,
  EmptyDescription,
  EmptyHeader,
  EmptyTitle,
  Input,
  Separator,
  Skeleton,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
  Textarea,
} from '@databricks/appkit-ui/react';
import { AlertTriangle, CheckCircle2, FileText, ShieldAlert, XCircle } from 'lucide-react';
import { api, documentUrl, type Check, type PackDetail, type PackRow, type Summary } from './api';

const fmtMoney = (v: number | null, ccy: string | null) =>
  v == null ? '-' : `${ccy ?? ''} ${v.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const fmtConf = (v: number | null) => (v == null ? '-' : `${Math.round(v * 100)}%`);
const fmtTime = (v: string | null) => (v ? new Date(v).toLocaleString() : 'unknown');

function PriorityBadge({ priority }: { priority: string }) {
  if (priority === 'high') return <Badge variant="destructive">High</Badge>;
  if (priority === 'medium') return <Badge className="bg-warning text-warning-foreground border-transparent">Medium</Badge>;
  if (priority === 'low') return <Badge variant="secondary">Low</Badge>;
  return <Badge className="bg-success text-success-foreground border-transparent">Clear</Badge>;
}

function CheckRow({ c }: { c: Check }) {
  const Icon = c.passed ? CheckCircle2 : c.severity === 'low' ? AlertTriangle : XCircle;
  const tone = c.passed ? 'text-success' : c.severity === 'low' ? 'text-warning' : 'text-destructive';
  return (
    <div className="flex gap-3 py-2">
      <Icon className={`size-4 mt-0.5 shrink-0 ${tone}`} aria-hidden />
      <div className="min-w-0">
        <div className="text-sm font-medium text-foreground">
          {c.check_code} {c.check_name}
          <span className="sr-only">{c.passed ? ' passed' : ' failed'}</span>
        </div>
        <div className="text-xs text-muted-foreground break-words">{c.detail}</div>
      </div>
    </div>
  );
}

function Kpi({ label, value, sub, loading }: { label: string; value: string; sub: string; loading: boolean }) {
  return (
    <Card className="gap-1 py-4">
      <CardHeader className="px-4">
        <CardDescription>{label}</CardDescription>
        {loading ? <Skeleton className="h-8 w-20" /> : <CardTitle className="text-2xl tabular-nums">{value}</CardTitle>}
      </CardHeader>
      <CardContent className="px-4 text-xs text-muted-foreground">{sub}</CardContent>
    </Card>
  );
}

function SummaryStrip({ summary, loading, error }: { summary: Summary | null; loading: boolean; error: string | null }) {
  if (error) {
    return (
      <Alert variant="destructive">
        <AlertTitle>Summary unavailable</AlertTitle>
        <AlertDescription>{error}</AlertDescription>
      </Alert>
    );
  }
  const s = summary;
  const pct = s && s.packs > 0 ? Math.round((100 * s.auto_cleared) / s.packs) : 0;
  return (
    <div className="space-y-2">
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
        <Kpi loading={loading} label="Permit packs in batch" value={s ? String(s.packs) : '-'} sub="Invoice + packing list + CoO each" />
        <Kpi loading={loading} label="Auto-cleared, no re-keying" value={s ? `${pct}%` : '-'} sub={s ? `${s.auto_cleared} packs passed all 11 checks` : ''} />
        <Kpi loading={loading} label="Need officer review" value={s ? String(s.needs_review) : '-'} sub={s ? `${s.decided} decided so far` : ''} />
        <Kpi loading={loading} label="High priority" value={s ? String(s.high_priority) : '-'} sub={s ? `${s.fta_rule_packs} packs breach an FTA origin rule` : ''} />
      </div>
      <p className="text-xs text-muted-foreground">
        Source: gold_permit_drafts (Lakeflow IDP pipeline), served from Lakebase. Drafted {fmtTime(s?.drafted_at ?? null)}. Synthetic demo data.
      </p>
    </div>
  );
}

function Queue({ rows, loading, error, selected, onSelect }: {
  rows: PackRow[]; loading: boolean; error: string | null; selected: string | null; onSelect: (id: string) => void;
}) {
  if (error) {
    return (
      <Alert variant="destructive">
        <AlertTitle>Queue unavailable</AlertTitle>
        <AlertDescription>{error}</AlertDescription>
      </Alert>
    );
  }
  if (loading) return <div className="space-y-2">{[0, 1, 2, 3, 4].map((i) => <Skeleton key={i} className="h-10 w-full" />)}</div>;
  if (rows.length === 0) {
    return (
      <Empty>
        <EmptyHeader>
          <EmptyTitle>Nothing in this queue</EmptyTitle>
          <EmptyDescription>All packs in this view are cleared. Switch to the All packs tab to browse everything.</EmptyDescription>
        </EmptyHeader>
      </Empty>
    );
  }
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Pack</TableHead>
          <TableHead>Priority</TableHead>
          <TableHead>Importer</TableHead>
          <TableHead>Why flagged</TableHead>
          <TableHead>Decision</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {rows.map((r) => (
          <TableRow
            key={r.pack_id}
            data-state={selected === r.pack_id ? 'selected' : undefined}
            className="cursor-pointer"
            onClick={() => onSelect(r.pack_id)}
          >
            <TableCell className="font-medium">{r.pack_id}</TableCell>
            <TableCell><PriorityBadge priority={r.priority} /></TableCell>
            <TableCell className="max-w-40 truncate">{r.importer_name}</TableCell>
            <TableCell className="max-w-64 truncate text-muted-foreground">{r.failed_checks ?? 'All checks passed'}</TableCell>
            <TableCell>{r.last_decision ? <Badge variant="outline">{r.last_decision.replace('_', ' ')}</Badge> : '-'}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}

function DocumentViewer({ detail }: { detail: PackDetail }) {
  const d = detail.draft;
  const docs = [
    { key: 'coo', label: 'Certificate of Origin', file: d.coo_file },
    { key: 'invoice', label: 'Invoice', file: d.invoice_file },
    { key: 'packing', label: 'Packing list', file: d.packing_list_file },
  ];
  return (
    <Tabs defaultValue="coo">
      <TabsList>
        {docs.map((x) => <TabsTrigger key={x.key} value={x.key}>{x.label}</TabsTrigger>)}
      </TabsList>
      {docs.map((x) => (
        <TabsContent key={x.key} value={x.key}>
          {x.file ? (
            x.file.endsWith('.pdf') ? (
              <iframe title={`${x.label} ${d.pack_id}`} src={documentUrl(d.pack_id, x.file)} className="w-full h-[560px] rounded-md border" />
            ) : (
              <img alt={`Scanned ${x.label} for ${d.pack_id}`} src={documentUrl(d.pack_id, x.file)} className="w-full rounded-md border" />
            )
          ) : (
            <Alert variant="destructive"><AlertTitle>Document missing from pack</AlertTitle></Alert>
          )}
        </TabsContent>
      ))}
    </Tabs>
  );
}

function DecisionPanel({ detail, onSaved }: { detail: PackDetail; onSaved: () => void }) {
  const [note, setNote] = useState('');
  const [field, setField] = useState('');
  const [value, setValue] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (decision: string) => {
    setSaving(true);
    setError(null);
    try {
      await api.decide(detail.draft.pack_id, {
        decision,
        note: note || undefined,
        corrected_field: field || undefined,
        corrected_value: value || undefined,
      });
      setNote(''); setField(''); setValue('');
      onSaved();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="space-y-3">
      <div className="grid grid-cols-2 gap-2">
        <Input aria-label="Corrected field" placeholder="Field to correct (optional)" value={field} onChange={(e) => setField(e.target.value)} />
        <Input aria-label="Corrected value" placeholder="Corrected value" value={value} onChange={(e) => setValue(e.target.value)} />
      </div>
      <Textarea aria-label="Officer note" placeholder="Note for the trader or audit trail" value={note} onChange={(e) => setNote(e.target.value)} />
      <div className="flex flex-wrap gap-2">
        <Button disabled={saving} onClick={() => void submit('approved')}>Approve permit</Button>
        <Button disabled={saving} variant="outline" onClick={() => void submit('info_requested')}>Request info from trader</Button>
        <Button disabled={saving} variant="destructive" onClick={() => void submit('rejected')}>Reject preference claim</Button>
      </div>
      {error && <Alert variant="destructive"><AlertDescription>{error}</AlertDescription></Alert>}
      {detail.decisions.length > 0 && (
        <div className="text-xs text-muted-foreground space-y-1">
          {detail.decisions.map((x) => (
            <div key={x.decided_at}>
              {fmtTime(x.decided_at)}: <span className="text-foreground">{x.decision.replace('_', ' ')}</span> by {x.officer}
              {x.corrected_field ? ` (corrected ${x.corrected_field} to "${x.corrected_value}")` : ''}{x.note ? `: ${x.note}` : ''}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function PackPanel({ packId, onDecided }: { packId: string | null; onDecided: () => void }) {
  const [detail, setDetail] = useState<PackDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    if (!packId) return;
    let cancelled = false;
    api.pack(packId).then(
      (d) => { if (!cancelled) { setDetail(d); setError(null); } },
      (e: unknown) => { if (!cancelled) setError((e as Error).message); },
    );
    return () => { cancelled = true; };
  }, [packId, reloadKey]);

  // Show a skeleton while the selected pack's detail has not arrived yet.
  const loading = detail?.draft.pack_id !== packId;

  if (!packId) {
    return (
      <Empty>
        <EmptyHeader>
          <EmptyTitle>Select a pack</EmptyTitle>
          <EmptyDescription>Pick a pack from the queue to see the source documents, extracted permit and failed checks.</EmptyDescription>
        </EmptyHeader>
      </Empty>
    );
  }
  if (error) return <Alert variant="destructive"><AlertTitle>Could not load {packId}</AlertTitle><AlertDescription>{error}</AlertDescription></Alert>;
  if (loading || !detail) return <Skeleton className="h-[600px] w-full" />;

  const d = detail.draft;
  const failed = detail.checks.filter((c) => !c.passed);
  const passed = detail.checks.filter((c) => c.passed);
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <h2 className="text-lg font-semibold text-foreground">{d.pack_id}</h2>
        <PriorityBadge priority={d.priority} />
        <Badge variant="outline">{d.preferential_scheme ?? 'no FTA'} claim</Badge>
        <span className="text-xs text-muted-foreground">Lowest extraction confidence {fmtConf(d.min_field_confidence)}</span>
      </div>

      <div className="grid grid-cols-1 xl:grid-cols-2 gap-4">
        <Card>
          <CardHeader>
            <CardTitle className="text-base flex items-center gap-2"><FileText className="size-4" aria-hidden /> Source documents</CardTitle>
            <CardDescription>As submitted by the trader (UC volume)</CardDescription>
          </CardHeader>
          <CardContent><DocumentViewer detail={detail} /></CardContent>
        </Card>

        <div className="space-y-4">
          <Card>
            <CardHeader>
              <CardTitle className="text-base flex items-center gap-2">
                <ShieldAlert className={`size-4 ${failed.length ? 'text-destructive' : 'text-success'}`} aria-hidden />
                {failed.length ? `${failed.length} check${failed.length > 1 ? 's' : ''} failed` : 'All checks passed'}
              </CardTitle>
              <CardDescription>Cross-document and FTA origin rules (rules table owned by Trade)</CardDescription>
            </CardHeader>
            <CardContent>
              {failed.map((c) => <CheckRow key={c.check_code} c={c} />)}
              {failed.length > 0 && <Separator className="my-2" />}
              <details>
                <summary className="text-xs text-muted-foreground cursor-pointer">{passed.length} passed checks</summary>
                {passed.map((c) => <CheckRow key={c.check_code} c={c} />)}
              </details>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Auto-populated permit</CardTitle>
              <CardDescription>Extracted by ai_extract; officer confirms or corrects</CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              <dl className="grid grid-cols-2 gap-x-4 gap-y-1 text-sm">
                {([
                  ['Importer', `${d.importer_name ?? '-'} (${d.importer_uen ?? '-'})`],
                  ['Exporter', `${d.exporter_name ?? '-'}, ${d.exporter_country ?? '-'}`],
                  ['Invoice', `${d.invoice_number ?? '-'} on ${d.invoice_date ?? '-'}`],
                  ['Declared value', fmtMoney(d.declared_value, d.currency)],
                  ['Port of loading', d.port_of_loading ?? '-'],
                  ['Shipment date', d.shipment_date ?? '-'],
                  ['Certificate', `${d.certificate_number ?? '-'} (${d.preferential_scheme ?? '-'})`],
                  ['Origin country', d.origin_country ?? '-'],
                ] as const).map(([k, v]) => (
                  <div key={k} className="contents">
                    <dt className="text-muted-foreground">{k}</dt>
                    <dd className="text-foreground break-words">{v}</dd>
                  </div>
                ))}
              </dl>
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>HS</TableHead><TableHead>Goods</TableHead><TableHead className="text-right">Qty</TableHead>
                    <TableHead className="text-right">Amount</TableHead><TableHead>Origin</TableHead><TableHead className="text-right">Conf.</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {detail.items.map((it) => (
                    <TableRow key={it.line_no}>
                      <TableCell className="font-mono text-xs">{it.hs_code}</TableCell>
                      <TableCell className="max-w-40 truncate">{it.description}</TableCell>
                      <TableCell className="text-right tabular-nums">{it.quantity?.toLocaleString()} {it.unit}</TableCell>
                      <TableCell className="text-right tabular-nums">{fmtMoney(it.amount, null)}</TableCell>
                      <TableCell>{it.origin_criterion}{it.rvc_percent != null ? ` ${it.rvc_percent}%` : ''}</TableCell>
                      <TableCell className={`text-right tabular-nums ${it.extraction_confidence != null && it.extraction_confidence < 0.9 ? 'text-warning' : ''}`}>
                        {fmtConf(it.extraction_confidence)}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Officer decision</CardTitle>
              <CardDescription>Saved to Lakebase with your identity for the audit trail</CardDescription>
            </CardHeader>
            <CardContent>
              <DecisionPanel detail={detail} onSaved={() => { setReloadKey((k) => k + 1); onDecided(); }} />
            </CardContent>
          </Card>
        </div>
      </div>
    </div>
  );
}

export function ReviewPage() {
  const [status, setStatus] = useState('NEEDS_REVIEW');
  const [rows, setRows] = useState<PackRow[]>([]);
  const [summary, setSummary] = useState<Summary | null>(null);
  const [loading, setLoading] = useState(true);
  const [queueError, setQueueError] = useState<string | null>(null);
  const [summaryError, setSummaryError] = useState<string | null>(null);
  const [selected, setSelected] = useState<string | null>(null);

  const [reloadKey, setReloadKey] = useState(0);

  // Set state only in the async callback; ignore stale responses.
  useEffect(() => {
    let cancelled = false;
    void Promise.allSettled([api.summary(), api.packs(status)]).then(([s, q]) => {
      if (cancelled) return;
      if (s.status === 'fulfilled') { setSummary(s.value); setSummaryError(null); } else setSummaryError((s.reason as Error).message);
      if (q.status === 'fulfilled') { setRows(q.value); setQueueError(null); } else setQueueError((q.reason as Error).message);
      setLoading(false);
    });
    return () => { cancelled = true; };
  }, [status, reloadKey]);

  return (
    <div className="space-y-4">
      <SummaryStrip summary={summary} loading={loading && !summary} error={summaryError} />
      <div className="grid grid-cols-1 lg:grid-cols-[minmax(0,2fr)_minmax(0,5fr)] gap-4">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Review queue</CardTitle>
            <CardDescription>Highest priority first</CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <Tabs value={status} onValueChange={(v) => { setLoading(true); setStatus(v); }}>
              <TabsList>
                <TabsTrigger value="NEEDS_REVIEW">Needs review</TabsTrigger>
                <TabsTrigger value="AUTO_CLEARED">Auto-cleared</TabsTrigger>
                <TabsTrigger value="ALL">All packs</TabsTrigger>
              </TabsList>
            </Tabs>
            <Queue rows={rows} loading={loading} error={queueError} selected={selected} onSelect={setSelected} />
          </CardContent>
        </Card>
        <PackPanel packId={selected} onDecided={() => setReloadKey((k) => k + 1)} />
      </div>
    </div>
  );
}
