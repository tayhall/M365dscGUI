import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const R = require('../../src/PolicyEngine/Data/DriftReport.js');

const FP = 'a'.repeat(64);
const data = {
  Meta: {
    Tenant: 'dev',
    Source: { Run: '101', ExportedAt: '2026-11-03T10:00:00Z', Fingerprint: FP },
    Target: { Run: '102', ExportedAt: '2026-11-03T10:05:00Z', Fingerprint: 'b'.repeat(64) },
    ModuleVersion: '2.26.1021.1',
    GeneratedUtc: '2026-11-03T11:00:00Z',
    ReportId: 'c'.repeat(64),
  },
  Totals: { Total: 10, Matching: 4, Create: 3, Update: 1, Remove: 1, CannotApprove: 1 },
  Items: [
    { Id: 'Create|AADGroup|Finance', Action: 'Create', Kind: 'Missing', ResourceType: 'AADGroup', Key: 'Finance', Workload: 'Entra ID', Approvable: true, Reason: '', Differences: [] },
    { Id: 'Create|AADGroup|HR', Action: 'Create', Kind: 'Missing', ResourceType: 'AADGroup', Key: 'HR', Workload: 'Entra ID', Approvable: true, Reason: '', Differences: [] },
    { Id: 'Remove|AADGroup|Marketing', Action: 'Remove', Kind: 'TargetOnly', ResourceType: 'AADGroup', Key: 'Marketing', Workload: 'Entra ID', Approvable: true, Reason: '', Differences: [] },
    { Id: 'Update|AADGroup|Sales', Action: 'Update', Kind: 'Changed', ResourceType: 'AADGroup', Key: 'Sales', Workload: 'Entra ID', Approvable: true, Reason: '',
      Differences: [{ Property: 'MailNickname', Dev: 'sales1', PreProd: 'sales' }, { Property: 'Description', Dev: 'a', PreProd: 'b' }] },
    { Id: 'Create|EXOAcceptedDomain|contoso.com', Action: 'Create', Kind: 'Missing', ResourceType: 'EXOAcceptedDomain', Key: 'contoso.com', Workload: 'Exchange', Approvable: true, Reason: '', Differences: [] },
    { Id: 'Ambiguous|AADGroup|Dup', Action: null, Kind: 'Ambiguous', ResourceType: 'AADGroup', Key: 'Dup', Workload: 'Entra ID', Approvable: false, Reason: 'Key matches 2 blueprint and 2 target records', Differences: [] },
  ],
};
const now = new Date('2026-11-03T12:00:00Z');
const sel = (...ids) => Object.fromEntries(ids.map((i) => [i, { excluded: [] }]));
const build = (selection, by = 'andrew', removals = false) => R.buildApprovedList(data, selection, by, removals, now);

test('builds the exact approved list shape', () => {
  const list = build({ ...sel('Create|AADGroup|Finance'), 'Update|AADGroup|Sales': { excluded: ['MailNickname'] } });
  assert.deepEqual(Object.keys(list), ['Format', 'CreatedUtc', 'ApprovedBy', 'Tenant', 'ModuleVersion', 'Source', 'Target', 'Items', 'Counts']);
  assert.equal(list.Format, 1);
  assert.equal(list.CreatedUtc, '2026-11-03T12:00:00Z');
  assert.equal(list.Tenant, 'dev');
  assert.deepEqual(Object.keys(list.Source), ['Run', 'ExportedAt', 'Fingerprint']);
  assert.deepEqual(Object.keys(list.Items[0]), ['Action', 'ResourceType', 'Key', 'ExcludedProperties']);
  assert.deepEqual(list.Items[1].ExcludedProperties, ['MailNickname']);
  assert.deepEqual(list.Items[0].ExcludedProperties, []);
});

test('counts per type and action', () => {
  const list = build(sel('Create|AADGroup|Finance', 'Create|AADGroup|HR', 'Update|AADGroup|Sales', 'Create|EXOAcceptedDomain|contoso.com'));
  assert.deepEqual(list.Counts, [
    { ResourceType: 'AADGroup', Action: 'Create', Count: 2 },
    { ResourceType: 'AADGroup', Action: 'Update', Count: 1 },
    { ResourceType: 'EXOAcceptedDomain', Action: 'Create', Count: 1 },
  ]);
});

test('refuses an empty selection', () => {
  assert.throws(() => build({}), /^Error: Cannot download:.*nothing selected/i);
});

