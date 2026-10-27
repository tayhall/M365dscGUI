// Drift engine GUI. Reads the view models through /api, renders each screen from the URL, and sends action
// requests. Which actions a finding allows comes from the server (allowedActions); the server re-checks every
// request, so nothing here is the last line of defence.
'use strict';

const DRIFT = ['Missing', 'Changed', 'TargetOnly', 'PossibleRename', 'Ambiguous'];
const KIND_LABEL = {
  Missing: 'Missing', Changed: 'Changed', TargetOnly: 'Target-only', PossibleRename: 'Possible rename', Ambiguous: 'Ambiguous',
  NotChecked: 'Not read', NotAvailable: 'Not available', Unkeyed: 'Unkeyed', Unreadable: 'Unreadable', Aligned: 'Aligned', Checked: 'Checked'
};
const KIND_COLOR = { Missing: '#9a4f00', Changed: '#e39a25', TargetOnly: '#f2cf8b', PossibleRename: '#8b5cf6', Ambiguous: '#4c2a99' };
const ACTION_LABEL = { Accept: 'Revert tenant', RevertBlueprint: 'Restore blueprint version', FullCheck: 'Snapshot', Adopt: 'Adopt', AcceptRisk: 'Accept risk', RemoveRisk: 'Remove accepted risk', StandardCheck: 'Compare with standard', ImportStandard: 'Import standard', CheckStandardRelease: 'Look for a new release', Recheck: 'Snapshot or refresh',ExcludeProperty: 'Noise rule', ExcludePropertyForTenant: 'Property exclusion', IncludePropertyForTenant: 'Property enforced again', Unexclude: 'Bring back', GenerateConfig: 'Generate configuration' };
const actionLabel = (a) => ACTION_LABEL[a] || a;
// What a blueprint version records as its source, in the words of the buttons: a version made by Promote is stored as 'Accept', one made by Revert as 'Revert'.
const SOURCE_LABEL = { Accept: 'Promote', Revert: 'Restore' };
const srcLabel = (s) => SOURCE_LABEL[s] || s;
const ACTION_TITLE = {
  Accept: 'Revert the tenant to the blueprint', Promote: 'Promote the change', Exclude: 'Exclude from management',
  ExcludeProperty: 'Ignore a value as noise', ExcludePropertyForTenant: 'Stop enforcing a setting in this tenant', IncludePropertyForTenant: 'Enforce a setting again', Unexclude: 'Bring back under management', RevertBlueprint: 'Restore a blueprint version',
  PromoteUp: 'Promote to master blueprint', PullDown: 'Update tenant blueprint', Adopt: 'Adopt into the blueprint', AcceptRisk: 'Accept the risk', RemoveRisk: 'Remove an accepted risk', Run: 'Run the selection list'
};
const ACTION_SUB = {
  Accept: 'The tenant is brought back in line with the blueprint. The blueprint does not change.',
  Promote: "The drift becomes the intended state in this tenant's own blueprint. No tenant is written to.",
  Exclude: 'The item stays as it is and is no longer counted.',
  ExcludeProperty: 'Only this exact value is hidden. A different value still shows as drift.',
  ExcludePropertyForTenant: 'The setting stays visible but does not count as drift in this tenant, and a revert leaves it as the tenant has it. Other tenants still show it as drift.',
  IncludePropertyForTenant: 'The setting counts as drift again in this tenant if it differs. Nothing in the tenant changes now.',
  Unexclude: 'Nothing in the tenant changes now.',
  RevertBlueprint: 'Only the blueprint changes. No tenant is written to.',
  PromoteUp: 'What differs moves from the tenant blueprint into the master blueprint. No tenant is written to.',
  PullDown: 'What differs moves from the master blueprint into the tenant blueprint. No tenant is written to; apply the tenant blueprint afterwards to bring the tenant in line.',
  Adopt: 'The standard’s setting is copied into the tenant’s own blueprint. The tenant is not changed: revert it afterwards on Drift review.',
  AcceptRisk: 'The tenant stays as it is. A note records who approved leaving it and why.',
  Run: 'Exclusions and accepted risks first, then blueprint changes (Promote and Adopt), then the DSC configuration that reverts tenants. Only Revert writes to a tenant.'
};

// The selection list: Revert, Promote and Exclude add an item here instead of acting at once (one action per item). The list shows what
// they add up to (the DSC configuration, the blueprint change, the exclusions); Run applies it, Export saves the DSC configuration of the
// Revert items as .ps1 files for a pipeline agent. Kept in this browser only, per blueprint; the server re-checks everything when it runs.
const PICKS = [['Revert', 'Accept'], ['Promote', 'Promote'], ['Exclude', 'Exclude']];
const ACTION_TIP = {
  Revert: 'Revert: remove this drift from the tenant. The tenant is put back to match its blueprint, applied as a DSC configuration.',
  Promote: 'Promote: accept this drift into the blueprint. The blueprint takes the tenant’s value; the tenant is not changed.',
  Exclude: 'Exclude: ignore this drift. The item is no longer managed or counted as drift; nothing is changed in the tenant or the blueprint.'
};
const REQUEST_ACTION = { Revert: 'Accept', Promote: 'Promote', Exclude: 'Exclude', Adopt: 'Adopt', AcceptRisk: 'AcceptRisk' };
function queueKey() { return 'pe-selection:' + (D.index ? D.index.blueprint.name : ''); }
function loadQueue() { try { const v = JSON.parse(localStorage.getItem(queueKey()) || '[]'); return Array.isArray(v) ? v.filter((c) => REQUEST_ACTION[c.action]) : []; } catch (e) { return []; } }
function saveQueue() { try { localStorage.setItem(queueKey(), JSON.stringify(ui.queue)); } catch (e) { /* the list still works for this page view */ } }
const chosenAction = (t, id) => { const c = ui.queue.find((x) => x.t === t && x.itemId === id && !x.standard); return c ? c.action : ''; };
const workloadOf = (rt) => (D.types[rt] && D.types[rt].workload) || 'Other';
const allowedPick = (f, action) => !!f && (f.allowedActions || []).includes(REQUEST_ACTION[action]);
// Choose an action for items (a second choice replaces the first, choosing the same one again removes it). Returns how many were skipped
// because that action is not available for them.
function queuePick(t, ids, action) {
  const toggleOff = ids.length === 1 && chosenAction(t, ids[0]) === action;
  let skipped = 0;
  ids.forEach((id) => {
    const f = findingFor(t, id);
    ui.queue = ui.queue.filter((c) => !(c.t === t && c.itemId === id && !c.standard));
    if (toggleOff) return;
    if (!allowedPick(f, action)) { skipped++; return; }
    ui.queue.push({ t, itemId: id, resourceType: f.resourceType, key: f.key, kind: f.kind, action });
  });
  ui.selPreview = null;
  saveQueue();
  return skipped;
}
function queueRemove(t, ids) { ui.queue = ui.queue.filter((c) => !(c.t === t && ids.includes(c.itemId) && !c.standard)); ui.selPreview = null; saveQueue(); }
// Items still drifted in the latest check and still open to their chosen action; the rest are shown but never sent.
const queueLive = (c) => { if (c.standard) return stdQueueLive(c); const f = tenant(c.t) && findingFor(c.t, c.itemId); return !!f && isOpenDrift(f) && allowedPick(f, c.action); };
function queueGroups() {
  // One group, so one job and one generated config, per action, tenant and workload: an Entra ID failure does not stop the Intune config.
  // Exclude first, then Promote, then Revert, as the runner does.
  const by = new Map();
  ui.queue.filter((c) => !c.standard && queueLive(c)).forEach((c) => {
    const k = c.action + '|' + c.t + '|' + workloadOf(c.resourceType);
    if (!by.has(k)) by.set(k, { action: REQUEST_ACTION[c.action], pick: c.action, tenantId: c.t, items: [] });
    by.get(k).items.push({ itemId: c.itemId });
  });
  const rank = { Exclude: 0, AcceptRisk: 0, Promote: 1, Adopt: 1, Revert: 2 };
  return [...by.values(), ...PEStandards.groupStandardEntries(ui.queue.filter(queueLive))].sort((x, y) => rank[x.pick] - rank[y.pick]);
}
// Two files per tenant and workload, as a Microsoft365DSC export gives them: the .ps1 is exactly the configuration the review shows, and the
// .psd1 is its ConfigurationData with placeholders for the tenant values. Fill in the .psd1 and run the .ps1 by hand. Entra ID and Intune stay separate.
const KIND_ACTION = { Missing: 'Create', Changed: 'Update', TargetOnly: 'Remove' };
// Values from the tenant (item keys, names) go into comment lines of a file that is later executed: a line break would end the comment, so
// every control and line-separator character is turned into a space.
const oneLine = (v) => String(v == null ? '' : v).replace(/[\u0000-\u001f\u007f\u0085\u2028\u2029]/g, ' ');
function exportScript(g, preview, stamp) {
  const meta = tenant(g.tenantId).meta;
  const wl = oneLine(workloadOf((findingFor(g.tenantId, g.items[0].itemId) || {}).resourceType || ''));
  const name = ('PE_' + g.tenantId + wl).replace(/[^A-Za-z0-9_]/g, '').slice(0, 60);
  const count = Number(((preview.config || '').match(/Resource instances: (\d+)/) || [])[1] || g.items.length);
  const layers = layersOf(meta);
  const own = layers[layers.length - 1];
  const lines = g.items.map((it) => {
    const f = findingFor(g.tenantId, it.itemId);
    return `#   ${oneLine(KIND_ACTION[f.kind] || f.kind)} ${oneLine(f.resourceType)} '${oneLine(f.key)}'`;
  });
  const stem = `${g.tenantId}-${wl.toLowerCase().replace(/[^a-z0-9]+/g, '-')}-${stamp.slice(0, 19).replace(/[-:]/g, '').replace('T', '-')}`;
  const header = [
    '# Revert configuration exported from the Drift Engine GUI.',
    `# Exported:    ${stamp}`,
    `# Tenant:      ${oneLine(meta.displayName)} (${oneLine(meta.role).toLowerCase()}, slug ${oneLine(g.tenantId)}${meta.tenantDomain && meta.tenantDomain !== g.tenantId ? ', ' + oneLine(meta.tenantDomain) : ''})`,
    `# Blueprint:   “${oneLine(own.name)}” v${oneLine(own.version == null ? '?' : own.version)}${layers.length > 1 ? ` (the master blueprint “${oneLine(layers[0].name)}” is not applied to a tenant)` : ''}`,
    `# Based on:    the snapshot of ${oneLine(meta.lastFullCheck || 'unknown date')}`,
    `# Workload:    ${wl}, ${count} resource(s)`,
    ...lines,
    '#',
    `# Fill in ${stem}.psd1, then run this file to compile the MOF and apply it with Start-DscConfiguration.`,
    ''
  ].join('\n');
  const config = (preview.config || '').replace(/^# Preview of .*\n/m, '').replace(/^Configuration \S+/m, 'Configuration ' + name);
  const data = [
    `# ConfigurationData for ${stem}.ps1. Replace each <placeholder> with the value for the tenant above.`,
    '@{',
    '    AllNodes    = @(',
    '        @{',
    '            NodeName                    = "localhost"',
    '            PSDscAllowPlainTextPassword = $true',
    '            PSDscAllowDomainUser        = $true',
    '            ServerNumber                = "0"',
    '        }',
    '    )',
    '    NonNodeData = @(',
    '        @{',
    '            ApplicationId         = "<ApplicationId>"',
    '            CertificateThumbprint = "<CertificateThumbprint>"',
    '            OrganizationName      = "<OrganizationName>"',
    '            TenantGuid            = "<TenantGuid>"',
    '            TenantId              = "<TenantId>"',
    '        }',
    '    )',
    '}',
    ''
  ].join('\n');
  return [
    { name: stem + '.ps1', text: header + config + `\n\n${name} -ConfigurationData .\\${stem}.psd1\n` },
    { name: stem + '.psd1', text: data }
  ];
}
async function queueExport() {
  const groups = queueGroups().filter((g) => g.pick === 'Revert');
  if (!groups.length) return;
  ui.toast = { text: 'Generating the DSC configuration…', job: null };
  render();
  const stamp = new Date().toISOString();
  const problems = [];
  const files = [];
  try {
    const previews = await Promise.all(groups.map((g) => api('/api/requests/preview', Object.assign(groupBody(g), { reason: '(export)', confirmedMasterWrite: true }))));
    groups.forEach((g, i) => {
      const p = previews[i];
      const text = p.config || '';
      if ((p.errors || []).length) problems.push(...p.errors);
      else if (!text || /no configuration could be generated/.test(text)) problems.push(`${tenantLabel(g.tenantId)}: no DSC configuration could be generated for every item, so nothing was exported for it. Take a new snapshot of the tenant and try again.`);
      else files.push(...exportScript(g, p, stamp));
    });
  } catch (e) { problems.push(e.message); }
  files.forEach((f) => {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([f.text], { type: 'text/plain' }));
    a.download = f.name;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  });
  ui.toast = problems.length ? { text: problems.join(' '), job: null }
    : { text: `Exported ${plural(files.length, 'file')}: ${files.map((f) => f.name).join(', ')}.`, job: null };
  render();
}

const D = { ready: false, error: null, items: {}, compares: {}, layerRows: {}, bpVersions: {} };
function readStoredTenant() { try { return localStorage.getItem('pe.tenant') || ''; } catch (e) { return ''; } }
function storeTenant(t) { try { localStorage.setItem('pe.tenant', t); } catch (e) { /* storage blocked: the selection lives in the page only */ } }
function readStoredView() { try { return localStorage.getItem('pe.overviewView') === 'compare' ? 'compare' : 'cards'; } catch (e) { return 'cards'; } }
function storeView(v) { try { localStorage.setItem('pe.overviewView', v); } catch (e) { /* storage blocked: the choice lives in the page only */ } }
const urlTenant = new URLSearchParams(location.search).get('tenant');
const ui = { selReason: '', selPreview: null, connect: { mode: 'create', createWriter: true }, sel: new Set(), expanded: new Set(), itemShow: '', view: readStoredView(), openJob: null, dialog: null, toast: null, tenant: (urlTenant && urlTenant !== 'all' ? urlTenant : '') || readStoredTenant() || null, rename: null, queue: [], manual: {} };
// The tenant the snapshot and refresh buttons and the scope cards act on (the first one until another is picked).
function curTenant() { return D.ready && ui.tenant && D.tenantIds.includes(ui.tenant) ? ui.tenant : (D.ready ? D.tenantIds[0] : null); }
function curTenantMeta() { return D.ready ? D.index.tenants.find((t) => t.tenantId === curTenant()) : null; }
const app = document.getElementById('app');

// ---------- helpers ----------
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const enc = encodeURIComponent;
const plural = (n, word) => n + ' ' + word + (n === 1 ? '' : 's');
const typeName = (rt) => (D.types[rt] ? D.types[rt].name : rt);
const tenant = (t) => D.tenants[t];
const role = (t) => tenant(t).meta.role;
const tenantLabel = (t) => (tenant(t) ? tenant(t).meta.displayName : t);
const kindClass = (kind, state) => state === 'Unmanaged' ? 'c-excl' : kind === 'Aligned' ? 'c-ok'
  : kind === 'PossibleRename' || kind === 'Ambiguous' ? 'c-review' : DRIFT.includes(kind) ? 'c-drift' : 'c-grey';
const kindIcon = (kind, state) => ({ 'c-excl': '⊖', 'c-ok': '✓', 'c-review': '?', 'c-drift': '▲', 'c-grey': '⊘' })[kindClass(kind, state)];
const chip = (kind, state, label) => `<span class="chip ${kindClass(kind, state)}">${kindIcon(kind, state)} ${esc(label || (state === 'Unmanaged' ? 'Excluded' : KIND_LABEL[kind] || kind))}</span>`;
const jobClass = (s) => (s === 'Failed' ? 'c-fail' : s === 'Succeeded' ? 'c-ok' : s === 'Cancelled' ? 'c-grey' : 'c-run');
// A job can be cancelled while it is queued, or while it is a running Recheck (it only reads); the server decides again.
const canCancelJob = (j) => j.status === 'Queued' || (j.status === 'Running' && j.action === 'Recheck' && !j.cancelRequested);
const isOpenDrift = (f) => f.state === 'Open' && DRIFT.includes(f.kind);
const fmt = (v, max = 80) => {
  let s;
  if (v === undefined || v === null) return '—';
  if (Array.isArray(v)) s = v.length ? v.join(', ') : '(empty)';
  else if (v === true) s = 'True';
  else if (v === false) s = 'False';
  else if (v === '') s = '(empty)';
  else if (typeof v === 'object') s = JSON.stringify(v);
  else s = String(v);
  return s.length > max ? s.slice(0, max - 1) + '…' : s;
};
const fullText = (v) => fmt(v, Infinity);
const tt = (text, cls) => `<span class="trunc ${cls || ''}" title="${esc(text)}">${esc(text)}</span>`;
const fv = (v) => `<span class="wrap" title="${esc(fullText(v))}">${esc(fmt(v))}</span>`;
const now = () => (D.index && D.index.mockNow ? Date.parse(D.index.mockNow) : Date.now());
const ago = (iso) => {
  if (!iso) return 'never';
  const min = Math.max(0, Math.round((now() - Date.parse(iso)) / 60000));
  if (min < 60) return min + ' min ago';
  if (min < 48 * 60) return Math.round(min / 60) + ' h ago';
  return Math.round(min / 1440) + ' d ago';
};
// Share of a layer the tenant still matches. 100 only when nothing drifted: 20 drifted of 4477 is 99, not a rounded-up 100.
const alignedPct = (aligned, drifted) => { const tot = aligned + drifted; return !tot || !drifted ? 100 : Math.min(99, Math.floor((aligned / tot) * 100)); };
const overdue = (iso) => !iso || (now() - Date.parse(iso)) / 3600000 > (D.index.fullCheckOverdueHours || 36);
const shortDate = (iso) => (iso ? iso.slice(0, 16).replace('T', ' ') : '—');
const sameJson = (a, b) => JSON.stringify(a) === JSON.stringify(b);

const path = {
  overview: () => '/',
  workload: (t, wl) => `/tenants/${enc(t)}/workloads/${enc(wl)}`,
  type: (t, wl, rt, show) => `/tenants/${enc(t)}/workloads/${enc(wl)}/types/${enc(rt)}` + (show && show !== 'all' ? '?show=' + enc(show) : ''),
  item: (t, id, tab, layer) => {
    // layer: the master blueprint the Drift review was showing, so the item page compares with the same blueprint.
    const q = new URLSearchParams();
    if (tab && tab !== 'settings') q.set('tab', tab);
    if (layer) q.set('layer', layer);
    const s = q.toString();
    return `/tenants/${enc(t)}/items/${enc(id)}` + (s ? '?' + s : '');
  },
  drift: (p) => {
    const q = new URLSearchParams();
    Object.entries(p || {}).forEach(([k, v]) => { if (v && (v !== 'all' || k === 'tenant')) q.set(k, v); });
    const s = q.toString();
    return '/drift' + (s ? '?' + s : '');
  },
  // A tenant blueprint is named in ?name=; no name is the master blueprint.
  blueprint: (name) => '/blueprint' + (name ? '?name=' + enc(name) : ''),
  compare: (from, to, name) => `/blueprint/compare?from=${from}&to=${to}${name ? '&name=' + enc(name) : ''}`,
  version: (n, name) => `/blueprint/versions/${n}${name ? '?name=' + enc(name) : ''}`,
  activity: (job) => '/activity' + (job ? '/' + enc(job) : '')
};
const link = (href, text, cls) => `<a href="${esc(href)}" data-link class="${cls || 'lnk'}">${esc(text)}</a>`;

async function api(url, body) {
  const opts = body === undefined ? {} : { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) };
  const res = await fetch(url, opts);
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch (e) { throw new Error('Bad response from ' + url); }
  if (!res.ok && !(data && data.errors)) throw new Error((data && data.error) || res.status + ' from ' + url);
  return data;
}

