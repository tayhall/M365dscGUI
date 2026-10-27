// The Standards pages: the loaded standards with the selected tenant's headline and workload table, the check against one standard, and what
// is not covered. Read-only views of the view models the engine exports (standards-model.js has the pure helpers); the server decides what
// each row allows (allowedActions). Uses the globals of app.js (D, ui, api, esc, link, go, render, curTenant, tenant, role, plural, shortDate).
'use strict';

// Standards the engine can import (Data\StandardSources.psd1 on the server, which re-checks every request).
const STANDARD_SOURCES = [{ name: 'asd', label: 'ASD Blueprint for Secure Cloud' }];
const REASON_TEXT = {
  Placeholder: 'The standard leaves a value for each organisation to fill in (for example the break-glass group of a Conditional Access policy). Checking these needs per-tenant values. Left out for now.',
  UnknownProperty: 'The standard uses a setting name that the Microsoft365DSC version we run does not have, mostly renamed or retired. Not guessed.',
  Unkeyed: 'No key could be derived for the setting, so it cannot be matched with the tenant.'
};
const STATUS_LABEL = { differs: 'Differs', missing: 'Missing', lookAgain: 'Look again', accepted: 'Accepted' };
const STATUS_CLASS = { differs: 'warn', missing: 'person', lookAgain: 'person', accepted: 'accept' };
const BAR_CLASS = { match: 'ok', differ: 'warn', accepted: 'accept', notReadable: 'person', notCovered: 'nc' };
const BAR_LABEL = { match: 'match', differ: 'differ', accepted: 'accepted', notReadable: 'not readable', notCovered: 'not covered' };

const stdPath = {
  list: () => '/standards',
  check: (name, show) => `/standards/${enc(name)}` + (show && show !== 'decide' ? '?show=' + enc(show) : ''),
  notCovered: (name, reason) => `/standards/${enc(name)}/not-covered` + (reason && reason !== 'all' ? '?reason=' + enc(reason) : '')
};

// ---------- data ----------
// Called by loadAll: the list of standards, and fresh caches for the per-tenant views and the coverage lists.
async function loadStandards() {
  let list = [];
  try { list = await api('/api/standards'); } catch (e) { list = []; }
  D.standards = Array.isArray(list) ? list : [];
  D.std = { tenant: {}, coverage: {} };
}
function stdFetch(cache, key, url) {
  if (!cache[key]) {
    cache[key] = { loading: true };
    api(url).then((v) => { cache[key] = v; }, (e) => { cache[key] = { error: e.message }; }).then(render);
  }
  return cache[key];
}
const stdTenantView = (t, name) => stdFetch(D.std.tenant, t + '|' + name, `/api/tenants/${enc(t)}/standards/${enc(name)}`);
const stdCoverage = (name) => stdFetch(D.std.coverage, name, `/api/standards/${enc(name)}/coverage`);
const stdJobRunning = (action, match) => D.ready && D.activity.some((j) => j.action === action && (j.status === 'Queued' || j.status === 'Running') && (!match || match(j)));

// ---------- pieces ----------
const stdChip = (kind, text) => `<span class="std-chip ${kind}">${esc(text)}</span>`;
const stdStatusChip = (status) => stdChip(STATUS_CLASS[status] || 'warn', STATUS_LABEL[status] || status);

function stdBar(headline) {
  const segments = PEStandards.barSegments(headline);
  if (!segments.length) return '';
  const label = segments.map((s) => `${s.count} ${BAR_LABEL[s.key]}`).join(', ');
  const bar = `<div class="std-bar" role="img" aria-label="${esc(label)}">${segments.map((s) => `<i class="b-${BAR_CLASS[s.key]}" style="width:${s.percent}%"></i>`).join('')}</div>`;
  const legend = `<div class="std-legend">${segments.map((s) => `<span class="k-${BAR_CLASS[s.key]}">${s.count} ${BAR_LABEL[s.key]}</span>`).join('')}</div>`;
  return bar + legend;
}

