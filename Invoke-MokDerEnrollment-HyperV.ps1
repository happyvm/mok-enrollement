<#
.SYNOPSIS
  Imports DER certificates into MOK on Hyper-V Linux guests.

.DESCRIPTION
  Hyper-V equivalent of the VMware flow:
  - Validates local .der files
  - Copies files to the Linux guest over SCP
  - Executes mokutil --import over SSH
  - Reboots the VM from the host
  - Optionally sends keyboard scan codes via Hyper-V WMI to drive MOKManager

.NOTES
  Prerequisites:
  - Hyper-V PowerShell module on host
  - OpenSSH client on host (ssh/scp)
  - SSH server reachable in the Linux guest
  - UEFI Secure Boot enabled in guest
  - mokutil installed in guest
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [string]$DerFolder,

    [Parameter(Mandatory = $true)]
    [string]$GuestAddress,

    [Parameter(Mandatory = $true)]
    [string]$GuestUser,

    [string]$SshPrivateKeyPath,

    [string]$GuestDestination = '/var/tmp/mok-import',

    [ValidateSet('AutoMokManager', 'ManualMenu', 'SkipMokManager')]
    [string]$MokAutomationMode = 'ManualMenu',

    [int]$KeyDelayMs = 250,

    [int]$ScreenDelaySeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-BashLiteral {
    param([Parameter(Mandatory = $true)][string]$Text)
    "'" + $Text.Replace("'", "'\\''") + "'"
}

function Get-DerFiles {
    param([Parameter(Mandatory = $true)][string]$Folder)

    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
        throw "DerFolder not found or is not a directory: $Folder"
    }

    $files = @(Get-ChildItem -LiteralPath $Folder -Filter '*.der' -File |
            Sort-Object Name |
            Select-Object -ExpandProperty FullName)

    if ($files.Count -eq 0) {
        throw "No .der files found in: $Folder"
    }

    return $files
}

function Get-OptionalSshKeyArgs {
    if ([string]::IsNullOrWhiteSpace($SshPrivateKeyPath)) {
        return @()
    }

    if (-not (Test-Path -LiteralPath $SshPrivateKeyPath -PathType Leaf)) {
        throw "SSH private key not found: $SshPrivateKeyPath"
    }

    return @('-i', $SshPrivateKeyPath)
}

function Invoke-GuestSsh {
    param([Parameter(Mandatory = $true)][string]$RemoteCommand)

    $sshKeyArgs = Get-OptionalSshKeyArgs
    $target = "$GuestUser@$GuestAddress"

    $sshArgs = @('-o', 'StrictHostKeyChecking=accept-new') +
               $sshKeyArgs +
               @($target, $RemoteCommand)

    & ssh @sshArgs
    if ($LASTEXITCODE -ne 0) {
        throw "ssh command failed with exit code $LASTEXITCODE"
    }
}

function Copy-DerFilesToGuest {
    param([Parameter(Mandatory = $true)][string[]]$DerFiles)

    $sshKeyArgs = Get-OptionalSshKeyArgs
    $targetBase = "$GuestUser@$GuestAddress"

    $destQ = ConvertTo-BashLiteral -Text $GuestDestination
    Invoke-GuestSsh -RemoteCommand "mkdir -p $destQ && chmod 700 $destQ"

    foreach ($file in $DerFiles) {
        $fileName = [System.IO.Path]::GetFileName($file)
        $target = "${targetBase}:$GuestDestination/$fileName"

        $scpArgs = @('-o', 'StrictHostKeyChecking=accept-new') +
                   $sshKeyArgs +
                   @($file, $target)

        & scp @scpArgs
        if ($LASTEXITCODE -ne 0) {
            throw "scp failed for $file (exit code $LASTEXITCODE)"
        }
    }
}

function Get-HyperVKeyboard {
    param([Parameter(Mandatory = $true)][string]$TargetVMName)

    $vm = Get-VM -Name $TargetVMName -ErrorAction Stop
    $vmId = $vm.VMId.Guid

    $keyboard = Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_Keyboard |
        Where-Object { $_.SystemName -eq $vmId } |
        Select-Object -First 1

    if (-not $keyboard) {
        throw "Unable to find Hyper-V keyboard device for VM '$TargetVMName'."
    }

    return $keyboard
}

function Send-HyperVTypeKey {
    param(
        [Parameter(Mandatory = $true)]$Keyboard,
        [Parameter(Mandatory = $true)][uint16]$ScanCode,
        [switch]$IsUnicode
    )

    $args = @{
        scanCode = $ScanCode
        keyUp    = $false
        unicode  = [bool]$IsUnicode
    }

    $null = Invoke-CimMethod -InputObject $Keyboard -MethodName TypeKey -Arguments $args
    Start-Sleep -Milliseconds $KeyDelayMs
}

function Send-MokManagerKeys {
    param([Parameter(Mandatory = $true)][int]$DerFileCount)

    $keyboard = Get-HyperVKeyboard -TargetVMName $VMName

    # Typical flow:
    # Perform MOK management -> Enroll MOK -> Continue -> Yes -> Password -> Reboot
    # Scan codes are set 1 (PC/AT): DOWN=0x50 ENTER=0x1C

    Send-HyperVTypeKey -Keyboard $keyboard -ScanCode 0x50 # DOWN
    Send-HyperVTypeKey -Keyboard $keyboard -ScanCode 0x1C # ENTER
    Start-Sleep -Seconds $ScreenDelaySeconds

    for ($i = 0; $i -lt $DerFileCount; $i++) {
        Send-HyperVTypeKey -Keyboard $keyboard -ScanCode 0x50 # DOWN
    }
    Send-HyperVTypeKey -Keyboard $keyboard -ScanCode 0x1C # ENTER
    Start-Sleep -Seconds $ScreenDelaySeconds

    Send-HyperVTypeKey -Keyboard $keyboard -ScanCode 0x50 # DOWN (Yes)
    Send-HyperVTypeKey -Keyboard $keyboard -ScanCode 0x1C # ENTER

    Write-Warning 'Password entry in MOKManager is intentionally left manual for Hyper-V. Connect with VMConnect now.'
}

function Invoke-MokImport {
    param([Parameter(Mandatory = $true)][string[]]$DerFiles)

    $destQ = ConvertTo-BashLiteral -Text $GuestDestination
    $importLine = "for f in $destQ/*.der; do mokutil --import \"`$f\"; done"
    Invoke-GuestSsh -RemoteCommand $importLine
}

$derFiles = Get-DerFiles -Folder $DerFolder
Write-Host "[$VMName] Found $($derFiles.Count) .der file(s)."

if ($PSCmdlet.ShouldProcess($VMName, 'Copy DER files and request MOK import')) {
    Copy-DerFilesToGuest -DerFiles $derFiles
    Invoke-MokImport -DerFiles $derFiles

    Restart-VM -Name $VMName -Force -Confirm:$false
    Write-Host "[$VMName] VM restarted."

    switch ($MokAutomationMode) {
        'AutoMokManager' { Send-MokManagerKeys -DerFileCount $derFiles.Count }
        'ManualMenu'     { Write-Host 'Open VMConnect and complete MOKManager menu/password manually.' }
        'SkipMokManager' { Write-Host 'Skipping MOKManager interactions.' }
    }
}
