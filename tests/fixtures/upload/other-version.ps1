# Generated with Microsoft365DSC version 1.26.422.1
# For additional information on how to use Microsoft365DSC, please visit https://aka.ms/M365DSC
param (
)

Configuration Entra
{
    param (
    )

    $OrganizationName = $ConfigurationData.NonNodeData.OrganizationName

    Import-DscResource -ModuleName 'Microsoft365DSC' -ModuleVersion '1.26.422.1'

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
            MailNickname          = "x";
            SecurityEnabled       = $True;
            TenantId              = $ConfigurationData.NonNodeData.TenantId;
        }
        AADGroup "AADGroup-Finance"
        {
            ApplicationId         = $ConfigurationData.NonNodeData.ApplicationId;
            CertificateThumbprint = $ConfigurationData.NonNodeData.CertificateThumbprint;
            DisplayName           = "Finance";
            Ensure                = "Present";
            Id                    = "22222222-2222-2222-2222-222222222222";
            MailEnabled           = $False;
            MailNickname          = "x";
            SecurityEnabled       = $True;
            TenantId              = $ConfigurationData.NonNodeData.TenantId;
        }
    }
}

Entra -ConfigurationData .\ConfigurationData.psd1
