// Builds an approved list with the page's own code and writes it to the path given as the first argument.
// Used by tests/DriftReportJs.Tests.ps1 to prove that PowerShell's Read-PEApprovedList accepts what the browser produces.
import { createRequire } from 'node:module';
import { writeFileSync } from 'node:fs';

const require = createRequire(import.meta.url);
const R = require('../../src/PolicyEngine/Data/DriftReport.js');

const item = (action, type, key, differences = []) => ({
  Id: `${action}|${type}|${key}`, Action: action, Kind: 'x', ResourceType: type, Key: key, Workload: 'w',
  Approvable: true, Reason: '', Differences: differences,
});
const data = {
  Meta: {
    Tenant: 'dev', ModuleVersion: '2.26.1104.1', GeneratedUtc: '2026-11-03T11:00:00Z', ReportId: 'c'.repeat(64),
    Source: { Run: '101', ExportedAt: '2026-11-03T10:00:00Z', Fingerprint: 'a'.repeat(64) },
    Target: { Run: '102', ExportedAt: '2026-11-03T10:05:00Z', Fingerprint: 'b'.repeat(64) },
  },
  Totals: {},
  Items: [
    item('Create', 'AADGroup', 'Finance'),
    item('Update', 'AADGroup', 'Sales', [{ Property: 'MailNickname', Dev: 'a', PreProd: 'b' }, { Property: 'Description', Dev: 'a', PreProd: 'b' }]),
    item('Remove', 'AADGroup', 'Marketing'),
    item('Create', 'AADGroupLifecyclePolicy', 'Default'),
    item('Create', 'EXOAcceptedDomain', 'contoso.com'),
    item('Create', 'aadLowerCaseType', 'x'),
    item('Create', 'AADGroup', 'Ünïcode "quoted" key'),
  ],
};
const selection = Object.fromEntries(data.Items.map((i) => [i.Id, { excluded: i.Id === 'Update|AADGroup|Sales' ? ['MailNickname'] : [] }]));
const list = R.buildApprovedList(data, selection, 'andrew', true, new Date('2026-11-03T12:00:00Z'));
writeFileSync(process.argv[2], JSON.stringify(list, null, 2) + '\n', 'utf8');
