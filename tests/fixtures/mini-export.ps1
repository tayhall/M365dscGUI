# Invented sample in the layout of a Microsoft365DSC export. No real tenant data.
param (
)

Configuration mini-export
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
            Members               = @("a@x.com");
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
            Members               = @("a@x.com");
            SecurityEnabled       = $True;
            TenantId              = $ConfigurationData.NonNodeData.TenantId;
        }
        AADGroup "AADGroup-Finance_2"
        {
            ApplicationId         = $ConfigurationData.NonNodeData.ApplicationId;
            CertificateThumbprint = $ConfigurationData.NonNodeData.CertificateThumbprint;
            DisplayName           = "Finance";
            Ensure                = "Present";
            Id                    = "33333333-3333-3333-3333-333333333333";
            MailEnabled           = $False;
            Members               = @("a@x.com");
            SecurityEnabled       = $True;
            TenantId              = $ConfigurationData.NonNodeData.TenantId;
        }
        AADConditionalAccessPolicy "AADConditionalAccessPolicy-Require_MFA"
        {
            ApplicationId         = $ConfigurationData.NonNodeData.ApplicationId;
            BuiltInControls       = @("mfa");
            CertificateThumbprint = $ConfigurationData.NonNodeData.CertificateThumbprint;
            DisplayName           = "Require MFA";
            Ensure                = "Present";
            Id                    = "44444444-4444-4444-4444-444444444444";
            IncludeUsers          = @("All");
            SessionControls       = MSFT_Nested{
                IsEnabled = $True
                Name = "inner"
            };
            State                 = "enabled";
            TenantId              = $ConfigurationData.NonNodeData.TenantId;
        }
    }
}

mini-export -ConfigurationData .\ConfigurationData.psd1
