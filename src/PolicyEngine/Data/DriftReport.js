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
    ids.forEach(function (id) {
      var item = index[id];
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

  // filter: { type, kind, text }; state: { includeRemovals }. Returns the ids of the approvable items that match.
  function selectAll(data, filter, state) {
    var f = filter || {};
    var text = f.text ? String(f.text).toLowerCase() : '';
    return data.Items.filter(function (item) {
      if (!item.Approvable) { return false; }
      if (item.Action === 'Remove' && !(state && state.includeRemovals)) { return false; }
      if (f.type && item.ResourceType !== f.type) { return false; }
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

  var api = {
    buildApprovedList: buildApprovedList,
    selectAll: selectAll,
    summarise: summarise,
    whyNotDownloadable: whyNotDownloadable
  };
  root.PEReport = api;
  if (typeof module !== 'undefined' && module.exports) { module.exports = api; }
}(typeof window !== 'undefined' ? window : globalThis));
