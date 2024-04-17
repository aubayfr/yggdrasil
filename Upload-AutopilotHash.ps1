<#
.SYNOPSIS
    This script will upload the hardware hash of the device to the Microsoft Autopilot service.

.DESCRIPTION
    The script will generate a hardware hash using the OA3Tool and upload it to the Microsoft Autopilot service.
    The script will also wait for the device to be imported into the Microsoft Autopilot service.

    This script is intended to be run in WinPE.

    To connect to the Microsoft Graph API, the script requires the following information:
    - Tenant ID
    - Application ID
    - Application Secret
    This information should be stored in a config.json file in the same directory as the script.

    Greatly inspired from : 
    - https://mikemdm.de/2023/01/29/can-you-create-a-autopilot-hash-from-winpe-yes/
    - https://mikemdm.de/2023/09/10/modern-os-provisioning-for-windows-autopilot-using-osdcloud/
    - https://github.com/mmeierm/Scripts/blob/main/OSDCloud_helpers/OSDCloud_UploadAutopilot.ps1
    - https://www.powershellgallery.com/packages/WindowsAutoPilotIntune
#>

$ProjectRoot = "X:\OSDCloud\Config" 

#region Connect to Autopilot
$provider = Get-PackageProvider NuGet -ErrorAction Ignore
if (-not $provider) {
    Write-Host "Installing provider NuGet"
    Find-PackageProvider -Name NuGet -ForceBootstrap -IncludeDependencies
}

$module = Import-Module WindowsAutopilotIntune -PassThru -ErrorAction Ignore
if (-not $module) {
    Write-Host "Installing module WindowsAutopilotIntune"
    Install-Module WindowsAutopilotIntune -Force -SkipPublisherCheck
}
Import-Module WindowsAutopilotIntune -Scope Global

if (-not (Test-Path "$ProjectRoot/config.json")) {
    Write-Host "Please create a config.json file in the $ProjectRoot directory. See README.md for more information."
    Read-Host "Press any key to exit"
    Exit 1
}
$Credentials = Get-Content "$ProjectRoot/config.json" | ConvertFrom-Json

$SecureString = ConvertTo-SecureString -String $Credentials.appSecret -AsPlainText -Force
$ClientSecretCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $Credentials.appID, $SecureString
Connect-MgGraph -TenantId $Credentials.tenantID -ClientSecretCredential $ClientSecretCredential
#endregion

#region Generating Hash
#Create the ConfigFiles for OA3Tool
$inputxml=@' 
<?xml version="1.0"?>
  <Key>
    <ProductKey>XXXXX-XXXXX-XXXXX-XXXXX-XXXXX</ProductKey>
    <ProductKeyID>0000000000000</ProductKeyID>  
    <ProductKeyState>0</ProductKeyState>
  </Key>
'@

$oa3cft=@' 
<OA3>
   <FileBased>
       <InputKeyXMLFile>".\input.XML"</InputKeyXMLFile>
   </FileBased>
   <OutputData>
<AssembledBinaryFile>.\OA3.bin</AssembledBinaryFile>
<ReportedXMLFile>.\OA3.xml</ReportedXMLFile>
   </OutputData>
</OA3>
'@

If(!(Test-Path $ProjectRoot\input.xml))
{
    New-Item "$ProjectRoot\input.xml" -ItemType File -Value $inputxml
}
If(!(Test-Path $ProjectRoot\OA3.cfg))
{
    New-Item "$ProjectRoot\OA3.cfg" -ItemType File -Value $oa3cft
}

$serial = (Get-WmiObject -Class Win32_BIOS).SerialNumber
#endregion

#region Gather the AutoPilot Hash information
#################Start WinPE TPM Fix###################
If(Test-Path X:\Windows\System32\wpeutil.exe)
{
Copy-Item "$ProjectRoot\PCPKsp.dll" "X:\Windows\System32\PCPKsp.dll"
#Register PCPKsp
rundll32 X:\Windows\System32\PCPKsp.dll,DllInstall
}
#################End WinPE TPM Fix###################

#Run OA3Tool
start-process "$ProjectRoot\oa3tool.exe" -workingdirectory $ProjectRoot -argumentlist "/Report /ConfigFile=$ProjectRoot\OA3.cfg /NoKeyCheck" -wait

#Read Hash from generated XML File
[xml]$xmlhash = Get-Content -Path "$ProjectRoot\OA3.xml"
$hash=$xmlhash.Key.HardwareHash
#endregion

#region Upload Hash to AutoPilot
# Add the devices
$importStart = Get-Date
$imported = @()
$imported = Add-AutopilotImportedDevice -serialNumber $serial -hardwareIdentifier $Hash # -groupTag $_.'Group Tag' -assignedUser $_.'Assigned User'

# Wait until the devices have been imported
$processingCount = 1
while ($processingCount -gt 0)
{
    $current = @()
    $processingCount = 0
    $imported | % {
        $device = Get-AutopilotImportedDevice -id $_.id
        if ($device.state.deviceImportStatus -eq "unknown") {
            $processingCount = $processingCount + 1
        }
        $current += $device
    }
    $deviceCount = $imported.Length
    Write-Host "Waiting for $processingCount of $deviceCount to be imported"
    if ($processingCount -gt 0){
        Start-Sleep 30
    }
}
$importDuration = (Get-Date) - $importStart
$importSeconds = [Math]::Ceiling($importDuration.TotalSeconds)
$successCount = 0
$current | % {
    Write-Host "$($device.serialNumber): $($device.state.deviceImportStatus) $($device.state.deviceErrorCode) $($device.state.deviceErrorName)"
    if ($device.state.deviceImportStatus -eq "complete") {
        $successCount = $successCount + 1
    }
}
Write-Host "$successCount devices imported successfully. Elapsed time to complete import: $importSeconds seconds"
#endregion
