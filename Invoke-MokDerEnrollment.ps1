<#
.SYNOPSIS
  Automatically imports DER certificates into MOKManager on VMware VMs.

.DESCRIPTION
  This script:
  - Scans a local folder for .der files
  - Copies them into a Linux VM using VMware Tools
  - Prompts for a temporary MOK password (kept as SecureString, only briefly materialized)
  - Runs mokutil --import using Invoke-VMScript
  - Reboots the guest
  - Automatically catches the "Press any key to perform MOK management" screen
  - Drives MOKManager using VMware PutUsbScanCodes (key count is derived from the
    actual number of .der files found, not hardcoded)
  - Waits for VMware Tools to come back
  - Verifies the imported certificates with mokutil --test-key

  It supports:
  - Single VM mode
  - Batch mode using a CSV or plain text VM list

.CSV FORMAT
  The CSV/list file contains VM names only.

  CSV example:
    VMName
    redhat9_4_uefi
    redhat9_4_uefi_2

  Plain text example:
    redhat9_4_uefi
    redhat9_4_uefi_2

.PREREQUISITES
  - VMware PowerCLI
  - VMware Tools running in the guest
  - Linux VM booting with UEFI Secure Boot
  - mokutil installed in the guest
  - vSphere Guest Operations privileges
  - vSphere privilege: VirtualMachine.Interact.PutUsbScanCodes

.NOTES
  The MOK password is restricted to lowercase letters and digits.
  This avoids keyboard layout issues in UEFI / MOKManager.

  The expected MOKManager flow is:
    Press any key to perform MOK management
    -> Perform MOK management
    -> Enroll MOK
    -> View key 0 / View key 1 / ... / Continue
    -> Enroll the key(s)? No / Yes
    -> Password
    -> Perform MOK management
    -> Reboot

  The number of DOWN presses to reach "Continue" is automatically computed
  from the number of .der files found in -DerFolder.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$vCenter,

    [string]$VMName,

    # Local folder containing one or more .der files to enroll
    [Parameter(Mandatory = $true)]
    [string]$DerFolder,

    [Alias("VMListPath")]
    [string]$CsvPath,

    [char]$CsvDelimiter = ';',

    [string]$ReportCsvPath,

    [string]$GuestDestination = "/var/tmp/mok-import",

    [ValidateSet("AutoCatchPrompt", "ManualMenu", "SkipMokManager")]
    [string]$MokAutomationMode = "AutoCatchPrompt",

    [int]$CatchDurationSeconds = 90,

    [int]$CatchIntervalMs = 500,

    [int]$KeyDelayMs = 250,

    [int]$ScreenDelaySeconds = 2,

    [int]$GuestReadyTimeoutSeconds = 900,

    # Timeout in seconds for each individual DER file copy via VMware Tools
    [int]$CopyTimeoutSeconds = 300,

    # If the guest credential is root, sudo is never called
    [switch]$GuestCredentialIsRoot,

    [switch]$PromptGuestCredentialPerVM,

    [switch]$ContinueOnError,

    # Skip uploading local DER files; assumes they already exist in -GuestDestination
    [switch]$BypassCertUpload
)

# ---------------------------------------------------------------------------
# Runtime prerequisites
# ---------------------------------------------------------------------------

function Initialize-MokDerEnrollmentEnvironment {
    Import-Module VMware.PowerCLI -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# Security helpers
# ---------------------------------------------------------------------------

function Get-PlainTextFromSecureString {
    <#
    .SYNOPSIS
      Converts a SecureString to plain text. The caller is responsible for
      zeroing the returned string as soon as possible ($plain = $null).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [securestring]$SecureString
    )

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Get-Base64Utf8AndClear {
    <#
    .SYNOPSIS
      Encodes a plain-text string to Base64-UTF8 and immediately zeroes the
      input variable in the caller's scope.

      Usage:
        $b64 = Get-Base64Utf8AndClear -PlainText $plain
        $plain = $null
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$PlainText
    )

    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($PlainText))
}

# ---------------------------------------------------------------------------
# Bash helpers
# ---------------------------------------------------------------------------

function ConvertTo-BashLiteral {
    <#
    .SYNOPSIS
      Wraps a string in single quotes for safe use in a Bash script,
      escaping any embedded single quotes.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    "'" + $Text.Replace("'", "'\''") + "'"
}

function Expand-Template {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Template,

        [Parameter(Mandatory = $true)]
        [hashtable]$Values
    )

    foreach ($key in $Values.Keys) {
        $Template = $Template.Replace("__${key}__", [string]$Values[$key])
    }

    return $Template
}

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------

function Get-DerFiles {
    <#
    .SYNOPSIS
      Returns all .der files found in the given folder.
      Throws if the folder does not exist or contains no .der files.
      Warns if more than 8 files are found (unusual for MOK enrollment).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Folder
    )

    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
        throw "DerFolder not found or is not a directory: $Folder"
    }

    $files = @(Get-ChildItem -LiteralPath $Folder -Filter "*.der" -File |
               Sort-Object Name |
               Select-Object -ExpandProperty FullName)

    if ($files.Count -eq 0) {
        throw "No .der files found in: $Folder"
    }

    if ($files.Count -gt 8) {
        Write-Warning "$($files.Count) .der files found in $Folder — this is unusual. Continuing anyway."
    }

    return $files
}

