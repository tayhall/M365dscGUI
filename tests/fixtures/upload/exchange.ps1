# Generated with Microsoft365DSC version 2.26.1021.1
# For additional information on how to use Microsoft365DSC, please visit https://aka.ms/M365DSC
param (
)

Configuration Exchange
{
    param (
    )

    $OrganizationName = $ConfigurationData.NonNodeData.OrganizationName

    Import-DscResource -ModuleName 'Microsoft365DSC' -ModuleVersion '2.26.1021.1'

    Node localhost
    {
        EXOAcceptedDomain "EXOAcceptedDomain-contoso.example"
        {
            ApplicationId         = $ConfigurationData.NonNodeData.ApplicationId;
            CertificateThumbprint = $ConfigurationData.NonNodeData.CertificateThumbprint;
            DomainType            = "Authoritative";
            Ensure                = "Present";
            Identity              = "$OrganizationName";
            MatchSubDomains       = $False;
            OutboundOnly          = $False;
            TenantId              = $ConfigurationData.NonNodeData.TenantId;
        }
    }
}

Exchange -ConfigurationData .\ConfigurationData.psd1
