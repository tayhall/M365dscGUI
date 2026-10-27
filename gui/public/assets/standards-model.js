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

  const api = { statusOf, filterRows, filterCounts, headlineText, subText, barSegments, reasonLabel, valueText };
  root.PEStandards = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