function Read-MokPassword {
    <#
    .SYNOPSIS
      Prompts for the temporary MOK password and returns it as a SecureString.
      Validation is performed on the plain text, which is zeroed immediately.
    #>
    $secure = Read-Host "Temporary MOK password (lowercase letters and digits only, min 8 chars)" -AsSecureString

    # Briefly materialize for validation only
    $plain = Get-PlainTextFromSecureString -SecureString $secure

    try {
        if ($plain.Length -lt 8) {
            throw "The MOK password must be at least 8 characters long."
        }

        if ($plain -notmatch '^[a-z0-9]+$') {
            throw "To avoid UEFI keyboard layout issues, use lowercase letters and digits only."
        }
    }
    finally {
        $plain = $null
    }

    # Return the SecureString — plain text never leaves this function
    return $secure
}

# ---------------------------------------------------------------------------
# USB HID / MOKManager helpers
# ---------------------------------------------------------------------------

function Get-UsbHidKeyEvent {
    param(
        [Parameter(Mandatory = $true)]
        [int]$UsageId
    )

    $event = New-Object VMware.Vim.UsbScanCodeSpecKeyEvent
    $event.UsbHidCode = ([int64]$UsageId -shl 16) -bor 0x0007
    return $event
}

function Send-UsbHidEvent {
    param(
        [Parameter(Mandatory = $true)]
        $VmView,

        [Parameter(Mandatory = $true)]
        $KeyEvent
    )

    $spec = New-Object VMware.Vim.UsbScanCodeSpec
    $spec.KeyEvents = @($KeyEvent)

    try {
        [void]$VmView.PutUsbScanCodes($spec)
    }
    catch {
        Write-Warning "PutUsbScanCodes failed: $($_.Exception.Message)"
    }

    Start-Sleep -Milliseconds $KeyDelayMs
}

function Send-SpecialKey {
    param(
        [Parameter(Mandatory = $true)]
        $VmView,

        [Parameter(Mandatory = $true)]
        [ValidateSet("ENTER", "DOWN", "UP", "LEFT", "RIGHT", "ESC", "TAB", "BACKSPACE")]
        [string]$Key,

        [int]$Count = 1
    )

    $specialKeys = @{
        ENTER     = 0x28
        ESC       = 0x29
        BACKSPACE = 0x2A
        TAB       = 0x2B
        RIGHT     = 0x4F
        LEFT      = 0x50
        DOWN      = 0x51
        UP        = 0x52
    }

    for ($i = 0; $i -lt $Count; $i++) {
        $event = Get-UsbHidKeyEvent -UsageId $specialKeys[$Key]
        Send-UsbHidEvent -VmView $VmView -KeyEvent $event
    }
}