// ---------- data ----------
async function loadAll() {
  const [index, types, versions, exclusions, activity, setup] = await Promise.all([
    api('/api/index'), api('/api/resource-types'), api('/api/blueprint'), api('/api/exclusions'), api('/api/activity'), api('/api/tenant-setup').catch(() => ({ script: '' }))
  ]);
  const tenants = {};
  await Promise.all(index.tenants.map(async (meta) => {
    const t = meta.tenantId;
    const [status, findings, items] = await Promise.all([
      api(`/api/tenants/${enc(t)}/status`), api(`/api/tenants/${enc(t)}/findings`), api(`/api/tenants/${enc(t)}/items`)
    ]);
    tenants[t] = { meta, status, findings, items };
  }));
  Object.assign(D, { setup, index, types, versions, exclusions, activity, tenants, layerRows: {}, bpVersions: {}, tenantIds: index.tenants.map((m) => m.tenantId), ready: true, error: null });
  await loadStandards();
  ui.queue = loadQueue();
}
async function loadItem(t, id) {
  const k = t + '|' + id;
  if (D.items[k]) return;
  D.items[k] = { loading: true };
  try { D.items[k] = await api(`/api/tenants/${enc(t)}/item?id=${enc(id)}`); } catch (e) { D.items[k] = { error: e.message }; }
  render();
}
const findingsOf = (t) => tenant(t).findings;
const findingFor = (t, id) => findingsOf(t).find((f) => f.itemId === id);
const typeError = (t, rt) => findingsOf(t).find((f) => f.resourceType === rt && !f.key);
const currentVersion = () => D.index.blueprint.version;
function lastJobFor(t, id) {
  return D.activity.find((j) => j.requestId && j.tenantId === t && (j.items || []).some((i) => i.itemId === id));
}
function pendingChip(t, id) {
  const j = lastJobFor(t, id);
  if (!j) return '';
  const text = j.status === 'Succeeded' ? `${j.jobId} done, awaiting next snapshot` : `${j.jobId} ${j.status.toLowerCase()}`;
  return `<a href="${esc(path.activity(j.jobId))}" data-link class="pendchip" title="${esc(actionLabel(j.action) + ' requested')}">↻ ${esc(text)}</a>`;
}
const busy = (t, id) => { const j = lastJobFor(t, id); return !!j && (j.status === 'Queued' || j.status === 'Running'); };

async function loadCompare(from, to, name) {
  const k = (name || '') + '|' + from + '-' + to;
  if (D.compares[k]) return;
  D.compares[k] = { loading: true };
  try { D.compares[k] = { rows: await api(`/api/blueprint/compare?from=${from}&to=${to}${name ? '&name=' + enc(name) : ''}`) }; } catch (e) { D.compares[k] = { error: e.message }; }
  render();
}
// The versions of the master blueprint (no name) or of a tenant blueprint; null while a tenant blueprint's versions load.
function versionsFor(name) {
  if (!name) return D.versions;
  if (!D.bpVersions[name]) {
    D.bpVersions[name] = { loading: true };
    api('/api/blueprint?name=' + enc(name)).then((rows) => { D.bpVersions[name] = { rows }; render(); }).catch((e) => { D.bpVersions[name] = { error: e.message }; render(); });
  }
  const v = D.bpVersions[name];
  return v.rows || null;
}
const currentVersionOf = (list, name) => (name ? Math.max(0, ...list.map((v) => v.version)) : currentVersion());

// ---------- routing ----------
function route() {
  let parts;
  try { parts = location.pathname.split('/').filter(Boolean).map(decodeURIComponent); } catch (e) { return { screen: 'notfound' }; }
  const q = new URLSearchParams(location.search);
  const [a, b, c, d, e, f] = parts;
  if (!a) return { screen: 'overview' };
  if (a === 'tenants' && !b) return { screen: 'tenants' };
  if (a === 'tenants' && c === 'workloads' && d && !e) return { screen: 'workload', t: b, wl: d };
  if (a === 'tenants' && c === 'workloads' && e === 'types' && f) return { screen: 'type', t: b, wl: d, rt: f, show: q.get('show') || 'all' };
  if (a === 'tenants' && c === 'items' && d) return { screen: 'item', t: b, id: d, tab: q.get('tab') || 'settings', layer: q.get('layer') || '' };
  if (a === 'drift') return { screen: 'drift', tenant: q.get('tenant') || (D.ready ? curTenant() : 'all'), workload: q.get('workload') || 'all', kind: q.get('kind') || 'all', q: q.get('q') || '', layer: q.get('layer') || '' };
  if (a === 'blueprint' && b === 'compare') return { screen: 'compare', from: Number(q.get('from')) || 1, to: Number(q.get('to')) || 1, name: q.get('name') || '' };
  if (a === 'blueprint' && b === 'versions' && c) return { screen: 'version', n: Number(c), name: q.get('name') || '' };
  if (a === 'blueprint') return { screen: 'blueprint', name: q.get('name') || '' };
  if (a === 'exclusions') return { screen: 'exclusions' };
  if (a === 'queue') return { screen: 'queue' };
  if (a === 'standards' && !b) return { screen: 'standards' };
  if (a === 'standards' && b && c === 'not-covered') return { screen: 'notcovered', name: b, reason: q.get('reason') || 'all' };
  if (a === 'standards' && b && !c) return { screen: 'standard', name: b, show: q.get('show') || 'decide' };
  if (a === 'activity') return { screen: 'activity', job: b || null };
  return { screen: 'notfound' };
}
function go(href, replace) {
  if (replace) history.replaceState(null, '', href); else history.pushState(null, '', href);
  ui.expanded.clear();
  ui.itemShow = '';
  render();
  if (!replace) window.scrollTo(0, 0);
}

// ---------- shared pieces ----------
function setTenant(t) {
  if (!D.tenantIds.includes(t)) return;
  ui.tenant = t;
  storeTenant(t);
  const r = route();
  if (r.screen === 'workload') return go(path.workload(t, r.wl));
  if (r.screen === 'type') return go(path.type(t, r.wl, r.rt, r.show));
  if (r.screen === 'item') return go(path.item(t, r.id, r.tab));
  if (r.screen === 'drift') return go(path.drift({ tenant: t, workload: r.workload, kind: r.kind, q: r.q }), true);
  syncTenantUrl(r);
  render();
}
// The selected tenant stays in the URL (?tenant=) on pages whose address does not already name it.
function syncTenantUrl(r) {
  if (D.tenantIds.length < 2 || !['overview', 'blueprint', 'exclusions', 'tenants', 'activity'].includes(r.screen)) return;
  const u = new URL(location.href);
  if (u.searchParams.get('tenant') === curTenant()) return;
  u.searchParams.set('tenant', curTenant());
  history.replaceState(null, '', u.pathname + u.search);
}
// The blueprints a tenant follows, master first, as text: used by the context strip and the top bar.
function followsText(meta) {
  const layers = (meta && meta.layers) || [];
  return layers.length ? layers.map((l) => `“${esc(l.name)}” v${esc(l.version == null ? '?' : l.version)}`).join(' → ') : `“${esc(D.index.blueprint.name)}”`;
}
// Which tenant a page is about, and what it follows: shown under the top bar on every page that is about one tenant.
function contextStrip(t) {
  const meta = D.index.tenants.find((x) => x.tenantId === t);
  if (!meta) return '';
  const layers = meta.layers || [];
  const own = layers[layers.length - 1];
  const follows = followsText(meta);
  const state = own && own.checked ? `${alignedPct(own.aligned, own.drifted)}% aligned · ${plural(own.drifted, 'item')} drifted` : 'No snapshot yet';
  return `<div class="ctx" role="region" aria-label="Selected tenant"><b class="wrap">${esc(meta.displayName)}</b><span class="rolebadge">${esc(meta.role)}</span><span class="muted">Follows ${follows}</span><span class="muted">${state}</span></div>`;
}
function topbar(r) {
  const open = findingsOf(curTenant()).filter(isOpenDrift).length;
  const running = D.activity.filter((j) => j.status === 'Queued' || j.status === 'Running').length;
  const top = { workload: 'overview', type: 'overview', item: 'overview', compare: 'blueprint', version: 'blueprint', standard: 'standards', notcovered: 'standards' }[r.screen] || r.screen;
  const nav = [['overview', 'Overview', '/'], ['drift', 'Drift review', '/drift'], ['blueprint', 'Blueprint', '/blueprint'], ['standards', 'Standards', '/standards'], ['exclusions', 'Exclusions', '/exclusions'], ['queue', 'Selection list', '/queue'], ['tenants', 'Tenants', '/tenants'], ['activity', 'Activity', '/activity']]
    .map(([k, label, href]) => `<a href="${href}" data-link class="navb${top === k ? ' on' : ''}"${top === k ? ' aria-current="page"' : ''}>${label}${k === 'drift' && open ? `<span class="badge">${open}</span>` : ''}${k === 'queue' && ui.queue.length ? `<span class="badge">${ui.queue.length}</span>` : ''}</a>`).join('');
  return `<header class="top">
    <div class="brand"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#9cc0ff" stroke-width="2" aria-hidden="true"><path d="M3 12h4l3-8 4 16 3-8h4"></path></svg>Drift Engine</div>
    <nav class="nav" aria-label="Main">${nav}</nav>
    <div class="topr">${D.tenantIds.length > 1 ? `<label class="tenpick">Tenant <select id="tenant-pick" aria-label="Selected tenant">${D.tenantIds.map((t) => `<option value="${esc(t)}"${t === curTenant() ? ' selected' : ''}>${esc(tenantLabel(t))} (${esc(role(t))})</option>`).join('')}</select></label>` : ''}<span class="bpchip" title="The blueprints the selected tenant is compared with, master first. Pick another tenant to see its own.">Follows ${followsText(curTenantMeta())}</span>
    ${!curTenantMeta().offline ? `<button class="jobsb recheckb" data-act="recheck"${rechecking() ? ' disabled' : ''}>${rechecking() ? 'Taking snapshot…' : (D.tenantIds.length > 1 ? '↻ New snapshot of ' + esc(curTenantMeta().displayName) : '↻ New snapshot')}</button>` : `<button class="jobsb recheckb" data-act="open-upload" data-tenant="${esc(curTenant())}">Upload newer snapshot</button>${genConfigBtn(curTenantMeta(), 'jobsb')}`}
    <a href="/activity" data-link class="jobsb">Jobs · ${running} running</a></div>
  </header>`;
}
function crumbs(r) {
  if (r.screen === 'standard' || r.screen === 'notcovered') return standardCrumbs(r);
  let list = [];
  if (['workload', 'type', 'item'].includes(r.screen) && tenant(r.t)) {
    const wl = r.wl || (D.types[itemType(r)] || {}).workload;
    list = [['Overview', '/'], [tenantLabel(r.t), '/'], [wl, path.workload(r.t, wl)]];
    const rt = r.rt || itemType(r);
    if (r.screen !== 'workload') list.push([typeName(rt), path.type(r.t, wl, rt)]);
    if (r.screen === 'item') list.push([itemKey(r), null]);
  }
  if (r.screen === 'compare') list = [['Blueprint', path.blueprint(r.name)], ['Compare versions', null]];
  if (r.screen === 'version') list = [['Blueprint', path.blueprint(r.name)], ['v' + r.n, null]];
  if (!list.length) return '';
  const html = list.map(([label, href], i) => i === list.length - 1
    ? `<span class="crumbcur" aria-current="page">${esc(label)}</span>`
    : `${link(href, label, 'crumb')}<span class="sep" aria-hidden="true">›</span>`).join('');
  let sw = '';
  if (['workload', 'type', 'item'].includes(r.screen) && D.tenantIds.length > 1) {
    sw = `<div class="switch" role="group" aria-label="Tenant">${D.tenantIds.map((t) => {
      const href = r.screen === 'workload' ? path.workload(t, r.wl) : r.screen === 'type' ? path.type(t, r.wl, r.rt, r.show) : path.item(t, r.id, r.tab);
      return `<a href="${esc(href)}" data-link class="sw${t === r.t ? ' on' : ''}" aria-pressed="${t === r.t}">${esc(tenantLabel(t))}</a>`;
    }).join('')}</div>`;
  }
  return `<div class="crumbs"><nav aria-label="Breadcrumb" style="display:flex;flex-wrap:wrap;align-items:center;gap:4px">${html}</nav>${sw}</div>`;
}
const itemType = (r) => (r.id ? r.id.split('~')[0] : r.rt);
const itemKey = (r) => { const it = tenant(r.t).items.find((i) => i.itemId === r.id); return it ? it.key : decodeURIComponent((r.id || '').split('~')[1] || ''); };
const ages = (meta) => `<span class="${overdue(meta.lastFullCheck) ? 'overdue' : ''}">Snapshot ${esc(ago(meta.lastFullCheck))}${overdue(meta.lastFullCheck) ? ' (overdue)' : ''}</span>`;

function actionButtons(t, f, compact) {
  if (!f) return '';
  if (f.layer) return (f.allowedActions || []).includes('PullDown') ? `<button class="btn sm" data-act="move" data-action="PullDown" data-tenant="${esc(t)}" data-ids="${esc(f.itemId)}">Update tenant blueprint</button>` : '';
  const ids = esc(f.itemId);
  const acts = f.allowedActions || [];
  const lock = busy(t, f.itemId);
  if (acts.includes('Unexclude')) return `<button class="btn sm" data-act="action" data-action="Unexclude" data-tenant="${esc(t)}" data-ids="${ids}"${lock ? ' disabled title="A request for this item is still running"' : ''}>Bring back…</button>`;
  if (!PICKS.some(([, allow]) => acts.includes(allow))) {
    return `<span class="muted sub">${f.kind === 'Ambiguous' ? 'No actions until the key is unique' : 'No actions'}</span>`;
  }
  const cur = chosenAction(t, f.itemId);
  const buttons = PICKS.map(([name, allow]) => {
    const ok = acts.includes(allow) && !lock;
    const on = cur === name;
    const title = !acts.includes(allow) ? (name === 'Revert' && f.revertBlocked ? 'Revert is not available for this type: ' + f.revertBlocked : name + ' is not available for this item.') : lock ? 'A request for this item is still running' : ACTION_TIP[name];
    return `<button class="btn${compact ? ' sm' : ''}${on ? ' sel' : ''}" data-act="pick" data-pick="${name}" data-tenant="${esc(t)}" data-ids="${ids}" aria-pressed="${on}" title="${esc(title + (on ? ' (selected: click to remove)' : ''))}"${ok ? '' : ' disabled'}>${name}${on ? ' ✓' : ''}</button>`;
  }).join('');
  return `<span class="rowacts">${buttons}</span>`;
}
function bulkBar() {
  const n = ui.sel.size;
  const dis = n ? '' : ' disabled';
  const pickBtn = (name) => `<button class="btn sm" data-act="pick-sel" data-pick="${name}" title="${esc(ACTION_TIP[name])}"${dis}>${name} selected</button>`;
  return `<div class="bulk${n ? '' : ' idle'}" role="region" aria-label="Bulk actions"><span class="cnt">${n ? n + ' selected' : 'Tick rows, or use the buttons on each row. Nothing is applied until you run the selection list.'}</span>
    ${PICKS.map(([name]) => pickBtn(name)).join('')}
    ${n ? '<button class="lnk" style="color:#9cc0ff;margin-left:auto" data-act="clear-sel">Clear ticks</button>' : ''}</div>`;
}
function selectBox(t, f) {
  if (!f || !PICKS.some(([, allow]) => (f.allowedActions || []).includes(allow)) || busy(t, f.itemId)) return '';
  const key = t + '|' + f.itemId;
  return `<input class="cb" type="checkbox" id="sel-${esc(key)}" data-act="toggle-sel" data-key="${esc(key)}"${ui.sel.has(key) ? ' checked' : ''} aria-label="Select ${esc(f.key)}">`;
}
const dscChanged = () => D.ready && D.index.dsc && D.index.dsc.match === false;
function addedProps(f) {
  // Settings the tenant has and the blueprint lacks, at any depth of a nested setting: what a newer Microsoft365DSC module adds.
  const isObj = (v) => v && typeof v === 'object' && !Array.isArray(v);
  const out = [];
  const walk = (b, t, path) => {
    if (!isObj(t)) return;
    Object.keys(t).forEach((k) => {
      if (k === 'CIMInstance') return;
      const p = path + '.' + k;
      if (!isObj(b) || b[k] === undefined || b[k] === null) { if (t[k] !== undefined && t[k] !== null) out.push(p); } else walk(b[k], t[k], p);
    });
  };
  (f.differences || []).forEach((d) => {
    if (d.blueprint === undefined || d.blueprint === null) { if (d.target !== undefined && d.target !== null) out.push(d.property); } else walk(d.blueprint, d.target, d.property);
  });
  return out;
}
// Only while the installed module differs from the one the blueprint was built with: then a setting the blueprint lacks is probably new in the module.
const newInModule = (f) => (dscChanged() && f.kind === 'Changed' ? addedProps(f) : []);
function detail(f) {
  if (!f) return 'Matches the blueprint';
  if (f.kind === 'Changed') {
    const added = newInModule(f);
    return plural(f.differences.length, 'setting') + ' differ: ' + f.differences.map((d) => d.property).join(', ')
      + (added.length ? ` · the tenant has ${added.join(', ')}, which the blueprint lacks (probably new in the installed Microsoft365DSC)` : '');
  }
  if (f.kind === 'Missing') return 'In the blueprint, not in the tenant';
  if (f.kind === 'TargetOnly') return 'In the tenant, not in the blueprint';
  if (f.kind === 'PossibleRename') return 'Possibly renamed to “' + f.other + '”';
  if (f.kind === 'Ambiguous') return 'Key is not unique';
  return f.error || KIND_LABEL[f.kind];
}