function stdCheckButton(name, t, label) {
  const meta = tenant(t).meta;
  const busy = stdJobRunning('StandardCheck', (j) => j.tenantId === t);
  const offline = !!meta.offline;
  const title = offline ? 'This tenant is offline: a standard check reads the tenant.' : '';
  return `<button class="btn sm pri" data-act="std-check" data-standard="${esc(name)}" data-tenant="${esc(t)}"${busy || offline ? ' disabled' : ''}${title ? ` title="${esc(title)}"` : ''}>${busy ? 'Checking…' : esc(label)}</button>${offline ? `<span class="muted" style="margin-left:8px">${esc(title)}</span>` : ''}`;
}

function stdWorkloadTable(view) {
  const rows = view.byWorkload || [];
  if (!rows.length) return '';
  const num = (n) => `<td class="num">${n}</td>`;
  return `<div class="card"><h2>By workload</h2><div class="std-scroll"><table class="std-table"><thead><tr><th>Workload</th><th class="num">In standard</th><th class="num">Checked</th><th class="num">Match</th><th class="num">Differ</th><th class="num">Accepted</th><th class="num">Not readable</th><th class="num">Not covered</th></tr></thead><tbody>${rows.map((w) => `<tr><td>${esc(w.workload)}</td>${num(w.total)}${num(w.checked)}${num(w.match)}${num(w.differ)}${num(w.accepted)}${num(w.notReadable)}${num(w.notCovered)}</tr>`).join('')}</tbody></table></div><p class="muted std-note">Not readable means the last export could not read that type in this tenant (a permission or a failed component). Those settings are never reported as missing.</p></div>`;
}

function stdTenantCard(std, t) {
  const view = stdTenantView(t, std.name);
  const head = `<h2>${esc(tenantLabel(t))}${view.checked ? `, last checked ${esc(shortDate(view.checkedAt))}` : ''}</h2>`;
  if (view.loading) return `<div class="card">${head}<p class="muted">Loading…</p></div>`;
  if (view.error) return `<div class="card">${head}<p class="err">${esc(view.error)}</p></div>`;
  if (!view.checked) {
    return `<div class="card">${head}<div class="big">Not checked yet</div><p class="muted">${esc(tenantLabel(t))} has not been checked against ${esc(std.sourceName)}. The check reads the tenant for the workloads the standard covers.</p><div class="btns">${stdCheckButton(std.name, t, `Check ${tenantLabel(t)} against it`)}</div></div>`;
  }
  const h = view.headline;
  const notes = [];
  if (view.patched) notes.push('Updated after your decisions; check again to read the tenant.');
  if (view.newerVersionImported) notes.push('A newer version of the standard is imported. Check again to compare with it.');
  return `<div class="card">${head}<div class="big">${esc(PEStandards.headlineText(h))}</div><div class="muted" style="margin:2px 0 12px">${esc(PEStandards.subText(h))}</div>${stdBar(h)}${notes.map((n) => `<p class="muted std-note">${esc(n)}</p>`).join('')}<div class="btns" style="margin-top:12px">${stdCheckButton(std.name, t, 'Check again')}${link(stdPath.check(std.name), 'See the differences', 'btn sm')}</div></div>`;
}

function stdInfoCard(std, t) {
  const latest = std.latest || {};
  const view = D.std.tenant[t + '|' + std.name];
  const adoption = view && view.checked ? `<dt>Adopted</dt><dd>${view.adoption.adopted} of ${view.adoption.covered} are in blueprint <b>${esc(view.adoption.blueprint)}</b></dd>` : '';
  const importing = stdJobRunning('ImportStandard');
  const looking = stdJobRunning('CheckStandardRelease');
  return `<div class="card"><div class="role">Standard</div><div class="domain">${esc(std.sourceName)}</div>
    <dl class="std-kv"><dt>Version</dt><dd>${esc(latest.sourceVersion || '—')} (blueprint version ${esc(latest.version)}), imported ${esc(shortDate(latest.importedAt))}</dd>
    <dt>Source</dt><dd class="mono">${esc(String(std.sourceUrl).replace(/^https?:\/\//, ''))}</dd>
    <dt>Licence</dt><dd>${esc(std.license)}. ${esc(std.attribution)}</dd>
    <dt>Settings</dt><dd>${latest.total} in the standard, ${latest.covered} can be checked here</dd>${adoption}</dl>
    <div class="btns" style="margin-top:12px">${link(stdPath.notCovered(std.name), 'What is not covered', 'btn sm')}
      <button class="btn sm" data-act="std-release" data-standard="${esc(std.name)}"${looking ? ' disabled' : ''}>${looking ? 'Looking…' : 'Look for a new release'}</button>
      <button class="btn sm" data-act="std-import" data-standard="${esc(std.name)}"${importing ? ' disabled' : ''}>${importing ? 'Importing…' : 'Import latest release'}</button></div></div>`;
}