function Send-Text {
    <#
    .SYNOPSIS
      Sends a string character by character as USB HID events.
      Only lowercase letters and digits are supported (MOK password constraint).
    #>
    param(
        [Parameter(Mandatory = $true)]
        $VmView,

        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    foreach ($char in $Text.ToCharArray()) {
        $s = [string]$char
        $usageId = $null

        if ($s -cmatch "^[a-z]$") {
            $usageId = 0x04 + ([byte][char]$s - [byte][char]'a')
        }
        elseif ($s -match "^[1-9]$") {
            $usageId = 0x1D + [int]$s
        }
        elseif ($s -eq "0") {
            $usageId = 0x27
        }
        else {
            throw "Unsupported character in MOK password: '$s'"
        }

        $event = Get-UsbHidKeyEvent -UsageId $usageId
        Send-UsbHidEvent -VmView $VmView -KeyEvent $event
    }
}

function Wait-MokManagerPrompt {
    param(
        [Parameter(Mandatory = $true)]
        $VmView,

        [int]$DurationSeconds = 90,

        [int]$IntervalMs = 500
    )

    Write-Host "Catching the MOKManager prompt for $DurationSeconds seconds..."
    Write-Host "Sending LEFT regularly to catch the 10-second timeout window."

    $deadline = (Get-Date).AddSeconds($DurationSeconds)

    while ((Get-Date) -lt $deadline) {
        Send-SpecialKey -VmView $VmView -Key LEFT
        Start-Sleep -Milliseconds $IntervalMs
    }

    Write-Host "Prompt catch completed. Assuming the main MOKManager menu is displayed."
}

function Invoke-MokManagerEnrollFlow {
    <#
    .SYNOPSIS
      Drives MOKManager menus via USB HID scan codes.

    .PARAMETER DerFileCount
      Number of .der files that were imported.
      MOKManager shows one "View key N" entry per file, then "Continue".
      The cursor starts on "View key 0", so we need DerFileCount DOWN presses
      to land on "Continue".
    #>
    param(
        [Parameter(Mandatory = $true)]
        $VmView,

        [Parameter(Mandatory = $true)]
        [securestring]$MokPasswordSecure,

        [Parameter(Mandatory = $true)]
        [int]$DerFileCount
    )

    Write-Host "MOKManager: selecting 'Enroll MOK'..."
    Send-SpecialKey -VmView $VmView -Key DOWN
    Send-SpecialKey -VmView $VmView -Key ENTER
    Start-Sleep -Seconds $ScreenDelaySeconds

    # The list is: View key 0, View key 1, ..., View key (N-1), Continue
    # Cursor starts at "View key 0" -> need DerFileCount presses to reach "Continue"
    Write-Host "MOKManager: selecting 'Continue' ($DerFileCount key(s) listed, pressing DOWN $DerFileCount time(s))..."
    Send-SpecialKey -VmView $VmView -Key DOWN -Count $DerFileCount
    Send-SpecialKey -VmView $VmView -Key ENTER
    Start-Sleep -Seconds $ScreenDelaySeconds

    Write-Host "MOKManager: selecting 'Yes' (Enroll the key(s)?)..."
    Send-SpecialKey -VmView $VmView -Key DOWN
    Send-SpecialKey -VmView $VmView -Key ENTER
    Start-Sleep -Seconds $ScreenDelaySeconds

    Write-Host "MOKManager: entering the MOK password..."

    # Materialize the password only for the duration of the USB HID sending
    $plain = Get-PlainTextFromSecureString -SecureString $MokPasswordSecure
    try {
        Send-Text -VmView $VmView -Text $plain
    }
    finally {
        $plain = $null
    }

    Send-SpecialKey -VmView $VmView -Key ENTER
    Start-Sleep -Seconds $ScreenDelaySeconds

    Write-Host "MOKManager: selecting 'Reboot'..."
    Send-SpecialKey -VmView $VmView -Key ENTER
}

# ---------------------------------------------------------------------------
# Guest execution helpers
# ---------------------------------------------------------------------------

function Invoke-GuestBash {
    param(
        [Parameter(Mandatory = $true)]
        $VM,

        [Parameter(Mandatory = $true)]
        [pscredential]$GuestCredential,

        [Parameter(Mandatory = $true)]
        [string]$ScriptText,

        [int]$ToolsWaitSecs = 120
    )

    # VMware Guest Operations may flatten multiline scripts into a single
    # command separated by ';'. Blank lines can become ';;', which Bash parses
    # as an unexpected token outside of a case statement.
    # Remove empty/whitespace-only lines before execution to avoid generating
    # accidental ';;' sequences.
    $sanitizedScript = (($ScriptText -split "`r?`n") |
        Where-Object { $_ -notmatch '^\s*$' }) -join "`n"

    $result = Invoke-VMScript `
        -VM $VM `
        -GuestCredential $GuestCredential `
        -ScriptType Bash `
        -ScriptText $sanitizedScript `
        -ToolsWaitSecs $ToolsWaitSecs `
        -ErrorAction Stop

    if ($result.ExitCode -ne 0) {
        throw "Guest script exited with code $($result.ExitCode).`n$($result.ScriptOutput)"
    }

    return $result
}

function Wait-GuestReady {
    param(
        [Parameter(Mandatory = $true)]
        $VM,

        [Parameter(Mandatory = $true)]
        [pscredential]$GuestCredential,

        [int]$TimeoutSeconds = 900
    )

    $deadline    = (Get-Date).AddSeconds($TimeoutSeconds)
    $sleepSecs   = 10
    # Require two consecutive successful responses before declaring the guest ready.
    # This avoids false positives when the guest briefly responds then reboots again
    # (e.g. during a kernel update triggered by the same boot).
    $needed      = 2
    $consecutive = 0

    Write-Host "Waiting for VMware Tools / Guest Operations to come back (need $needed consecutive responses)..."

    while ((Get-Date) -lt $deadline) {
        try {
            $result = Invoke-VMScript `
                -VM $VM `
                -GuestCredential $GuestCredential `
                -ScriptType Bash `
                -ScriptText "echo READY" `
                -ToolsWaitSecs 20 `
                -ErrorAction Stop

            if ($result.ScriptOutput -match "READY") {
                $consecutive++
                Write-Host "Guest responded ($consecutive/$needed)."

                if ($consecutive -ge $needed) {
                    Write-Host "Guest is ready."
                    return $true
                }

                # Short fixed delay between the confirmation probes
                Start-Sleep -Seconds 5
                continue
            }
        }
        catch {
            # Guest not yet reachable — reset streak and back off
            $consecutive = 0
        }

        Start-Sleep -Seconds $sleepSecs
        if ($sleepSecs -lt 30) { $sleepSecs += 10 }
    }

    return $false
}

# ---------------------------------------------------------------------------
# VM list import
# ---------------------------------------------------------------------------

function Import-VMList {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [char]$Delimiter = ';'
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "VM list file not found: $Path"
    }

    $lines = Get-Content -LiteralPath $Path | Where-Object {
        $null -ne $_ -and $_.Trim() -ne "" -and -not $_.Trim().StartsWith("#")
    }

    if (-not $lines -or $lines.Count -eq 0) {
        throw "VM list file is empty: $Path"
    }

    $firstLine = $lines[0].Trim().TrimStart([char]0xFEFF)
    $headerFirstColumn = @($firstLine -split [regex]::Escape([string]$Delimiter), 2)[0].Trim()

    # Detect CSV format by checking whether the first column header is "VMName"
    $isCsv = $headerFirstColumn -eq "VMName"

    if ($isCsv) {
        $rows = Import-Csv -LiteralPath $Path -Delimiter $Delimiter
        return @(
            foreach ($row in $rows) {
                $name = "$($row.VMName)".Trim()
                if ($name -ne "") {
                    [pscustomobject]@{ VMName = $name }
                }
            }
        )
    }

    # Plain text: one VM name per line
    return @(
        foreach ($line in $lines) {
            $name = $line.Trim().TrimStart([char]0xFEFF)
            if ($name -ne "" -and $name -ne "VMName") {
                [pscustomobject]@{ VMName = $name }
            }
        }
    )
}

