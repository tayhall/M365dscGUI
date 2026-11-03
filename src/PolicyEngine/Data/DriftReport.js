/* Drift report page. Part 1: selection logic (pure functions, no DOM), tested in Node by tests/driftreport/logic.test.mjs.
   Part 2 (the page) is appended below and only runs in a browser. Plain JavaScript, no libraries, no network.
   The approved list built here is exactly the format of New-PEApprovedList (Format 1); Read-PEApprovedList is the authority on it. */
(function (root) {
  'use strict';

  var ACTION_ORDER = { Create: 0, Update: 1, Remove: 2 };
  var PROPERTY_NAME = /^[A-Za-z0-9_.]+$/;
  var CONTROL = /[\u0000-\u001f\u007f-\u009f]/;

  function fail(message) {
    throw new Error('Cannot download: ' + message);
  }

  function itemIndex(data) {
    var index = Object.create(null);
    data.Items.forEach(function (item) { index[item.Id] = item; });
    return index;
  }

  function validApprover(approvedBy) {
    var name = String(approvedBy == null ? '' : approvedBy).trim();
    if (name.length < 1 || name.length > 100 || CONTROL.test(name)) {
      fail('fill in "Approved by" (1 to 100 characters).');
    }
    return name;
  }

  function validKey(item) {
    var key = String(item.Key == null ? '' : item.Key);
    if (key.length < 1 || key.length > 500 || CONTROL.test(key)) {
      fail('the item "' + item.ResourceType + '" has an invalid key (1 to 500 characters, one line).');
    }
  }

  function excludedFor(item, entry) {
    var excluded = (entry && entry.excluded) || [];
    var seen = Object.create(null);
    var names = [];
    excluded.forEach(function (name) {
      var known = item.Action === 'Update' && item.Differences.some(function (d) { return d.Property === name; });
      if (!PROPERTY_NAME.test(name) || !known) {
        fail('"' + name + '" is not an excluded property that ' + item.ResourceType + ' "' + item.Key + '" can have.');
      }
      if (!seen[name]) { seen[name] = true; names.push(name); }
    });
    return names.sort();
  }

  function countsOf(items) {
    var groups = Object.create(null);
    items.forEach(function (item) {
      var k = item.ResourceType + '|' + item.Action;
      groups[k] = groups[k] || { ResourceType: item.ResourceType, Action: item.Action, Count: 0 };
      groups[k].Count += 1;
    });
    return Object.keys(groups).map(function (k) { return groups[k]; }).sort(function (a, b) {
      if (a.ResourceType !== b.ResourceType) { return a.ResourceType < b.ResourceType ? -1 : 1; }
      return ACTION_ORDER[a.Action] - ACTION_ORDER[b.Action];
    });
  }

  function isoNoMillis(date) {
    return date.toISOString().replace(/\.\d{3}Z$/, 'Z');
  }

  // selection: { [itemId]: { excluded: [propertyName, ...] } }
  function buildApprovedList(data, selection, approvedBy, includeRemovals, now) {
    var ids = Object.keys(selection || {});
    if (ids.length === 0) { fail('nothing selected.'); }
    var approver = validApprover(approvedBy);
    var index = itemIndex(data);
    // Read-PEApprovedList compares Action, type and key case-insensitively, so two items that differ only in case would be refused at apply time.
    var seen = Object.create(null);
    ids.forEach(function (id) {
      var item = index[id];
      if (item) {
        var same = (item.Action + '|' + item.ResourceType + '|' + item.Key).toLowerCase();
        if (seen[same]) { fail('"' + item.Key + '" and "' + seen[same] + '" are the same item twice (they differ only in letter case).'); }
        seen[same] = item.Key;
      }
      if (!item) { fail('"' + id + '" is not in this report.'); }
      if (!item.Approvable) { fail(item.ResourceType + ' "' + item.Key + '" cannot be approved: ' + item.Reason); }
      if (item.Action === 'Remove' && !includeRemovals) { fail('turn on "Include removals" to approve a removal (' + item.ResourceType + ' "' + item.Key + '").'); }
      validKey(item);
    });
    var items = data.Items.filter(function (item) { return selection[item.Id]; }).map(function (item) {
      return { Action: item.Action, ResourceType: item.ResourceType, Key: item.Key, ExcludedProperties: excludedFor(item, selection[item.Id]) };
    });
    var meta = data.Meta;
    return {
      Format: 1,
      CreatedUtc: isoNoMillis(now || new Date()),
      ApprovedBy: approver,
      Tenant: meta.Tenant,
      ModuleVersion: meta.ModuleVersion,
      Source: { Run: meta.Source.Run, ExportedAt: meta.Source.ExportedAt, Fingerprint: meta.Source.Fingerprint },
      Target: { Run: meta.Target.Run, ExportedAt: meta.Target.ExportedAt, Fingerprint: meta.Target.Fingerprint },
      Items: items,
      Counts: countsOf(items)
    };
  }

  // filter: { workload, type, kind, text }; state: { includeRemovals }. Returns the ids of the approvable items that match.
  function selectAll(data, filter, state) {
    var f = filter || {};
    var text = f.text ? String(f.text).toLowerCase() : '';
    return data.Items.filter(function (item) {
      if (!item.Approvable) { return false; }
      if (item.Action === 'Remove' && !(state && state.includeRemovals)) { return false; }
      if (f.type && item.ResourceType !== f.type) { return false; }
      if (f.workload && workloadOf(data, item) !== f.workload) { return false; }
      if (f.kind && item.Action !== f.kind) { return false; }
      if (text && String(item.Key).toLowerCase().indexOf(text) < 0) { return false; }
      return true;
    }).map(function (item) { return item.Id; });
  }

  // The lines Apply will print for the same list (for example "Create 10 AADGroup").
  function summarise(data, selection) {
    var index = itemIndex(data);
    var chosen = Object.keys(selection || {}).map(function (id) { return index[id]; }).filter(Boolean);
    var lines = countsOf(chosen).map(function (c) { return c.Action + ' ' + c.Count + ' ' + c.ResourceType; });
    return { lines: lines, total: chosen.length };
  }

  // '' when the list can be downloaded, otherwise the reason (shown next to the disabled Download button).
  function whyNotDownloadable(data, selection, approvedBy, includeRemovals) {
    try {
      buildApprovedList(data, selection, approvedBy, includeRemovals, new Date());
      return '';
    } catch (error) {
      return String(error.message).replace(/^Cannot download: /, '');
    }
  }

  // ---- workloads, types and totals -------------------------------------------------------------------------------------------
  var KINDS = ['', 'Create', 'Update', 'Remove', 'Cannot', 'NotCompared'];
  var GROUP_ORDER = { 'different': 0, 'excluded': 1, 'ignored': 2, 'only-source': 3, 'only-target': 4, 'same': 5 };
  var typeWorkloads = typeof WeakMap === 'function' ? new WeakMap() : null;

  function workloadIndex(data) {
    var cached = typeWorkloads && typeWorkloads.get(data);
    if (cached) { return cached; }
    var index = Object.create(null);
    (data.Types || []).forEach(function (t) { index[t.ResourceType] = t.Workload || 'Other'; });
    if (typeWorkloads) { typeWorkloads.set(data, index); }
    return index;
  }

  // The workload of an item: the one its resource type has in the report totals, else Other.
  function workloadOf(data, item) {
    return workloadIndex(data)[item.ResourceType] || 'Other';
  }

  function emptyCounts() { return { Create: 0, Update: 0, Remove: 0, Cannot: 0, NotCompared: 0, Drift: 0 }; }

  function addItem(counts, item) {
    if (item.NotCompared) { counts.NotCompared += 1; return; }
    if (item.Approvable) { counts[item.Action] += 1; } else { counts.Cannot += 1; }
    counts.Drift += 1;
  }

  // [{ name, source, target, counts, types: [{ ResourceType, source, target, counts, items, notCompared }] }] in the engine's workload order.
  // source / target are the record counts of the two exports; items are the drift items (not-compared ones are kept apart).
  function workloadTree(data) {
    var byWorkload = Object.create(null);
    var typeNodes = Object.create(null);
    function typeNode(resourceType, workload, source, target) {
      if (typeNodes[resourceType]) { return typeNodes[resourceType]; }
      var node = { ResourceType: resourceType, source: source || 0, target: target || 0, counts: emptyCounts(), items: [], notCompared: [] };
      typeNodes[resourceType] = node;
      var w = byWorkload[workload];
      if (!w) { w = byWorkload[workload] = { name: workload, source: 0, target: 0, counts: emptyCounts(), types: [] }; }
      w.types.push(node);
      w.source += node.source;
      w.target += node.target;
      return node;
    }
    (data.Types || []).forEach(function (t) { typeNode(t.ResourceType, t.Workload || 'Other', t.Source, t.Target); });
    data.Items.forEach(function (item) {
      var node = typeNode(item.ResourceType, workloadOf(data, item), 0, 0);
      var w = byWorkload[workloadOf(data, item)];
      if (item.NotCompared) { node.notCompared.push(item); } else { node.items.push(item); }
      addItem(node.counts, item);
      addItem(w.counts, item);
    });
    var order = (data.Meta && data.Meta.WorkloadOrder) || [];
    var names = Object.keys(byWorkload);
    names.sort(function (a, b) {
      var ia = order.indexOf(a); var ib = order.indexOf(b);
      if (ia < 0) { ia = 999; } if (ib < 0) { ib = 999; }
      return ia !== ib ? ia - ib : (a < b ? -1 : a > b ? 1 : 0);
    });
    return names.map(function (name) { return byWorkload[name]; });
  }

  // How many of the selected items are inside a workload and / or a type.
  function countSelected(data, selection, filter) {
    var f = filter || {};
    var index = itemIndex(data);
    return Object.keys(selection || {}).filter(function (id) {
      var item = index[id];
      if (!item) { return false; }
      if (f.type && item.ResourceType !== f.type) { return false; }
      if (f.workload && workloadOf(data, item) !== f.workload) { return false; }
      return true;
    }).length;
  }

  // ---- routes (the address after # decides which screen is shown, so the back button and shared links work) --------------------
  function safeDecode(text) {
    try { return decodeURIComponent(text); } catch (error) { return ''; }
  }

  function routeToHash(route) {
    if (route.view === 'item') { return '#/item/' + encodeURIComponent(route.id); }
    if (route.view === 'review') {
      var parts = [];
      [['workload', route.workload], ['type', route.type], ['kind', route.kind], ['q', route.text]].forEach(function (pair) {
        if (pair[1]) { parts.push(pair[0] + '=' + encodeURIComponent(pair[1])); }
      });
      return '#/review' + (parts.length ? '?' + parts.join('&') : '');
    }
    return '#/';
  }

  function parseRoute(hash) {
    var text = String(hash || '').replace(/^#/, '');
    if (text.indexOf('/item/') === 0) {
      var id = safeDecode(text.slice('/item/'.length));
      return id ? { view: 'item', id: id } : { view: 'overview' };
    }
    if (text === '/review' || text.indexOf('/review?') === 0) {
      var route = { view: 'review', workload: '', type: '', kind: '', text: '' };
      var query = text.indexOf('?') >= 0 ? text.slice(text.indexOf('?') + 1) : '';
      query.split('&').forEach(function (pair) {
        var at = pair.indexOf('=');
        if (at < 0) { return; }
        var name = pair.slice(0, at);
        var value = safeDecode(pair.slice(at + 1));
        if (name === 'workload') { route.workload = value; }
        else if (name === 'type') { route.type = value; }
        else if (name === 'kind') { route.kind = KINDS.indexOf(value) >= 0 ? value : ''; }
        else if (name === 'q') { route.text = value; }
      });
      return route;
    }
    return { view: 'overview' };
  }

  // ---- wording and ordering for the page -----------------------------------------------------------------------------------------
  function kindLabel(action, sourceLabel, targetLabel) {
    if (action === 'Create') { return 'Missing in ' + targetLabel; }
    if (action === 'Update') { return 'Different'; }
    if (action === 'Remove') { return 'Only in ' + targetLabel; }
    return 'Cannot be approved';
  }

  // The property rows of one resource: differences first, equal ones last, names A to Z inside a group. The input is not changed.
  function orderProps(props) {
    return props.slice().sort(function (a, b) {
      var ga = GROUP_ORDER[a.State]; var gb = GROUP_ORDER[b.State];
      if (ga !== gb) { return ga - gb; }
      var na = a.Property.toLowerCase(); var nb = b.Property.toLowerCase();
      return na < nb ? -1 : na > nb ? 1 : 0;
    });
  }

  var api = {
    buildApprovedList: buildApprovedList,
    selectAll: selectAll,
    summarise: summarise,
    whyNotDownloadable: whyNotDownloadable,
    workloadOf: workloadOf,
    workloadTree: workloadTree,
    countSelected: countSelected,
    parseRoute: parseRoute,
    routeToHash: routeToHash,
    kindLabel: kindLabel,
    orderProps: orderProps
  };
  root.PEReport = api;
  if (typeof module !== 'undefined' && module.exports) { module.exports = api; }
}(typeof window !== 'undefined' ? window : globalThis));
