@{
    # Where each published standard comes from: the one place that knows a source. Repository is cloned (sparse, one tag), DscPath is the
    # folder of DSC configuration files inside it, the rest is what Import-PEStandard records (the licence needs the attribution).
    asd = @{
        Repository  = 'https://github.com/ASD-Blueprint/ASD-Blueprint-for-Secure-Cloud.git'
        Url         = 'https://github.com/ASD-Blueprint/ASD-Blueprint-for-Secure-Cloud'
        DscPath     = 'static/content/files/automation/dsc'
        SourceName  = 'ASD Blueprint for Secure Cloud'
        Attribution = 'ASD Blueprint for Secure Cloud, Australian Signals Directorate, CC BY 4.0'
    }
}