# ---------------------------------------------------------------------------
# Bash script builders — two variants depending on whether we run as root
# ---------------------------------------------------------------------------

function Get-PrepareScript {
    <#
    .SYNOPSIS
      Returns the Bash script that creates the guest destination directory.
      Two variants: root (no sudo) and non-root (sudo with password).
    #>
    param(
        [bool]$IsRoot,
        [string]$GuestDestinationQ,
        # Only used when IsRoot = $false
        [Alias("SudoPasswordB64")]
        [string]$SudoSecretB64
    )

    if ($IsRoot) {
        # Single-quoted here-string — no PowerShell interpolation, all $ belong to Bash.
        # DEST is the only thing injected, via Expand-Template.
        return Expand-Template -Template @'
set -e
DEST=__DEST__
mkdir -p "$DEST"
chmod 700 "$DEST"
echo "Directory ready: $DEST"
'@ -Values @{ DEST = $GuestDestinationQ }
    }

    return Expand-Template -Template @'
set -e
SUDO_PASSWORD="$(printf '%s' '__SUDO_B64__' | base64 -d)"
DEST=__DEST__
printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p '' mkdir -p "$DEST"
printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p '' chown "$(id -un):$(id -gn)" "$DEST" 2>/dev/null \
    || printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p '' chown "$(id -un)" "$DEST"
chmod 700 "$DEST"
unset SUDO_PASSWORD
echo "Directory ready: $DEST"
'@ -Values @{
        SUDO_B64 = $SudoSecretB64
        DEST     = $GuestDestinationQ
    }
}

function Get-ImportScript {
    <#
    .SYNOPSIS
      Returns the Bash script that runs mokutil --import.

      All variable content (passwords, paths) is injected exclusively through
      Expand-Template — no PowerShell string interpolation touches the Bash source,
      preventing silent corruption if a value contains $, `, or __X__.
    #>
    param(
        [bool]$IsRoot,
        [string]$MokSecretB64,
        [string]$SudoSecretB64,
        [string]$GuestCertListQ,
        [string]$HashFileQ
    )

    if ($IsRoot) {
        $sudoSetupBlock = ""
        $sudoPrefix     = ""
    }
    else {
        # Single-quoted literal block — SUDO_B64 is resolved by Expand-Template below.
        $sudoSetupBlock = 'SUDO_PASSWORD="$(printf ''%s'' ''__SUDO_B64__'' | base64 -d)"' + "`n" +
                          '_sudo() { printf ''%s\n'' "$SUDO_PASSWORD" | sudo -S -p '''' "$@"; }'
        $sudoPrefix     = "_sudo "
    }

    return Expand-Template -Template @'
set -e

# --- Verify mokutil is available before doing anything else ---
if ! command -v mokutil > /dev/null 2>&1; then
    echo "ERROR: mokutil is not installed or not in PATH. Aborting." >&2
    exit 1
fi

MOK_PASSWORD="$(printf '%s' '__MOK_B64__' | base64 -d)"
__SUDO_SETUP__
# Ensure the hash file is removed on exit, whether the import succeeds or fails.
HASH_FILE=__HASH_FILE__
_cleanup() { rm -f "$HASH_FILE"; unset MOK_PASSWORD SUDO_PASSWORD; }
trap _cleanup EXIT

echo "=== mokutil version ==="
# Some mokutil builds print version but still return non-zero (seen on 0.6.0).
# Do not abort the whole enrollment pre-check on this informational command.
mokutil --version || true

echo ""
echo "=== Secure Boot state ==="
mokutil --sb-state || true

echo ""
echo "=== Copied DER files ==="
ls -l __CERT_LIST__

echo ""
echo "=== Setting file permissions ==="
__SUDO_PREFIX__chmod 600 __CERT_LIST__

echo ""
echo "=== Checking whether certificates are already enrolled ==="
for cert in __CERT_LIST__; do
    __SUDO_PREFIX__mokutil --test-key "$cert" || true
done

echo ""
echo "=== Generating MOK password hash ==="
umask 077
mokutil --generate-hash="$MOK_PASSWORD" > "$HASH_FILE"
chmod 600 "$HASH_FILE"

echo ""
echo "=== Importing DER certificates into MOK pending list ==="
__SUDO_PREFIX__mokutil --import __CERT_LIST__ --hash-file "$HASH_FILE"

echo ""
echo "=== Pending MOK enrollment requests ==="
__SUDO_PREFIX__mokutil --list-new || true

echo ""
echo "MOK import prepared. Final enrollment will happen at reboot in MOKManager."
'@ -Values @{
        MOK_B64     = $MokSecretB64
        SUDO_B64    = $SudoSecretB64
        SUDO_SETUP  = $sudoSetupBlock
        SUDO_PREFIX = $sudoPrefix
        CERT_LIST   = $GuestCertListQ
        HASH_FILE   = $HashFileQ
    }
}

function Get-VerifyScript {
    param(
        [bool]$IsRoot,
        [string]$SudoSecretB64,
        [string]$GuestCertListQ
    )

    if ($IsRoot) {
        $sudoSetupBlock = ""
        $sudoPrefix     = ""
    }
    else {
        $sudoSetupBlock = 'SUDO_PASSWORD="$(printf ''%s'' ''__SUDO_B64__'' | base64 -d)"' + "`n" +
                          '_sudo() { printf ''%s\n'' "$SUDO_PASSWORD" | sudo -S -p '''' "$@"; }'
        $sudoPrefix     = "_sudo "
    }

    return Expand-Template -Template @'