function stdReleaseBanner(std) {
  const found = std.latestRelease && std.latestRelease.tag;
  const have = std.latest && std.latest.sourceVersion;
  if (!found || !have || found === have || (found.localeCompare(have, undefined, { numeric: true }) <= 0)) return '';
  const importing = stdJobRunning('ImportStandard');
  return `<div class="banner b-warn" role="status"><div style="flex:1"><b>${esc(std.sourceName)} ${esc(found)} is available.</b> You have ${esc(have)}. Import it to see what changed and which accepted risks need another look.</div><button class="btn pri sm" data-act="std-import" data-standard="${esc(std.name)}" data-tag="${esc(found)}"${importing ? ' disabled' : ''}>${importing ? 'Importing…' : 'Import ' + esc(found)}</button></div>`;
}

// ---------- pages ----------
function standardsPage() {
  const t = curTenant();
  const list = D.standards || [];
  const importPanel = ui.stdImport
    ? `<div class="card" style="margin-bottom:16px"><h2>Standards you can import</h2>${STANDARD_SOURCES.map((s) => `<div class="std-source"><span>${esc(s.label)}</span><button class="btn sm pri" data-act="std-import" data-standard="${esc(s.name)}"${stdJobRunning('ImportStandard') ? ' disabled' : ''}>Import latest release</button></div>`).join('')}<p class="muted std-note">The files are downloaded from the publisher and only read, never run. Settings that need a value from each organisation, or that this tool cannot read yet, are listed as not covered.</p></div>`
    : '';
  const head = `<div class="phead"><div><h1>Standards</h1><div class="muted">Published security standards. Read-only: check a tenant against one, adopt settings into a blueprint.</div></div><button class="btn" data-act="std-import-toggle">${ui.stdImport ? 'Close' : 'Import a standard'}</button></div>`;
  if (!list.length) {
    return head + importPanel + `<div class="card"><h2>No standard imported yet</h2><p class="muted">Import the ASD Blueprint for Secure Cloud to see how a tenant compares with it.</p><div class="btns"><button class="btn pri" data-act="std-import" data-standard="asd"${stdJobRunning('ImportStandard') ? ' disabled' : ''}>Import the ASD Blueprint</button></div></div>`;
  }
  return head + importPanel + list.map((std) => {
    const view = stdTenantView(t, std.name);
    return stdReleaseBanner(std) + `<div class="cards2">${stdInfoCard(std, t)}${stdTenantCard(std, t)}</div>` + (view.checked ? stdWorkloadTable(view) : '');
  }).join('<div style="height:16px"></div>');
}