test('refuses a missing or overlong or control-character approver', () => {
  const one = sel('Create|AADGroup|Finance');
  assert.throws(() => build(one, ''), /Cannot download:.*Approved by/);
  assert.throws(() => build(one, '   '), /Cannot download:.*Approved by/);
  assert.throws(() => build(one, 'x'.repeat(101)), /Cannot download:.*Approved by/);
  assert.throws(() => build(one, 'bad\nname'), /Cannot download:.*Approved by/);
});

test('refuses a non-approvable item even if it is in the selection', () => {
  assert.throws(() => build(sel('Ambiguous|AADGroup|Dup')), /Cannot download:.*cannot be approved/);
});

test('refuses an id that is not in the report', () => {
  assert.throws(() => build(sel('Create|AADGroup|Nope')), /Cannot download:.*not in this report/);
});

test('refuses a Remove while removals are off, accepts it when on', () => {
  assert.throws(() => build(sel('Remove|AADGroup|Marketing')), /Cannot download:.*Include removals/);
  const list = build(sel('Remove|AADGroup|Marketing'), 'andrew', true);
  assert.equal(list.Items[0].Action, 'Remove');
});

test('refuses a key with a newline, an empty key or an overlong key', () => {
  for (const key of ['a\nb', '', 'k'.repeat(501)]) {
    const bad = { ...data, Items: [{ ...data.Items[0], Id: 'Create|AADGroup|x', Key: key }] };
    assert.throws(() => R.buildApprovedList(bad, sel('Create|AADGroup|x'), 'andrew', false, now), /Cannot download:.*key/i);
  }
});

test('refuses an excluded property that is not one of the differences', () => {
  assert.throws(() => build({ 'Update|AADGroup|Sales': { excluded: ['Nope'] } }), /Cannot download:.*excluded property/i);
  assert.throws(() => build({ 'Create|AADGroup|Finance': { excluded: ['X'] } }), /Cannot download:.*excluded property/i);
});

test('select all skips non-approvable and, with removals off, Remove items', () => {
  const ids = R.selectAll(data, {}, { includeRemovals: false });
  assert.ok(!ids.includes('Ambiguous|AADGroup|Dup'));
  assert.ok(!ids.includes('Remove|AADGroup|Marketing'));
  assert.equal(ids.length, 4);
  assert.ok(R.selectAll(data, {}, { includeRemovals: true }).includes('Remove|AADGroup|Marketing'));
});

test('select all honours type, kind and text filters', () => {
  const state = { includeRemovals: true };
  assert.deepEqual(R.selectAll(data, { type: 'EXOAcceptedDomain' }, state), ['Create|EXOAcceptedDomain|contoso.com']);
  assert.deepEqual(R.selectAll(data, { type: 'AADGroup', kind: 'Update' }, state), ['Update|AADGroup|Sales']);
  assert.deepEqual(R.selectAll(data, { text: 'fin' }, state), ['Create|AADGroup|Finance']);
});

test('summary lines match the format Create 10 AADGroup', () => {
  const s = R.summarise(data, sel('Create|AADGroup|Finance', 'Create|AADGroup|HR', 'Update|AADGroup|Sales', 'Create|EXOAcceptedDomain|contoso.com'));
  assert.deepEqual(s.lines, ['Create 2 AADGroup', 'Update 1 AADGroup', 'Create 1 EXOAcceptedDomain']);
  assert.equal(s.total, 4);
});

test('describes why a download is not possible', () => {
  assert.match(R.whyNotDownloadable(data, {}, 'andrew', false), /nothing selected/i);
  assert.match(R.whyNotDownloadable(data, sel('Create|AADGroup|Finance'), '', false), /Approved by/);
  assert.equal(R.whyNotDownloadable(data, sel('Create|AADGroup|Finance'), 'andrew', false), '');
});

test('refuses two items whose Action, type and key differ only in letter case (the list format compares them case-insensitively)', () => {
  const bad = { ...data, Items: [
    { ...data.Items[0], Id: 'Create|AADGroup|Finance', Key: 'Finance' },
    { ...data.Items[0], Id: 'Create|AADGroup|finance', Key: 'finance' },
  ] };
  const both = { 'Create|AADGroup|Finance': { excluded: [] }, 'Create|AADGroup|finance': { excluded: [] } };
  assert.throws(() => R.buildApprovedList(bad, both, 'andrew', false, now), /Cannot download:.*twice|Cannot download:.*same/i);
});

test('select all with the Cannot-be-approved kind selects nothing', () => {
  assert.deepEqual(R.selectAll(data, { kind: 'Cannot' }, { includeRemovals: true }), []);
});
