import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const R = require('../../src/PolicyEngine/Data/DriftReport.js');

const item = (action, kind, type, key, extra = {}) => ({
  Id: `${action || kind}|${type}|${key}`, Action: action, Kind: kind, ResourceType: type, Key: key, Workload: 'ignored-here',
  Approvable: !!action, Reason: action ? '' : 'why', NotCompared: false, Differences: [], Props: [], ...extra,
});
const data = {
  Meta: {
    Tenant: 'replica', SourceLabel: 'master', TargetLabel: 'replica', ModuleVersion: '2.26.1021.1', ReportId: 'c'.repeat(64),
    WorkloadOrder: ['Entra ID', 'Intune', 'Exchange Online', 'Teams', 'Security and Compliance', 'Other'],
    Source: { Run: '1', ExportedAt: '2026-11-03T10:00:00Z', Fingerprint: 'a'.repeat(64) },
    Target: { Run: '2', ExportedAt: '2026-11-03T10:05:00Z', Fingerprint: 'b'.repeat(64) },
  },
  Totals: {},
  Types: [
    { ResourceType: 'AADGroup', Workload: 'Entra ID', Source: 100, Target: 98 },
    { ResourceType: 'AADUser', Workload: 'Entra ID', Source: 50, Target: 50 },
    { ResourceType: 'EXOAcceptedDomain', Workload: 'Exchange Online', Source: 3, Target: 2 },
    { ResourceType: 'TeamsChannelTab', Workload: 'Teams', Source: 0, Target: 0 },
  ],
  Items: [
    item('Create', 'Missing', 'AADGroup', 'Finance'),
    item('Create', 'Missing', 'AADGroup', 'HR'),
    item('Update', 'Changed', 'AADGroup', 'Sales', { Differences: [{ Property: 'MailNickname', Dev: 'a', PreProd: 'b' }] }),
    item('Remove', 'TargetOnly', 'AADGroup', 'Marketing'),
    item(null, 'Ambiguous', 'AADGroup', 'Dup'),
    item('Create', 'Missing', 'EXOAcceptedDomain', 'contoso.com'),
    item(null, 'NotChecked', 'TeamsChannelTab', '', { NotCompared: true }),
    item(null, 'Excluded', 'AADUser', '', { NotCompared: true }),
    item('Create', 'Missing', 'SomethingNew', 'x'),
  ],
};
const sel = (...ids) => Object.fromEntries(ids.map((i) => [i, { excluded: [] }]));

test('workloadOf takes the workload of the type from the report totals, and falls back to Other', () => {
  assert.equal(R.workloadOf(data, data.Items[0]), 'Entra ID');
  assert.equal(R.workloadOf(data, data.Items[5]), 'Exchange Online');
  assert.equal(R.workloadOf(data, data.Items[8]), 'Other');
});

test('the tree lists workloads in the engine order, with totals from the types', () => {
  const tree = R.workloadTree(data);
  assert.deepEqual(tree.map((w) => w.name), ['Entra ID', 'Exchange Online', 'Teams', 'Other']);
  const entra = tree[0];
  assert.equal(entra.source, 150);
  assert.equal(entra.target, 148);
  assert.deepEqual(entra.types.map((t) => t.ResourceType), ['AADGroup', 'AADUser']);
  assert.deepEqual(entra.counts, { Create: 2, Update: 1, Remove: 1, Cannot: 1, NotCompared: 1, Drift: 5 });
});

test('a type carries its own totals and only drift items; not-compared items are kept apart', () => {
  const group = R.workloadTree(data)[0].types[0];
  assert.equal(group.source, 100);
  assert.equal(group.target, 98);
  assert.equal(group.items.length, 5);
  assert.deepEqual(group.counts, { Create: 2, Update: 1, Remove: 1, Cannot: 1, NotCompared: 0, Drift: 5 });
  const user = R.workloadTree(data)[0].types[1];
  assert.equal(user.items.length, 0);
  assert.equal(user.notCompared.length, 1);
});

test('a type that is only in the items still gets a row', () => {
  const other = R.workloadTree(data).find((w) => w.name === 'Other');
  assert.deepEqual(other.types.map((t) => t.ResourceType), ['SomethingNew']);
  assert.equal(other.types[0].source, 0);
});

test('select all honours the workload filter', () => {
  const state = { includeRemovals: true };
  assert.deepEqual(R.selectAll(data, { workload: 'Exchange Online' }, state), ['Create|EXOAcceptedDomain|contoso.com']);
  assert.equal(R.selectAll(data, { workload: 'Entra ID' }, state).length, 4);
  assert.deepEqual(R.selectAll(data, { workload: 'Entra ID', type: 'AADGroup', kind: 'Update' }, state), ['Update|AADGroup|Sales']);
});

test('counts what is selected inside a workload or a type', () => {
  const selection = sel('Create|AADGroup|Finance', 'Update|AADGroup|Sales', 'Create|EXOAcceptedDomain|contoso.com');
  assert.equal(R.countSelected(data, selection, { workload: 'Entra ID' }), 2);
  assert.equal(R.countSelected(data, selection, { workload: 'Entra ID', type: 'AADGroup' }), 2);
  assert.equal(R.countSelected(data, selection, { type: 'EXOAcceptedDomain' }), 1);
  assert.equal(R.countSelected(data, {}, {}), 0);
});

test('routes round-trip, and anything unknown is the overview', () => {
  const routes = [
    { view: 'overview' },
    { view: 'review', workload: 'Entra ID', type: 'AADGroup', kind: 'Create', text: 'fin & co' },
    { view: 'review', workload: '', type: '', kind: '', text: '' },
    { view: 'item', id: 'Create|AADGroup|a/b?c#d' },
  ];
  routes.forEach((route) => assert.deepEqual(R.parseRoute(R.routeToHash(route)), route));
  assert.deepEqual(R.parseRoute(''), { view: 'overview' });
  assert.deepEqual(R.parseRoute('#/nonsense'), { view: 'overview' });
  assert.deepEqual(R.parseRoute('#/item/'), { view: 'overview' });
  assert.deepEqual(R.parseRoute('#/review?kind=Bogus&workload=x'), { view: 'review', workload: 'x', type: '', kind: '', text: '' });
});

test('kind labels use plain words and the names of the two sides', () => {
  assert.equal(R.kindLabel('Create', 'master', 'replica'), 'Missing in replica');
  assert.equal(R.kindLabel('Update', 'master', 'replica'), 'Different');
  assert.equal(R.kindLabel('Remove', 'master', 'replica'), 'Only in replica');
  assert.equal(R.kindLabel(null, 'master', 'replica'), 'Cannot be approved');
});

test('properties are ordered: different first, same last, names A to Z inside a group', () => {
  const props = [
    { Property: 'Zeta', State: 'same' }, { Property: 'beta', State: 'different' }, { Property: 'Alpha', State: 'same' },
    { Property: 'Gamma', State: 'only-source' }, { Property: 'Delta', State: 'ignored' }, { Property: 'Alpha2', State: 'different' },
    { Property: 'Eps', State: 'excluded' }, { Property: 'Only', State: 'only-target' },
  ];
  assert.deepEqual(R.orderProps(props).map((p) => p.Property), ['Alpha2', 'beta', 'Eps', 'Delta', 'Gamma', 'Only', 'Alpha', 'Zeta']);
  assert.equal(props[0].Property, 'Zeta', 'the input is not changed');
});