function stdRowHtml(row) {
  const status = PEStandards.statusOf(row);
  const values = (list, side) => list.map((d) => `<span class="std-val"><span class="mono">${esc(d.property)}</span> <b>${esc(PEStandards.valueText(d[side]))}</b></span>`).join('');
  const diffs = row.differences || [];
  const accepted = row.acceptedDifferences || [];
  const standard = row.kind === 'Missing' ? '<b>Present</b>' : values(diffs, 'standard') + values(accepted, 'standard');
  const tenantSide = row.kind === 'Missing' ? '<span class="muted">Not in this tenant</span>' : values(diffs, 'tenant') + values(accepted, 'tenant');
  let state = `<div class="std-chips">${stdStatusChip(status)}${row.adopted ? stdChip('ok', 'Adopted' + (row.adoptedFrom ? ' (' + row.adoptedFrom + ')' : '')) : ''}</div>`;
  if (status === 'accepted' || accepted.length) state += `<span class="std-sub">${accepted.length && status !== 'accepted' ? 'Accepted for ' + esc(accepted.map((d) => d.property).join(', ')) + ' · ' : ''}by ${esc(row.approvedBy || 'someone')}${row.acceptedAt ? ', ' + esc(shortDate(row.acceptedAt)) : ''}</span>${row.acceptedReason ? `<span class="std-sub">${esc(row.acceptedReason)}</span>` : ''}`;
  if (status === 'lookAgain') state += `<span class="std-sub std-look">${esc(row.hint || 'The standard changed after this was accepted.')}</span>`;
  return `<tr class="${status === 'accepted' ? 'std-acc' : ''}"><td><b>${esc(row.key)}</b><span class="std-sub mono">${esc(row.resourceType)}</span><span class="std-sub">${esc(row.workload)}</span></td><td>${standard}</td><td>${tenantSide}</td><td>${state}</td></tr>`;
}

function standardCheckPage(r) {
  const std = (D.standards || []).find((s) => s.name === r.name);
  if (!std) return notFound();
  const t = curTenant();
  const view = stdTenantView(t, std.name);
  const head = `<div class="phead"><div><h1>${esc(tenantLabel(t))} against ${esc(std.sourceName)}</h1>${view.checked ? `<div class="muted">${esc(PEStandards.headlineText(view.headline))}, ${esc(shortDate(view.checkedAt))}. Only what the standard states is compared.</div>` : ''}</div><div class="btns">${stdCheckButton(std.name, t, view.checked ? 'Check again' : `Check ${tenantLabel(t)} against it`)}</div></div>`;
  if (view.loading) return head + '<div class="card"><p class="muted">Loading…</p></div>';
  if (view.error) return head + `<div class="card"><p class="err">${esc(view.error)}</p></div>`;
  if (!view.checked) return head + `<div class="card"><h2>Not checked yet</h2><p class="muted">${esc(tenantLabel(t))} has not been checked against this standard.</p></div>`;
  const show = ['decide', 'accepted', 'all'].includes(r.show) ? r.show : 'decide';
  const counts = PEStandards.filterCounts(view.rows);
  const rows = PEStandards.filterRows(view.rows, show);
  const pill = (key, label) => `<button class="tab${show === key ? ' on' : ''}" data-act="std-filter" data-standard="${esc(std.name)}" data-show="${key}" aria-pressed="${show === key}">${label} <b>${counts[key]}</b></button>`;
  const empty = show === 'accepted' ? 'No accepted risks.' : show === 'decide' ? 'Nothing needs a decision. Every checked setting matches or has an accepted risk.' : 'No differences.';
  return head + `<div class="card"><div class="pills" role="group" aria-label="Show">${pill('decide', 'Needs a decision')}${pill('accepted', 'Accepted')}${pill('all', 'All differences')}</div>
    ${rows.length ? `<div class="std-scroll"><table class="std-table"><thead><tr><th>Setting</th><th>Standard says</th><th>Tenant has</th><th>Status</th></tr></thead><tbody>${rows.map(stdRowHtml).join('')}</tbody></table></div>` : `<p class="muted">${esc(empty)}</p>`}</div>`;
}