// ---------- screens ----------
// The blueprint layers a tenant follows (master blueprint first, its own last). Data written before layers existed has none:
// then the tenant follows the master blueprint alone and its counts come from its findings.
function layersOf(meta) {
  if (meta.layers && meta.layers.length) return meta.layers;
  const f = findingsOf(meta.tenantId).filter(isOpenDrift);
  const n = (k) => f.filter((x) => x.kind === k).length;
  const man = tenant(meta.tenantId).status.workloads.reduce((a, w) => a + w.managed, 0);
  return [{ name: D.index.blueprint.name, version: currentVersion(), role: 'master', sameAsOwn: true, checked: !!meta.lastFullCheck, problem: null, drifted: f.length, aligned: Math.max(0, man - f.length), changed: n('Changed'), missing: n('Missing'), targetOnly: n('TargetOnly') }];
}
function driftIds(t, action) {
  return findingsOf(t).filter((f) => isOpenDrift(f) && (f.allowedActions || []).includes(action)).map((f) => f.itemId).join(' ');
}
// One comparison of the selected tenant: its own blueprint, or the master blueprint above it. A tenant is only ever written from
// its own blueprint, so the master panel changes the tenant blueprint, never the tenant.
// A ring of how much of one blueprint layer the tenant still matches: aligned out of aligned plus drifted.
function layerRing(layer, label) {
  if (!layer.checked) return `<div class="rg"><div class="ring" style="background:#d9dde2"><div class="ringin"><b>–</b><span>not checked</span></div></div><div class="rl">${esc(label)}</div></div>`;
  const pct = alignedPct(layer.aligned, layer.drifted);
  return `<div class="rg"><div class="ring" role="img" aria-label="${esc(label + ': ' + pct + '% aligned, ' + layer.drifted + ' drifted')}" style="background:conic-gradient(#3a9a6a 0 ${pct}%, #e39a25 ${pct}% 100%)"><div class="ringin"><b>${pct}%</b><span>aligned</span></div></div><div class="rl">${esc(label)}</div><div class="muted sub">${layer.drifted} drifted</div></div>`;
}
// The layer a tenant card's heat cells follow: the master blueprint when the tenant has one that was checked, else its own.
function headlineLayer(meta) {
  const ls = layersOf(meta);
  const master = ls.find((l) => l.sameAsOwn === false && l.checked);
  return master && ui.tileLayer !== 'own' ? { layer: master, own: false } : { layer: ls[ls.length - 1], own: true };
}
// One entry per workload for a tenant card: the drifted count and the tone (PEHeat.tone). Both layers count the open drift of their findings, so the cells add up to the ring; the master layer's
// counts come from that layer's findings, which load once (tone 'ld' and drifted null until they have).
function heatRow(t, layer, own) {
  const T = tenant(t);
  if (!layer) ({ layer, own } = headlineLayer(T.meta));
  const rows = own ? findingsOf(t) : D.layerRows[t + '|' + layer.name];
  if (!own && layer.checked && !rows) loadLayer(t, layer.name);
  const failed = !!(rows && rows.failed);
  const counts = rows && !failed ? PEHeat.countByWorkload(rows.filter(isOpenDrift), D.index.workloads) : null;
  return D.index.workloads.map((wl) => {
    const w = T.status.workloads.find((x) => x.workload === wl) || { managed: 0, aligned: 0, drifted: 0, notChecked: 0 };
    const checked = layer.checked && !failed && !(w.notChecked > 0 && w.aligned + w.drifted === 0);
    const drifted = counts ? counts[wl] : null;
    return { wl, managed: w.managed, drifted, failed, tone: drifted === null && checked ? 'ld' : PEHeat.tone(drifted || 0, w.managed, checked) };
  });
}
// What a heat cell says in its tooltip and aria-label.
function heatWhat(c) {
  return c.failed ? 'could not load' : c.tone === 'nc' ? 'not checked' : c.tone === 'ld' ? 'loading' : `${c.drifted} drifted of ${c.managed} managed`;
}
// The row of coloured workload cells on a tenant card. A cell with drift opens that tenant's Drift review for the workload and layer.
function heatCells(t) {
  const { layer, own } = headlineLayer(tenant(t).meta);
  const solo = layersOf(tenant(t).meta).length < 2;
  const cells = heatRow(t, layer, own).map((c) => {
    const href = c.drifted > 0 ? path.drift({ tenant: t, workload: c.wl, layer: own ? '' : layer.name }) : path.workload(t, c.wl);
    const num = c.tone === 'nc' ? 'n/c' : c.tone === 'ld' ? '…' : c.drifted;
    const what = heatWhat(c);
    return `<a class="hm-cell hm-${c.tone}" href="${esc(href)}" data-link title="${esc(c.wl + ': ' + what)}" aria-label="${esc(c.wl + ': ' + what)}"><span class="hm-l">${esc(c.wl)}</span><b>${esc(num)}</b></a>`;
  }).join('');
  const pick = (name, label) => `<button class="lnk tilepick" data-act="tile-layer" data-layer="${name}" aria-pressed="${(name === 'own') === own}">${label}</button>`;
  const caption = solo ? 'by workload, against its blueprint' : (layersOf(tenant(t).meta).some((l) => l.sameAsOwn === false && l.checked) ? `by workload, against: ${pick('master', 'master blueprint')} · ${pick('own', 'own blueprint')}` : 'by workload, against its own blueprint');
  return `<div class="hm-row">${cells}</div><div class="muted sub">${caption}</div>`;
}
// One entry per blueprint layer a tenant follows, master layer first: what the Compare matrix shows as a row.
function layerRowsFor(t) {
  const ls = layersOf(tenant(t).meta);
  return ls.map((layer, i) => ({ layer, own: i === ls.length - 1, label: ls.length < 2 ? 'vs its blueprint' : i === 0 ? 'vs master blueprint' : 'vs own blueprint' }));
}
// Tenants (a row per layer) against workloads, same colours as the card cells. A workload header opens the Drift review of that workload
// across all tenants; a cell with drift opens that tenant's, carrying the layer.
function compareMatrix() {
  const wls = D.index.workloads;
  const sel = curTenant();
  const head = wls.map((wl) => `<a class="hm-h" href="${esc(path.drift({ tenant: 'all', workload: wl }))}" data-link>${esc(wl)}</a>`).join('');
  const rows = D.tenantIds.map((t) => layerRowsFor(t).map(({ layer, own, label }) => {
    const cells = heatRow(t, layer, own).map((c) => {
      const href = c.drifted > 0 ? path.drift({ tenant: t, workload: c.wl, layer: own ? '' : layer.name }) : path.workload(t, c.wl);
      const num = c.tone === 'nc' ? 'n/c' : c.tone === 'ld' ? '…' : c.drifted;
      const what = heatWhat(c);
      return `<a class="hm-cell hm-${c.tone}" href="${esc(href)}" data-link title="${esc(tenantLabel(t) + ' ' + label + ', ' + c.wl + ': ' + what)}" aria-label="${esc(tenantLabel(t) + ' ' + label + ', ' + c.wl + ': ' + what)}"><b>${esc(num)}</b></a>`;
    }).join('');
    return `<div class="hm-rl${t === sel ? ' hm-sel' : ''}">${link('/?tenant=' + enc(t), tenantLabel(t), 'lnk strong wrap')}<div class="muted sub">${esc(label)}</div></div>${cells}<div class="hm-tot">${layer.checked ? layer.drifted : 'n/c'}</div>`;
  }).join('')).join('');
  return `<section class="card"><div class="tw"><div class="hm-matrix" style="grid-template-columns:minmax(120px,1.4fr) repeat(${wls.length},minmax(56px,1fr)) 56px"><div></div>${head}<div class="hm-h">Total</div>${rows}</div></div></section>`;
}
// The top of the Overview: a Cards / Compare toggle, then the tenant cards or the matrix.
function overviewTop(sel) {
  const btn = (v, label) => `<button id="ov-view-${v}" class="btn sm${ui.view === v ? ' pri' : ''}" data-act="overview-view" data-view="${v}" aria-pressed="${ui.view === v}">${label}</button>`;
  return `<div class="vt-toggle" role="group" aria-label="Tenant view">${btn('cards', 'Cards')}${btn('compare', 'Compare')}</div>${ui.view === 'compare' ? compareMatrix() : tenantCards(sel)}`;
}
// One card per tenant: how far it has drifted from the master blueprint and from its own blueprint. The picked tenant is marked.
function tenantCards(sel) {
  return `<div class="tcards">${D.index.tenants.map((m) => {
    const ls = layersOf(m);
    const rings = ls.length > 1 ? layerRing(ls[0], 'master blueprint') + layerRing(ls[ls.length - 1], 'own blueprint') : layerRing(ls[0], 'its blueprint');
    return `<section class="card tcard${m.tenantId === sel ? ' hl' : ''}" aria-label="${esc(m.displayName)}"><div class="role">${esc(m.role)}</div>${link('/?tenant=' + enc(m.tenantId), m.displayName, 'lnk strong wrap domain')}
      <div class="rings">${rings}</div>${heatCells(m.tenantId)}<div class="muted sub">${snapshotSummary(m)}</div></section>`;
  }).join('')}</div>`;
}
function layerPanel(t, layer, own, solo) {
  const meta = tenant(t).meta;
  const title = solo ? 'Against its blueprint' : own ? 'Against its own blueprint' : 'Against the master blueprint';
  const name = `“${esc(layer.name)}” v${esc(layer.version == null ? '?' : layer.version)}`;
  const note = solo ? `${name} · the master and tenant blueprint are the same` : name;
  if (!layer.checked) {
    return `<section class="card layerp" aria-label="${esc(title)}"><div class="lab">${esc(title)}</div><div class="muted wrap">${note}</div>
      <div class="bigline"><b>Not checked yet</b></div>${layer.problem ? `<div class="err wrap">${esc(layer.problem)}</div>` : ''}
      ${own && !meta.offline ? `<div class="btns"><button class="btn pri" data-act="recheck"${rechecking() ? ' disabled' : ''}>Take snapshot</button></div>` : ''}</section>`;
  }
  const btn = (label, attrs, cls) => `<button class="btn${cls ? ' ' + cls : ''}" ${attrs}>${esc(label)}</button>`;
  let actions = link(path.drift({ tenant: t, layer: own ? '' : layer.name }), 'Review', 'btn');
  if (own) {
    const promoteIds = driftIds(t, 'Promote');
    const acceptIds = driftIds(t, 'Accept');
    const count = (ids) => ids.split(' ').filter(Boolean).length;
    const noOwn = solo && meta.role === 'Replica';
    const pickAll = (name, ids) => btn(`${name} ${count(ids)}`, `data-act="pick" data-pick="${name}" data-tenant="${esc(t)}" data-ids="${esc(ids)}" title="${esc(ACTION_TIP[name] + ' Adds all ' + count(ids) + ' to the selection list.')}"${name === 'Promote' && noOwn ? ' disabled' : ''}`, '');
    if (acceptIds) actions += pickAll('Revert', acceptIds);
    if (promoteIds) actions += pickAll('Promote', promoteIds);
    if (!solo) actions += btn('Promote to master blueprint', `data-act="move" data-action="PromoteUp" data-tenant="${esc(t)}" title="Moves what differs from this tenant’s blueprint into the master blueprint. No tenant is changed."`);
  } else {
    actions += btn('Update tenant blueprint', `data-act="move" data-action="PullDown" data-tenant="${esc(t)}"`);
  }
  return `<section class="card layerp" aria-label="${esc(title)}"><div class="lab">${esc(title)}</div><div class="muted wrap">${note}</div>
    <div><div class="bigline"><b>${layer.drifted}</b> drifted <span class="muted">${layer.aligned} aligned</span></div>
    <div class="muted">${layer.changed} changed · ${layer.missing} missing · ${layer.targetOnly} target-only</div></div><div class="btns">${actions}</div></section>`;
}
// Alignment by workload for one tenant: a bar per workload; each segment links on (aligned and not checked to the workload page,
// drifted to the Drift review of that workload).
function workloadBars(t) {
  const T = tenant(t);
  const meta = T.meta;
  const bars = D.index.workloads.map((wl) => {
    const w = T.status.workloads.find((x) => x.workload === wl) || { aligned: 0, drifted: 0, notChecked: 0 };
    const tot = w.aligned + w.drifted + w.notChecked || 1;
    const text = `${w.aligned} aligned · ${w.drifted} drifted${w.notChecked ? ' · ' + w.notChecked + ' not read' : ''}`;
    const snap = ((meta.snapshot && meta.snapshot.workloads) || []).find((x) => x.workload === wl);
    const seg = (cls, n, href, what) => n ? `<a class="seg ${cls}" href="${esc(href)}" data-link style="width:${(n / tot) * 100}%" aria-label="${esc(wl + ': ' + n + ' ' + what)}" title="${esc(wl + ': ' + n + ' ' + what)}"></a>` : '';
    return `<div class="barrow"><div>${link(path.workload(t, wl), wl, 'lnk strong')}${snap ? `<div class="muted sub">${esc(snapshotLabel(snap.source, snap.at))}</div>` : ''}</div><div class="barline"><span></span><div class="bar">${seg('s-ok', w.aligned, path.workload(t, wl), 'aligned')}${seg('s-dr', w.drifted, path.drift({ tenant: t, workload: wl }), 'drifted')}${seg('s-nc', w.notChecked, path.workload(t, wl), 'not read')}</div><span class="muted bt">${esc(text)}</span></div></div>`;
  }).join('');
  return `<section class="card"><h2>Alignment by workload</h2><div class="legend"><span class="lg"><span class="sw10 s-ok"></span>Aligned</span><span class="lg"><span class="sw10 s-dr"></span>Drifted</span><span class="lg"><span class="sw10 s-nc"></span>Not read (components)</span></div>${bars}</section>`;
}
function overview() {
  const t = curTenant();
  const T = tenant(t);
  const meta = T.meta;
  const layers = layersOf(meta);
  const solo = layers.length < 2;
  const own = layers[layers.length - 1];
  const follows = layers.map((l, i) => `${layers.length > 1 ? (i === 0 ? 'master blueprint ' : 'tenant blueprint ') : 'blueprint '}“${esc(l.name)}” v${esc(l.version == null ? '?' : l.version)}`).join(' → ');
  const head = `<section class="card ovhead" aria-label="Selected tenant"><div class="role">${esc(meta.role)}</div><div class="domain wrap">${esc(meta.displayName)}</div>
    <div class="muted mono">${tt('slug: ' + meta.tenantId + (meta.tenantDomain && meta.tenantDomain !== meta.displayName ? ' · ' + meta.tenantDomain : ''))}</div>
    <div style="margin-top:6px">Follows ${follows}</div>
    <div class="ages">${meta.crossTenant === true ? 'Compared across tenants: ids generated per tenant are ignored. ' : meta.crossTenant === false ? 'Same tenant as the blueprint: everything is compared. ' : ''}${snapshotSummary(meta)}</div>${meta.offline ? `<div class="btns"><button class="btn pri" data-act="open-upload" data-tenant="${esc(meta.tenantId)}">Upload newer snapshot</button>${genConfigBtn(meta, 'btn')}</div>` : ''}</section>`;
  const panels = `<div class="cards2">${solo ? layerPanel(t, own, true, true) : layerPanel(t, own, true, false) + layerPanel(t, layers[0], false, false)}</div>${solo ? '' : blueprintGap(t)}`;
  const typeCard = typeScopesCard();
  const anyDrift = (meta.typeScopes || []).some((x) => x.drifted);
  return `<div class="phead"><div><h1>Overview</h1><div class="muted">How far each tenant has drifted from the master blueprint and from its own blueprint, then the selected tenant in detail. Excluded items are outside the counts.</div></div></div>
    ${overviewTop(t)}
    <h2 class="sech">Selected tenant</h2>
    ${head}${panels}
    ${dscBanner()}
    ${scopesCard()}
    ${workloadBars(t)}
    ${typeCard ? `<details class="tgroup"${anyDrift ? ' open' : ''}><summary>Refresh by resource type${anyDrift ? '' : ' (nothing drifted)'}</summary>${typeCard}</details>` : ''}`;
}

function workload(r) {
  const T = tenant(r.t);
  const w = T.status.workloads.find((x) => x.workload === r.wl);
  if (!w) return notFound();
  const open = T.findings.filter((f) => f.workload === r.wl && isOpenDrift(f));
  const kinds = DRIFT.map((k) => ({ k, n: open.filter((f) => f.kind === k).length }));
  let acc = 0;
  const segs = kinds.filter((k) => k.n).map((k) => { const a = (acc / open.length) * 100; acc += k.n; return `${KIND_COLOR[k.k]} ${a}% ${(acc / open.length) * 100}%`; });
  const order = (ty) => (ty.status !== 'Checked' ? 0 : ty.drifted ? 1 : 2);
  const types = w.types.slice().sort((a, b) => order(a) - order(b));
  const typeRows = types.map((ty) => {
    const st = ty.status !== 'Checked' ? chip(ty.status, 'Open') : ty.drifted ? chip('Changed', 'Open', ty.drifted + ' drifted') : chip('Aligned', 'Open');
    return `<div class="gr types"><span>${link(path.type(r.t, r.wl, ty.resourceType), typeName(ty.resourceType), 'lnk strong')}<div class="mono muted">${tt(ty.resourceType)}</div>${ty.error ? `<div class="muted sub">${esc(ty.error)}</div>` : ''}</span>
      <span class="num">${ty.items}</span><span class="num">${ty.status === 'NotChecked' || ty.status === 'NotAvailable' ? '—' : ty.aligned}</span><span class="num">${ty.drifted}</span><span class="num">${ty.excluded}</span><span>${st}</span></div>`;
  }).join('');
  const top = types.filter((t) => t.drifted).sort((a, b) => b.drifted - a.drifted).slice(0, 10);
  const max = top.length ? top[0].drifted : 1;
  const tiles = [['Managed', w.managed, path.workload(r.t, r.wl)], ['Aligned', w.aligned, path.workload(r.t, r.wl)], ['Drifted', w.drifted, path.drift({ tenant: r.t, workload: r.wl })], ['Excluded', w.excluded, '/exclusions'], ['Not read', w.notChecked, path.workload(r.t, r.wl)]];
  return `<div class="phead"><div><h1>${esc(r.wl)}</h1><div class="muted">${esc(T.meta.displayName)} · ${ages(T.meta)}</div></div>${link(path.drift({ tenant: r.t, workload: r.wl }), `Review drift in this workload (${w.drifted})`, 'btn pri')}</div>
    <div class="tiles">${tiles.map(([l, v, h]) => `<a href="${esc(h)}" data-link class="tile" style="color:inherit;text-decoration:none"><div class="l">${l}</div><div class="v">${v}</div></a>`).join('')}</div>
    ${w.notChecked ? `<div class="banner b-grey" role="status"><span class="warn">!</span><div><b>${plural(w.notChecked, 'component')} not read in the latest snapshot.</b> Their items are never shown as Missing or Target-only. Revert is limited to items whose own component exported.</div></div>` : ''}
    <div class="cards2">
      <section class="card"><h2>Drift by kind</h2><div class="donutwrap"><div class="donut" style="background:${segs.length ? 'conic-gradient(' + segs.join(', ') + ')' : '#e1e3e6'}" role="img" aria-label="${esc(kinds.map((k) => KIND_LABEL[k.k] + ' ' + k.n).join(', '))}"><div class="donutin"><b>${open.length}</b><span class="muted sub">drifted</span></div></div>
        <div style="flex:1;min-width:180px">${kinds.map((k) => `<div class="kl"><span class="sw10" style="background:${KIND_COLOR[k.k]}"></span>${k.n ? link(path.drift({ tenant: r.t, workload: r.wl, kind: k.k }), KIND_LABEL[k.k]) : `<span>${KIND_LABEL[k.k]}</span>`}<span class="num">${k.n}</span></div>`).join('')}</div></div></section>
      <section class="card"><h2>Drift per resource type</h2>${top.length ? top.map((t) => `<div class="hb">${link(path.type(r.t, r.wl, t.resourceType), typeName(t.resourceType))}<div><a class="hbar" href="${esc(path.type(r.t, r.wl, t.resourceType))}" data-link aria-label="${esc(typeName(t.resourceType) + ': ' + t.drifted + ' drifted')}" style="width:${(t.drifted / max) * 100}%"></a></div><span class="num">${t.drifted}</span></div>`).join('') : '<div class="empty">No drift in this workload.</div>'}</section>
    </div>
    <section class="card"><h2>Resource types</h2><div class="tw"><div class="gt"><div class="gr h types"><span>Type</span><span class="num">Items</span><span class="num">Aligned</span><span class="num">Drifted</span><span class="num">Excluded</span><span>Status</span></div>${typeRows}</div></div></section>`;
}

function typePage(r) {
  const T = tenant(r.t);
  const err = typeError(r.t, r.rt);
  let rows = T.items.filter((i) => i.resourceType === r.rt).map((i) => {
    const f = findingFor(r.t, i.itemId);
    let kind = f ? f.kind : 'Aligned';
    if (!f && err && (err.kind === 'NotChecked' || err.kind === 'NotAvailable')) kind = err.kind;
    return { i, f, kind, state: f ? f.state : 'Open' };
  });
  const show = r.show;
  rows = rows.filter((x) => show === 'all' || (show === 'drifted' && x.f && isOpenDrift(x.f)) || (show === 'aligned' && x.kind === 'Aligned') || (show === 'excluded' && x.state === 'Unmanaged'));
  const filters = [['all', 'All'], ['drifted', 'Drifted'], ['aligned', 'Aligned'], ['excluded', 'Excluded']]
    .map(([k, l]) => `<a href="${esc(path.type(r.t, r.wl, r.rt, k))}" data-link data-replace class="btn sm${show === k ? ' pri' : ''}" aria-pressed="${show === k}">${l}</a>`).join('');
  const body = rows.map(({ i, f, kind, state }) => `<div class="gr items">
      <span>${selectBox(r.t, f)}</span>
      <span>${link(path.item(r.t, i.itemId), i.key, 'lnk strong clamp2')}${pendingChip(r.t, i.itemId)}</span>
      <span>${chip(kind, state)}</span>
      <span class="muted">${esc(f ? detail(f) : kind === 'Aligned' ? 'Matches the blueprint' : 'Component not exported')}</span>
      <span class="muted">${esc(f && f.firstSeen ? f.firstSeen.slice(0, 10) : '—')}</span>
      <span>${f ? actionButtons(r.t, f, true) : ''}</span></div>`).join('');
  return `<div class="phead"><div><h1>${esc(typeName(r.rt))}</h1><div class="muted"><span class="mono">${esc(r.rt)}</span> · ${esc(T.meta.displayName)} · ${plural(T.items.filter((i) => i.resourceType === r.rt).length, 'item')}</div></div><div class="btns">${isOffline(r.t) ? '' : `<button class="btn" data-act="recheck-scope" data-scope="${esc(r.rt)}" data-tenant="${esc(r.t)}"${rechecking() ? ' disabled' : ''} title="Refreshes the snapshot for this type: reads every ${esc(typeName(r.rt))} item of this tenant again (a DSC export of this one resource type, not the whole tenant) and compares them with the blueprint.">Refresh</button>`}<span class="btns" role="group" aria-label="Filter">${filters}</span></div></div>
    ${err ? `<div class="banner b-grey"><span class="warn">!</span><div><b>${esc(KIND_LABEL[err.kind])}</b><div class="mono wrap">${esc(err.error)}</div></div></div>` : ''}
    ${bulkBar()}
    <section class="card"><div class="tw"><div class="gt"><div class="gr h items"><span></span><span>Item</span><span>Status</span><span>Detail</span><span>First seen</span><span>Actions</span></div>${body || '<div class="empty">Nothing matches this filter.</div>'}</div></div></section>`;
}