set -e
__SUDO_SETUP__
trap 'unset SUDO_PASSWORD' EXIT

echo "=== Secure Boot state ==="
mokutil --sb-state || true

echo ""
echo "=== Certificate enrollment verification ==="
for cert in __CERT_LIST__; do
    echo "--- $cert ---"
    __SUDO_PREFIX__mokutil --test-key "$cert" || true
done

echo ""
echo "=== Remaining pending MOK requests ==="
__SUDO_PREFIX__mokutil --list-new || true

echo ""
echo "=== Enrolled MOK keys (first 120 lines) ==="
__SUDO_PREFIX__mokutil --list-enrolled | head -n 120 || true
'@ -Values @{
        SUDO_B64    = $SudoSecretB64
        SUDO_SETUP  = $sudoSetupBlock
        SUDO_PREFIX = $sudoPrefix
        CERT_LIST   = $GuestCertListQ
    }
}

# ---------------------------------------------------------------------------
# Core enrollment function
# ---------------------------------------------------------------------------

function Invoke-MokDerEnrollmentForVm {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetVMName,

        # Full local paths of the .der files to enroll
        [Parameter(Mandatory = $true)]
        [string[]]$LocalDerFiles,

        [Parameter(Mandatory = $true)]
        [string]$TargetGuestDestination,

        [Parameter(Mandatory = $true)]
        [ValidateSet("AutoCatchPrompt", "ManualMenu", "SkipMokManager")]
        [string]$TargetMokAutomationMode,

        [Parameter(Mandatory = $true)]
        [int]$TargetCatchDurationSeconds,

        [Parameter(Mandatory = $true)]
        [int]$TargetCatchIntervalMs,

        [Parameter(Mandatory = $true)]
        [int]$TargetCopyTimeoutSeconds,

        [Parameter(Mandatory = $true)]
        # vCenter server name — passed to the copy job which runs in an isolated runspace
        [string]$TargetVCenter,

        [Parameter(Mandatory = $true)]
        # vCenter credential — passed to the copy job
        [pscredential]$VCenterCredential,

        [Parameter(Mandatory = $true)]
        [pscredential]$GuestCredential,

        # MOK password kept as SecureString — never stored as plain string in this scope
        [Parameter(Mandatory = $true)]
        [securestring]$MokPasswordSecure,

        [bool]$IsRoot,

        [bool]$SkipCertUpload
    )

    $startedAt = Get-Date

    # Normalise the destination path: strip any trailing slash to avoid double-slash
    # in constructed paths like "$dest/mok-password.hash".
    $TargetGuestDestination = $TargetGuestDestination.TrimEnd('/')

    $derCount = $LocalDerFiles.Count

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "Processing VM : $TargetVMName"
    Write-Host "DER files     : $derCount file(s) from $DerFolder"
    foreach ($f in $LocalDerFiles) { Write-Host "               $f" }
    Write-Host "Guest path    : $TargetGuestDestination"
    Write-Host "Mode          : $TargetMokAutomationMode"
    Write-Host "Run as root   : $IsRoot"
    Write-Host "============================================================"

    $vm = Get-VM -Name $TargetVMName -ErrorAction Stop

    if (@($vm).Count -gt 1) {
        throw "[$TargetVMName] Multiple VMs found with this name in vCenter. Use a unique name or target a specific datacenter."
    }

    if ($vm.PowerState -ne "PoweredOn") {
        throw "VM must be powered on to use VMware Tools: $TargetVMName"
    }

    $vmView = Get-View -Id $vm.Id

    # -----------------------------------------------------------------------
    # Extract guest password — used only to build the script, then zeroed
    # -----------------------------------------------------------------------
    $guestPasswordPlain = $GuestCredential.GetNetworkCredential().Password
    $guestPasswordB64   = Get-Base64Utf8AndClear -PlainText $guestPasswordPlain
    $guestPasswordPlain = $null

    # MOK password Base64 — materialized briefly, then zeroed
    $mokPlain = Get-PlainTextFromSecureString -SecureString $MokPasswordSecure
    $mokB64   = Get-Base64Utf8AndClear -PlainText $mokPlain
    $mokPlain = $null

    # -----------------------------------------------------------------------
    # Build guest paths
    # -----------------------------------------------------------------------
    $guestDestQ  = ConvertTo-BashLiteral $TargetGuestDestination
    $hashFileQ   = ConvertTo-BashLiteral "$TargetGuestDestination/mok-password.hash"

    # Map local files to guest paths using a fixed numeric name (mok-key-001.der, ...)
    # to avoid silent collisions when two local files share the same basename.
    $guestDerPaths = @(
        for ($idx = 0; $idx -lt $LocalDerFiles.Count; $idx++) {
            "$TargetGuestDestination/mok-key-{0:D3}.der" -f ($idx + 1)
        }
    )

    # Space-separated list of single-quoted paths for use in Bash loops / args
    $guestCertListQ = ($guestDerPaths | ForEach-Object { ConvertTo-BashLiteral $_ }) -join " "

    # -----------------------------------------------------------------------
    # Step 1 — Prepare guest directory
    # -----------------------------------------------------------------------
    Write-Host "[$TargetVMName] Creating guest directory: $TargetGuestDestination"

    $prepareScript = Get-PrepareScript `
        -IsRoot $IsRoot `
        -GuestDestinationQ $guestDestQ `
        -SudoSecretB64 $guestPasswordB64

    Invoke-GuestBash -VM $vm -GuestCredential $GuestCredential -ScriptText $prepareScript | Out-Null

    # -----------------------------------------------------------------------
    # Step 2 — Copy DER files (with per-file timeout via background job)
    # -----------------------------------------------------------------------
    if ($SkipCertUpload) {
        Write-Host "[$TargetVMName] Skipping DER upload (-BypassCertUpload enabled). Assuming cert files already exist in: $TargetGuestDestination"
    }
    else {
        for ($i = 0; $i -lt $LocalDerFiles.Count; $i++) {
        $localFile = $LocalDerFiles[$i]
        $guestDest = $guestDerPaths[$i]
        $label     = "mok-key-{0:D3}.der" -f ($i + 1)

        Write-Host "[$TargetVMName] Copying $([System.IO.Path]::GetFileName($localFile)) -> $guestDest (as $label)"

        # Run Copy-VMGuestFile in a background job so we can enforce a timeout.
        # Start-Job runs in an isolated runspace — the parent's vCenter session is
        # NOT inherited. We reconnect explicitly inside the job using the vCenter
        # credential. Guest credential is passed as B64 (SecureString is not safely
        # serialisable across job boundaries).
        $vcPassB64    = [Convert]::ToBase64String(
                            [Text.Encoding]::UTF8.GetBytes(
                                $VCenterCredential.GetNetworkCredential().Password))
        $guestPassB64 = [Convert]::ToBase64String(
                            [Text.Encoding]::UTF8.GetBytes(
                                $GuestCredential.GetNetworkCredential().Password))

        $copyJob = Start-Job -ScriptBlock {
            param($vcServer, $vcUser, $vcPassB64,
                  $vmName,   $src,   $dst,
                  $guestUser, $guestPassB64)

            Import-Module VMware.PowerCLI -ErrorAction Stop

            # Reconnect to vCenter inside the isolated runspace
            $vcPassPlain  = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($vcPassB64))
            $vcSecPass    = ConvertTo-SecureString $vcPassPlain -AsPlainText -Force
            $vcCred       = [pscredential]::new($vcUser, $vcSecPass)
            Connect-VIServer -Server $vcServer -Credential $vcCred -ErrorAction Stop | Out-Null

            $guestPassPlain = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($guestPassB64))
            $guestSecPass   = ConvertTo-SecureString $guestPassPlain -AsPlainText -Force
            $guestCred      = [pscredential]::new($guestUser, $guestSecPass)

            $vm = Get-VM -Name $vmName -ErrorAction Stop

            Copy-VMGuestFile `
                -VM $vm `
                -Source $src `
                -Destination $dst `
                -LocalToGuest `
                -GuestCredential $guestCred `
                -Force `
                -ErrorAction Stop
        } -ArgumentList @(
            $TargetVCenter,
            $VCenterCredential.UserName,
            $vcPassB64,
            $TargetVMName,
            $localFile,
            $guestDest,
            $GuestCredential.UserName,
            $guestPassB64
        )

        $completed = Wait-Job -Job $copyJob -Timeout $TargetCopyTimeoutSeconds

        if ($null -eq $completed) {
            Stop-Job  -Job $copyJob
            Remove-Job -Job $copyJob -Force
            throw "[$TargetVMName] Copy of '$label' timed out after $TargetCopyTimeoutSeconds seconds. VMware Tools may be unresponsive."
        }

        # Snapshot errors into a new array before removing the job.
        # Remove-Job -Force disposes the job's PSDataCollection, which clears
        # ChildJobs[0].Error in-place — checking Count after removal always yields 0.
        $jobErrors = @($copyJob.ChildJobs[0].Error)
        Remove-Job -Job $copyJob -Force

        if ($jobErrors.Count -gt 0) {
            throw "[$TargetVMName] Copy of '$label' failed: $($jobErrors[0].Exception.Message)"
        }

        Write-Host "[$TargetVMName] $label copied successfully."
        }
    }

    # -----------------------------------------------------------------------
    # Step 3 — mokutil --import
    # -----------------------------------------------------------------------
    Write-Host "[$TargetVMName] Running mokutil --import..."

    $importScript = Get-ImportScript `
        -IsRoot $IsRoot `
        -MokSecretB64 $mokB64 `
        -SudoSecretB64 $guestPasswordB64 `
        -GuestCertListQ $guestCertListQ `
        -HashFileQ $hashFileQ

    # Zero the B64 copies now that the scripts are built
    $mokB64          = $null
    $guestPasswordB64 = $null

    $result = Invoke-GuestBash -VM $vm -GuestCredential $GuestCredential -ScriptText $importScript -ToolsWaitSecs 180
    Write-Host $result.ScriptOutput

    # -----------------------------------------------------------------------
    # Step 4 — MOKManager (optional)
    # -----------------------------------------------------------------------
    if ($TargetMokAutomationMode -eq "SkipMokManager") {
        Write-Host "[$TargetVMName] SkipMokManager: import prepared, manual enrollment still required."
        return [pscustomobject]@{
            VMName     = $TargetVMName
            DerCount   = $derCount
            Status     = "PreparedOnly"
            Message    = "MOK import prepared. Manual MOKManager enrollment still required."
            StartedAt  = $startedAt
            FinishedAt = Get-Date
        }
    }

    Write-Host "[$TargetVMName] Rebooting guest..."
    Restart-VMGuest -VM $vm -Confirm:$false

    # Wait until VMware Tools reports as not running, which confirms the guest
    # has actually started its shutdown/reboot sequence.
    # Without this, Wait-MokManagerPrompt could fire before the reboot even begins.
    Write-Host "[$TargetVMName] Waiting for VMware Tools to disconnect (reboot confirmation)..."
    $toolsDisconnectDeadline = (Get-Date).AddSeconds(120)
    $toolsDisconnected = $false

    while ((Get-Date) -lt $toolsDisconnectDeadline) {
        $refreshed = Get-VM -Name $TargetVMName -ErrorAction SilentlyContinue
        if ($refreshed -and $refreshed.ExtensionData.Guest.ToolsRunningStatus -ne "guestToolsRunning") {
            $toolsDisconnected = $true
            Write-Host "[$TargetVMName] VMware Tools disconnected — reboot confirmed."
            break
        }
        Start-Sleep -Seconds 3
    }

    if (-not $toolsDisconnected) {
        Write-Warning "[$TargetVMName] VMware Tools did not disconnect within 120 seconds. The guest may not have rebooted. Proceeding anyway."
    }

    if ($TargetMokAutomationMode -eq "ManualMenu") {
        Write-Host ""
        Write-Host "Open the VM console."
        Write-Host "Wait until the main MOKManager menu shows:"
        Write-Host "  Continue boot"
        Write-Host "  Enroll MOK"
        Read-Host "Press ENTER here when the menu is visible"
    }
    else {
        # Refresh the view object — it was captured before the reboot and may be stale.
        $vmView = Get-View -Id $vm.Id

        Wait-MokManagerPrompt `
            -VmView $vmView `
            -DurationSeconds $TargetCatchDurationSeconds `
            -IntervalMs $TargetCatchIntervalMs

        Start-Sleep -Seconds 2
    }

    # Ensure the view is current for the enroll flow regardless of mode.
    $vmView = Get-View -Id $vm.Id

    Invoke-MokManagerEnrollFlow `
        -VmView $vmView `
        -MokPasswordSecure $MokPasswordSecure `
        -DerFileCount $derCount

    # -----------------------------------------------------------------------
    # Step 5 — Wait for guest + verify
    # -----------------------------------------------------------------------
    $ready = Wait-GuestReady `
        -VM $vm `
        -GuestCredential $GuestCredential `
        -TimeoutSeconds $GuestReadyTimeoutSeconds

    if (-not $ready) {
        throw "[$TargetVMName] VM did not become reachable through VMware Tools within the configured timeout."
    }

    # Re-extract guest password for verify script
    $guestPasswordPlain2 = $GuestCredential.GetNetworkCredential().Password
    $guestPasswordB642   = Get-Base64Utf8AndClear -PlainText $guestPasswordPlain2
    $guestPasswordPlain2 = $null

    Write-Host "[$TargetVMName] Running post-enrollment verification..."

    $verifyScript = Get-VerifyScript `
        -IsRoot $IsRoot `
        -SudoSecretB64 $guestPasswordB642 `
        -GuestCertListQ $guestCertListQ

    $guestPasswordB642 = $null

    $verify = Invoke-GuestBash -VM $vm -GuestCredential $GuestCredential -ScriptText $verifyScript -ToolsWaitSecs 120
    Write-Host $verify.ScriptOutput

    return [pscustomobject]@{
        VMName     = $TargetVMName
        DerCount   = $derCount
        Status     = "Completed"
        Message    = "MOK enrollment workflow completed."
        StartedAt  = $startedAt
        FinishedAt = Get-Date
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

function Invoke-MokDerEnrollmentMain {
    Initialize-MokDerEnrollmentEnvironment

    # Resolve and validate DER files once for all VMs
    $localDerFiles = Get-DerFiles -Folder $DerFolder

    Write-Host "Found $($localDerFiles.Count) .der file(s) in $DerFolder :"
    $localDerFiles | ForEach-Object { Write-Host "  $_" }

    # Build VM work list
    if ($CsvPath) {
        $vmList = Import-VMList -Path $CsvPath -Delimiter $CsvDelimiter

        if (-not $vmList -or $vmList.Count -eq 0) {
            throw "No VM found in CSV/list file: $CsvPath"
        }

        $workItems = @($vmList | ForEach-Object { [pscustomobject]@{ VMName = $_.VMName } })
    }
    else {
        if (-not $VMName) {
            throw "Single VM mode requires -VMName. Batch mode requires -CsvPath."
        }

        $workItems = @([pscustomobject]@{ VMName = $VMName })
    }

    # Prompt for MOK password — stored as SecureString for the lifetime of the script
    $mokPasswordSecure = Read-MokPassword

    Write-Host "Connecting to vCenter: $vCenter"
    $vCenterCredential = Get-Credential -Message "vCenter credential"
    Connect-VIServer -Server $vCenter -Credential $vCenterCredential -ErrorAction Stop | Out-Null

    $sharedGuestCredential = $null

    if (-not $PromptGuestCredentialPerVM) {
        $sharedGuestCredential = Get-Credential -Message "Guest OS credential. Root recommended; otherwise sudo must be available."
    }

    $results = @()

    foreach ($item in $workItems) {
        $targetVmName = "$($item.VMName)".Trim()

        if (-not $targetVmName) {
            $msg = "Empty VM name found in list."
            $results += [pscustomobject]@{
                VMName     = ""
                DerCount   = $localDerFiles.Count
                Status     = "Failed"
                Message    = $msg
                StartedAt  = Get-Date
                FinishedAt = Get-Date
            }

            if (-not $ContinueOnError) { throw $msg }
            continue
        }

        $guestCredential = if ($PromptGuestCredentialPerVM) {
            Get-Credential -Message "Guest OS credential for VM: $targetVmName"
        }
        else {
            $sharedGuestCredential
        }

        # Determine at call site whether this credential is root
        $isRoot = $GuestCredentialIsRoot.IsPresent -or ($guestCredential.UserName -eq "root")

        try {
            $result = Invoke-MokDerEnrollmentForVm `
                -TargetVMName               $targetVmName `
                -LocalDerFiles              $localDerFiles `
                -TargetGuestDestination     $GuestDestination `
                -TargetMokAutomationMode    $MokAutomationMode `
                -TargetCatchDurationSeconds $CatchDurationSeconds `
                -TargetCatchIntervalMs      $CatchIntervalMs `
                -TargetCopyTimeoutSeconds   $CopyTimeoutSeconds `
                -TargetVCenter              $vCenter `
                -VCenterCredential          $vCenterCredential `
                -GuestCredential            $guestCredential `
                -MokPasswordSecure          $mokPasswordSecure `
                -IsRoot                     $isRoot `
                -SkipCertUpload             $BypassCertUpload.IsPresent

            $results += $result
        }
        catch {
            $errorMessage = $_.Exception.Message

            Write-Host ""
            Write-Host "ERROR while processing VM: $targetVmName"
            Write-Host $errorMessage

            $results += [pscustomobject]@{
                VMName     = $targetVmName
                DerCount   = $localDerFiles.Count
                Status     = "Failed"
                Message    = $errorMessage
                StartedAt  = Get-Date
                FinishedAt = Get-Date
            }

            if (-not $ContinueOnError) { break }
        }
    }

    # Zero the MOK SecureString
    $mokPasswordSecure = $null

    # Add duration column to results
    $results = $results | ForEach-Object {
        $_ | Add-Member -NotePropertyName DurationSeconds `
                        -NotePropertyValue ([int]($_.FinishedAt - $_.StartedAt).TotalSeconds) `
                        -PassThru
    }

    if ($ReportCsvPath) {
        $results | Export-Csv `
            -LiteralPath $ReportCsvPath `
            -Delimiter $CsvDelimiter `
            -NoTypeInformation `
            -Encoding UTF8

        Write-Host "Report written to: $ReportCsvPath"
    }

    # Return the result objects to the pipeline so callers can process them.
    # Display a formatted summary only when running interactively.
    $results

    if ($Host.UI.RawUI -and [Environment]::UserInteractive) {
        Write-Host ""
        Write-Host "Summary:"
        $results | Format-Table -AutoSize
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-MokDerEnrollmentMain
}