function notCoveredPage(r) {
  const std = (D.standards || []).find((s) => s.name === r.name);
  if (!std) return notFound();
  const cov = stdCoverage(std.name);
  const head = `<div class="phead"><div><h1>Not covered</h1>${cov.rows ? `<div class="muted">${cov.total - cov.covered} of ${cov.total} settings cannot be checked in this tool yet. They are never counted as passing.</div>` : ''}</div></div>`;
  if (cov.loading) return head + '<div class="card"><p class="muted">Loading…</p></div>';
  if (cov.error) return head + `<div class="card"><p class="err">${esc(cov.error)}</p></div>`;
  const reasons = Object.keys(cov.byReason || {});
  const show = r.reason && reasons.includes(r.reason) ? r.reason : 'all';
  const rows = (cov.rows || []).filter((x) => show === 'all' || x.reason === show);
  const cards = `<div class="std-reasons">${reasons.map((k) => `<div class="card">${stdChip(k === 'Placeholder' ? 'person' : 'grey', PEStandards.reasonLabel(k))}<div class="big" style="margin:6px 0 2px">${cov.byReason[k]}</div><div class="muted">${esc(REASON_TEXT[k] || '')}</div></div>`).join('')}</div>`;
  const pill = (key, label, n) => `<button class="tab${show === key ? ' on' : ''}" data-act="std-notcov-filter" data-standard="${esc(std.name)}" data-reason="${esc(key)}" aria-pressed="${show === key}">${esc(label)} <b>${n}</b></button>`;
  return head + cards + `<div class="card"><div class="pills" role="group" aria-label="Reason">${pill('all', 'All', (cov.rows || []).length)}${reasons.map((k) => pill(k, PEStandards.reasonLabel(k), cov.byReason[k])).join('')}</div>
    <div class="std-scroll"><table class="std-table"><thead><tr><th>Setting</th><th>Workload</th><th>Reason</th><th>Detail</th></tr></thead><tbody>${rows.map((x) => `<tr><td><b>${esc(x.key)}</b><span class="std-sub mono">${esc(x.resourceType)}</span></td><td>${esc(x.workload)}</td><td>${stdChip(x.reason === 'Placeholder' ? 'person' : 'grey', PEStandards.reasonLabel(x.reason))}</td><td class="mono">${esc(x.detail)}</td></tr>`).join('')}</tbody></table></div></div>`;
}

function standardCrumbs(r) {
  const std = (D.standards || []).find((s) => s.name === r.name);
  const list = [['Standards', stdPath.list()], [std ? std.sourceName : r.name, r.screen === 'notcovered' ? stdPath.check(r.name) : null]];
  if (r.screen === 'notcovered') list.push(['Not covered', null]);
  const html = list.map(([label, href], i) => (i === list.length - 1 || !href
    ? `<span class="crumbcur" aria-current="page">${esc(label)}</span>`
    : `${link(href, label, 'crumb')}<span class="sep" aria-hidden="true">›</span>`)).join('');
  return `<div class="crumbs"><nav aria-label="Breadcrumb" style="display:flex;flex-wrap:wrap;align-items:center;gap:4px">${html}</nav></div>`;
}

// ---------- actions ----------
async function stdRequest(body, queued) {
  // Queues a request; the worker does the work and the page reloads its data when the job finishes.
  try {
    const res = await api('/api/requests', body);
    if (res.created) ui.toast = { text: queued.replace('{job}', res.jobId), job: res.jobId };
    else ui.toast = { text: res.errors.join(' '), job: null };
    await refreshActivity();
  } catch (e) { ui.toast = { text: e.message, job: null }; }
  render();
}
function standardsClick(el) {
  const act = el.dataset.act;
  const name = el.dataset.standard;
  if (act === 'std-check') stdRequest({ action: 'StandardCheck', tenantId: el.dataset.tenant, standard: name }, 'Standard check {job} queued. This page updates when it finishes.');
  else if (act === 'std-import') stdRequest(Object.assign({ action: 'ImportStandard', standard: name }, el.dataset.tag ? { tag: el.dataset.tag } : {}), 'Import {job} queued. This page updates when it finishes.');
  else if (act === 'std-release') stdRequest({ action: 'CheckStandardRelease', standard: name }, 'Looking for a new release ({job}).');
  else if (act === 'std-import-toggle') { ui.stdImport = !ui.stdImport; render(); }
  else if (act === 'std-filter') go(stdPath.check(name, el.dataset.show));
  else if (act === 'std-notcov-filter') go(stdPath.notCovered(name, el.dataset.reason));
}
