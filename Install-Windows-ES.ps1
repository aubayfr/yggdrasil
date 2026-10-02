<#
.SYNOPSIS
Deployments of Windows 11 Autopilot/Intune ready with OSDCloud

.DESCRIPTION
This script is used to deploy Windows 11 with OSDCloud.
It will automatically register the device in Autopilot (Intune).

A transcript is written to X:\OSDCloud\Logs and copied to C:\OSDCloud\Logs (X:\ is lost on reboot).
On error, the computer is NOT restarted so the error can be read on screen.
#>

#region Logging
$Serial = (Get-WmiObject -Class Win32_BIOS).SerialNumber
$LogFile = "X:\OSDCloud\Logs\Install-Windows_$($Serial)_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
New-Item -Path (Split-Path $LogFile) -ItemType Directory -Force | Out-Null
Start-Transcript -Path $LogFile -Append | Out-Null

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Level = 'Info'
    )
    $Line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    switch ($Level) {
        'Error' { Write-Host -ForegroundColor Red $Line }
        'Warning' { Write-Host -ForegroundColor Yellow $Line }
        default { Write-Host -ForegroundColor DarkMagenta $Line }
    }
}

function Save-Log {
    # X:\ is a RAM disk, copy the transcript to the local disk so it survives the reboot
    Stop-Transcript | Out-Null
    if (Test-Path 'C:\') {
        New-Item -Path 'C:\OSDCloud\Logs' -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        Copy-Item -Path $LogFile -Destination 'C:\OSDCloud\Logs' -Force -ErrorAction SilentlyContinue
    }
}
#endregion

$Success = $false
try {
    Write-Log "Starting deployment - Model: $(Get-MyComputerModel) - Serial: $Serial"

    #region Prepare the environment
    if ((Get-MyComputerModel) -match 'Virtual') {
        Write-Log "Setting display response to 1024x"
        Set-DisRes 1920
    }

    if (-not (Get-InstalledModule -Name 'OSD' -ErrorAction SilentlyContinue)) {
        Write-Log "Installing OSD module"
        Install-Module -Name OSD -Force -ErrorAction Stop
        Import-Module OSD -ErrorAction Stop
    }
    Write-Log "OSD module version: $((Get-Module -Name OSD -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1).Version)"
    #endregion

    #region Autopilot registration
    Write-Log "Starting Autopilot registration"
    Invoke-RestMethod https://raw.githubusercontent.com/aubayfr/yggdrasil/refs/heads/master/Upload-AutopilotHash.ps1 -ErrorAction Stop | Invoke-Expression
    Write-Log "Autopilot registration finished"
    #endregion

    #region Start-OSDCloud configuration
    $OSDCloudParameters = @{
        OSVersion = "Windows 11"
        OSBuild = "25H2"
        OSEdition = "Enterprise"
        OSLanguage = "es-es"
        OSLicense = "Volume"
        ZTI = $true
    }
    Write-Log "Starting OSDCloud: $(($OSDCloudParameters.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"
    Start-OSDCloud @OSDCloudParameters

    if (-not (Test-Path 'C:\Windows\System32')) {
        throw "Windows was not applied to C:\ by OSDCloud. See OSDCloud logs in C:\OSDCloud\Logs (if present)."
    }
    Write-Log "OSDCloud finished"
    #endregion

    $Success = $true
}
catch {
    Write-Log -Level Error "Deployment failed: $($_.Exception.Message)"
    Write-Log -Level Error "Location: $($_.InvocationInfo.PositionMessage)"
    Write-Log -Level Error "Stack trace: $($_.ScriptStackTrace)"
}
finally {
    if ($Error.Count -gt 0) {
        Write-Log -Level Warning "$($Error.Count) error(s) recorded during the session:"
        $Error | Select-Object -First 20 | ForEach-Object { Write-Log -Level Warning "  $($_.Exception.Message)" }
    }
    Save-Log
}

#region Restart Computer
if ($Success) {
    Write-Log "Restarting in 10 seconds..."
    Start-Sleep -Seconds 10
    wpeutil reboot
}
else {
    Write-Log -Level Error "The computer will NOT restart. Log file: $LogFile (copied to C:\OSDCloud\Logs if the disk is available)"
    Read-Host "Press Enter to return to the shell"
}
#endregion