function itemPage(r) {
  const T = tenant(r.t);
  const rt = itemType(r);
  const key = itemKey(r);
  const item = D.items[r.t + '|' + r.id];
  if (!item) { loadItem(r.t, r.id); return '<div class="loading">Loading item…</div>'; }
  if (item.loading) return '<div class="loading">Loading item…</div>';
  if (item.error) return `<div class="banner b-danger">${esc(item.error)}</div>`;
  // A master layer in the URL (from the Drift review) shows that blueprint's side and its finding instead of the tenant blueprint's.
  const viewLayerMeta = r.layer ? layersOf(T.meta).find((l) => !l.sameAsOwn && l.name === r.layer) : null;
  const viewLayer = viewLayerMeta ? viewLayerMeta.name : '';
  if (viewLayer && !D.layerRows[r.t + '|' + viewLayer]) { loadLayer(r.t, viewLayer); return '<div class="loading">Loading item…</div>'; }
  const f = viewLayer ? D.layerRows[r.t + '|' + viewLayer].find((x) => x.itemId === r.id) : findingFor(r.t, r.id);
  const err = typeError(r.t, rt);
  const kind = f ? f.kind : err && err.kind === 'NotChecked' ? 'NotChecked' : 'Aligned';
  const state = f ? f.state : 'Open';
  const layerSides = item.layerBlueprints || {};
  const bp = viewLayer && Object.prototype.hasOwnProperty.call(layerSides, viewLayer) ? layerSides[viewLayer] : item.blueprint;
  const bpLabel = viewLayer ? `Blueprint “${viewLayer}” (v${viewLayerMeta.version})` : `Blueprint (v${currentVersion()})`;
  const tv = item.target;
  const props = [];
  [bp || {}, tv || {}].forEach((o) => Object.keys(o).forEach((k) => { if (!props.includes(k)) props.push(k); }));
  const rows = props.map((p) => ({ p, b: bp ? bp[p] : undefined, v: tv ? tv[p] : undefined, same: !!bp && !!tv && sameJson(bp[p], tv[p]) }));
  const comparable = bp && tv;
  const diffs = comparable ? rows.filter((x) => !x.same) : [];
  const same = comparable ? rows.filter((x) => x.same) : rows;
  const canNoise = f && (f.allowedActions || []).includes('ExcludeProperty') && !busy(r.t, r.id);
  const canTenantProp = f && (f.allowedActions || []).includes('ExcludePropertyForTenant') && !busy(r.t, r.id);
  const propExcluded = (p) => !!f && (f.excludedDifferences || []).some((d) => d.property.toLowerCase() === p.toLowerCase());
  const tenantCol = T.meta.displayName + (f && f.other ? ` (“${f.other}”)` : '');
  let banner = '';
  if (f && f.kind === 'PossibleRename') banner = ['b-review', `Possible rename: the blueprint item “${f.key}” is missing and “${f.other}” exists only in the ${T.meta.role.toLowerCase()} with similar settings. Actions apply to the pair.`];
  if (f && f.kind === 'Ambiguous') banner = ['b-review', (f.hint || 'The key is not unique.') + ' No actions are offered until the key is unique.'];
  if (kind === 'NotChecked') banner = ['b-grey', 'This component was not read in the latest snapshot, so this item could not be compared. ' + (err ? err.error : '')];
  if (f && f.kind === 'Unreadable') banner = ['b-grey', f.error];
  if (viewLayer && !banner) banner = ['b-grey', `Compared with the master blueprint “${viewLayer}”, as in the Drift review you came from.`];
  if (state === 'Unmanaged') {
    const ex = D.exclusions.unmanaged.find((u) => u.tenantId === r.t && u.itemId === r.id);
    banner = ['b-grey', ex ? `Excluded from management on ${ex.at.slice(0, 10)}: ${ex.reason}` : f && (f.excludedDifferences || []).length ? 'Every difference of this item is a setting excluded for this tenant, so it is not counted as drift. The settings stay visible below.' : 'Excluded from management.'];
  }
  const tabs = [['settings', 'Settings'], ['raw', 'Raw'], ['history', 'History']]
    .map(([k, l]) => `<a href="${esc(path.item(r.t, r.id, k, viewLayer))}" data-link data-replace class="tab${r.tab === k ? ' on' : ''}" role="tab" aria-selected="${r.tab === k}">${l}</a>`).join('');
  let body = '';
  if (r.tab === 'raw') {
    const raw = (o, note) => (o ? JSON.stringify(o, null, 2) : note || '(not present)');
    body = `<div class="raw"><div><span class="lab">${esc(bpLabel)}</span><pre>${esc(raw(bp))}</pre></div><div><span class="lab">${esc(tenantCol)}</span><pre>${esc(raw(tv, item.targetNote))}</pre></div></div>`;
  } else if (r.tab === 'history') {
    const vs = D.versions.filter((v) => v.changes.some((c) => c.itemId === r.id)).reverse();
    const versions = vs.map((v) => {
      const c = v.changes.find((x) => x.itemId === r.id);
      const op = c.op === 'Added' ? 'opa' : c.op === 'Removed' ? 'opr' : 'opc';
      return `<div class="gr" style="grid-template-columns:50px 1fr auto"><b>v${v.version}</b><span><span class="${op}">${esc(c.op)}</span>${v.source === 'Revert' ? ` (restored from v${v.revertTo})` : ''} · ${esc((v.at || "").slice(0, 10))} · <span class="muted">${esc(v.reason)}</span></span>
        ${v.version > 1 ? `<button class="btn sm" data-act="restore" data-version="${v.version - 1}" data-item="${esc(r.id)}">Undo: restore from v${v.version - 1}…</button>` : ''}</div>`;
    }).join('');
    const jobs = D.activity.filter((j) => (j.items || []).some((i) => i.itemId === r.id)).map((j) => `<div class="gr" style="grid-template-columns:80px 1fr auto">${link(path.activity(j.jobId), j.jobId)}<span>${esc(actionLabel(j.action))} · ${esc(T.meta.role)} · ${esc(shortDate(j.requestedAt))}</span><span class="chip ${jobClass(j.status)}">${esc(j.status)}</span></div>`).join('');
    body = `<div class="cards2"><section class="card"><h2>Blueprint versions that changed this item</h2>${versions || `<div class="muted">${bp ? 'In the blueprint since v1, unchanged.' : 'Not in the blueprint.'}</div>`}</section>
      <section class="card"><h2>Actions on this item</h2>${jobs || '<div class="muted">No actions yet.</div>'}</section></div>`;
  } else {
    const diffRows = diffs.map((x) => {
      if (propExcluded(x.p)) {
        // Excluded for this tenant: visible, greyed, not counted; the rule (this item's, else the type's) can be removed here.
        const rule = (D.exclusions.propertyExclusions || []).filter((e) => e.tenantId === r.t && e.resourceType === rt && e.property.toLowerCase() === x.p.toLowerCase()).sort((a, b) => (b.itemId ? 1 : 0) - (a.itemId ? 1 : 0))[0];
        return `<div class="gr setg" style="opacity:.7"><span class="mono">${esc(x.p)}</span><span>${fv(x.b)}</span><span>${fv(x.v)}</span>
          <span><span class="chip c-grey">excluded for this tenant</span>${rule ? ` <button class="lnk sub" data-act="include-prop" data-tenant="${esc(r.t)}" data-type="${esc(rt)}" data-prop="${esc(x.p)}" data-item="${esc(rule.itemId || '')}">Bring back…</button>` : ''}</span></div>`;
      }
      const differs = f && f.differences.some((d) => d.property === x.p);
      return `<div class="gr setg hl"><span class="mono">${esc(x.p)}</span><span>${fv(x.b)}</span><span><span class="diffv">${fv(x.v)}</span></span>
      <span>${canNoise && differs ? `<button class="lnk sub" data-act="noise" data-tenant="${esc(r.t)}" data-item="${esc(r.id)}" data-prop="${esc(x.p)}">Ignore value as noise…</button>` : ''}${canTenantProp && differs ? `<div><button class="lnk sub" data-act="tenant-prop" data-tenant="${esc(r.t)}" data-item="${esc(r.id)}" data-prop="${esc(x.p)}">Exclude for this tenant…</button></div>` : ''}</span></div>`;
    }).join('');
    // Opens on what differs; an item that matches everywhere opens on its matching settings. Without a blueprint or tenant side there is
    // nothing to compare, so every setting shows and there is no filter.
    const show = comparable ? ui.itemShow || (diffs.length ? 'drifted' : 'matching') : 'all';
    const showDrift = show !== 'matching';
    const showMatch = show !== 'drifted';
    const sameRows = showMatch ? same.map((x) => `<div class="gr setg${comparable ? ' ok' : ''}"><span class="mono">${esc(x.p)}</span><span>${bp ? fv(x.b) : '—'}</span><span>${tv ? fv(x.v) : esc(item.targetNote || '—')}</span><span>${comparable ? '<span class="chip c-ok">match</span>' : ''}</span></div>`).join('') : '';
    const filterBtn = (v, label) => `<button id="item-show-${v}" class="btn sm${show === v ? ' pri' : ''}" data-act="item-show" data-show="${v}" aria-pressed="${show === v}">${label}</button>`;
    const filter = comparable ? `<div class="gr setg"><span class="vt-toggle" style="grid-column:1 / -1;margin:0" role="group" aria-label="Show settings">${filterBtn('all', `All ${rows.length}`)}${filterBtn('drifted', `Drifted ${diffs.length}`)}${filterBtn('matching', `Matching ${same.length}`)}</span></div>` : '';
    const empty = !showDrift || diffRows ? '' : `<div class="gr setg"><span class="muted" style="grid-column:1 / -1">${comparable ? 'No differing settings.' : tv ? 'Not in the blueprint; only the tenant has it.' : bp ? (item.targetNote || 'Not in the tenant.') : 'Nothing to compare.'}</span></div>`;
    body = `<section class="card"><div class="tw"><div class="gt">
      ${filter}
      <div class="gr h setg"><span>Setting</span><span>${esc(bpLabel)}</span><span>${esc(tenantCol)}</span><span></span></div>
      ${showDrift ? diffRows : ''}${empty}
      ${sameRows}
      ${item.unreadable && item.unreadable.length ? `<div class="gr setg"><span class="muted" style="grid-column:1 / -1">Unreadable, not compared: <span class="mono">${esc(item.unreadable.join(', '))}</span></span></div>` : ''}
    </div></div></section>`;
  }
  return `<div class="phead"><div><h1>${esc(key)}${pendingChip(r.t, r.id)}</h1><div class="muted">${chip(kind, state)} · ${esc(typeName(rt))} <span class="mono">(${esc(rt)})</span> · ${esc(T.meta.displayName)} · ${esc(f ? detail(f) : kind === 'NotChecked' ? 'Not compared' : 'Matches the blueprint')}</div></div>
    <div class="btns">${f ? actionButtons(r.t, f, false) : ''}${isOffline(r.t) ? '' : `<button class="btn" data-act="recheck-scope" data-scope="${esc(rt)}" data-tenant="${esc(r.t)}"${rechecking() ? ' disabled' : ''} title="Refreshes the snapshot for this type: reads every ${esc(typeName(rt))} item of this tenant again (a DSC export of this one resource type, not the whole tenant) and compares them with the blueprint. The rest keeps the latest snapshot.">↻ Refresh ${esc(typeName(rt))}</button>`}</div></div>
    ${banner ? `<div class="banner ${banner[0]}"><span class="warn">i</span><div>${esc(banner[1])}</div></div>` : ''}
    <div class="tabs" role="tablist">${tabs}</div>${body}`;
}

const layerLoading = new Set();
async function loadLayer(t, name) {
  const key = t + '|' + name;
  if (layerLoading.has(key)) return;
  layerLoading.add(key);
  try { D.layerRows[key] = await api(`/api/tenants/${enc(t)}/layer-findings?layer=${enc(name)}`); } catch (e) { D.layerRows[key] = Object.assign([], { failed: true }); }
  layerLoading.delete(key);
  render();
}
function drift(r) {
  const q = r.q.trim().toLowerCase();
  const lt = r.tenant !== 'all' && tenant(r.tenant) ? r.tenant : null;
  const otherLayers = lt ? (tenant(lt).meta.layers || []).filter((l) => !l.sameAsOwn && l.checked) : [];
  const viewLayer = lt && r.layer && otherLayers.some((l) => l.name === r.layer) ? r.layer : '';
  const all = [];
  if (viewLayer) {
    const layerRows = D.layerRows[lt + '|' + viewLayer];
    if (!layerRows) loadLayer(lt, viewLayer);
    (layerRows || []).filter(isOpenDrift).forEach((f) => all.push({ t: lt, f }));
  } else D.tenantIds.forEach((t) => findingsOf(t).filter(isOpenDrift).forEach((f) => all.push({ t, f })));
  const list = all.filter(({ t, f }) => (r.tenant === 'all' || t === r.tenant) && (r.workload === 'all' || f.workload === r.workload)
    && (r.kind === 'all' || f.kind === r.kind) && (!q || (f.key + ' ' + f.resourceType + ' ' + typeName(f.resourceType)).toLowerCase().includes(q)));
  const groups = [];
  D.tenantIds.forEach((t) => D.index.workloads.forEach((wl) => {
    const rows = list.filter((x) => x.t === t && x.f.workload === wl);
    if (rows.length) groups.push({ title: tenantLabel(t) + ' · ' + wl, rows });
  }));
  const opt = (v, l, cur) => `<option value="${esc(v)}"${v === cur ? ' selected' : ''}>${esc(l)}</option>`;
  const body = groups.map((g) => `<div class="ghead">${esc(g.title)} <span class="muted">(${g.rows.length})</span></div>` + g.rows.map(({ t, f }) => {
    const key = t + '|' + f.itemId;
    const open = ui.expanded.has(key);
    let note = '';
    if (f.kind === 'Missing') note = `In the blueprint, not in the ${role(t).toLowerCase()}.`;
    if (f.kind === 'TargetOnly') note = `In the ${role(t).toLowerCase()}, not in the blueprint.`;
    if (f.kind === 'PossibleRename') note = `Blueprint item “${f.key}” is missing; “${f.other}” is new with similar settings. Treated as one pair.`;
    if (f.kind === 'Ambiguous') note = f.hint || '';
    const lines = f.kind === 'Changed' ? f.differences.map((d) => `<div class="dl"><span class="mono">${esc(d.property)}</span><span class="old">${fv(d.blueprint)}</span><span aria-hidden="true">→</span><span class="new">${fv(d.target)}</span></div>`).join('') : '';
    return `<div class="gr drift">
      <span>${selectBox(t, f)}</span>
      <span>${link(path.item(t, f.itemId, undefined, viewLayer), f.kind === 'PossibleRename' ? f.key + ' → ' + f.other : f.key, 'lnk strong clamp2')}${pendingChip(t, f.itemId)}<div class="muted sub">${esc(typeName(f.resourceType))}</div></span>
      <span>${chip(f.kind, f.state)}</span><span class="muted wrap">${esc(detail(f))}</span>
      <span>${actionButtons(t, f, true)}</span>
      <button class="lnk" id="exp-${esc(key)}" data-act="expand" data-key="${esc(key)}" aria-expanded="${open}" aria-label="${open ? 'Hide' : 'Show'} details for ${esc(f.key)}">${open ? '▾' : '▸'}</button></div>
      ${open ? `<div class="exp">${lines}${note ? `<div>${esc(note)}</div>` : ''}<div class="muted sub">First seen ${esc(f.firstSeen ? f.firstSeen.slice(0, 10) : '—')}</div></div>` : ''}`;
  }).join('')).join('');
  const layerNote = viewLayer ? `<div class="banner b-grey"><span class="warn">i</span><div>Showing how this tenant differs from the master blueprint “${esc(viewLayer)}”. Only the tenant blueprint can be updated from here; a tenant is only written from its own blueprint.</div></div>` : '';
  return `<div class="phead"><div><h1>Drift review</h1><div class="muted">Open drift across ${D.tenantIds.length > 1 ? 'both tenants' : 'the tenant'}. Expand a row to see the differing settings.</div></div></div>
    ${dscBanner(true)}${layerNote}<div class="filters">
      <label class="fl">Tenant<select id="f-tenant" data-filter="tenant">${opt('all', 'All tenants', r.tenant)}${D.tenantIds.map((t) => opt(t, tenantLabel(t), r.tenant)).join('')}</select></label>
      ${otherLayers.length ? `<label class="fl">Compared with<select id="f-layer" data-filter="layer">${opt('', 'Its own blueprint', viewLayer)}${otherLayers.map((l) => opt(l.name, 'Master blueprint “' + l.name + '”', viewLayer)).join('')}</select></label>` : ''}
      <label class="fl">Workload<select id="f-workload" data-filter="workload">${opt('all', 'All workloads', r.workload)}${D.index.workloads.map((w) => opt(w, w, r.workload)).join('')}</select></label>
      <label class="fl">Kind<select id="f-kind" data-filter="kind">${opt('all', 'All kinds', r.kind)}${DRIFT.map((k) => opt(k, KIND_LABEL[k], r.kind)).join('')}</select></label>
      <label class="fl">Search<input id="f-q" type="text" data-filter="q" value="${esc(r.q)}" placeholder="Item or type, then Enter"></label>
      <span class="muted" style="padding-bottom:10px">${list.length} shown</span></div>
    ${bulkBar()}
    <section class="card"><div class="tw"><div class="gt"><div class="gr h drift"><span></span><span>Item</span><span>Kind</span><span>Detail</span><span>Actions</span><span></span></div>
      ${body || '<div class="empty">No open drift matches these filters.</div>'}</div></div></section>`;
}

