@{
    # The workloads this engine supports: the DSC resource-name prefix (Microsoft365DSC names every resource <Workload><Name>),
    # the label shown in results and the GUI, and whether a check exports it by default. This is our scope choice, not a copy of
    # DSC's workload list: a resource whose name starts with none of these is reported as 'Other'. Security and Compliance (SC)
    # is supported for checking (apps, permissions, scope checks) but is not part of the default full export.
    # OwnProcess: Microsoft365DSC reads every component of one export in one process, and Security and Compliance cannot share it:
    # after an Entra or Intune (Graph) component its connection fails, and before a Teams component Teams fails to load (see
    # docs\handover.md, 'Why Security and Compliance reads fail'). Such a workload is exported by a second process and merged.
    Workloads = @(
        @{ Prefix = 'AAD'; Name = 'Entra ID'; Default = $true }
        @{ Prefix = 'Intune'; Name = 'Intune'; Default = $true }
        @{ Prefix = 'EXO'; Name = 'Exchange Online'; Default = $true }
        @{ Prefix = 'Teams'; Name = 'Teams'; Default = $true }
        @{ Prefix = 'SC'; Name = 'Security and Compliance'; Default = $false; OwnProcess = $true }
    )
}
