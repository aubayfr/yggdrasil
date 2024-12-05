<#
.SYNOPSIS
Deployments of Windows 11 Autopilot/Intune ready with OSDCloud

.DESCRIPTION
This script is used to deploy Windows 11 with OSDCloud.
It will automatically register the device in Autopilot (Intune).
#>

#region Prepare the environment
if ((Get-MyComputerModel) -match 'Virtual') {
    Write-Host -ForegroundColor DarkMagenta "Setting display response to 1024x"
    Set-DisRes 1920
}

if (-not (Get-InstalledModule -Name 'OSD' -ErrorAction SilentlyContinue)) {
    Install-Module -Name OSD -Force
    Import-Module OSD
}
#endregion

#region Autopilot registration
Invoke-RestMethod https://raw.githubusercontent.com/n4kama/yggdrasil/master/Upload-AutopilotHash.ps1 | Invoke-Expression
#endregion

#region Start-OSDCloud configuration
$OSDCloudParameters = @{
    OSVersion = "Windows 11"
    OSBuild = "24H2"
    OSEdition = "Enterprise"
    OSLanguage = "pt-pt"
    OSLicense = "Volume"
    ZTI = $true
}
Start-OSDCloud @OSDCloudParameters
#endregion

#region Restart Computer
Write-Host -ForegroundColor DarkMagenta "Restarting in 10 seconds..."
Start-Sleep -Seconds 10
wpeutil reboot
#endregion