// The Blueprint page: the master blueprint, or a tenant blueprint (?name=) of the selected tenant. The tabs are the blueprints that tenant follows.
function blueprint(r) {
  const masterName = D.index.blueprint.name;
  const layers = tenant(curTenant()).meta.layers || [];
  const name = r && r.name && r.name !== masterName && layers.some((l) => l.name === r.name) ? r.name : '';
  const t = name ? curTenant() : D.tenantIds.find((x) => role(x) === 'Master');
  const list = versionsFor(name);
  const cur = list ? currentVersionOf(list, name) : 0;
  const curV = (list || []).find((v) => v.version === cur) || {};
  const inBlueprint = t ? tenant(t).items.filter((i) => i.inBlueprint) : [];
  const contents = D.index.workloads.filter((wl) => inBlueprint.some((i) => i.workload === wl)).map((wl) => {
    const items = inBlueprint.filter((i) => i.workload === wl);
    const types = new Set(items.map((i) => i.resourceType)).size;
    return `<div class="kl" style="grid-template-columns:1fr auto auto"><span>${t ? link(path.workload(t, wl), wl, 'lnk') : esc(wl)}</span><span class="muted">${plural(types, 'type')}</span><span class="num">${plural(items.length, 'item')}</span></div>`;
  }).join('');
  const pending = t ? findingsOf(t).filter(isOpenDrift) : [];
  const byKind = Object.entries(pending.reduce((m, f) => { m[f.kind] = (m[f.kind] || 0) + 1; return m; }, {})).map(([k, n]) => `${n} ${KIND_LABEL[k] || k}`).join(' · ');
  const waiting = pending.length
    ? `<div class="bigline"><b>${pending.length}</b> ${pending.length === 1 ? 'item differs' : 'items differ'} <span class="muted">between ${esc(tenantLabel(t))} and this blueprint</span></div><div class="muted">${esc(byKind)}</div>
      <div class="muted note">Promote takes a change into the blueprint; Revert tenant puts the tenant back. Both are done on the Drift review page.</div>
      <div class="btns">${link(path.drift({ tenant: t }), 'Review in Drift review', 'btn pri')}</div>`
    : '<div class="empty">No difference: the tenant matches this blueprint.</div>';
  const row = (v) => {
    const c = { Added: 0, Changed: 0, Removed: 0 };
    v.changes.forEach((x) => { c[x.op]++; });
    const src = v.source === 'Revert' ? 'c-review' : v.source === 'Initial' ? 'c-grey' : 'c-excl';
    return `<div class="gr verg"><b>v${v.version}${v.version === cur ? ' <span class="chip c-ok">current</span>' : ''}</b><span>${esc((v.at || "").slice(0, 10))}</span>
      <span><span class="chip ${src}">${esc(srcLabel(v.source) + (v.revertTo ? ' → v' + v.revertTo : ''))}</span></span><span>${esc(v.reason)}</span>
      <span class="mono">${v.version === 1 ? 'initial' : `+${c.Added} ~${c.Changed} −${c.Removed}`}</span>
      <span class="btns">${link(path.version(v.version, name), 'View changes', 'btn sm')}${!name && v.version !== cur ? `<button class="btn sm" data-act="revert" data-version="${v.version}">Restore v${v.version}…</button>` : ''}</span></div>`;
  };
  const newest = (list || []).slice().reverse();
  const head = '<div class="gr h verg"><span>Version</span><span>Date</span><span>Made by</span><span>Reason</span><span>Changes</span><span></span></div>';
  const older = newest.slice(5);
  const versions = list
    ? newest.slice(0, 5).map(row).join('') + (older.length ? `<details class="olderv"><summary class="lnk">Show ${plural(older.length, 'older version')}</summary>${older.map(row).join('')}</details>` : '')
    : (D.bpVersions[name] && D.bpVersions[name].error ? `<div class="err">${esc(D.bpVersions[name].error)}</div>` : '<div class="loading">Loading the versions…</div>');
  const tabs = layers.length > 1 ? `<div class="vt-toggle" role="group" aria-label="Blueprint of ${esc(tenantLabel(curTenant()))}">${layers.map((l, i) => {
    const nm = i === 0 ? '' : l.name;
    return `<a href="${esc(path.blueprint(nm))}" data-link class="btn sm${nm === name ? ' pri' : ''}" aria-current="${nm === name}">${i === 0 ? 'Master' : 'Tenant'} “${esc(l.name)}” v${esc(l.version == null ? '?' : l.version)}</a>`;
  }).join('')}</div>` : '';
  const title = name ? `Tenant blueprint “${esc(name)}”` : `Master blueprint “${esc(masterName)}”`;
  const about = name
    ? `${esc(tenantLabel(curTenant()))}’s own blueprint. It started as a copy of the master blueprint, and ${esc(tenantLabel(curTenant()))} is only ever changed from it. It is locked: it changes only through Promote, and each creates a new version.`
    : 'The approved state every tenant is compared with. It is locked: it changes only through Promote or Restore, and each creates a new version.';
  return `<div class="phead"><div><h1>${title}</h1><div class="muted">${about}</div></div>${list ? link(path.compare(Math.max(1, cur - 1), cur, name), 'Compare two versions', 'btn') : ''}</div>
    ${tabs}
    <div class="cards2"><section class="card"><h2>What it holds · v${cur || '…'}</h2><div class="muted" style="margin-bottom:10px">${list ? `Latest change ${esc((curV.at || '').slice(0, 10))} · ${esc(srcLabel(curV.source || ''))} · ${esc(curV.reason || '')}` : 'Loading…'}</div>${contents || '<div class="empty">Nothing yet.</div>'}</section>
    <section class="card"><h2>${t ? esc(tenantLabel(t)) : 'Master tenant'} against this blueprint</h2>${waiting}</section></div>
    <section class="card"><h2>Versions</h2><div class="tw"><div class="gt">${head}${versions}</div></div></section>`;
}

function versionPage(r) {
  const list = versionsFor(r.name);
  if (!list) return (D.bpVersions[r.name] && D.bpVersions[r.name].error) ? notFound() : '<div class="loading">Loading the versions…</div>';
  const v = list.find((x) => x.version === r.n);
  if (!v) return notFound();
  const cur = currentVersionOf(list, r.name);
  const rows = v.changes.map((c) => `<div class="gr cmpg"><span class="${c.op === 'Added' ? 'opa' : c.op === 'Removed' ? 'opr' : 'opc'}"><b>${esc(c.op)}</b></span><span>${esc((D.types[c.resourceType] || {}).workload || '')}</span><span>${esc(typeName(c.resourceType))}</span><span>${esc(c.key)}</span></div>`).join('');
  return `<div class="phead"><div><h1>${r.name ? 'Tenant blueprint “' + esc(r.name) + '”' : 'Blueprint'} v${v.version}${v.version === cur ? ' (current)' : ''}</h1><div class="muted">${esc((v.at || "").slice(0, 10))} · ${esc(srcLabel(v.source) + (v.revertTo ? ' from v' + v.revertTo : ''))} · ${esc(v.reason)}</div></div>
    <div class="btns">${v.version > 1 ? link(path.compare(v.version - 1, v.version, r.name), 'Compare with v' + (v.version - 1), 'btn') : ''}${!r.name && v.version !== cur ? `<button class="btn" data-act="revert" data-version="${v.version}">Restore v${v.version}…</button>` : ''}</div></div>
    <section class="card"><h2>${v.version === 1 ? 'Initial version' : 'Changes recorded in this version'}</h2><div class="tw"><div class="gt">
      ${v.version === 1 ? '<div class="muted">The first blueprint, taken from a full export of the master. It has no change record.</div>' : `<div class="gr h cmpg"><span>Change</span><span>Workload</span><span>Type</span><span>Item</span></div>${rows || '<div class="empty">No item changes recorded.</div>'}`}
    </div></div></section>`;
}

function compare(r) {
  const list = versionsFor(r.name);
  if (!list) return '<div class="loading">Loading the versions…</div>';
  const cur = currentVersionOf(list, r.name);
  const res = D.compares[(r.name || '') + '|' + r.from + '-' + r.to];
  if (!res) { loadCompare(r.from, r.to, r.name); return '<div class="loading">Comparing…</div>'; }
  if (res.loading) return '<div class="loading">Comparing…</div>';
  if (res.error) return `<div class="banner b-danger">${esc(res.error)}</div>`;
  const rows = res.rows;
  const opts = (sel) => list.map((v) => `<option value="${v.version}"${v.version === sel ? ' selected' : ''}>v${v.version} · ${esc((v.at || "").slice(0, 10))}${v.version === cur ? ' (current)' : ''}</option>`).join('');
  const body = rows.map((c) => `<div class="gr cmpg"><span class="${c.op === 'Added' ? 'opa' : c.op === 'Removed' ? 'opr' : 'opc'}"><b>${esc(c.op)}</b></span><span>${esc((D.types[c.resourceType] || {}).workload || '')}</span><span>${esc(typeName(c.resourceType))}</span><span>${esc(c.key)}</span></div>`).join('');
  return `<div class="phead"><div><h1>Compare blueprint versions</h1><div class="muted">Changes going from v${r.from} to v${r.to}: ${plural(rows.length, 'item')}.</div></div>
    ${!r.name && r.to === cur && r.from !== cur ? `<button class="btn" data-act="revert" data-version="${r.from}">Restore v${r.from}…</button>` : ''}</div>
    <div class="filters"><label class="fl">From<select id="c-from" data-compare="from">${opts(r.from)}</select></label><label class="fl">To<select id="c-to" data-compare="to">${opts(r.to)}</select></label></div>
    <section class="card"><div class="tw"><div class="gt"><div class="gr h cmpg"><span>Change</span><span>Workload</span><span>Type</span><span>Item</span></div>${body || '<div class="empty">The two versions are identical.</div>'}</div></div></section>`;
}

const SELECTION_SECTIONS = [
  ['Revert', 'Revert: put the tenant back', 'Applied to the tenant as a DSC configuration (one per tenant and workload). The only action that writes to a tenant.'],
  ['Promote', 'Promote: accept into the blueprint', 'The tenant’s value becomes the blueprint’s. A new blueprint version; no tenant is changed.'],
  ['Exclude', 'Exclude: ignore the drift', 'Recorded as an exclusion; the item is no longer managed or counted as drift.'],
  ['AcceptRisk', 'Accept risk: leave it as it is', 'A note of who approved the difference from a standard and why. The tenant and the blueprint are not changed.'],
  ['Adopt', 'Adopt: copy the standard’s setting into the blueprint', 'A new version of the tenant’s own blueprint. No tenant is changed; revert the items afterwards on Drift review.']
];
async function queuePreview() {
  const groups = queueGroups();
  if (!groups.length) return;
  ui.selPreview = { loading: true };
  render();
  try {
    const previews = await Promise.all(groups.map((g) => api('/api/requests/preview', Object.assign(groupBody(g), { reason: '(preview)', confirmedMasterWrite: true }))));
    ui.selPreview = { groups, previews };
  } catch (e) { ui.selPreview = { error: e.message }; }
  render();
}
function selectionReview() {
  const v = ui.selPreview;
  if (!v) return '';
  if (v.loading) return '<section class="card"><div class="muted">Working out what the selection list does…</div></section>';
  if (v.error) return `<section class="card"><div class="err">${esc(v.error)}</div></section>`;
  const errors = v.previews.flatMap((p) => p.errors || []);
  const config = v.previews.map((p) => p.config).filter(Boolean).join('\n\n');
  const blocks = v.groups.map((g, i) => {
    const p = v.previews[i];
    const what = { Revert: 'Revert', Promote: 'Promote into blueprint', Exclude: 'Exclude', Adopt: 'Adopt into blueprint', AcceptRisk: 'Accept risk' }[g.pick];
    const bp = p.blueprintVersionAfter ? `<div class="muted sub">Creates blueprint “${esc(p.blueprintName || '')}” v${esc(p.blueprintVersionAfter)}.</div>` : '';
    return `<div class="revblock"><div><b>${esc(what)}</b> · ${esc(tenantLabel(g.tenantId))} · ${esc(workloadOf(((findingFor(g.tenantId, g.items[0].itemId) || {}).resourceType) || ''))}</div>${bp}
      ${(p.items || []).map((it) => `<div class="dit"><span><b>${esc(it.label)}</b></span><span>${esc(it.effect)}</span></div>`).join('')}</div>`;
  }).join('');
  return `<section class="card"><h2>Everything the selection list will do</h2>
    ${errors.length ? `<div class="banner b-danger" style="flex-direction:column">${errors.map((e) => `<div>${esc(e)}</div>`).join('')}</div>` : ''}
    ${blocks}
    <div class="lab mt3">Combined DSC configuration (the Revert items)</div>
    ${config ? `<pre style="max-height:360px">${esc(config)}</pre>` : '<div class="muted">No Revert items, so no DSC configuration. Promote and Exclude do not write to a tenant.</div>'}
    <div class="muted sub">This is the configuration as it would be generated now. When the list is run, each Revert item is planned again from the latest check and the configuration is saved to the audit folder before anything is applied.</div></section>`;
}
function queuePage() {
  const sections = SELECTION_SECTIONS.map(([name, title, blurb]) => {
    const list = ui.queue.filter((c) => c.action === name);
    if (!list.length) return '';
    const rows = list.map((c) => {
      if (c.standard) return stdQueueRow(c);
      const live = queueLive(c);
      const f = tenant(c.t) && findingFor(c.t, c.itemId);
      const why = !tenant(c.t) ? 'tenant no longer registered' : !f || !isOpenDrift(f) ? 'no longer drifted in the latest check' : `cannot be ${name === 'Revert' ? 'reverted' : name === 'Promote' ? 'promoted' : 'excluded'} now`;
      return `<div class="gr selrow"><span><b class="wrap">${esc(c.key)}</b><div class="muted sub">${esc(workloadOf(c.resourceType))} · ${esc(typeName(c.resourceType))}</div></span>
        <span>${esc(tenant(c.t) ? tenant(c.t).meta.displayName : c.t)} <span class="muted">· ${esc(tenant(c.t) ? role(c.t) : '')}</span></span>
        <span>${live ? chip(f.kind, f.state) : `<span class="chip c-grey">⊘ ${esc(why)}</span>`}</span>
        <button class="btn sm" data-act="queue-remove" data-tenant="${esc(c.t)}" data-ids="${esc(c.itemId)}" aria-label="Remove ${esc(c.key)} from the selection list">Remove</button></div>`;
    }).join('');
    return `<section class="card"><h2>${esc(title)} (${list.length})</h2><div class="muted sub" style="margin-bottom:8px">${esc(blurb)}</div>${rows}</section>`;
  }).join('');
  const live = ui.queue.filter(queueLive);
  const masterWrite = live.some((c) => c.action === 'Revert' && role(c.t) === 'Master');
  const needReason = live.some((c) => c.action !== 'Revert' && c.action !== 'AcceptRisk');
  const disabled = live.length ? '' : ' disabled';
  return `<div class="phead"><div><h1>Selection list</h1><div class="muted">Revert, Promote or Exclude drifted items on the Drift review page, and Adopt or Accept risk on the Standards page. They collect here; nothing is applied until you run the list, or export the DSC configuration of the Revert items as a .ps1 file to run later on a pipeline agent.</div></div>
    <div class="btns"><button class="btn" data-act="queue-clear"${ui.queue.length ? '' : ' disabled'}>Clear list</button>
      <button class="btn" data-act="queue-preview"${disabled}>Review the DSC configuration</button>
      <button class="btn" data-act="queue-export"${live.some((c) => c.action === 'Revert') ? '' : ' disabled'} title="Saves the DSC configuration of the Revert items as a .ps1 plus a .psd1 of placeholders per tenant and workload, to fill in and apply by hand. Promote and Exclude are not in it.">Export DSC configuration (.ps1 + .psd1)</button>
      <button class="${masterWrite ? 'btn dan' : 'btn pri'}" data-act="queue-run"${disabled}>Run ${plural(live.length, 'item')}…</button></div></div>
    ${sections || '<section class="card"><div class="empty muted">The selection list is empty. Choose Revert, Promote or Exclude on the Drift review page or an item row.</div></section>'}
    ${live.length < ui.queue.length ? '<div class="banner b-grey" role="status"><span class="warn">!</span><div>Items marked ⊘ are not sent when the list runs or is exported. Remove them, or take a new snapshot and choose them again.</div></div>' : ''}
    ${live.length ? `<section class="card"><label class="lab" for="sel-reason">Reason ${needReason ? '(needed for Promote, Adopt and Exclude)' : '(optional)'}</label><textarea id="sel-reason" placeholder="Why? Recorded with the blueprint version and the exclusions when you run the list.">${esc(ui.selReason || '')}</textarea></section>` : ''}
    ${selectionReview()}
    <div class="muted sub">The export is the configuration shown above for the Revert items only (Promote and Exclude change the blueprint and the exclusions, not a tenant, so run them here), as a <code>.ps1</code> and a <code>.psd1</code> of placeholders for ApplicationId, CertificateThumbprint, OrganizationName, TenantGuid and TenantId. Fill in the .psd1 and run the .ps1.</div>`;
}
function exclusions() {
  const items = D.exclusions.unmanaged.map((u) => `<div class="gr exg"><span>${esc(tenantLabel(u.tenantId))}</span><span>${esc(typeName(u.resourceType))}</span>
    <span>${link(path.item(u.tenantId, u.itemId), u.key, 'lnk strong')}${pendingChip(u.tenantId, u.itemId)}</span><span>${esc(u.reason)}</span><span class="muted">${esc(u.at.slice(0, 10))}</span>
    <span><button class="btn sm" data-act="action" data-action="Unexclude" data-tenant="${esc(u.tenantId)}" data-ids="${esc(u.itemId)}">Bring back…</button></span></div>`).join('');
  const noise = D.exclusions.noise.map((n, i) => `<div class="gr nzg"><span>${esc(typeName(n.resourceType))}</span><span class="mono">${esc(n.property)}</span><span>${fv(n.value)}</span>
    <span>${esc(n.itemId ? decodeURIComponent(n.itemId.split('~')[1]) : 'All items')}</span><span>${esc(n.reason)}</span><span class="muted">${esc(n.at.slice(0, 10))}</span>
    <span><button class="btn sm" data-act="unnoise" data-index="${i}">Remove…</button></span></div>`).join('');
  const propRules = (D.exclusions.propertyExclusions || []);
  const props = propRules.map((e) => `<div class="gr exg"><span>${esc(tenantLabel(e.tenantId))}</span><span>${esc(typeName(e.resourceType))}</span>
    <span><span class="mono">${esc(e.property)}</span> · ${e.itemId ? link(path.item(e.tenantId, e.itemId), e.key, 'lnk strong') : 'all items'}</span><span>${esc(e.reason)}</span><span class="muted">${esc((e.at || '').slice(0, 10))}</span>
    <span><button class="btn sm" data-act="include-prop" data-tenant="${esc(e.tenantId)}" data-type="${esc(e.resourceType)}" data-prop="${esc(e.property)}" data-item="${esc(e.itemId || '')}">Bring back…</button></span></div>`).join('');
  return `<div class="phead"><div><h1>Exclusions</h1><div class="muted">Items left unmanaged, settings not enforced in one tenant, and values ignored as noise. Not counted as aligned or drifted.</div></div></div>
    <div class="stack"><section class="card"><h2>Unmanaged items (${D.exclusions.unmanaged.length})</h2><div class="tw"><div class="gt"><div class="gr h exg"><span>Tenant</span><span>Type</span><span>Item</span><span>Reason</span><span>Since</span><span></span></div>${items || '<div class="empty">None.</div>'}</div></div></section>
    <section class="card"><h2>Properties not enforced in a tenant (${propRules.length})</h2><div class="muted" style="margin-bottom:6px">Still shown in the item, not counted as drift, and left as the tenant has them by a revert.</div><div class="tw"><div class="gt"><div class="gr h exg"><span>Tenant</span><span>Type</span><span>Property</span><span>Reason</span><span>Since</span><span></span></div>${props || '<div class="empty">None.</div>'}</div></div></section>
    <section class="card"><h2>Noise rules (${D.exclusions.noise.length})</h2><div class="tw"><div class="gt"><div class="gr h nzg"><span>Type</span><span>Property</span><span>Value</span><span>Scope</span><span>Reason</span><span>Since</span><span></span></div>${noise || '<div class="empty">None.</div>'}</div></div></section></div>`;
}

