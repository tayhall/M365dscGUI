// Pure helpers for the Overview heat cells: the colour of a workload cell and the drift count per workload. Kept apart from app.js
// so node can test them (gui/tests/Heat.Tests.ps1).
'use strict';

(function (root) {
  // How drifted a workload is: ok (none), w1 up to 10% of its managed items, w2 up to 30%, w3 above that, nc when it was not checked.
  // Nothing managed but something drifted is w3.
  function tone(drifted, managed, checked) {
    if (!checked) return 'nc';
    if (!drifted) return 'ok';
    if (!managed) return 'w3';
    const share = drifted / managed;
    return share <= 0.1 ? 'w1' : share <= 0.3 ? 'w2' : 'w3';
  }

  // Findings per workload, every listed workload present (0 when none); findings of other workloads are ignored.
  function countByWorkload(findings, workloads) {
    const counts = {};
    workloads.forEach((w) => { counts[w] = 0; });
    findings.forEach((f) => { if (Object.prototype.hasOwnProperty.call(counts, f.workload)) counts[f.workload]++; });
    return counts;
  }

  const api = { tone, countByWorkload };
  root.PEHeat = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
