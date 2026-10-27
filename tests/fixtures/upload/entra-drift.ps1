# Generated with Microsoft365DSC version 2.26.1021.1
# For additional information on how to use Microsoft365DSC, please visit https://aka.ms/M365DSC
param (
)

Configuration Entra
{
    param (
    )

    $OrganizationName = $ConfigurationData.NonNodeData.OrganizationName

    Import-DscResource -ModuleName 'Microsoft365DSC' -ModuleVersion '2.26.1021.1'

    Node localhost
    {
        AADGroup "AADGroup-Sales"
        {
            ApplicationId         = $ConfigurationData.NonNodeData.ApplicationId;
            CertificateThumbprint = $ConfigurationData.NonNodeData.CertificateThumbprint;
            DisplayName           = "Sales";
            Ensure                = "Present";
            Id                    = "11111111-1111-1111-1111-111111111111";
            MailEnabled           = $False;
            MailNickname          = "sales-renamed-alias";
            SecurityEnabled       = $True;
            TenantId              = $ConfigurationData.NonNodeData.TenantId;
        }
        AADGroup "AADGroup-Marketing"
        {
            ApplicationId         = $ConfigurationData.NonNodeData.ApplicationId;
            CertificateThumbprint = $ConfigurationData.NonNodeData.CertificateThumbprint;
            DisplayName           = "Marketing";
            Ensure                = "Present";
            Id                    = "33333333-3333-3333-3333-333333333333";
            MailEnabled           = $False;
            MailNickname          = "marketing";
            SecurityEnabled       = $True;
            TenantId              = $ConfigurationData.NonNodeData.TenantId;
        }
    }
}

Entra -ConfigurationData .\ConfigurationData.psd1