// The files of a GenerateConfig job, downloaded from the server (the job itself holds only their item counts).
const configUrl = (jobId, file) => '/api/jobs/' + enc(jobId) + '/config/' + file;
const CONFIG_FILES = [['Changes', '.ps1', 'changes'], ['Removals', '.ps1', 'removals'], ['Manual', '.json', 'manual']];
const CONFIG_NOTE = { Changes: 'creates and updates; run it first', Removals: 'removes what is left as drift; run it second', Manual: 'what needs manual action' };
async function loadManual(jobId) {
  const cur = ui.manual[jobId];
  if (cur && !cur.retry) return;
  ui.manual[jobId] = { loading: true };
  try { const rows = await api(configUrl(jobId, 'Manual')); ui.manual[jobId] = { rows: Array.isArray(rows) ? rows : [] }; } catch (e) { ui.manual[jobId] = { error: e.message, retry: false }; }
  render();
  // An error is shown once and not kept: the next render asks again.
  if (ui.manual[jobId].error) ui.manual[jobId].retry = true;
}
function configFiles(j) {
  // A file with no items was not written, so it gets no link; the manual list is always there.
  const links = CONFIG_FILES.filter(([name, , k]) => name === 'Manual' || j.files[k] > 0)
    .map(([name, ext, k]) => `<div><a class="lnk" href="${esc(configUrl(j.jobId, name))}" download="${esc(j.jobId + '-' + name + ext)}">${esc(name + ext)}</a> <span class="muted">${esc(plural(j.files[k] || 0, 'item') + ' · ' + CONFIG_NOTE[name])}</span></div>`).join('');
  const list = ui.manual[j.jobId];
  if (!list || list.retry) loadManual(j.jobId);
  const manual = !list || list.loading ? '<div class="muted">Loading…</div>' : list.error ? `<div class="err">${esc(list.error)}</div>`
    : !list.rows.length ? '<div class="muted">Nothing needs manual action.</div>'
      : list.rows.map((m) => `<div class="mt3"><b>${esc(typeName(m.ResourceType))} · ${esc(m.Key)}</b> <span class="muted">${esc(m.Action)}</span><div class="muted wrap">${esc(m.Reason)}</div></div>`).join('');
  return `${links}<span class="lab mt3">Needs manual action</span>${manual}`;
}
function activity(r) {
  const openJob = ui.openJob || r.job;
  const rows = D.activity.map((j) => {
    const open = openJob === j.jobId;
    const items = (j.items || []).length ? j.items : [{ label: 'Whole tenant' }];
    const summary = !(j.items || []).length ? '—' : j.items.length === 1 ? j.items[0].label || j.items[0].key : plural(j.items.length, 'item');
    return `<div class="gr jg"><b>${esc(j.jobId)}</b><span>${esc(actionLabel(j.action))}</span><span>${esc(j.tenantId && tenant(j.tenantId) ? tenantLabel(j.tenantId) : '—')}</span><span>${esc(summary || '—')}</span><span class="muted">${esc(shortDate(j.requestedAt))}</span>
      <span><span class="chip ${jobClass(j.status)}">${esc(j.status === 'Running' && j.cancelRequested ? 'Cancelling…' : j.status)}</span>${canCancelJob(j) ? ` <button class="btn sm" data-act="cancel-job" data-job="${esc(j.jobId)}" title="${j.status === 'Queued' ? 'Takes the job off the queue.' : 'Stops the export; nothing is saved.'}">Cancel</button>` : ''}</span>
      <button class="lnk" id="job-${esc(j.jobId)}" data-act="job" data-job="${esc(j.jobId)}" aria-expanded="${open}" aria-label="${open ? 'Hide' : 'Show'} details for ${esc(j.jobId)}">${open ? '▾' : '▸'}</button></div>
      ${open ? `<div class="exp" style="padding-left:16px"><div class="cards2" style="margin-bottom:0"><div>
        <span class="lab">Items</span>${items.map((i) => `<div>${esc(i.label || (typeName(i.resourceType) + ' · ' + i.key))}</div>`).join('')}
        ${j.reason ? `<span class="lab" class="mt3">Reason</span><div>${esc(j.reason)}</div>` : ''}
        ${j.result ? `<span class="lab" class="mt3">Result</span><div>${esc(j.result)}</div>` : ''}
        ${j.requestId ? `<span class="lab" class="mt3">Request file</span><div class="mono">${tt('requests/' + j.requestId + '.json')}</div>` : ''}
      </div><div><span class="lab">Generated config</span>${j.action === 'GenerateConfig' && j.status === 'Succeeded' && j.files ? configFiles(j) : j.config ? `<pre>${esc(j.config)}</pre>` : '<div class="muted">No tenant change, so no config.</div>'}</div></div></div>` : ''}`;
  }).join('');
  return `<div class="phead"><div><h1>Activity</h1><div class="muted">Every action request and check, newest first.${D.activity.some((j) => j.mock) ? ' Mock jobs finish a few seconds after they are queued.' : ''}</div></div></div>
    <section class="card"><div class="tw"><div class="gt"><div class="gr h jg"><span>Job</span><span>Action</span><span>Tenant</span><span>Items</span><span>Requested</span><span>Status</span><span></span></div>${rows || '<div class="empty">No activity yet.</div>'}</div></div></section>`;
}
const notFound = () => `<div class="empty"><h1>Not found</h1><p>${link('/', 'Back to the overview')}</p></div>`;

