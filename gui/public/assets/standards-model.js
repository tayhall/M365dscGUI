// Pure helpers for the Standards pages: which rows a filter shows, the headline words, the segments of the coverage bar, how a value is
// written. Kept apart from standards.js so node can test them (gui/tests/Standards.Tests.ps1). No DOM here.
'use strict';

(function (root) {
  const STATUSES = ['differs', 'missing', 'lookAgain', 'accepted'];
  const statusOf = (row) => (row && STATUSES.includes(row.status) ? row.status : 'differs');

  // decide: what still needs a person (differs, missing, look again); accepted: risks that were accepted; all: every row.
  function filterRows(rows, filter) {
    const list = rows || [];
    if (filter === 'all') return list.slice();
    if (filter === 'accepted') return list.filter((r) => statusOf(r) === 'accepted');
    return list.filter((r) => statusOf(r) !== 'accepted');
  }
  function filterCounts(rows) {
    return { decide: filterRows(rows, 'decide').length, accepted: filterRows(rows, 'accepted').length, all: (rows || []).length };
  }

  const headlineText = (h) => `Checked ${h.checked} of ${h.total} settings`;
  const subText = (h) => `${h.match} match, ${h.differ} differ, ${h.accepted} ${h.accepted === 1 ? 'is an accepted risk' : 'are accepted risks'}`;

  // The coverage bar: every setting of the standard is in exactly one segment, so not covered and not readable never count as matching.
  const BAR_ORDER = ['match', 'differ', 'accepted', 'notReadable', 'notCovered'];
  function barSegments(h) {
    if (!h || !h.total) return [];
    return BAR_ORDER.filter((k) => h[k] > 0).map((k) => ({ key: k, count: h[k], percent: Math.round((h[k] / h.total) * 1000) / 10 }));
  }

  const REASON = { Placeholder: 'Placeholder', UnknownProperty: 'Unknown property', Unkeyed: 'No key' };
  const reasonLabel = (reason) => REASON[reason] || String(reason);

  function valueText(v) {
    if (v === null || v === undefined) return '—';
    if (typeof v === 'boolean') return v ? 'True' : 'False';
    if (Array.isArray(v)) return v.length ? v.map(valueText).join(', ') : '—';
    if (typeof v === 'object') return JSON.stringify(v);
    return String(v);
  }

  // ---- the selection list ----
  // An entry of the list is for one item of one tenant, and a standards entry is also for one standard, so a pick on the Standards page and a
  // pick of the same item on Drift review never replace each other.
  const queueIdentity = (entry) => [entry.t, entry.standard || '', entry.itemId].join('|');

  // What a request carries for one Accept risk entry: who approved it and why; properties only when the person ticked some of several.
  function riskItems(entry) {
    const item = { itemId: entry.itemId, approvedBy: entry.approvedBy, why: entry.why };
    if (Array.isArray(entry.properties) && entry.properties.length) item.properties = entry.properties.slice();
    return item;
  }
  // Standards entries grouped by action, tenant and standard, in the order they were picked: one group is one request, so one blueprint version
  // for an Adopt and one write per decision for an Accept risk. Entries of Drift review (no standard) are not here.
  function groupStandardEntries(entries) {
    const by = new Map();
    (entries || []).filter((c) => c.standard).forEach((c) => {
      const key = [c.action, c.t, c.standard].join('|');
      if (!by.has(key)) by.set(key, { action: c.action, pick: c.action, tenantId: c.t, standard: c.standard, items: [] });
      by.get(key).items.push(c.action === 'AcceptRisk' ? riskItems(c) : { itemId: c.itemId });
    });
    return Array.from(by.values());
  }

  // ---- the Accept risk dialog ----
  // d: { approvedBy, why, differing: [property names of the row], ticked: [the ones chosen] }.
  function riskDialogProblem(d) {
    if (!String(d.approvedBy || '').trim()) return 'Say who approved it.';
    if (!String(d.why || '').trim()) return 'Say why.';
    if ((d.differing || []).length > 1 && !(d.ticked || []).length) return 'Tick at least one setting.';
    return '';
  }
  // The whole item when every setting is ticked (or only one differs); otherwise just the ticked ones.
  function riskProperties(d) {
    const differing = d.differing || [];
    const ticked = d.ticked || [];
    return differing.length > 1 && ticked.length < differing.length ? ticked.slice() : [];
  }

  const api = { statusOf, filterRows, filterCounts, headlineText, subText, barSegments, reasonLabel, valueText, queueIdentity, riskItems, groupStandardEntries, riskDialogProblem, riskProperties };
  root.PEStandards = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
