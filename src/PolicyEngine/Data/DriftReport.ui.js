/* Drift report page. Part 2: the user interface. Needs DriftReport.js (PEReport) above it. Runs only in a browser.
   Every tenant value (keys, property values, reasons) is set with textContent, never as markup. No network access. */
(function () {
  'use strict';
  if (typeof document === 'undefined' || !window.PEReport) { return; }

  var R = window.PEReport;
  var PAGE = 200;
  var app = document.getElementById('app');
  var dataElement = document.getElementById('report-data');
  if (!app || !dataElement) { return; }

  var data;
  try {
    data = JSON.parse(dataElement.textContent);
  } catch (error) {
    app.textContent = 'The report data could not be read: ' + error.message;
    return;
  }

  var ARROW_CLOSED = String.fromCharCode(0x25b8);
  var ARROW_OPEN = String.fromCharCode(0x25be);
  var STORE_KEY = 'pe-drift-report:' + data.Meta.ReportId;

  // ---- state -------------------------------------------------------------------------------------------------------------
  var S = {
    selection: {},
    approvedBy: '',
    includeRemovals: false,
    filter: { type: '', kind: '', text: '' },
    expanded: {},   // type -> true
    shown: {},      // type -> number of rows rendered
    open: {}        // item id -> true (differences panel open)
  };

  var SRC = data.Meta.SourceLabel || 'PreProd';
  var TGT = data.Meta.TargetLabel || 'Dev';

  // Drift items are grouped by resource type. Items that say something was not compared (not drift, nothing to approve) are kept apart.
  var itemsByType = {};
  var types = [];
  var notCompared = [];
  data.Items.forEach(function (item) {
    if (item.NotCompared) { notCompared.push(item); return; }
    if (!itemsByType[item.ResourceType]) { itemsByType[item.ResourceType] = []; types.push(item.ResourceType); }
    itemsByType[item.ResourceType].push(item);
  });
  var allTypes = types.slice();
  notCompared.forEach(function (item) { if (allTypes.indexOf(item.ResourceType) < 0) { allTypes.push(item.ResourceType); } });
  allTypes.sort();
  var itemById = {};
  data.Items.forEach(function (item) { itemById[item.Id] = item; });

  // ---- persistence (only a convenience: the page works without it) ---------------------------------------------------------
  function loadState() {
    try {
      var saved = JSON.parse(window.localStorage.getItem(STORE_KEY) || 'null');
      if (!saved || typeof saved !== 'object') { return; }
      S.approvedBy = typeof saved.approvedBy === 'string' ? saved.approvedBy.slice(0, 100) : '';
      S.includeRemovals = saved.includeRemovals === true;
      var selection = saved.selection && typeof saved.selection === 'object' ? saved.selection : {};
      Object.keys(selection).forEach(function (id) {
        var item = itemById[id];
        if (!item || !item.Approvable) { return; }
        if (item.Action === 'Remove' && !S.includeRemovals) { return; }
        var excluded = Array.isArray(selection[id].excluded) ? selection[id].excluded : [];
        var known = item.Differences.map(function (d) { return d.Property; });
        S.selection[id] = { excluded: excluded.filter(function (name) { return known.indexOf(name) >= 0; }) };
      });
    } catch (error) { /* storage unavailable or damaged: start empty */ }
  }

  function saveState() {
    try {
      window.localStorage.setItem(STORE_KEY, JSON.stringify({ selection: S.selection, approvedBy: S.approvedBy, includeRemovals: S.includeRemovals }));
    } catch (error) { /* storage unavailable: nothing is lost but the reload convenience */ }
  }

  // ---- small DOM helper: strings are always text ---------------------------------------------------------------------------
  function h(tag, props, kids) {
    var node = document.createElement(tag);
    Object.keys(props || {}).forEach(function (name) {
      var value = props[name];
      if (name === 'text') { node.textContent = value; }
      else if (name === 'on') { Object.keys(value).forEach(function (type) { node.addEventListener(type, value[type]); }); }
      else if (name === 'checked' || name === 'disabled' || name === 'value' || name === 'indeterminate') { node[name] = value; }
      else if (value !== false && value != null) { node.setAttribute(name, value); }
    });
    (kids || []).forEach(function (kid) {
      if (kid == null) { return; }
      node.appendChild(typeof kid === 'string' ? document.createTextNode(kid) : kid);
    });
    return node;
  }

  // ---- the page ------------------------------------------------------------------------------------------------------------
  var els = {};
  var rowInputs = {};      // item id -> checkbox currently on the page
  var sectionRefs = {};    // type -> { count, box }

  function isRemovalLocked(item) { return item.Action === 'Remove' && !S.includeRemovals; }

  function matchesFilter(item) {
    var f = S.filter;
    if (f.kind === 'NotCompared') { return false; }
    if (f.type && item.ResourceType !== f.type) { return false; }
    if (f.kind === 'Cannot') { if (item.Approvable) { return false; } }
    else if (f.kind && item.Action !== f.kind) { return false; }
    if (f.text && String(item.Key).toLowerCase().indexOf(f.text.toLowerCase()) < 0) { return false; }
    return true;
  }

  function visibleIn(type) { return itemsByType[type].filter(matchesFilter); }

  function card(label, value, cls) {
    return h('div', { 'class': 'card' }, [h('div', { 'class': 'num ' + (cls || ''), text: String(value) }), h('div', { 'class': 'lbl', text: label })]);
  }

  function describeRun(name, side) {
    return name + ': run ' + side.Run + ', exported ' + side.ExportedAt;
  }

  function buildHeader() {
    var m = data.Meta;
    var t = data.Totals;
    return h('div', {}, [
      h('h1', { text: 'Drift report: ' + SRC + ' to ' + TGT }),
      h('p', { 'class': 'muted', text: 'Generated ' + m.GeneratedUtc + ' | ' + describeRun(SRC + ' export', m.Source) + ' | ' + describeRun(TGT + ' export', m.Target) + ' | Microsoft365DSC ' + m.ModuleVersion }),
      h('div', { 'class': 'cards' }, [
        card('Total', t.Total), card('Matching', t.Matching, 'good'), card('Create', t.Create, 'create'),
        card('Update', t.Update, 'update'), card('Remove', t.Remove, 'remove'), card('Cannot be approved', t.CannotApprove, 'cannot'), card('Not compared', t.NotCompared || 0, 'cannot')
      ])
    ]);
  }

  function kindButton(label, value) {
    var button = h('button', { type: 'button', 'class': 'chip', 'aria-pressed': 'false', text: label, on: { click: function () {
      S.filter.kind = S.filter.kind === value ? '' : value;
      renderFilterState();
      renderSections();
    } } });
    button.dataset.kind = value;
    return button;
  }

  function buildControls() {
    var typeSelect = h('select', { 'aria-label': 'Resource type', on: { change: function () { S.filter.type = typeSelect.value; renderSections(); } } },
      [h('option', { value: '', text: 'All resource types' })].concat(allTypes.map(function (type) {
        var n = (itemsByType[type] ? itemsByType[type].length : 0) + notCompared.filter(function (i) { return i.ResourceType === type; }).length;
        return h('option', { value: type, text: type + ' (' + n + ')' });
      })));
    var search = h('input', { type: 'search', placeholder: 'Search keys', 'aria-label': 'Search keys', on: { input: function () { S.filter.text = search.value; renderSections(); } } });
    els.removals = h('input', { type: 'checkbox', checked: S.includeRemovals, on: { change: function () { setIncludeRemovals(els.removals.checked); } } });
    els.approvedBy = h('input', { type: 'text', maxlength: '100', value: S.approvedBy, placeholder: 'Your name', 'aria-label': 'Approved by', on: { input: function () {
      S.approvedBy = els.approvedBy.value; saveState(); refreshSelectionUi();
    } } });
    els.kindButtons = [kindButton('Create', 'Create'), kindButton('Update', 'Update'), kindButton('Remove', 'Remove'), kindButton('Cannot be approved', 'Cannot'), kindButton('Not compared', 'NotCompared')];
    return h('div', { 'class': 'controls' }, [
      h('div', { 'class': 'row-controls' }, els.kindButtons.concat([typeSelect, search])),
      h('div', { 'class': 'row-controls' }, [
        h('button', { type: 'button', 'class': 'btn', text: 'Select all shown', on: { click: selectAllShown } }),
        h('button', { type: 'button', 'class': 'btn', text: 'Clear selection', on: { click: function () { S.selection = {}; saveState(); refreshSelectionUi(); } } }),
        h('label', { 'class': 'inline' }, [els.removals, ' Include removals']),
        h('label', { 'class': 'inline' }, ['Approved by ', els.approvedBy])
      ])
    ]);
  }

  function renderFilterState() {
    els.kindButtons.forEach(function (button) { button.setAttribute('aria-pressed', S.filter.kind === button.dataset.kind ? 'true' : 'false'); });
  }

  function setIncludeRemovals(on) {
    S.includeRemovals = on;
    if (!on) {
      Object.keys(S.selection).forEach(function (id) { if (itemById[id] && itemById[id].Action === 'Remove') { delete S.selection[id]; } });
    }
    saveState();
    renderSections();
  }

  function filterForAction() {
    // With the "Cannot be approved" chip on, only rows nobody can tick are shown, so nothing is selectable (selectAll returns none for it).
    return { type: S.filter.type, kind: S.filter.kind, text: S.filter.text };
  }

  function selectAllShown() {
    if (S.filter.kind === 'Cannot') { return; }
    R.selectAll(data, filterForAction(), { includeRemovals: S.includeRemovals }).forEach(function (id) {
      if (!S.selection[id]) { S.selection[id] = { excluded: [] }; }
    });
    saveState();
    refreshSelectionUi();
  }

  function idsForSection(type) {
    var f = filterForAction();
    f.type = type;
    return R.selectAll(data, f, { includeRemovals: S.includeRemovals });
  }

  function toggleSection(type) {
    var ids = idsForSection(type);
    var all = ids.length > 0 && ids.every(function (id) { return S.selection[id]; });
    ids.forEach(function (id) { if (all) { delete S.selection[id]; } else if (!S.selection[id]) { S.selection[id] = { excluded: [] }; } });
    saveState();
    refreshSelectionUi();
  }

  function toggleItem(item, on) {
    if (on) { if (!S.selection[item.Id]) { S.selection[item.Id] = { excluded: [] }; } }
    else { delete S.selection[item.Id]; }
    saveState();
    refreshSelectionUi();
  }

  function toggleExcluded(item, property, on) {
    var entry = S.selection[item.Id];
    if (!entry) { return; }
    var index = entry.excluded.indexOf(property);
    if (on && index < 0) { entry.excluded.push(property); }
    if (!on && index >= 0) { entry.excluded.splice(index, 1); }
    saveState();
  }

  function diffTable(item) {
    var rows = item.Differences.map(function (d) {
      var box = h('input', { type: 'checkbox', 'aria-label': 'Keep ' + TGT + ' value of ' + d.Property, checked: !!(S.selection[item.Id] && S.selection[item.Id].excluded.indexOf(d.Property) >= 0),
        disabled: !S.selection[item.Id], title: S.selection[item.Id] ? 'Keep the ' + TGT + ' value for this property' : 'Select the item first',
        on: { change: function () { toggleExcluded(item, d.Property, box.checked); } } });
      box.dataset.itemId = item.Id;
      return h('tr', {}, [h('td', { text: d.Property }), h('td', { 'class': 'val', text: d.Dev }), h('td', { 'class': 'val', text: d.PreProd }), h('td', {}, [box])]);
    });
    return h('div', { 'class': 'diffwrap' }, [h('table', { 'class': 'diff' }, [
      h('thead', {}, [h('tr', {}, [h('th', { text: 'Property' }), h('th', { text: TGT + ' now' }), h('th', { text: SRC + ' (wanted)' }), h('th', { text: 'Keep ' + TGT + ' value' })])]),
      h('tbody', {}, rows)])]);
  }

  function renderRow(item) {
    var kind = item.Action || 'Cannot';
    var box = null;
    if (item.Approvable) {
      box = h('input', { type: 'checkbox', 'aria-label': 'Approve ' + item.Action + ' ' + item.Key, checked: !!S.selection[item.Id], disabled: isRemovalLocked(item),
        title: isRemovalLocked(item) ? 'Turn on "Include removals" to approve removals' : '', on: { change: function () { toggleItem(item, box.checked); } } });
      rowInputs[item.Id] = box;
    }
    var main = h('div', { 'class': 'row' }, [
      h('span', { 'class': 'pick' }, [box]),
      h('span', { 'class': 'badge ' + kind.toLowerCase(), text: item.Action || item.Kind }),
      h('span', { 'class': 'key', text: item.Key || '(no key)' }),
      item.Workload ? h('span', { 'class': 'muted wl', text: item.Workload }) : null
    ]);
    var wrapper = h('div', { 'class': 'item' }, [main]);
    if (!item.Approvable) {
      wrapper.appendChild(h('div', { 'class': 'reason', text: 'Cannot be approved: ' + item.Reason }));
    }
    if (item.Differences.length > 0) {
      var panel = null;
      var toggle = h('button', { type: 'button', 'class': 'link', 'aria-expanded': S.open[item.Id] ? 'true' : 'false',
        text: (S.open[item.Id] ? ARROW_OPEN : ARROW_CLOSED) + ' ' + item.Differences.length + ' difference' + (item.Differences.length === 1 ? '' : 's'),
        on: { click: function () {
          S.open[item.Id] = !S.open[item.Id];
          toggle.setAttribute('aria-expanded', S.open[item.Id] ? 'true' : 'false');
          toggle.textContent = (S.open[item.Id] ? ARROW_OPEN : ARROW_CLOSED) + ' ' + item.Differences.length + ' difference' + (item.Differences.length === 1 ? '' : 's');
          if (S.open[item.Id]) { panel = diffTable(item); wrapper.appendChild(panel); } else if (panel) { wrapper.removeChild(panel); panel = null; }
        } } });
      main.appendChild(toggle);
      if (S.open[item.Id]) { panel = diffTable(item); wrapper.appendChild(panel); }
    }
    return wrapper;
  }

  function renderSection(type) {
    var visible = visibleIn(type);
    var expanded = !!S.expanded[type];
    var count = h('span', { 'class': 'muted' });
    var box = h('input', { type: 'checkbox', 'aria-label': 'Select all shown in ' + type, on: { change: function () { toggleSection(type); } } });
    sectionRefs[type] = { count: count, box: box };
    var headButton = h('button', { type: 'button', 'class': 'shead-btn', 'aria-expanded': expanded ? 'true' : 'false',
      text: (expanded ? ARROW_OPEN : ARROW_CLOSED) + ' ' + type + ' (' + visible.length + (visible.length === itemsByType[type].length ? '' : ' of ' + itemsByType[type].length) + ')',
      on: { click: function () { S.expanded[type] = !S.expanded[type]; if (!S.shown[type]) { S.shown[type] = PAGE; } renderSections(); } } });
    var section = h('section', { 'class': 'section' }, [h('div', { 'class': 'shead' }, [box, headButton, count])]);
    if (expanded) {
      var limit = S.shown[type] || PAGE;
      var body = h('div', { 'class': 'sbody' });
      visible.slice(0, limit).forEach(function (item) { body.appendChild(renderRow(item)); });
      if (visible.length > limit) {
        body.appendChild(h('button', { type: 'button', 'class': 'btn more', text: 'Show more (' + (visible.length - limit) + ' left)',
          on: { click: function () { S.shown[type] = limit + PAGE; renderSections(); } } }));
      }
      if (visible.length === 0) { body.appendChild(h('p', { 'class': 'muted', text: 'Nothing matches the filters.' })); }
      section.appendChild(body);
    }
    return section;
  }

  function notComparedMatches(item) {
    var f = S.filter;
    if (f.kind && f.kind !== 'NotCompared') { return false; }
    if (f.type && item.ResourceType !== f.type) { return false; }
    if (f.text) {
      var hay = (item.ResourceType + ' ' + item.Key + ' ' + item.Reason).toLowerCase();
      if (hay.indexOf(f.text.toLowerCase()) < 0) { return false; }
    }
    return true;
  }

  // The things the comparison did not look at (out of scope, not checked, not in the export). Information only: no checkboxes.
  function renderNotCompared(list) {
    var expanded = S.filter.kind === 'NotCompared' || !!S.expanded.__notCompared;
    var head = h('button', { type: 'button', 'class': 'shead-btn', 'aria-expanded': expanded ? 'true' : 'false',
      text: (expanded ? ARROW_OPEN : ARROW_CLOSED) + ' Not compared (' + list.length + ')',
      on: { click: function () { S.expanded.__notCompared = !expanded; if (!S.shown.__notCompared) { S.shown.__notCompared = PAGE; } renderSections(); } } });
    var section = h('section', { 'class': 'section' }, [h('div', { 'class': 'shead' }, [h('span', { 'class': 'pick' }), head,
      h('span', { 'class': 'muted', text: 'information, not drift: nothing here can be approved' })])]);
    if (expanded) {
      var limit = S.shown.__notCompared || PAGE;
      var body = h('div', { 'class': 'sbody' });
      list.slice(0, limit).forEach(function (item) {
        body.appendChild(h('div', { 'class': 'item' }, [
          h('div', { 'class': 'row' }, [h('span', { 'class': 'pick' }), h('span', { 'class': 'badge cannot', text: item.Kind }),
            h('span', { 'class': 'key', text: item.ResourceType + (item.Key ? ' ' + item.Key : '') })]),
          h('div', { 'class': 'reason', text: item.Reason })]));
      });
      if (list.length > limit) {
        body.appendChild(h('button', { type: 'button', 'class': 'btn more', text: 'Show more (' + (list.length - limit) + ' left)',
          on: { click: function () { S.shown.__notCompared = limit + PAGE; renderSections(); } } }));
      }
      section.appendChild(body);
    }
    return section;
  }

  function renderSections() {
    rowInputs = {};
    sectionRefs = {};
    while (els.sections.firstChild) { els.sections.removeChild(els.sections.firstChild); }
    var shownTypes = types.filter(function (type) { return (!S.filter.type || S.filter.type === type) && visibleIn(type).length > 0; });
    var shownNotCompared = notCompared.filter(notComparedMatches);
    if (data.Items.length === 0) {
      els.sections.appendChild(h('p', { 'class': 'empty', text: 'No drift: ' + TGT + ' matches ' + SRC + ' for everything compared. Nothing to approve.' }));
    } else if (shownTypes.length === 0 && shownNotCompared.length === 0) {
      els.sections.appendChild(h('p', { 'class': 'empty', text: 'Nothing matches the filters.' }));
    }
    shownTypes.forEach(function (type) { els.sections.appendChild(renderSection(type)); });
    if (shownNotCompared.length > 0) { els.sections.appendChild(renderNotCompared(shownNotCompared)); }
    refreshSelectionUi();
  }

  function buildBar() {
    els.barLines = h('div', { 'class': 'lines' });
    els.reason = h('span', { 'class': 'why' });
    els.download = h('button', { type: 'button', 'class': 'btn primary', text: 'Download approved.json', on: { click: download } });
    return h('div', { 'class': 'bar', role: 'region', 'aria-label': 'Selection' }, [els.barLines, h('div', { 'class': 'bar-actions' }, [els.reason, els.download])]);
  }

  function refreshSelectionUi() {
    Object.keys(rowInputs).forEach(function (id) {
      rowInputs[id].checked = !!S.selection[id];
      rowInputs[id].disabled = isRemovalLocked(itemById[id]);
    });
    Object.keys(sectionRefs).forEach(function (type) {
      var ids = idsForSection(type);
      var chosen = ids.filter(function (id) { return S.selection[id]; }).length;
      var ref = sectionRefs[type];
      ref.box.checked = ids.length > 0 && chosen === ids.length;
      ref.box.indeterminate = chosen > 0 && chosen < ids.length;
      ref.box.disabled = ids.length === 0;
      ref.count.textContent = chosen > 0 ? chosen + ' selected' : '';
    });
    Array.prototype.forEach.call(document.querySelectorAll('input[data-item-id]'), function (input) {
      var entry = S.selection[input.dataset.itemId];
      input.disabled = !entry;
      input.title = entry ? 'Keep the ' + TGT + ' value for this property' : 'Select the item first';
      if (!entry) { input.checked = false; }
    });
    var summary = R.summarise(data, S.selection);
    while (els.barLines.firstChild) { els.barLines.removeChild(els.barLines.firstChild); }
    els.barLines.appendChild(h('strong', { text: summary.total + ' selected' }));
    summary.lines.forEach(function (line) { els.barLines.appendChild(h('span', { 'class': 'line', text: line })); });
    var why = R.whyNotDownloadable(data, S.selection, S.approvedBy, S.includeRemovals);
    els.download.disabled = why !== '';
    els.reason.textContent = why;
  }

  function download() {
    var list;
    try {
      list = R.buildApprovedList(data, S.selection, S.approvedBy, S.includeRemovals, new Date());
    } catch (error) {
      els.reason.textContent = String(error.message).replace(/^Cannot download: /, '');
      return;
    }
    var blob = new Blob([JSON.stringify(list, null, 2) + '\n'], { type: 'application/json' });
    var url = URL.createObjectURL(blob);
    var link = h('a', { href: url, download: 'approved.json' });
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    window.setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
  }

  loadState();
  els.sections = h('div', { 'class': 'sections' });
  app.textContent = '';
  app.appendChild(buildHeader());
  app.appendChild(buildControls());
  app.appendChild(els.sections);
  app.appendChild(buildBar());
  renderFilterState();
  renderSections();
}());
