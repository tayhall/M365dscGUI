/* Drift report page. Part 2: the user interface. Needs DriftReport.js (PEReport) above it. Runs only in a browser.
   Three screens, chosen by the address after # so the back button and shared links work:
     #/                                  Overview: totals, then one row per workload
     #/review?workload=&type=&kind=&q=   Review: workload > resource type > item, each level collapsible and selectable
     #/item/<id>                         One resource: every property of the two exports side by side
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

  var SRC = data.Meta.SourceLabel || 'PreProd';
  var TGT = data.Meta.TargetLabel || 'Dev';
  var ARROW_CLOSED = String.fromCharCode(0x25b8);
  var ARROW_OPEN = String.fromCharCode(0x25be);
  var ARROW_TO = String.fromCharCode(0x2192);
  var DOT = ' ' + String.fromCharCode(0xb7) + ' ';
  var STORE_KEY = 'pe-drift-report:' + data.Meta.ReportId;
  var KIND_CHIPS = ['Create', 'Update', 'Remove', 'Cannot', 'NotCompared'];

  // ---- state ---------------------------------------------------------------------------------------------------------------------
  var S = {
    selection: {},
    approvedBy: '',
    includeRemovals: false,
    filter: { workload: '', type: '', kind: '', text: '' },
    openW: {},       // workload name -> true / false (absent: the default)
    openT: {},       // resource type -> true / false
    shown: {},       // resource type -> rows rendered
    propView: ''     // '' (decide per item) | 'differences' | 'all'
  };
  var tree = R.workloadTree(data);
  var itemById = {};
  data.Items.forEach(function (item) { itemById[item.Id] = item; });
  var typeNodes = {};
  var workloadNodes = {};
  tree.forEach(function (w) { workloadNodes[w.name] = w; w.types.forEach(function (t) { typeNodes[t.ResourceType] = t; }); });

  // ---- persistence (only a convenience: the page works without it) -----------------------------------------------------------------
  function loadState() {
    try {
      var saved = JSON.parse(window.localStorage.getItem(STORE_KEY) || 'null');
      if (!saved || typeof saved !== 'object') { return; }
      S.approvedBy = typeof saved.approvedBy === 'string' ? saved.approvedBy.slice(0, 100) : '';
      S.includeRemovals = saved.includeRemovals === true;
      var selection = saved.selection && typeof saved.selection === 'object' ? saved.selection : {};
      Object.keys(selection).forEach(function (id) {
        var item = itemById[id];
        if (!item || !item.Approvable || !selection[id]) { return; }
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

  // ---- small DOM helper: strings are always text ----------------------------------------------------------------------------------
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

  function clear(node) { while (node.firstChild) { node.removeChild(node.firstChild); } }
  function link(route, text, cls) { return h('a', { href: R.routeToHash(route), 'class': cls || 'lnk', text: text }); }
  function plural(n, one, many) { return n + ' ' + (n === 1 ? one : many); }
  function label(action) { return R.kindLabel(action, SRC, TGT); }

  // ---- shared pieces -------------------------------------------------------------------------------------------------------------
  var els = {};
  var rowInputs = {};     // item id -> checkbox on the page
  var groupRefs = [];     // header checkboxes: { box, count, extra }
  var overviewSel = {};   // workload -> "selected" cell
  var itemBox = null;
  var OVERVIEW = { view: 'overview' };

  function reviewRoute(extra) {
    var r = { view: 'review', workload: '', type: '', kind: '', text: '' };
    Object.keys(extra || {}).forEach(function (key) { r[key] = extra[key]; });
    return r;
  }

  function isRemovalLocked(item) { return item.Action === 'Remove' && !S.includeRemovals; }

  // The filter for "select all": kinds that have no checkboxes (Cannot, Not compared) select nothing.
  function filterForSelect(extra) {
    var f = S.filter;
    var kind = (f.kind === 'Cannot' || f.kind === 'NotCompared') ? '__none__' : f.kind;
    var out = { workload: f.workload, type: f.type, kind: kind, text: f.text };
    Object.keys(extra || {}).forEach(function (key) { out[key] = extra[key]; });
    return out;
  }

  function idsFor(extra) { return R.selectAll(data, filterForSelect(extra), { includeRemovals: S.includeRemovals }); }

  function setSelected(ids, on) {
    ids.forEach(function (id) { if (on) { if (!S.selection[id]) { S.selection[id] = { excluded: [] }; } } else { delete S.selection[id]; } });
    saveState();
    refreshSelectionUi();
  }

  function toggleGroup(extra) {
    var ids = idsFor(extra);
    var all = ids.length > 0 && ids.every(function (id) { return S.selection[id]; });
    setSelected(ids, !all);
  }

  function toggleExcluded(item, property, on) {
    var entry = S.selection[item.Id];
    if (!entry) { return; }
    var index = entry.excluded.indexOf(property);
    if (on && index < 0) { entry.excluded.push(property); }
    if (!on && index >= 0) { entry.excluded.splice(index, 1); }
    saveState();
  }

  function setIncludeRemovals(on) {
    S.includeRemovals = on;
    if (!on) {
      Object.keys(S.selection).forEach(function (id) { if (itemById[id] && itemById[id].Action === 'Remove') { delete S.selection[id]; } });
    }
    saveState();
    render(true);
  }

  function groupBox(extra, countNode) {
    var box = h('input', { type: 'checkbox', 'aria-label': 'Select all shown in ' + (extra.type || extra.workload) });
    box.addEventListener('change', function () { toggleGroup(extra); });
    groupRefs.push({ box: box, count: countNode, extra: extra });
    return box;
  }

  function chips(counts) {
    var out = [];
    [['Create', 'create'], ['Update', 'update'], ['Remove', 'remove'], ['Cannot', 'cannot']].forEach(function (pair) {
      if (counts[pair[0]] > 0) {
        out.push(h('span', { 'class': 'chip-n ' + pair[1], text: counts[pair[0]] + ' ' + (pair[0] === 'Cannot' ? 'cannot approve' : label(pair[0]).toLowerCase()) }));
      }
    });
    return out;
  }

  // ---- screen frame: top bar, crumbs ---------------------------------------------------------------------------------------------
  function buildTop() {
    els.tabOverview = h('a', { href: R.routeToHash(OVERVIEW), 'class': 'tab', text: 'Overview' });
    els.tabReview = h('a', { href: R.routeToHash(reviewRoute({})), 'class': 'tab', text: 'Review' });
    return h('header', { 'class': 'top' }, [
      h('span', { 'class': 'brand', text: 'Drift report' }),
      h('nav', { 'class': 'tabs', 'aria-label': 'Screens' }, [els.tabOverview, els.tabReview]),
      h('span', { 'class': 'direction', text: SRC + ' ' + ARROW_TO + ' ' + TGT })
    ]);
  }

  function crumbs(list) {
    var nodes = [];
    list.forEach(function (entry, i) {
      if (i > 0) { nodes.push(h('span', { 'class': 'sep', text: '/' })); }
      nodes.push(entry.route ? link(entry.route, entry.text, 'crumb') : h('span', { 'class': 'crumbcur', text: entry.text }));
    });
    return h('nav', { 'class': 'crumbs', 'aria-label': 'Breadcrumb' }, nodes);
  }

  // ---- Overview --------------------------------------------------------------------------------------------------------------------
  function statCard(title, value, cls, route) {
    var inner = [h('div', { 'class': 'num ' + (cls || ''), text: String(value) }), h('div', { 'class': 'lbl', text: title })];
    return route ? h('a', { href: R.routeToHash(route), 'class': 'card linkcard' }, inner) : h('div', { 'class': 'card' }, inner);
  }

  function numberCell(value, route) {
    return h('td', { 'class': 'n' }, [value > 0 ? link(route, String(value)) : h('span', { 'class': 'zero', text: '0' })]);
  }

  function viewOverview() {
    var t = data.Totals;
    var m = data.Meta;
    var wrap = h('div', {}, [
      h('h1', { text: 'Overview' }),
      h('p', { 'class': 'muted', text: SRC + ' compared with ' + TGT + '. ' + SRC + ' export: run ' + m.Source.Run + ', ' + m.Source.ExportedAt + '. ' + TGT + ' export: run ' + m.Target.Run + ', ' + m.Target.ExportedAt + '. Generated ' + m.GeneratedUtc + '. Microsoft365DSC ' + m.ModuleVersion + '.' }),
      h('div', { 'class': 'cards' }, [
        statCard('Total', t.Total), statCard('Matching', t.Matching, 'good'),
        statCard(label('Create'), t.Create, 'create', reviewRoute({ kind: 'Create' })),
        statCard(label('Update'), t.Update, 'update', reviewRoute({ kind: 'Update' })),
        statCard(label('Remove'), t.Remove, 'remove', reviewRoute({ kind: 'Remove' })),
        statCard('Cannot be approved', t.CannotApprove, 'cannot', reviewRoute({ kind: 'Cannot' })),
        statCard('Not compared', t.NotCompared || 0, 'cannot', reviewRoute({ kind: 'NotCompared' }))
      ])
    ]);

    var head = h('tr', {}, ['Workload', SRC + ' records', TGT + ' records', label('Create'), label('Update'), label('Remove'), 'Cannot approve', 'Not compared', 'Selected']
      .map(function (title, i) { return h('th', { 'class': i === 0 ? '' : 'n', text: title }); }));
    var body = tree.map(function (w) {
      var c = w.counts;
      var sel = h('td', { 'class': 'n', text: '0' });
      overviewSel[w.name] = sel;
      return h('tr', {}, [
        h('td', {}, [link(reviewRoute({ workload: w.name }), w.name), h('span', { 'class': 'muted small', text: '  ' + plural(w.types.length, 'type', 'types') })]),
        h('td', { 'class': 'n', text: String(w.source) }), h('td', { 'class': 'n', text: String(w.target) }),
        numberCell(c.Create, reviewRoute({ workload: w.name, kind: 'Create' })), numberCell(c.Update, reviewRoute({ workload: w.name, kind: 'Update' })),
        numberCell(c.Remove, reviewRoute({ workload: w.name, kind: 'Remove' })), numberCell(c.Cannot, reviewRoute({ workload: w.name, kind: 'Cannot' })),
        numberCell(c.NotCompared, reviewRoute({ workload: w.name, kind: 'NotCompared' })), sel
      ]);
    });
    var all = tree.reduce(function (acc, w) { acc.source += w.source; acc.target += w.target; return acc; }, { source: 0, target: 0 });
    body.push(h('tr', { 'class': 'total' }, [h('td', { text: 'All workloads' }), h('td', { 'class': 'n', text: String(all.source) }), h('td', { 'class': 'n', text: String(all.target) }),
      h('td', { 'class': 'n', text: String(t.Create) }), h('td', { 'class': 'n', text: String(t.Update) }), h('td', { 'class': 'n', text: String(t.Remove) }),
      h('td', { 'class': 'n', text: String(t.CannotApprove) }), h('td', { 'class': 'n', text: String(t.NotCompared || 0) }), h('td', { 'class': 'n', text: '' })]));

    wrap.appendChild(h('section', { 'class': 'panel' }, [
      h('h2', { text: 'By workload' }),
      h('p', { 'class': 'muted', text: 'Pick a workload or a number to review the resource types and items behind it. Matching resources are only counted.' }),
      h('div', { 'class': 'tablewrap' }, [h('table', { 'class': 'grid' }, [h('thead', {}, [head]), h('tbody', {}, body)])])
    ]));
    if (data.Items.length === 0) {
      wrap.appendChild(h('p', { 'class': 'empty', text: 'No drift: ' + TGT + ' matches ' + SRC + ' for everything compared. Nothing to approve.' }));
    }
    return wrap;
  }

  // ---- Review ----------------------------------------------------------------------------------------------------------------------
  function visibleItems(node) {
    var f = S.filter;
    var list;
    if (f.kind === 'NotCompared') { list = node.notCompared; }
    else if (f.kind === 'Cannot') { list = node.items.filter(function (i) { return !i.Approvable; }); }
    else if (f.kind) { list = node.items.filter(function (i) { return i.Action === f.kind; }); }
    else { list = node.items; }
    if (f.text) {
      var needle = f.text.toLowerCase();
      list = list.filter(function (i) { return (String(i.Key) + ' ' + (f.kind === 'NotCompared' ? i.Reason : '')).toLowerCase().indexOf(needle) >= 0; });
    }
    return list;
  }

  function isOpenW(name) { return S.openW[name] !== undefined ? S.openW[name] : !!S.filter.workload; }
  function isOpenT(type) { return S.openT[type] !== undefined ? S.openT[type] : !!S.filter.type; }

  function itemRow(item) {
    var box = null;
    if (item.Approvable) {
      box = h('input', { type: 'checkbox', 'aria-label': 'Approve ' + item.Action + ' ' + item.Key, checked: !!S.selection[item.Id], disabled: isRemovalLocked(item),
        title: isRemovalLocked(item) ? 'Turn on "Include removals" to approve removals' : '' });
      box.addEventListener('change', function () { setSelected([item.Id], box.checked); });
      rowInputs[item.Id] = box;
    }
    var kind = item.NotCompared ? 'cannot' : (item.Action || 'cannot').toLowerCase();
    var changed = item.Differences.slice(0, 3).map(function (d) { return d.Property; }).join(', ') + (item.Differences.length > 3 ? ', +' + (item.Differences.length - 3) : '');
    var line = h('div', { 'class': 'row' }, [
      h('span', { 'class': 'pick' }, [box]),
      h('span', { 'class': 'badge ' + kind, text: item.NotCompared ? item.Kind : label(item.Action) }),
      h('span', { 'class': 'key', text: item.Key ? item.Key : (item.NotCompared ? '(whole type)' : '(no key)') }),
      item.Differences.length ? h('span', { 'class': 'muted small', text: 'differs: ' + changed }) : null,
      item.Props && item.Props.length ? link({ view: 'item', id: item.Id }, 'Details', 'lnk detail') : null
    ]);
    var node = h('div', { 'class': 'item' }, [line]);
    if (!item.Approvable) { node.appendChild(h('div', { 'class': 'reason', text: (item.NotCompared ? '' : 'Cannot be approved: ') + item.Reason })); }
    return node;
  }

  function typeSection(typeNode, items) {
    var open = isOpenT(typeNode.ResourceType);
    var count = h('span', { 'class': 'selcount' });
    var head = h('div', { 'class': 'thead' }, [
      h('span', { 'class': 'pick' }, [S.filter.kind === 'NotCompared' ? null : groupBox({ type: typeNode.ResourceType }, count)]),
      h('button', { type: 'button', 'class': 'toggle', 'aria-expanded': open ? 'true' : 'false', text: (open ? ARROW_OPEN : ARROW_CLOSED) + ' ' + typeNode.ResourceType,
        on: { click: function () { S.openT[typeNode.ResourceType] = !open; if (!S.shown[typeNode.ResourceType]) { S.shown[typeNode.ResourceType] = PAGE; } renderTree(); } } }),
      h('span', { 'class': 'totals', text: SRC + ' ' + typeNode.source + DOT + TGT + ' ' + typeNode.target + DOT + typeNode.counts.Drift + ' drifted' })
    ].concat(chips(typeNode.counts)).concat([count]));
    var section = h('div', { 'class': 'type' }, [head]);
    if (open) {
      var limit = S.shown[typeNode.ResourceType] || PAGE;
      var body = h('div', { 'class': 'tbody' });
      items.slice(0, limit).forEach(function (item) { body.appendChild(itemRow(item)); });
      if (items.length > limit) {
        body.appendChild(h('button', { type: 'button', 'class': 'btn more', text: 'Show more (' + (items.length - limit) + ' left)',
          on: { click: function () { S.shown[typeNode.ResourceType] = limit + PAGE; renderTree(); } } }));
      }
      section.appendChild(body);
    }
    return section;
  }

  function workloadSection(node, visible) {
    var open = isOpenW(node.name);
    var count = h('span', { 'class': 'selcount' });
    var head = h('div', { 'class': 'whead' }, [
      h('span', { 'class': 'pick' }, [S.filter.kind === 'NotCompared' ? null : groupBox({ workload: node.name }, count)]),
      h('button', { type: 'button', 'class': 'toggle wname', 'aria-expanded': open ? 'true' : 'false', text: (open ? ARROW_OPEN : ARROW_CLOSED) + ' ' + node.name,
        on: { click: function () { S.openW[node.name] = !open; renderTree(); } } }),
      h('span', { 'class': 'totals', text: SRC + ' ' + node.source + DOT + TGT + ' ' + node.target + DOT + plural(node.types.length, 'type', 'types') })
    ].concat(chips(node.counts)).concat([count]));
    var section = h('section', { 'class': 'workload' }, [head]);
    if (open) {
      var body = h('div', { 'class': 'wbody' });
      visible.forEach(function (entry) { body.appendChild(typeSection(entry.node, entry.items)); });
      section.appendChild(body);
    }
    return section;
  }

  function renderTree() {
    rowInputs = {};
    groupRefs = [];
    clear(els.tree);
    var f = S.filter;
    var shownWorkloads = 0;
    tree.forEach(function (w) {
      if (f.workload && w.name !== f.workload) { return; }
      var visible = [];
      w.types.forEach(function (t) {
        if (f.type && t.ResourceType !== f.type) { return; }
        var items = visibleItems(t);
        if (items.length > 0) { visible.push({ node: t, items: items }); }
      });
      if (visible.length === 0) { return; }
      shownWorkloads += 1;
      els.tree.appendChild(workloadSection(w, visible));
    });
    if (shownWorkloads === 0) {
      els.tree.appendChild(h('p', { 'class': 'empty', text: data.Items.length === 0 ? 'No drift: ' + TGT + ' matches ' + SRC + ' for everything compared. Nothing to approve.' : 'Nothing matches the filters.' }));
    }
    refreshSelectionUi();
  }

  function navigateFilter(extra) {
    var next = reviewRoute({ workload: S.filter.workload, type: S.filter.type, kind: S.filter.kind, text: S.filter.text });
    Object.keys(extra).forEach(function (key) { next[key] = extra[key]; });
    window.location.hash = R.routeToHash(next);
  }

  function buildControls() {
    var workloadSelect = h('select', { 'aria-label': 'Workload', on: { change: function () { navigateFilter({ workload: workloadSelect.value, type: '' }); } } },
      [h('option', { value: '', text: 'All workloads' })].concat(tree.map(function (w) { return h('option', { value: w.name, text: w.name + ' (' + w.counts.Drift + ' drifted)' }); })));
    workloadSelect.value = S.filter.workload;
    var typesForSelect = [];
    tree.forEach(function (w) {
      if (!S.filter.workload || w.name === S.filter.workload) {
        w.types.forEach(function (t) { if (t.counts.Drift + t.counts.NotCompared > 0) { typesForSelect.push(t); } });
      }
    });
    var typeSelect = h('select', { 'aria-label': 'Resource type', on: { change: function () { navigateFilter({ type: typeSelect.value }); } } },
      [h('option', { value: '', text: 'All resource types' })].concat(typesForSelect.map(function (t) { return h('option', { value: t.ResourceType, text: t.ResourceType + ' (' + (t.counts.Drift + t.counts.NotCompared) + ')' }); })));
    typeSelect.value = S.filter.type;
    var search = h('input', { type: 'search', placeholder: 'Search keys', 'aria-label': 'Search keys', value: S.filter.text });
    search.addEventListener('input', function () { S.filter.text = search.value; renderTree(); });
    var kindButtons = KIND_CHIPS.map(function (kind) {
      var text = kind === 'Cannot' ? 'Cannot be approved' : kind === 'NotCompared' ? 'Not compared' : label(kind);
      return h('button', { type: 'button', 'class': 'chip', 'aria-pressed': S.filter.kind === kind ? 'true' : 'false', text: text,
        on: { click: function () { navigateFilter({ kind: S.filter.kind === kind ? '' : kind }); } } });
    });
    var removals = h('input', { type: 'checkbox', checked: S.includeRemovals });
    removals.addEventListener('change', function () { setIncludeRemovals(removals.checked); });
    var approvedBy = h('input', { type: 'text', maxlength: '100', value: S.approvedBy, placeholder: 'Your name', 'aria-label': 'Approved by' });
    approvedBy.addEventListener('input', function () { S.approvedBy = approvedBy.value; saveState(); refreshSelectionUi(); });
    var setAll = function (open) {
      tree.forEach(function (w) {
        S.openW[w.name] = open;
        w.types.forEach(function (t) { S.openT[t.ResourceType] = open; if (!S.shown[t.ResourceType]) { S.shown[t.ResourceType] = PAGE; } });
      });
      renderTree();
    };
    return h('div', { 'class': 'controls' }, [
      h('div', { 'class': 'row-controls' }, [workloadSelect, typeSelect, search].concat(kindButtons)),
      h('div', { 'class': 'row-controls' }, [
        h('button', { type: 'button', 'class': 'btn', text: 'Select all shown', on: { click: function () { setSelected(idsFor({}), true); } } }),
        h('button', { type: 'button', 'class': 'btn', text: 'Clear selection', on: { click: function () { S.selection = {}; saveState(); refreshSelectionUi(); } } }),
        h('button', { type: 'button', 'class': 'btn', text: 'Expand all', on: { click: function () { setAll(true); } } }),
        h('button', { type: 'button', 'class': 'btn', text: 'Collapse all', on: { click: function () { setAll(false); } } }),
        h('label', { 'class': 'inline' }, [removals, ' Include removals']),
        h('label', { 'class': 'inline' }, ['Approved by ', approvedBy])
      ])
    ]);
  }

  function viewReview() {
    var wrap = h('div', {});
    var trail = [{ text: 'Overview', route: OVERVIEW }, { text: 'Review', route: S.filter.workload || S.filter.type ? reviewRoute({}) : null }];
    if (S.filter.workload) { trail.push({ text: S.filter.workload, route: S.filter.type ? reviewRoute({ workload: S.filter.workload }) : null }); }
    if (S.filter.type) { trail.push({ text: S.filter.type }); }
    wrap.appendChild(crumbs(trail));
    wrap.appendChild(h('h1', { text: 'Review' }));
    wrap.appendChild(h('p', { 'class': 'muted', text: 'Open a workload, then a resource type, and tick what to apply. Open Details on an item to see every property of both exports.' }));
    wrap.appendChild(buildControls());
    els.tree = h('div', { 'class': 'tree' });
    wrap.appendChild(els.tree);
    return wrap;
  }

  // ---- One resource ----------------------------------------------------------------------------------------------------------------
  function propertyRows(item, mode) {
    var rows = R.orderProps(item.Props).filter(function (p) { return mode === 'all' || (p.State !== 'same' && p.State !== 'ignored'); });
    var canExclude = item.Approvable && item.Action === 'Update';
    return rows.map(function (p) {
      var cells = [
        h('td', { 'class': 'pname', text: p.Property }),
        p.Source === null ? h('td', { 'class': 'val absent', text: '(not present)' }) : h('td', { 'class': 'val', text: p.Source }),
        p.Target === null ? h('td', { 'class': 'val absent', text: '(not present)' }) : h('td', { 'class': 'val', text: p.Target }),
        h('td', {}, [h('span', { 'class': 'state ' + p.State, text: p.State === 'only-source' ? 'only in ' + SRC : p.State === 'only-target' ? 'only in ' + TGT : p.State })])
      ];
      if (canExclude) {
        var cell = h('td', {});
        if (p.State === 'different') {
          var box = h('input', { type: 'checkbox', 'aria-label': 'Keep ' + TGT + ' value of ' + p.Property, checked: !!(S.selection[item.Id] && S.selection[item.Id].excluded.indexOf(p.Property) >= 0),
            disabled: !S.selection[item.Id], title: S.selection[item.Id] ? 'Keep the ' + TGT + ' value for this property' : 'Select the item first' });
          box.dataset.itemId = item.Id;
          box.addEventListener('change', function () { toggleExcluded(item, p.Property, box.checked); });
          cell.appendChild(box);
        }
        cells.push(cell);
      }
      return h('tr', { 'class': 'p-' + p.State }, cells);
    });
  }

  function viewItem(item) {
    var wl = R.workloadOf(data, item);
    var trail = [{ text: 'Overview', route: OVERVIEW }, { text: 'Review', route: reviewRoute({}) }, { text: wl, route: reviewRoute({ workload: wl }) },
      { text: item.ResourceType, route: reviewRoute({ workload: wl, type: item.ResourceType }) }, { text: item.Key || '(no key)' }];
    var wrap = h('div', {}, [crumbs(trail)]);
    wrap.appendChild(h('h1', { 'class': 'mono-title', text: item.Key || item.ResourceType }));
    var kindClass = item.NotCompared ? 'cannot' : (item.Action || 'cannot').toLowerCase();
    var status = [h('span', { 'class': 'badge ' + kindClass, text: item.NotCompared ? item.Kind : label(item.Action) }), h('span', { 'class': 'muted', text: item.ResourceType + DOT + wl })];
    if (item.Approvable) {
      itemBox = h('input', { type: 'checkbox', 'aria-label': 'Approve ' + item.Action + ' ' + item.Key, checked: !!S.selection[item.Id], disabled: isRemovalLocked(item) });
      itemBox.addEventListener('change', function () { setSelected([item.Id], itemBox.checked); });
      status.push(h('label', { 'class': 'inline' }, [itemBox, ' Approve this ' + item.Action.toLowerCase() + (isRemovalLocked(item) ? ' (turn on "Include removals" in Review first)' : '')]));
    }
    wrap.appendChild(h('div', { 'class': 'status' }, status));
    if (!item.Approvable) { wrap.appendChild(h('p', { 'class': 'reason', text: (item.NotCompared ? '' : 'Cannot be approved: ') + item.Reason })); }

    var what = item.Action === 'Create' ? 'This resource exists in ' + SRC + ' but not in ' + TGT + '. Approving it creates it in ' + TGT + ' with these properties.'
      : item.Action === 'Remove' ? 'This resource exists in ' + TGT + ' but not in ' + SRC + '. Approving it removes it from ' + TGT + '.'
      : item.Action === 'Update' ? 'Both exports have this resource. Approving it sets the ' + TGT + ' resource to the ' + SRC + ' definition, except properties you keep.' : '';
    if (what) { wrap.appendChild(h('p', { 'class': 'muted', text: what })); }

    var differing = item.Props.filter(function (p) { return p.State !== 'same' && p.State !== 'ignored'; }).length;
    var mode = S.propView || (differing > 0 ? 'differences' : 'all');
    var panel = h('section', { 'class': 'panel' });
    var switcher = h('div', { 'class': 'switch' }, [
      h('button', { type: 'button', 'class': 'sw' + (mode === 'differences' ? ' on' : ''), text: 'Differences (' + differing + ')', on: { click: function () { S.propView = 'differences'; render(true); } } }),
      h('button', { type: 'button', 'class': 'sw' + (mode === 'all' ? ' on' : ''), text: 'All properties (' + item.Props.length + ')', on: { click: function () { S.propView = 'all'; render(true); } } })
    ]);
    panel.appendChild(h('div', { 'class': 'panelhead' }, [h('h2', { text: 'Properties' }), switcher]));
    if (item.Props.length === 0) {
      panel.appendChild(h('p', { 'class': 'muted', text: 'This item has no property list.' }));
    } else {
      var canExclude = item.Approvable && item.Action === 'Update';
      var headings = ['Property', SRC, TGT, 'State'].concat(canExclude ? ['Keep ' + TGT + ' value'] : []);
      var rows = propertyRows(item, mode);
      panel.appendChild(h('div', { 'class': 'tablewrap' }, [h('table', { 'class': 'grid props' }, [
        h('thead', {}, [h('tr', {}, headings.map(function (title) { return h('th', { text: title }); }))]),
        h('tbody', {}, rows)])]));
      if (rows.length === 0) { panel.appendChild(h('p', { 'class': 'muted', text: 'No properties differ.' })); }
    }
    wrap.appendChild(panel);
    return wrap;
  }

  // ---- selection bar and refresh -------------------------------------------------------------------------------------------------
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
    groupRefs.forEach(function (ref) {
      var ids = idsFor(ref.extra);
      var chosen = ids.filter(function (id) { return S.selection[id]; }).length;
      ref.box.checked = ids.length > 0 && chosen === ids.length;
      ref.box.indeterminate = chosen > 0 && chosen < ids.length;
      ref.box.disabled = ids.length === 0;
      ref.count.textContent = chosen > 0 ? chosen + ' selected' : '';
    });
    if (itemBox && itemBox.isConnected) {
      var current = R.parseRoute(window.location.hash);
      var shown = current.view === 'item' ? itemById[current.id] : null;
      if (shown) { itemBox.checked = !!S.selection[shown.Id]; itemBox.disabled = isRemovalLocked(shown); }
    }
    Object.keys(overviewSel).forEach(function (name) { overviewSel[name].textContent = String(R.countSelected(data, S.selection, { workload: name })); });
    Array.prototype.forEach.call(document.querySelectorAll('input[data-item-id]'), function (input) {
      var entry = S.selection[input.dataset.itemId];
      input.disabled = !entry;
      input.title = entry ? 'Keep the ' + TGT + ' value for this property' : 'Select the item first';
      if (!entry) { input.checked = false; }
    });
    var summary = R.summarise(data, S.selection);
    clear(els.barLines);
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
    var anchor = h('a', { href: url, download: 'approved.json' });
    document.body.appendChild(anchor);
    anchor.click();
    document.body.removeChild(anchor);
    window.setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
  }

  // ---- routing ---------------------------------------------------------------------------------------------------------------------
  var lastHash = null;

  function render(keepScroll) {
    var route = R.parseRoute(window.location.hash);
    if (route.view === 'item' && !itemById[route.id]) { route = OVERVIEW; }
    if (route.view === 'review') {
      S.filter = {
        workload: workloadNodes[route.workload] ? route.workload : '',
        type: typeNodes[route.type] ? route.type : '',
        kind: route.kind,
        text: route.text
      };
    }
    els.tabOverview.setAttribute('aria-current', route.view === 'overview' ? 'page' : 'false');
    els.tabReview.setAttribute('aria-current', route.view !== 'overview' ? 'page' : 'false');
    rowInputs = {};
    groupRefs = [];
    overviewSel = {};
    itemBox = null;
    clear(els.main);
    if (route.view === 'overview') { els.main.appendChild(viewOverview()); }
    else if (route.view === 'review') { els.main.appendChild(viewReview()); renderTree(); }
    else { els.main.appendChild(viewItem(itemById[route.id])); }
    refreshSelectionUi();
    var hash = window.location.hash;
    if (!keepScroll && hash !== lastHash) { window.scrollTo(0, 0); }
    lastHash = hash;
  }

  loadState();
  els.main = h('main', { id: 'main' });
  app.textContent = '';
  app.appendChild(buildTop());
  app.appendChild(els.main);
  app.appendChild(buildBar());
  window.addEventListener('hashchange', function () { S.propView = ''; render(false); });
  render(true);
}());
