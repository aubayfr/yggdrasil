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

    Blocking errors are thrown so that the calling script (Install-Windows*.ps1) can log them and stop the deployment.

    Greatly inspired from :
    - https://mikemdm.de/2023/01/29/can-you-create-a-autopilot-hash-from-winpe-yes/
    - https://mikemdm.de/2023/09/10/modern-os-provisioning-for-windows-autopilot-using-osdcloud/
    - https://github.com/mmeierm/Scripts/blob/main/OSDCloud_helpers/OSDCloud_UploadAutopilot.ps1
    - https://www.powershellgallery.com/packages/WindowsAutoPilotIntune
#>

$ProjectRoot = "X:\OSDCloud\Config"

# Write-Log is defined by Install-Windows*.ps1, define a fallback when this script is run alone
if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    function Write-Log {
        param(
            [string]$Message,
            [ValidateSet('Info', 'Warning', 'Error')][string]$Level = 'Info'
        )
        $Line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
        switch ($Level) {
            'Error' { Write-Host -ForegroundColor Red $Line }
            'Warning' { Write-Host -ForegroundColor Yellow $Line }
            default { Write-Host $Line }
        }
    }
}

#region Connect to Autopilot
$provider = Get-PackageProvider NuGet -ErrorAction Ignore
if (-not $provider) {
    Write-Log "Installing provider NuGet"
    Find-PackageProvider -Name NuGet -ForceBootstrap -IncludeDependencies -ErrorAction Stop | Out-Null
}

$module = Import-Module WindowsAutopilotIntune -PassThru -ErrorAction Ignore
if (-not $module) {
    Write-Log "Installing module WindowsAutopilotIntune"
    Install-Module WindowsAutopilotIntune -Force -SkipPublisherCheck -ErrorAction Stop
}
Import-Module WindowsAutopilotIntune -Scope Global -ErrorAction Stop
Write-Log "WindowsAutopilotIntune module version: $((Get-Module WindowsAutopilotIntune).Version)"

if (-not (Test-Path "$ProjectRoot/config.json")) {
    throw "$ProjectRoot/config.json not found. Please create it (see README.md), e.g. by running Prepare-OSDCloudEnv.ps1."
}
$Credentials = Get-Content "$ProjectRoot/config.json" -ErrorAction Stop | ConvertFrom-Json
foreach ($Key in 'tenantID', 'appID', 'appSecret') {
    if (-not $Credentials.$Key) {
        throw "'$Key' is missing in $ProjectRoot/config.json."
    }
}

Write-Log "Connecting to Microsoft Graph (tenant: $($Credentials.tenantID), application: $($Credentials.appID))"
$SecureString = ConvertTo-SecureString -String $Credentials.appSecret -AsPlainText -Force
$ClientSecretCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $Credentials.appID, $SecureString
try {
    Connect-MgGraph -TenantId $Credentials.tenantID -ClientSecretCredential $ClientSecretCredential -ErrorAction Stop
}
catch {
    throw "Unable to connect to Microsoft Graph (check tenant ID, application ID, secret expiration and WinPE date/time: $(Get-Date)): $($_.Exception.Message)"
}
Write-Log "Connected to Microsoft Graph"
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
    New-Item "$ProjectRoot\input.xml" -ItemType File -Value $inputxml | Out-Null
}
If(!(Test-Path $ProjectRoot\OA3.cfg))
{
    New-Item "$ProjectRoot\OA3.cfg" -ItemType File -Value $oa3cft | Out-Null
}

$serial = (Get-WmiObject -Class Win32_BIOS).SerialNumber
if (-not $serial) {
    throw "Unable to read the BIOS serial number."
}
Write-Log "Serial number: $serial"
#endregion

#region Gather the AutoPilot Hash information
#################Start WinPE TPM Fix###################
If(Test-Path X:\Windows\System32\wpeutil.exe)
{
Write-Log "Registering PCPKsp.dll (WinPE TPM fix)"
Copy-Item "$ProjectRoot\PCPKsp.dll" "X:\Windows\System32\PCPKsp.dll" -ErrorAction Stop
#Register PCPKsp
rundll32 X:\Windows\System32\PCPKsp.dll,DllInstall
}
#################End WinPE TPM Fix###################

#Run OA3Tool
if (-not (Test-Path "$ProjectRoot\oa3tool.exe")) {
    throw "$ProjectRoot\oa3tool.exe not found. Run Prepare-OSDCloudEnv.ps1 to copy it from the Windows ADK."
}
Write-Log "Running OA3Tool"
Remove-Item "$ProjectRoot\OA3.xml" -Force -ErrorAction SilentlyContinue
$oa3 = start-process "$ProjectRoot\oa3tool.exe" -workingdirectory $ProjectRoot -argumentlist "/Report /ConfigFile=$ProjectRoot\OA3.cfg /NoKeyCheck" -wait -PassThru
if ($oa3.ExitCode -ne 0) {
    Write-Log -Level Warning "OA3Tool exited with code $($oa3.ExitCode)"
}
if (-not (Test-Path "$ProjectRoot\OA3.xml")) {
    throw "OA3Tool did not generate $ProjectRoot\OA3.xml (exit code: $($oa3.ExitCode))."
}

#Read Hash from generated XML File
[xml]$xmlhash = Get-Content -Path "$ProjectRoot\OA3.xml"
$hash=$xmlhash.Key.HardwareHash
if (-not $hash) {
    throw "The hardware hash is empty in $ProjectRoot\OA3.xml (TPM not ready / PCPKsp.dll not registered?)."
}
Write-Log "Hardware hash generated ($($hash.Length) characters)"
#endregion

#region Upload Hash to AutoPilot
# Add the devices
Write-Log "Uploading hardware hash to Autopilot"
$importStart = Get-Date
$imported = @()
$imported = Add-AutopilotImportedDevice -serialNumber $serial -hardwareIdentifier $Hash -ErrorAction Stop # -groupTag $_.'Group Tag' -assignedUser $_.'Assigned User'
if (-not $imported) {
    throw "Add-AutopilotImportedDevice returned no device for serial $serial."
}

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
    Write-Log "Waiting for $processingCount of $deviceCount to be imported ($([Math]::Ceiling(((Get-Date) - $importStart).TotalSeconds)) seconds elapsed)"
    if ($processingCount -gt 0){
        Start-Sleep 30
    }
}
$importDuration = (Get-Date) - $importStart
$importSeconds = [Math]::Ceiling($importDuration.TotalSeconds)
$successCount = 0
$current | % {
    if ($_.state.deviceImportStatus -eq "complete") {
        Write-Log "$($_.serialNumber): $($_.state.deviceImportStatus)"
        $successCount = $successCount + 1
    }
    else {
        # e.g. 806 / ZtdDeviceAlreadyAssigned when the device is already registered
        Write-Log -Level Warning "$($_.serialNumber): $($_.state.deviceImportStatus) $($_.state.deviceErrorCode) $($_.state.deviceErrorName)"
    }
}
Write-Log "$successCount devices imported successfully. Elapsed time to complete import: $importSeconds seconds"
#endregion