// ---------- dialog ----------
// What a request carries of a selection group (its display-only fields stay in the page).
function groupBody(g) { const { pick, ...rest } = g; return Object.assign({}, rest); }
async function openDialog(action, groups, extra) {
  ui.dialog = Object.assign({ action, groups, step: 1, reason: '', confirmed: false, scopeItem: false, loading: true, previews: [], errors: [], previewErrors: 0 }, extra || {});
  render();
  try {
    const previews = await Promise.all(groups.map((g) => api('/api/requests/preview', Object.assign(groupBody(g), { action: g.action || action, reason: '(preview)', confirmedMasterWrite: true }))));
    if (!ui.dialog) return;
    ui.dialog.previews = previews;
    ui.dialog.errors = previews.flatMap((p) => p.errors || []);
    ui.dialog.previewErrors = ui.dialog.errors.length;
  } catch (e) {
    if (ui.dialog) { ui.dialog.errors = [e.message]; ui.dialog.previewErrors = 1; }
  }
  if (ui.dialog) { ui.dialog.loading = false; render(); }
}
const reasonRequired = (d) => d.previews.some((p) => p.reasonRequired);
function dialogDisabled(d) {
  return d.loading || d.previewErrors > 0 || !d.previews.length || (reasonRequired(d) && !d.reason.trim()) || (d.step === 2 && !d.confirmed);
}
function dialogView() {
  const d = ui.dialog;
  if (!d) return '';
  const items = d.previews.flatMap((p) => (p.items || []).map((i) => Object.assign({ role: p.role }, i)));
  const writesMaster = d.previews.some((p) => p.writesMaster);
  const destructive = d.previews.some((p) => p.destructive);
  const vAfter = (d.previews.find((p) => p.blueprintVersionAfter) || {}).blueprintVersionAfter;
  const vCount = d.previews.filter((p) => p.blueprintVersionAfter).length;
  const bpName = (d.previews.find((p) => p.blueprintName) || {}).blueprintName;
  const vText = vCount > 1 ? `blueprint v${vAfter} to v${vAfter + vCount - 1}, one per tenant` : `blueprint ${bpName ? '“' + bpName + '” ' : ''}v${vAfter}`;
  const config = d.previews.map((p) => p.config).filter(Boolean).join('\n\n');
  const masterMeta = D.tenantIds.map((t) => tenant(t).meta).find((m) => m.role === 'Master');
  let title = ACTION_TITLE[d.action] + (d.action === 'RevertBlueprint' ? (d.restoreItem ? ` (restore one item from v${d.groups[0].targetVersion})` : ` to v${d.groups[0].targetVersion}`) : ` (${plural(items.length || d.count || 0, 'item')})`);
  if (d.step === 2) title = 'Confirm: change the master';
  const list = d.loading ? '<div class="muted">Working out what this does…</div>'
    : items.map((i) => `<div class="dit"><span><b>${esc(i.label)}</b>${i.role ? `<div class="muted sub">${esc(i.role)}${i.findingKind ? ' · ' + esc(KIND_LABEL[i.findingKind]) : ''}</div>` : ''}</span><span>${esc(i.effect)}</span></div>`).join('');
  let primaryLabel = { Accept: 'Revert and apply', Promote: 'Promote', Exclude: 'Exclude', ExcludeProperty: 'Add noise rule', ExcludePropertyForTenant: 'Exclude for this tenant', IncludePropertyForTenant: 'Bring back', Unexclude: 'Bring back', RevertBlueprint: d.restoreItem ? 'Restore item' : 'Restore blueprint version', PromoteUp: 'Promote to master blueprint', PullDown: 'Update tenant blueprint', Run: 'Run selection' }[d.action];
  let primaryAct = 'submit';
  if (writesMaster && d.step === 1) { primaryLabel = 'Continue'; primaryAct = 'step2'; }
  else if (writesMaster) primaryLabel = 'Change the master';
  const primaryCls = (writesMaster || destructive) && primaryAct === 'submit' ? 'btn dan' : 'btn pri';
  const needReason = reasonRequired(d);
  const step1 = `<div><span class="lab">What will happen</span>${list}</div>
    ${d.action === 'ExcludeProperty' || d.action === 'ExcludePropertyForTenant' ? `<fieldset style="border:0;padding:0;margin:0"><legend class="lab">Scope</legend>
      <label style="display:flex;gap:8px;align-items:center;min-height:32px"><input type="radio" name="scope" id="scope-type" data-act="scope" data-scope="type"${d.scopeItem ? '' : ' checked'}> All items of this type</label>
      <label style="display:flex;gap:8px;align-items:center;min-height:32px"><input type="radio" name="scope" id="scope-item" data-act="scope" data-scope="item"${d.scopeItem ? ' checked' : ''}> Only this item</label></fieldset>` : ''}
    ${vAfter ? `<div class="banner b-review" style="margin:0">${d.action === 'RevertBlueprint' ? `Creates v${vAfter}${d.restoreItem ? ' with this item as it was in v' + d.groups[0].targetVersion : ' as a copy of v' + d.groups[0].targetVersion}. Nothing is deleted; v1 to v${vAfter - 1} are kept.` : `Creates ${vText}. Earlier versions are kept.`}</div>` : ''}
    ${d.action === 'RevertBlueprint' && items.length ? `<div class="banner b-warn" style="margin:0">On the next snapshot, up to ${plural(items.length, 'item')} in each tenant may show as drift against the restored blueprint. Deal with them through Accept, Promote or Exclude.</div>` : ''}
    ${config ? `<div><span class="lab">Generated config (saved for audit before anything is applied)</span><pre style="max-height:220px">${esc(config)}</pre></div>` : ''}
    ${writesMaster ? '<div class="banner b-danger" style="margin:0"><b>Writes to the master tenant.</b>&nbsp;You will be asked to confirm again on the next step.</div>' : ''}
    <div><label class="lab" for="dlg-reason">Reason ${needReason ? '(required)' : '(optional)'}</label><textarea id="dlg-reason" placeholder="Why? Shown in the audit trail.">${esc(d.reason)}</textarea></div>`;
  const step2 = `<div class="banner b-danger" style="margin:0;flex-direction:column;gap:6px"><b style="font-size:15px">This changes the master tenant ${esc(masterMeta ? masterMeta.displayName : '')}.</b>
      <div>Production will be changed for every item below. The generated config is saved before it is applied, and the same items are read again afterwards.</div></div>
    <div>${items.map((i) => `<div class="dit"><b>${esc(i.label)}</b><span>${esc(i.effect)}</span></div>`).join('')}</div>
    <label style="display:flex;gap:10px;align-items:center;font-weight:600;min-height:44px"><input class="cb" type="checkbox" id="dlg-confirm"${d.confirmed ? ' checked' : ''}> I have checked these items and the generated config, and want to change the master.</label>`;
  return `<div class="overlay"><div class="dialog" role="dialog" aria-modal="true" aria-labelledby="dlgt">
    <div class="dh"><h2 id="dlgt" tabindex="-1" style="font-size:19px;margin:0">${esc(title)}</h2><div class="muted" style="margin-top:4px">${esc(ACTION_SUB[d.action])}</div></div>
    <div class="db">${d.errors.length ? `<div class="banner b-danger" style="margin:0;flex-direction:column">${d.errors.map((e) => `<div>${esc(e)}</div>`).join('')}</div>` : ''}${d.step === 2 ? step2 : step1}</div>
    <div class="df"><button class="btn" data-act="cancel">Cancel</button>${d.step === 2 ? '<button class="btn" data-act="back">Back</button>' : ''}
      <button class="${primaryCls}" id="dlg-primary" data-act="${primaryAct}"${dialogDisabled(d) ? ' disabled' : ''}>${esc(primaryLabel)}</button></div>
  </div></div>`;
}
// "New snapshot": reads the whole tenant again. For a replica the page offers to use the snapshot as the tenant's blueprint, a clean slate:
// what the tenant looks like now becomes the baseline, and later changes show against it on the next snapshot.
function snapshotDialogView() {
  const s = ui.snapshotDlg;
  if (!s) return '';
  const t = s.tenantId;
  const meta = tenant(t).meta;
  const replica = meta.role !== 'Master';
  const ownLayer = (meta.layers || [])[(meta.layers || []).length - 1];
  const box = replica ? `<label class="chk" style="display:flex;gap:8px;align-items:flex-start;margin-top:14px"><input type="checkbox" id="snap-baseline" data-snap="baseline"${s.baseline ? ' checked' : ''}>
      <span><b>Also use this snapshot as ${esc(meta.displayName)}’s blueprint</b>
      <div class="muted sub">A clean slate: the tenant blueprint${ownLayer ? ` “${esc(ownLayer.name)}”` : ''} gets a new version that matches what the tenant looks like now. This snapshot reads everything Microsoft365DSC exports, including types and items that are new in the installed version, so it takes longer (about half an hour). Later changes in the tenant show as drift on the next snapshot, ready to Promote. The master blueprint is not changed. Left out: items excluded for this tenant and items that need a decision (renames, duplicate keys).</div></span></label>`
    : '<div class="muted" style="margin-top:12px">The master blueprint changes only through Promote, so this snapshot is kept for comparison only.</div>';
  return `<div class="overlay"><div class="dialog" role="dialog" aria-modal="true" aria-labelledby="dlgt">
    <div class="dh"><h2 id="dlgt" tabindex="-1" style="font-size:19px;margin:0">New snapshot of ${esc(meta.displayName)}</h2><div class="muted" style="margin-top:4px">Reads every resource type the blueprint holds, which can take a while. Nothing in the tenant is changed.</div></div>
    <div class="db">${box}</div>
    <div class="df"><button class="btn" data-act="snapshot-cancel">Cancel</button><button class="btn pri" id="dlg-primary" data-act="snapshot-go">${s.baseline && replica ? 'Take snapshot and set blueprint' : 'Take snapshot'}</button></div>
  </div></div>`;
}
function setupScript() {
  const c = ui.connect;
  return (D.setup && D.setup.script ? D.setup.script : '(The setup script appears after the next data refresh.)')
    .split('{slug}').join(c.slug || '<short-name>').split('{tenant}').join(c.tenantDomain || '<tenant>.onmicrosoft.com');
}
const GUID_RE = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;
const THUMB_RE = /^[0-9A-Fa-f]{40}$/;
function connectProblem() {
  // Why the Create/Register button is disabled, in words ('' when everything is fine).
  const c = ui.connect;
  if (c.mode === 'upload') return uploadProblem();
  if (!(c.slug || '').trim()) return 'Enter a short name (for example dev).';
  if (!/^[a-z0-9][a-z0-9-]{0,39}$/.test(c.slug)) return 'The short name can only hold lower-case letters, digits and hyphens, and must start with a letter or digit.';
  if (c.slug === 'master') return "'master' is the tenant the blueprint comes from; choose another short name.";
  if (!(c.tenantDomain || '').trim()) return 'Enter the tenant domain, for example contoso-dev.onmicrosoft.com.';
  if (!/^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$/.test(c.tenantDomain)) return 'The tenant domain looks wrong: use only letters, digits, dots and hyphens, for example contoso-dev.onmicrosoft.com.';
  if (c.mode === 'create') return '';
  if (!GUID_RE.test(c.readerApplicationId || '')) return 'The Reader application (client) id must be a GUID, like 11111111-2222-3333-4444-555555555555.';
  if (!THUMB_RE.test(c.readerThumbprint || '')) return 'The Reader certificate thumbprint must be 40 hex characters.';
  if (c.writerApplicationId || c.writerThumbprint) {
    if (!GUID_RE.test(c.writerApplicationId || '')) return 'The Writer application (client) id must be a GUID, or leave both Writer fields empty.';
    if (!THUMB_RE.test(c.writerThumbprint || '')) return 'The Writer certificate thumbprint must be 40 hex characters, or leave both Writer fields empty.';
  }
  return '';
}
function connectReady() { return connectProblem() === ''; }async function connectTenant() {
  try {
    const res = await api('/api/requests', { action: 'ConnectTenant', connect: ui.connect });
    if (res.created) { ui.toast = { text: `Registering ${ui.connect.slug}: request ${res.jobId} queued.`, job: res.jobId }; ui.connect = { mode: 'create', createWriter: true }; }
    else ui.toast = { text: res.errors.join(' '), job: null };
    await refreshActivity();
  } catch (e) { ui.toast = { text: e.message, job: null }; }
  render();
}
function connectJobBanner() {
  // The newest Connect tenant job that is still running: its text carries the sign-in code.
  const job = (D.activity || []).find((j) => j.action === 'ConnectTenant' && (j.status === 'Queued' || j.status === 'Running'));
  if (!job) return '';
  return `<div class="banner b-warn" role="status" style="margin:8px 0"><span class="warn">!</span><div><b>Connecting a tenant (${esc(job.jobId)}).</b> ${esc(job.result || 'Waiting for the worker to start…')}</div></div>`;
}
// ---------- offline tenants: upload DSC export files ----------
const newUpload = () => ({ tenantId: '', files: [], workloads: [], complete: [], saveAsBlueprint: false, busy: false, reading: false, error: '' });
ui.upload = newUpload();
const isOffline = (t) => { const m = D.ready ? D.index.tenants.find((x) => x.tenantId === t) : null; return !!(m && m.offline); };
const VERSION_LINE = /^﻿?#\s*Generated with Microsoft365DSC version\s+([0-9][0-9.]*)\s*$/;
// A resource instance of a DSC export looks like: AADGroup "AADGroup-Sales"
const INSTANCE_LINE = /^[ \t]*([A-Za-z][A-Za-z0-9]+)[ \t]+"[^"\r\n]*"[ \t]*\r?$/gm;
// The workload of a resource type by the engine's rule (index workloadPrefixes: the name starts with the prefix, case-insensitive), else from ResourceTypes.json.
const workloadOfType = (rt) => { const p = ((D.index && D.index.workloadPrefixes) || []).find((x) => rt.toLowerCase().startsWith(String(x.prefix).toLowerCase())); return p ? p.name : (D.types[rt] && D.types[rt].workload) || ''; };
function readUploadFile(file) {
  // The text goes into the request and nowhere else; only the first line (the version) and the resource type names are looked at.
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const text = String(reader.result || '');
      const m = VERSION_LINE.exec(text.slice(0, 400).split('\n')[0]);
      const workloads = new Set();
      for (const hit of text.matchAll(INSTANCE_LINE)) { const w = workloadOfType(hit[1]); if (w) workloads.add(w); }
      resolve({ name: file.name, text, version: m ? m[1] : '', workloads: [...workloads] });
    };
    reader.onerror = () => reject(new Error('The file ' + file.name + ' could not be read.'));
    reader.readAsText(file, 'utf-8');
  });
}
async function readUploadFiles(fileList) {
  const u = ui.upload;
  u.reading = true; u.error = ''; render();
  try {
    u.files = await Promise.all([...fileList].map(readUploadFile));
    u.workloads = [...new Set(u.files.flatMap((f) => f.workloads))].sort();
    u.complete = u.complete.filter((w) => u.workloads.includes(w));
  } catch (e) { u.files = []; u.workloads = []; u.error = e.message; }
  u.reading = false;
  render();
}
const hasOwnBlueprint = (meta) => !!meta && layersOf(meta).length > 1;
// Generate configuration: the files an offline tenant's owner runs to bring it in line with its own blueprint (the worker writes them, Activity links to them).
const genConfigBtn = (meta, cls) => `<button class="${cls}" data-act="generate-config" data-tenant="${esc(meta.tenantId)}"${hasOwnBlueprint(meta) ? '' : ' disabled title="Save an upload as the tenant&#39;s own blueprint first."'}>Generate configuration</button>`;
function uploadProblem() {
  // Why the Upload button is disabled, in words ('' when everything is fine).
  const c = ui.connect;
  const u = ui.upload;
  if (!u.tenantId) {
    if (!(c.slug || '').trim()) return 'Enter a short name (for example acme).';
    if (!/^[a-z0-9][a-z0-9-]{0,39}$/.test(c.slug)) return 'The short name can only hold lower-case letters, digits and hyphens, and must start with a letter or digit.';
    if (c.slug === 'master') return "'master' is the tenant the blueprint comes from; choose another short name.";
    if (D.index.tenants.some((t) => t.tenantId === c.slug)) return 'A tenant with this short name already exists; use its Upload newer snapshot button.';
    if (!(c.tenantDomain || '').trim()) return 'Enter the tenant domain, for example contoso.onmicrosoft.com.';
  }
  if ((c.tenantDomain || '').trim() && !/^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$/.test(c.tenantDomain.trim())) return 'The tenant domain looks wrong: use only letters, digits, dots and hyphens, for example contoso.onmicrosoft.com.';
  if (u.reading) return 'Reading the files…';
  if (!u.files.length) return 'Choose the DSC export files (.ps1) of the tenant.';
  if (u.files.length > 50) return 'At most 50 files can be uploaded at once.';
  const pin = D.index.dsc && D.index.dsc.pin;
  const noVersion = u.files.find((f) => !f.version);
  if (noVersion) return `${noVersion.name} has no “# Generated with Microsoft365DSC version” first line, so it is not a DSC export.`;
  const other = pin && u.files.find((f) => f.version !== pin);
  if (other) return `${other.name} was exported with Microsoft365DSC ${other.version}; this installation needs ${pin}. Export it again with that version.`;
  return '';
}
async function uploadSnapshot() {
  const c = ui.connect;
  const u = ui.upload;
  u.busy = true; render();
  try {
    const slug = u.tenantId || c.slug;
    const own = u.tenantId ? hasOwnBlueprint(D.index.tenants.find((t) => t.tenantId === u.tenantId)) : false;
    const res = await api('/api/requests', {
      action: 'UploadSnapshot', tenantId: slug,
      files: u.files.map((f) => ({ name: f.name, text: f.text })),
      tenantDomain: (c.tenantDomain || '').trim(),
      completeWorkloads: u.complete,
      saveAsBlueprint: u.saveAsBlueprint && !own,
      newTenant: u.tenantId ? null : { slug, displayName: (c.displayName || '').trim() }
    });
    if (res.created) { ui.toast = { text: `Uploading ${plural(u.files.length, 'file')} for ${slug}: request ${res.jobId} queued. This page updates when it finishes.`, job: res.jobId }; ui.upload = newUpload(); ui.connect = { mode: 'upload', createWriter: true }; }
    else { u.error = res.errors.join(' '); ui.toast = { text: u.error, job: null }; }
    await refreshActivity();
  } catch (e) { u.error = e.message; ui.toast = { text: e.message, job: null }; }
  u.busy = false;
  render();
}
function uploadForm() {
  const c = ui.connect;
  const u = ui.upload;
  const meta = D.index.tenants.find((t) => t.tenantId === u.tenantId);
  const pin = D.index.dsc && D.index.dsc.pin;
  const field = (key, label, hint) => `<label class="cxf"><span>${label}</span><input data-cx="${key}" value="${esc(c[key] || '')}" autocomplete="off" spellcheck="false"><span class="muted sub">${hint}</span></label>`;
  const who = u.tenantId
    ? `<div class="muted" style="margin-bottom:8px">Uploading a newer snapshot for <b>${esc(meta ? meta.displayName : u.tenantId)}</b>. The workloads in the files replace that tenant's records of them; the other workloads keep their last snapshot.</div><div class="cxrow">${field('tenantDomain', 'Tenant domain', 'optional: only to change it')}</div>`
    : `<div class="cxrow">${field('slug', 'Short name', 'for example acme; lower-case letters, digits, hyphens')}${field('tenantDomain', 'Tenant domain', 'for example contoso.onmicrosoft.com')}${field('displayName', 'Display name', 'optional')}</div>`;
  const fileRows = u.files.map((f) => `<div class="gr" style="grid-template-columns:1fr auto"><span class="wrap">${esc(f.name)}</span><span class="${pin && f.version !== pin ? 'err' : 'muted'}">${f.version ? 'Microsoft365DSC ' + esc(f.version) : 'no version line'}</span></div>`).join('');
  const wlRows = u.workloads.map((w) => `<label class="cxchk"><input type="checkbox" data-upwl="${esc(w)}"${u.complete.includes(w) ? ' checked' : ''}> The ${esc(w)} files are complete: a resource type of ${esc(w)} that has no records in them is empty in the tenant, not unknown</label>`).join('');
  const own = u.tenantId ? hasOwnBlueprint(meta) : false;
  return `<div class="muted" style="font-size:13px;margin-bottom:8px">For a tenant the engine cannot sign in to. Export it yourself with Microsoft365DSC${pin ? ' ' + esc(pin) : ''} and choose the resulting .ps1 files here. The files are read in this browser and sent to the engine; nothing connects to the tenant.</div>
    ${who}
    <label class="cxf wide"><span>DSC export files</span><input type="file" id="up-files" multiple accept=".ps1,text/plain"><span class="muted sub">Choosing files again replaces the list.</span></label>
    ${fileRows}
    ${wlRows ? `<h3 style="margin:12px 0 4px;font-size:14px">Does each workload hold everything?</h3>${wlRows}` : ''}
    ${own ? '' : `<label class="cxchk"><input type="checkbox" data-up="saveAsBlueprint"${u.saveAsBlueprint ? ' checked' : ''}> Use this snapshot as the tenant's own blueprint (it has none yet)</label>`}
    <button class="btn pri" id="cx-submit" data-act="upload-snapshot"${connectReady() && !u.busy ? '' : ' disabled'}>${u.busy ? 'Sending…' : 'Upload snapshot'}</button>
    <div class="cxproblem" id="cx-problem" role="status">${esc(connectProblem() || u.error)}</div>`;
}
// What the snapshot of a tenant or workload is: read live from the tenant, or uploaded from export files, and when.
function snapshotLabel(source, at) { return source && at ? (source === 'Uploaded' ? 'Uploaded ' : 'Exported live ') + shortDate(at) : ''; }
function oldestWorkload(snapshot) {
  const ws = ((snapshot && snapshot.workloads) || []).filter((w) => w.at);
  return ws.length ? ws.reduce((a, b) => (Date.parse(b.at) < Date.parse(a.at) ? b : a)) : null;
}
// One line about how fresh a tenant's snapshot is: when it was read, how long ago, and whether every workload was read in the same run.
function snapshotSummary(meta) {
  const s = meta.snapshot;
  const at = (s && s.at) || meta.lastFullCheck;
  if (!at) return meta.offline ? 'Nothing uploaded yet.' : 'No snapshot yet. Press “New snapshot”.';
  const old = oldestWorkload(s);
  const stale = old && Date.parse(at) - Date.parse(old.at) > 10 * 60000;
  const late = overdue(meta.lastFullCheck) ? ' <span class="overdue">(overdue)</span>' : '';
  return `Snapshot: ${esc(s && s.source === 'Uploaded' ? 'uploaded' : 'read live')} ${esc(shortDate(at))}, ${esc(ago(at))}${late} · ${stale ? `${esc(old.workload)} is older, read ${esc(ago(old.at))}` : 'every workload read in the same run'}`;
}
// How much the master blueprint and the tenant's own blueprint disagree, as this tenant shows it: the items that drift against one and not
// the other, or that the two blueprints hold differently. Close totals can hide this: the two counts may match while the items do not.
function blueprintGap(t) {
  const ls = layersOf(tenant(t).meta);
  if (ls.length < 2 || !ls[0].checked || !ls[ls.length - 1].checked) return '';
  const rows = D.layerRows[t + '|' + ls[0].name];
  if (!rows) { loadLayer(t, ls[0].name); return ''; }
  if (rows.failed) return '';
  const sig = (f) => f.kind + '|' + JSON.stringify((f.differences || []).map((d) => [d.property, d.blueprint]));
  const own = new Map(findingsOf(t).filter(isOpenDrift).map((f) => [f.itemId, f]));
  const master = new Map(rows.filter(isOpenDrift).map((f) => [f.itemId, f]));
  const diff = [...new Set([...own.keys(), ...master.keys()])].filter((id) => !own.has(id) || !master.has(id) || sig(own.get(id)) !== sig(master.get(id)));
  const names = `“${esc(ls[ls.length - 1].name)}” v${esc(ls[ls.length - 1].version)} and “${esc(ls[0].name)}” v${esc(ls[0].version)}`;
  if (!diff.length) return `<div class="muted gap">${names} treat every item of this tenant the same.</div>`;
  const some = diff.slice(0, 3).map((id) => { const f = own.get(id) || master.get(id); return `${esc(typeName(f.resourceType))} · ${esc(f.key)}`; }).join(', ');
  return `<div class="muted gap">${names} treat ${plural(diff.length, 'item')} of this tenant differently: ${some}${diff.length > 3 ? ', …' : ''}.</div>`;
}
function tenantsPage() {
  const nameCell = (t) => ui.rename && ui.rename.tenantId === t.tenantId
    ? `<span class="rnform"><input type="text" id="rn-input" data-rn="1" maxlength="80" value="${esc(ui.rename.text)}" aria-label="Friendly name of ${esc(t.tenantId)}"><button class="btn sm pri" data-act="rename-save"${ui.rename.busy ? ' disabled' : ''}>Save</button><button class="btn sm" data-act="rename-cancel">Cancel</button><span class="err" role="status">${esc(ui.rename.error || '')}</span></span>`
    : `<b class="wrap">${esc(t.displayName)}</b>`;
  const driftText = (t) => { const ls = layersOf(t); return ls.map((l) => (l.checked ? `${l.drifted} drifted vs ${ls.length > 1 ? (l === ls[0] ? 'master' : 'own') : 'its'} blueprint` : 'not checked')).join(' · '); };
  const rows = D.index.tenants.map((t) => `<div class="gr tenrow"><span>${nameCell(t)}<div class="muted mono sub">${tt('slug: ' + t.tenantId + (t.tenantDomain && t.tenantDomain !== t.displayName ? ' · ' + t.tenantDomain : ''))}</div></span>
    <span>${esc(t.role)}</span><span class="wrap">${esc(driftText(t))}</span><span class="muted">${t.snapshot && t.snapshot.source ? esc(snapshotLabel(t.snapshot.source, t.snapshot.at)) : t.lastFullCheck ? 'snapshot ' + esc(ago(t.lastFullCheck)) : 'no snapshot yet'}</span>
    <span class="rowacts">${link('/?tenant=' + enc(t.tenantId), 'Open', 'btn sm')}${t.offline ? `<button class="btn sm" data-act="open-upload" data-tenant="${esc(t.tenantId)}">Upload newer snapshot</button>${genConfigBtn(t, 'btn sm')}` :`<button class="btn sm" data-act="recheck-tenant" data-tenant="${esc(t.tenantId)}"${rechecking() ? ' disabled' : ''}>New snapshot</button>`}<button class="btn sm" data-act="rename-start" data-tenant="${esc(t.tenantId)}" aria-label="Rename ${esc(t.displayName)}">Rename</button></span></div>`).join('');
  const c = ui.connect;
  const field = (key, label, hint, wide) => `<label class="cxf${wide ? ' wide' : ''}"><span>${label}</span><input data-cx="${key}" value="${esc(c[key] || '')}" autocomplete="off" spellcheck="false"><span class="muted sub">${hint}</span></label>`;
  return `<div class="phead"><div><h1>Tenants</h1><div class="muted">The master is where the blueprint comes from. Every other tenant is a replica: it is compared with the same blueprint and can be brought into line with it.</div></div></div>
    <section class="card"><h2>Connected tenants</h2>${rows}</section>
    <section class="card"><h2>Connect a tenant</h2>
      <div class="pills" role="group" aria-label="How to connect"><button class="tab${c.mode === 'create' ? ' on' : ''}" data-act="connect-mode" data-mode="create" aria-pressed="${c.mode === 'create'}">Create the apps for me</button><button class="tab${c.mode === 'register' ? ' on' : ''}" data-act="connect-mode" data-mode="register" aria-pressed="${c.mode === 'register'}">I already created them</button><button class="tab${c.mode === 'upload' ? ' on' : ''}" data-act="connect-mode" data-mode="upload" aria-pressed="${c.mode === 'upload'}">Offline tenant (upload files)</button></div>
      ${connectJobBanner()}
      ${c.mode === 'upload' ? uploadForm() : `<div class="cxrow">${field('slug', 'Short name', 'for example dev; lower-case letters, digits, hyphens')}${field('tenantDomain', 'Tenant domain', 'for example contoso-dev.onmicrosoft.com')}${field('displayName', 'Display name', 'optional')}</div>
      ${c.mode === 'create' ? `
      <div class="muted" style="font-size:13px;margin-bottom:8px">You will be given a code to sign in with as an administrator of that tenant (MFA works). The permission lists come from Microsoft365DSC; with your sign-in the worker creates the Reader and Writer apps and their certificates, gives consent and registers the tenant. Nothing is kept except the application ids and certificate thumbprints.</div>
      <label class="cxchk"><input type="checkbox" data-cx="createWriter"${c.createWriter ? ' checked' : ''}> Also create a Writer app (needed to bring the tenant into line with the blueprint)</label>
      <label class="cxchk"><input type="checkbox" data-cx="writerRoles"${c.writerRoles ? ' checked' : ''}${c.createWriter ? '' : ' disabled'}> Give the Writer app the Exchange Administrator and Teams Administrator roles (needed to change Exchange and Teams)</label>
      <button class="btn pri" id="cx-submit" data-act="connect-submit"${connectReady() ? '' : ' disabled'}>Create the apps and connect</button>
      <div class="cxproblem" id="cx-problem" role="status">${esc(connectProblem())}</div>
      <span class="muted" class="sub ml2">The sign-in code appears here and in Activity once the worker starts.</span>` : `
      <h3 style="margin:12px 0 4px;font-size:14px">1. Run this in the new tenant</h3>
      <div class="muted" style="font-size:13px;margin-bottom:6px">As an administrator of the tenant, on a machine with Microsoft365DSC installed. It creates the Reader and Writer apps with DSC's own command; the steps it cannot do (admin consent, directory roles) are listed at the end of the script.</div>
      <pre class="raw" id="cx-script" style="max-height:260px;overflow:auto">${esc(setupScript())}</pre>
      <button class="btn sm" data-act="copy-setup">Copy script</button>
      <h3 style="margin:16px 0 4px;font-size:14px">2. Register the apps</h3>
      <div class="cxrow">${field('readerApplicationId', 'Reader application (client) id', 'from the app in the Entra admin center')}${field('readerThumbprint', 'Reader certificate thumbprint', '40 characters; the certificate must be on this machine')}</div>
      <div class="cxrow">${field('writerApplicationId', 'Writer application (client) id', 'optional: without it the tenant can be checked but not brought into line')}${field('writerThumbprint', 'Writer certificate thumbprint', 'optional')}</div>
      <button class="btn pri" id="cx-submit" data-act="connect-submit"${connectReady() ? '' : ' disabled'}>Register tenant</button>
      <div class="cxproblem" id="cx-problem" role="status">${esc(connectProblem())}</div>
      <span class="muted" class="sub ml2">The Reader signs in once to prove it works.</span>`}`}    </section>`;
}
function dscBanner(onDriftPage) {
  // The blueprint was built with another Microsoft365DSC version than the one installed: a refresh runs with this warning; reverts wait until reviewed.
  const d = D.ready ? D.index.dsc : null;
  if (!d || d.match !== false) return '';
  const added = D.tenantIds.reduce((n, t) => n + findingsOf(t).filter((f) => isOpenDrift(f) && newInModule(f).length).length, 0);
  const changelog = 'https://github.com/Microsoft365DSC/Microsoft365DSC/blob/Dev/CHANGELOG.md';
  return `<div class="banner b-warn" role="alert"><span class="warn">!</span><div><b>Microsoft365DSC was updated from ${esc(d.blueprint)} to ${esc(d.pin)}.</b> A newer module can export settings the blueprint does not have yet, and they show up as drift.
    <ol style="margin:6px 0 6px 18px;padding:0">
      <li>${onDriftPage ? 'Review the items below' : 'Open ' + link('/drift', 'Drift review')}${added ? `: ${plural(added, 'item')} ${added === 1 ? 'has' : 'have'} a setting the blueprint lacks (probably new in the module). Promote what you want to keep; items already promoted stay listed until the next snapshot.` : '. Nothing is left to promote: no item has a setting the blueprint lacks.'}</li>
      <li>Then mark the blueprint reviewed. Reverts are paused until you do.</li>
    </ol>
    <a href="${changelog}" target="_blank" rel="noopener" class="lnk">What changed in Microsoft365DSC (changelog)</a>
    <div class="btns" style="margin-top:8px">${ui.reviewConfirm
    ? `<button class="btn pri sm" data-act="review-module">Yes, mark reviewed for ${esc(d.pin)}</button> <button class="btn sm" data-act="review-module-cancel">Cancel</button> <span class="muted">No tenant is changed; Reverts are allowed again.</span>`
    : `<button class="btn sm" data-act="review-module-ask">Mark reviewed for ${esc(d.pin)}…</button>`}</div></div></div>`;
}
async function reviewModule() {
  // Records the installed Microsoft365DSC version for the blueprints built with another one; the worker does it, the page reloads when it ends.
  ui.reviewConfirm = false;
  try {
    const res = await api('/api/requests', { action: 'ReviewModule' });
    if (res.created) ui.toast = { text: `Review ${res.jobId} queued. This page updates when it finishes.`, job: res.jobId };
    else ui.toast = { text: res.errors.join(' '), job: null };
    await refreshActivity();
  } catch (e) { ui.toast = { text: e.message, job: null }; }
  render();
}
function scopeActions(s) {
  // Choose an action for everything that has drifted in a scope or resource type: the same as ticking those rows on the Drift page.
  const ids = s.driftItems || [];
  if (!ids.length) return '';
  const t = curTenant();
  // An offline tenant cannot be reverted from here (the server offers no Accept for it).
  return PICKS.filter(([name]) => name !== 'Revert' || !curTenantMeta().offline).map(([name]) => ` <button class="btn sm" data-act="pick" data-pick="${name}" data-tenant="${esc(t)}" data-ids="${esc(ids.join(' '))}" title="${esc(ACTION_TIP[name] + ' Adds all ' + ids.length + ' to the selection list.')}">${name} ${ids.length}</button>`).join('');
}
function scopesCard() {
  // Named sets of types (and optionally keys) that are checked on their own, often, without re-reading the whole tenant.
  const scopes = D.ready && curTenantMeta() ? (curTenantMeta().scopes || []) : [];
  if (!scopes.length) return '';
  const rows = scopes.map((s) => `<div class="gr scoperow"><span><b>${esc(s.name)}</b><div class="muted sub">${esc(s.description || (s.types || []).join(', '))}${(s.keys || []).length ? ' · keys ' + esc(s.keys.join(', ')) : ''}</div></span>
    <span class="muted">${s.items} item${s.items === 1 ? '' : 's'}</span>
    <span>${s.drifted ? `<span class="chip c-drift">▲ ${s.drifted} drifted</span>` : '<span class="chip c-ok">✓ aligned</span>'}</span>
    <span class="muted">${s.lastChecked ? 'refreshed ' + esc(ago(s.lastChecked)) : 'not refreshed on its own yet'}</span>
    <span class="rowacts">${!curTenantMeta().offline ? `<button class="btn sm" data-act="recheck-scope" data-scope="${esc(s.name)}"${rechecking() ? ' disabled' : ''}>Refresh</button>` : ''}${scopeActions(s)}</span></div>`).join('');
  return `<section class="card"><h2>Scopes</h2><div class="muted note">Each scope re-reads only its own resource types, so it is quick enough to run often. Everything else keeps the latest snapshot.</div>${rows}</section>`;
}
function prettyType(type) {
  // Friendly name from ResourceTypes.json, else the DSC resource name split into words (AADAccessReviewDefinition -> Access review definition).
  if (D.types && D.types[type]) return D.types[type].name;
  const rest = type.replace(/^(AAD|EXO|Intune|Teams|SPO|O365|OD|Planner|SC|PP|Defender|Azure|Fabric|Commerce|M365)/, '').replace(/([a-z0-9])([A-Z])/g, '$1 $2').trim();
  return rest ? rest.charAt(0).toUpperCase() + rest.slice(1).toLowerCase() : type;
}
function typeScopesCard() {
  // Every DSC resource type in the blueprint is a scope of its own: check just that type, in seconds.
  const types = D.ready && curTenantMeta() ? (curTenantMeta().typeScopes || []) : [];
  if (!types.length) return '';
  const byWorkload = new Map();
  types.forEach((t) => { const w = t.workload || 'Other'; if (!byWorkload.has(w)) byWorkload.set(w, []); byWorkload.get(w).push(t); });
  const order = (D.index.workloads || []).filter((w) => byWorkload.has(w)).concat([...byWorkload.keys()].filter((w) => !(D.index.workloads || []).includes(w)));
  const groups = order.map((w) => {
    const list = byWorkload.get(w).slice().sort((a, b) => b.drifted - a.drifted || a.type.localeCompare(b.type));
    const drifted = list.reduce((n, t) => n + t.drifted, 0);
    const rows = list.map((t) => `<div class="gr scoperow"><span>${link(path.type(curTenant(), t.workload || 'Other', t.type), prettyType(t.type), 'lnk strong')}<div class="muted mono sub">${tt(t.type)}</div></span>
      <span class="muted">${t.items} item${t.items === 1 ? '' : 's'}</span>
      <span>${t.drifted ? `<a class="chip c-drift" href="${esc(path.type(curTenant(), t.workload || 'Other', t.type, 'drifted'))}" data-link>▲ ${t.drifted} drifted</a>` : '<span class="chip c-ok">✓ aligned</span>'}</span>
      <span class="muted">${t.lastChecked ? 'refreshed ' + esc(ago(t.lastChecked)) : 'not refreshed on its own yet'}</span>
      <span class="rowacts">${!curTenantMeta().offline ? `<button class="btn sm" data-act="recheck-scope" data-scope="${esc(t.type)}"${rechecking() ? ' disabled' : ''}>Refresh</button>` : ''}${scopeActions(t)}</span></div>`).join('');
    return `<details class="tgroup"${drifted ? ' open' : ''}><summary><b>${esc(w)}</b> <span class="muted">· ${plural(list.length, 'resource type')}${drifted ? ' · ' + drifted + ' drifted' : ''}</span></summary>${rows}</details>`;
  }).join('');
  return `<section class="card"><h2>Refresh by resource type</h2><div class="muted note">Every DSC resource type in the blueprint can be checked on its own.</div>${groups}</section>`;
}
function rechecking() { return D.ready && D.activity.some((j) => j.action === 'Recheck' && (j.status === 'Queued' || j.status === 'Running')); }
async function cancelJob(jobId) {
  // Asks the server to cancel a job: a queued one is cancelled at once, a running Recheck is stopped by its worker within seconds.
  try {
    const res = await api('/api/jobs/' + enc(jobId) + '/cancel', {});
    ui.toast = { text: jobId + ': ' + res.message, job: jobId };
  } catch (e) { ui.toast = { text: e.message, job: null }; }
  await refreshActivity();
  render();
}
// A snapshot of a replica asks first, because it can also become the tenant's blueprint; the master has nothing to choose.
function askSnapshot(tenantId) {
  if (role(tenantId) === 'Master') { recheck(undefined, tenantId); return; }
  ui.snapshotDlg = { tenantId, baseline: false };
  render();
}
async function recheck(scope, tenantId, baseline) {
  // Reads the tenant again (all of it, or just one scope) and compares it with the blueprint; the worker does the work, the page reloads when it ends.
  try {
    const res = await api('/api/requests', Object.assign({ action: 'Recheck', tenantId: tenantId || curTenant() }, scope ? { scope } : {}, baseline ? { baseline: true } : {}));
    if (res.created) ui.toast = { text: `${scope ? 'Refresh' : 'Snapshot'} ${res.jobId} queued. This page updates when it finishes.`, job: res.jobId };
    else ui.toast = { text: res.errors.join(' '), job: null };
    await refreshActivity();
  } catch (e) { ui.toast = { text: e.message, job: null }; }
  render();
}
async function generateConfig(tenantId) {
  // Queues the configuration for an offline tenant; the worker writes the files and the job in Activity links to them.
  try {
    const res = await api('/api/requests', { action: 'GenerateConfig', tenantId });
    if (res.created) ui.toast = { text: `Configuration ${res.jobId} queued. Its files are linked in Activity when it finishes.`, job: res.jobId };
    else ui.toast = { text: res.errors.join(' '), job: null };
    await refreshActivity();
  } catch (e) { ui.toast = { text: e.message, job: null }; }
  render();
}
async function renameTenant() {
  const r = ui.rename;
  const name = (r.text || '').trim();
  if (!name) { r.error = 'A name is required.'; render(); return; }
  r.busy = true; r.error = ''; render();
  try {
    const res = await api('/api/requests', { action: 'RenameTenant', tenantId: r.tenantId, displayName: name });
    if (!res.created) { r.busy = false; r.error = res.errors.join(' '); render(); return; }
    ui.toast = { text: `Request ${res.jobId} queued: renaming ${r.tenantId}.`, job: res.jobId };
    ui.rename = null;
  } catch (e) { r.busy = false; r.error = e.message; }
  await refreshActivity();
  render();
}
async function submitDialog() {
  const d = ui.dialog;
  d.loading = true;
  render();
  const jobs = [];
  const errors = [];
  const left = [];
  for (let i = 0; i < d.groups.length; i++) {
    const g = d.groups[i];
    let created = false;
    const items = d.action === 'ExcludeProperty' || d.action === 'ExcludePropertyForTenant' ? g.items.map((it) => Object.assign({}, it, { scopeItem: d.scopeItem })) : g.items;
    const body = Object.assign(groupBody(g), { items, action: g.action || d.action, reason: d.reason, confirmedMasterWrite: !!(d.previews[i] && d.previews[i].writesMaster && d.confirmed), expectedVersion: d.previews[i] && d.previews[i].targetVersion != null ? d.previews[i].targetVersion : undefined, expectedSourceVersion: d.previews[i] && d.previews[i].sourceVersion != null ? d.previews[i].sourceVersion : undefined });
    try {
      const res = await api('/api/requests', body);
      if (res.created) { jobs.push(res.jobId); created = true; } else errors.push(...res.errors);
    } catch (e) { errors.push(e.message); }
    if (!created) left.push(i);
  }
  if (jobs.length) ui.toast = { text: `Request ${jobs.join(', ')} queued.`, job: jobs[0] };
  if (errors.length) {
    // Keep only the groups that failed, so trying again never sends a request that was already queued.
    if (d.queueRun) d.groups.forEach((g, i) => { if (!left.includes(i)) queueRemoveGroup(g); });
    d.groups = left.map((i) => d.groups[i]);
    d.previews = left.map((i) => d.previews[i]);
    d.loading = false;
    d.errors = (jobs.length ? [`Queued ${jobs.join(', ')}; the rest failed:`] : []).concat(errors);
    await refreshActivity();
    render();
    return;
  }
  if (d.queueRun) d.groups.forEach((g) => queueRemoveGroup(g));
  ui.dialog = null;
  ui.sel.clear();
  await refreshActivity();
  render();
}

// ---------- events ----------
function pickItems(t, ids, action) {
  const skipped = queuePick(t, ids, action);
  const n = ids.length - skipped;
  ui.toast = { text: n > 0 ? `${plural(n, 'item')} added to the selection list as ${action}${skipped ? `; ${skipped} skipped` : ''}.` : skipped ? `${action} is not available for ${ids.length === 1 ? 'this item' : 'these items'}.` : 'Removed from the selection list.', job: null };
  render();
}
function itemsFromIds(ids) { return ids.split(' ').filter(Boolean).map((itemId) => ({ itemId })); }
function onClick(e) {
  const a = e.target.closest('a[data-link]');
  if (a && !e.ctrlKey && !e.metaKey && !e.shiftKey && e.button === 0) {
    e.preventDefault();
    if (a.classList.contains('pendchip') || a.closest('.toast')) ui.toast = null;
    go(a.getAttribute('href'), a.hasAttribute('data-replace'));
    return;
  }
  const el = e.target.closest('[data-act]');
  if (!el || el.disabled) return;
  const act = el.dataset.act;
  if (act.startsWith('std-')) { standardsClick(el); return; }
  if (act === 'action') openDialog(el.dataset.action, [{ tenantId: el.dataset.tenant, items: itemsFromIds(el.dataset.ids) }]);
  else if (act === 'bulk') {
    const byTenant = {};
    ui.sel.forEach((k) => { const [t, id] = k.split('|'); (byTenant[t] = byTenant[t] || []).push({ itemId: id }); });
    openDialog(el.dataset.action, Object.entries(byTenant).map(([t, items]) => ({ tenantId: t, items })), { count: ui.sel.size });
  } else if (act === 'noise') openDialog('ExcludeProperty', [{ tenantId: el.dataset.tenant, items: [{ itemId: el.dataset.item, property: el.dataset.prop }] }]);
  else if (act === 'tenant-prop') openDialog('ExcludePropertyForTenant', [{ tenantId: el.dataset.tenant, items: [{ itemId: el.dataset.item, property: el.dataset.prop }] }]);
  else if (act === 'include-prop') openDialog('IncludePropertyForTenant', [{ tenantId: el.dataset.tenant, items: [{ resourceType: el.dataset.type, property: el.dataset.prop, itemId: el.dataset.item || null }] }]);
  else if (act === 'unnoise') {
    const n = D.exclusions.noise[Number(el.dataset.index)];
    openDialog('Unexclude', [{ items: [{ resourceType: n.resourceType, property: n.property, value: n.value }] }]);
  } else if (act === 'revert') openDialog('RevertBlueprint', [{ targetVersion: Number(el.dataset.version), items: [] }]);
  else if (act === 'restore') openDialog('RevertBlueprint', [{ targetVersion: Number(el.dataset.version), items: [{ itemId: el.dataset.item }] }], { restoreItem: true });
  else if (act === 'pick') pickItems(el.dataset.tenant, el.dataset.ids.split(' ').filter(Boolean), el.dataset.pick);
  else if (act === 'pick-sel') {
    const by = new Map();
    ui.sel.forEach((k) => { const [t, id] = k.split('|'); if (!by.has(t)) by.set(t, []); by.get(t).push(id); });
    let skipped = 0; let n = 0;
    by.forEach((ids, t) => { skipped += queuePick(t, ids, el.dataset.pick); n += ids.length; });
    ui.sel.clear();
    ui.toast = { text: `${plural(n - skipped, 'item')} added to the selection list as ${el.dataset.pick}${skipped ? `; ${skipped} skipped, ${el.dataset.pick} is not available for them` : ''}.`, job: null };
    render();
  }
  else if (act === 'queue-remove') { queueRemove(el.dataset.tenant, el.dataset.ids.split(' ').filter(Boolean)); render(); }
  else if (act === 'queue-clear') { ui.queue = []; ui.selPreview = null; saveQueue(); render(); }
  else if (act === 'queue-export') queueExport();
  else if (act === 'queue-run') { const groups = queueGroups(); if (groups.length) openDialog('Run', groups, { queueRun: true, reason: ui.selReason || '', count: groups.reduce((n, g) => n + g.items.length, 0) }); }
  else if (act === 'queue-preview') queuePreview();
  else if (act === 'toggle-sel') { const k = el.dataset.key; if (ui.sel.has(k)) ui.sel.delete(k); else ui.sel.add(k); render(); }
  else if (act === 'clear-sel') { ui.sel.clear(); render(); }
  else if (act === 'expand') { const k = el.dataset.key; if (ui.expanded.has(k)) ui.expanded.delete(k); else ui.expanded.add(k); render(); }
  else if (act === 'overview-view') { ui.view = el.dataset.view === 'compare' ? 'compare' : 'cards'; storeView(ui.view); render(); }
  else if (act === 'item-show') { ui.itemShow = ['all', 'drifted', 'matching'].includes(el.dataset.show) ? el.dataset.show : ''; render(); }
  else if (act === 'job') { const r = route(); const cur = ui.openJob || r.job; ui.openJob = cur === el.dataset.job ? '' : el.dataset.job; render(); }
  else if (act === 'scope') { ui.dialog.scopeItem = el.dataset.scope === 'item'; }
  else if (act === 'cancel') { ui.dialog = null; render(); }
  else if (act === 'back') { ui.dialog.step = 1; ui.dialog.confirmed = false; render(); }
  else if (act === 'step2') { ui.dialog.step = 2; render(); }
  else if (act === 'submit') submitDialog();
  else if (act === 'toast-close') { ui.toast = null; render(); }
  else if (act === 'recheck') askSnapshot(curTenant());
  else if (act === 'tile-layer') { ui.tileLayer = el.dataset.layer; render(); }
  else if (act === 'review-module-ask') { ui.reviewConfirm = true; render(); }
  else if (act === 'review-module-cancel') { ui.reviewConfirm = false; render(); }
  else if (act === 'review-module') reviewModule();
  else if (act === 'move') openDialog(el.dataset.action, [{ tenantId: el.dataset.tenant, items: itemsFromIds(el.dataset.ids || '') }]);
  else if (act === 'copy-setup') { try { navigator.clipboard.writeText(setupScript()); ui.toast = { text: 'Setup script copied.', job: null }; } catch (err) { ui.toast = { text: 'Copy failed; select the text instead.', job: null }; } render(); }
  else if (act === 'connect-submit') connectTenant();
  else if (act === 'connect-mode') { if (el.dataset.mode !== 'upload') ui.upload.tenantId = ''; ui.connect.mode = el.dataset.mode; render(); }
  else if (act === 'upload-snapshot') uploadSnapshot();
  else if (act === 'open-upload') { const m = D.index.tenants.find((x) => x.tenantId === el.dataset.tenant); ui.upload = newUpload(); ui.upload.tenantId = m.tenantId; ui.connect = { mode: 'upload', createWriter: true, tenantDomain: m.tenantDomain && m.tenantDomain !== m.tenantId ? m.tenantDomain : '' }; go('/tenants?tenant=' + enc(m.tenantId)); }
  else if (act === 'generate-config') generateConfig(el.dataset.tenant);
  else if (act === 'recheck-scope') recheck(el.dataset.scope, el.dataset.tenant);
  else if (act === 'cancel-job') cancelJob(el.dataset.job);
  else if (act === 'recheck-tenant') askSnapshot(el.dataset.tenant);
  else if (act === 'snapshot-cancel') { ui.snapshotDlg = null; render(); }
  else if (act === 'snapshot-go') { const s = ui.snapshotDlg; ui.snapshotDlg = null; recheck(undefined, s.tenantId, s.baseline); }
  else if (act === 'rename-start') { const t = D.index.tenants.find((x) => x.tenantId === el.dataset.tenant); ui.rename = { tenantId: t.tenantId, text: t.displayName, error: '', busy: false }; render(); const i = document.getElementById('rn-input'); if (i) { i.focus(); i.select(); } }
  else if (act === 'rename-cancel') { ui.rename = null; render(); }
  else if (act === 'rename-save') renameTenant();
}
function onInput(e) {
  if (standardsInput(e)) return;
  if (e.target.dataset && e.target.dataset.rn && ui.rename) { ui.rename.text = e.target.value; return; }
  if (e.target.dataset && (e.target.dataset.up || e.target.dataset.upwl)) {
    if (e.target.dataset.up) ui.upload[e.target.dataset.up] = e.target.checked;
    else ui.upload.complete = e.target.checked ? [...new Set([...ui.upload.complete, e.target.dataset.upwl])] : ui.upload.complete.filter((w) => w !== e.target.dataset.upwl);
    return;
  }
  if (e.target.dataset && e.target.dataset.cx) {
    // The Tenants page form: keep the values, and keep the setup script text in step without redrawing (which would lose focus).
    if (e.target.dataset.cx === 'slug') {
      // Short names are lower-case with hyphens; fix capitals and spaces as they are typed.
      const fixed = e.target.value.toLowerCase().replace(/\s+/g, '-');
      if (fixed !== e.target.value) e.target.value = fixed;
    }
    ui.connect[e.target.dataset.cx] = e.target.type === 'checkbox' ? e.target.checked : e.target.value;
    const problem = document.getElementById('cx-problem');
    if (problem) problem.textContent = connectProblem();
    const pre = document.getElementById('cx-script');
    if (pre) pre.textContent = setupScript();
    const b = document.getElementById('cx-submit');
    if (b) b.disabled = !connectReady();
    return;
  }
  if (e.target.id === 'sel-reason') { ui.selReason = e.target.value; return; }
  if (!ui.dialog) return;
  if (e.target.id === 'dlg-reason') ui.dialog.reason = e.target.value;
  if (e.target.id === 'dlg-confirm') ui.dialog.confirmed = e.target.checked;
  const b = document.getElementById('dlg-primary');
  if (b) b.disabled = dialogDisabled(ui.dialog);
}
function onChange(e) {
  const t = e.target;
  if (t.id === 'tenant-pick') { setTenant(t.value); return; }
  if (t.id === 'up-files') { readUploadFiles(t.files); return; }
  if (t.dataset.filter) {
    const r = route();
    const p = { tenant: r.tenant, workload: r.workload, kind: r.kind, q: r.q, layer: r.layer };
    p[t.dataset.filter] = t.value;
    if (t.dataset.filter === 'tenant') p.layer = '';
    go(path.drift(p), true);
  } else if (t.dataset.snap === 'baseline') {
    ui.snapshotDlg.baseline = t.checked;
    render();
  } else if (t.dataset.compare) {
    const r = route();
    const p = { from: r.from, to: r.to };
    p[t.dataset.compare] = Number(t.value);
    go(path.compare(p.from, p.to, r.name), true);
  } else if (t.id === 'dlg-confirm') onInput(e);
}

// ---------- render loop ----------
function render() {
  if (!D.ready) { app.innerHTML = `<div class="loading">${D.error ? `<span class="err">${esc(D.error)}</span>` : 'Loading…'}</div>`; return; }
  const r = route();
  const urlSel = ['overview', 'blueprint', 'exclusions', 'tenants', 'activity'].includes(r.screen) ? new URLSearchParams(location.search).get('tenant') : null;
  const selected = ['workload', 'type', 'item'].includes(r.screen) ? r.t : r.screen === 'drift' ? r.tenant : urlSel;
  if (selected && D.tenantIds.includes(selected) && selected !== ui.tenant) { ui.tenant = selected; storeTenant(selected); }
  syncTenantUrl(r);
  const focusId = document.activeElement && document.activeElement.id;
  const hadDialog = !!document.querySelector('.dialog');
  const screens = { overview, workload, type: typePage, item: itemPage, drift, blueprint, compare, version: versionPage, exclusions, tenants: tenantsPage, queue: queuePage, standards: standardsPage, standard: standardCheckPage, notcovered: notCoveredPage, activity, notfound: notFound };
  const valid = !['workload', 'type', 'item'].includes(r.screen) || tenant(r.t);
  const body = valid ? screens[r.screen](r) : notFound();
  const toast = ui.toast ? `<div class="toast" role="status"><span>${esc(ui.toast.text)}</span>${ui.toast.job ? link(path.activity(ui.toast.job), 'View in Activity') : ''}<button class="lnk" data-act="toast-close" aria-label="Dismiss">✕</button></div>` : '';
  app.innerHTML = topbar(r) + `<main id="main" class="main">${['workload', 'type', 'item', 'drift'].includes(r.screen) ? contextStrip(curTenant()) : ''}${crumbs(r)}${body}</main>` + dialogView() + riskDialogView() + snapshotDialogView() + toast;
  document.title = (document.querySelector('h1') ? document.querySelector('h1').textContent + ' · ' : '') + 'Drift Engine';
  const again = focusId && document.getElementById(focusId);
  if (again) again.focus();
  else if (ui.dialog && !hadDialog) { const h = document.getElementById('dlgt'); if (h) h.focus(); }
}
async function refreshActivity() {
  try { D.activity = await api('/api/activity'); } catch (e) { /* keep the last list */ }
}
async function poll() {
  // Poll the short list of unfinished jobs; fetch the full activity only when one of them changed.
  const watching = D.ready ? D.activity.filter((j) => j.requestId && (j.status === 'Queued' || j.status === 'Running')) : [];
  if (watching.length) {
    try {
      const active = await api('/api/activity/active');
      const now = new Map(active.map((j) => [j.jobId, j.status]));
      const nowText = new Map(active.map((j) => [j.jobId, j.updatedAt]));
      if (watching.some((j) => now.get(j.jobId) !== j.status || (nowText.has(j.jobId) && nowText.get(j.jobId) !== j.updatedAt))) {
        await refreshActivity();
        // A finished job may have changed findings, blueprint or exclusions: read everything again.
        const done = watching.filter((j) => !now.has(j.jobId) && D.activity.some((a) => a.jobId === j.jobId && a.status === 'Succeeded'));
        if (done.length) { try { const activity = D.activity; await loadAll(); D.items = {}; D.activity = activity; } catch (e) { /* keep the old data */ } }
        if (!ui.dialog) render();
      }
    } catch (e) { /* try again next tick */ }
  }
  setTimeout(poll, 2000);
}

document.addEventListener('click', onClick);
document.addEventListener('input', onInput);
document.addEventListener('change', onChange);
document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && (ui.dialog || ui.riskDialog)) { ui.dialog = null; ui.riskDialog = null; render(); }
    else if (e.target && e.target.dataset && e.target.dataset.rn && ui.rename) { if (e.key === 'Enter') { e.preventDefault(); renameTenant(); } else if (e.key === 'Escape') { ui.rename = null; render(); } }
  });
window.addEventListener('popstate', () => { render(); });
loadAll().then(render, (e) => { D.error = 'Could not load data: ' + e.message; render(); });
poll();
