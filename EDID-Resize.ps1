<#
Simple EDID Editor - standalone PowerShell/WinForms port
Ported from web-app-edid-editor (https://github.com/dot-osk/web-app-edid-editor)
EDID spec: 1.4 (Block 0)

Detects local monitors, reads their EDID straight from the registry, backs up
the "Device Parameters" key automatically, and can write/remove the
EDID_OVERRIDE value directly - no manual .reg export/import round trip needed
for monitors detected on this machine. Requires admin (registry key is under
HKLM\SYSTEM), so the script re-launches itself elevated if needed.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# ----------------------------------------------------------------------------
# Elevation: writing EDID_OVERRIDE lives under HKLM\SYSTEM, so relaunch as admin
# ----------------------------------------------------------------------------

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    if (-not $PSCommandPath) {
        [System.Windows.Forms.MessageBox]::Show('Administrator privileges are required. Please run Run-EDID-Editor.bat as Administrator.', 'Elevation required', 'OK', 'Error') | Out-Null
        exit 1
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $psi.Verb = 'runas'
    try {
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    } catch {
        # user declined the UAC prompt
    }
    exit
}

# ----------------------------------------------------------------------------
# EDID constants (byte offsets within the 128-byte Block 0)
# ----------------------------------------------------------------------------

$EdidHeader = [byte[]](0x00,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x00)
$AddrEdidVersion  = 0x12
$AddrEdidRevision = 0x13
$AddrPhysHSize = 0x15
$AddrPhysVSize = 0x16

# Preferred Timing Mode block starts at 0x36
$AddrPtmHPixelLower8 = 0x36 + 2   # 0x38
$AddrPtmHPixelUpper4 = 0x36 + 4   # 0x3A (upper nibble)
$AddrPtmVPixelLower8 = 0x36 + 5   # 0x3B
$AddrPtmVPixelUpper4 = 0x36 + 7   # 0x3D (upper nibble)
$AddrPtmHImageLower8 = 0x36 + 12  # 0x42
$AddrPtmVImageLower8 = 0x36 + 13  # 0x43
$AddrPtmImageUpper   = 0x36 + 14  # 0x44 (upper nibble=H, lower nibble=V)

# ----------------------------------------------------------------------------
# EDID math helpers
# ----------------------------------------------------------------------------

function ConvertTo-HexByte([int]$n) { '{0:x2}' -f $n }

function Convert-InchToCm([double]$len) { $len * 2.54 }
function Convert-CmToInch([double]$len) { $len / 2.54 }

function Get-DiagonalSize([double]$h, [double]$v) {
    [Math]::Sqrt(($h * $h) + ($v * $v))
}

function Get-DimensionByDiagonal([double]$diagonalLen, [double]$hPixel, [double]$vPixel) {
    $diagonalPixel = Get-DiagonalSize $hPixel $vPixel
    if ($diagonalPixel -eq 0) { return @(0,0) }
    $scale = $diagonalLen / $diagonalPixel
    return @(($hPixel * $scale), ($vPixel * $scale))
}

function Get-EdidChecksum([byte[]]$first127Bytes) {
    if ($first127Bytes.Length -ne 127) { throw "invalid EDID byte count, must equal to 127" }
    $sum = 0
    foreach ($b in $first127Bytes) { $sum += $b }
    $remainder = $sum % 256
    if ($remainder -eq 0) { return 0 } else { return 256 - $remainder }
}

function Test-EdidChecksum([byte[]]$edid) {
    $desired = Get-EdidChecksum $edid[0..126]
    $actual = $edid[127]
    return ($desired -eq $actual)
}

function Get-EdidPtmPixelSize([byte[]]$edid) {
    $h = $edid[$AddrPtmHPixelLower8] + (($edid[$AddrPtmHPixelUpper4] -band 0xF0) -shl 4)
    $v = $edid[$AddrPtmVPixelLower8] + (($edid[$AddrPtmVPixelUpper4] -band 0xF0) -shl 4)
    return @($h, $v)
}

function Get-EdidPtmDimension([byte[]]$edid) {
    # returns cm
    $hMm = $edid[$AddrPtmHImageLower8] + (($edid[$AddrPtmImageUpper] -band 0xF0) -shl 4)
    $vMm = $edid[$AddrPtmVImageLower8] + (($edid[$AddrPtmImageUpper] -band 0x0F) -shl 8)
    return @(($hMm / 10.0), ($vMm / 10.0))
}

function Get-EdidPhysicalDimension([byte[]]$edid) {
    # returns cm
    $h = $edid[$AddrPhysHSize]
    $v = $edid[$AddrPhysVSize]
    if ($h -eq 0 -or $v -eq 0) { return @(0, 0) }
    return @($h, $v)
}

function Set-EdidScreenDimension([byte[]]$edid, [double]$hSize, [double]$vSize, [bool]$setPtmSize) {
    $hSize = [Math]::Round($hSize)
    $vSize = [Math]::Round($vSize)
    if ($hSize -gt 255) { $hSize = 255 }
    if ($vSize -gt 255) { $vSize = 255 }
    if ($hSize -lt 0)   { $hSize = 0 }
    if ($vSize -lt 0)   { $vSize = 0 }

    $new = [byte[]]$edid.Clone()
    $new[$AddrPhysHSize] = [byte]$hSize
    $new[$AddrPhysVSize] = [byte]$vSize

    if ($setPtmSize) {
        $ptmH = [int]($hSize * 10)
        $ptmV = [int]($vSize * 10)
        $ptmHUpper4 = ($ptmH -shr 8) -band 0x0F
        $ptmVUpper4 = ($ptmV -shr 8) -band 0x0F
        $new[$AddrPtmImageUpper]   = [byte](($ptmHUpper4 -shl 4) -bor $ptmVUpper4)
        $new[$AddrPtmHImageLower8] = [byte]($ptmH -band 0xFF)
        $new[$AddrPtmVImageLower8] = [byte]($ptmV -band 0xFF)
    }

    $new[127] = [byte](Get-EdidChecksum $new[0..126])
    return $new
}

function ConvertTo-EdidHexString([byte[]]$edid) {
    ($edid | ForEach-Object { ConvertTo-HexByte $_ }) -join ','
}

# ----------------------------------------------------------------------------
# Registry access (live monitors on this machine)
# ----------------------------------------------------------------------------

function Get-MonitorList {
    Get-PnpDevice -Class 'Monitor' -Status 'OK' -ErrorAction SilentlyContinue | Sort-Object Name
}

function Get-DeviceParametersPath([string]$instancePath) {
    "HKLM:\SYSTEM\CurrentControlSet\Enum\$instancePath\Device Parameters"
}

function Get-EdidFromRegistry([string]$instancePath) {
    $regPath = Get-DeviceParametersPath $instancePath
    if (-not (Test-Path -LiteralPath $regPath)) { return $null }
    $props = Get-ItemProperty -LiteralPath $regPath -Name 'EDID' -ErrorAction SilentlyContinue
    if ($null -eq $props) { return $null }
    return [byte[]]$props.EDID
}

function Test-EdidOverrideExists([string]$instancePath) {
    $regPath = Join-Path (Get-DeviceParametersPath $instancePath) 'EDID_OVERRIDE'
    if (-not (Test-Path -LiteralPath $regPath)) { return $false }
    $props = Get-ItemProperty -LiteralPath $regPath -Name '0' -ErrorAction SilentlyContinue
    return ($null -ne $props)
}

function Backup-DeviceParameters([string]$instancePath, [string]$deviceName) {
    # Automatic safety net: export the whole Device Parameters key before any write.
    $backupDir = Join-Path $PSScriptRoot 'Backups'
    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
    $safeName = ($deviceName -replace '[\\/:*?"<>|]', '_')
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupFile = Join-Path $backupDir "$safeName-$timestamp.reg"
    $regKeyPath = "HKLM\SYSTEM\CurrentControlSet\Enum\$instancePath\Device Parameters"

    & reg.exe export $regKeyPath $backupFile /y *> $null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $backupFile)) { return $null }
    return $backupFile
}

function Set-EdidOverrideInRegistry([string]$instancePath, [byte[]]$edid) {
    $regPath = Join-Path (Get-DeviceParametersPath $instancePath) 'EDID_OVERRIDE'
    if (-not (Test-Path -LiteralPath $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $regPath -Name '0' -PropertyType Binary -Value $edid -Force | Out-Null
}

function Remove-EdidOverrideFromRegistry([string]$instancePath) {
    $regPath = Join-Path (Get-DeviceParametersPath $instancePath) 'EDID_OVERRIDE'
    if (Test-Path -LiteralPath $regPath) {
        Remove-ItemProperty -LiteralPath $regPath -Name '0' -ErrorAction SilentlyContinue
    }
}

# ----------------------------------------------------------------------------
# .reg file parsing (advanced/manual path: file from another machine, etc.)
# ----------------------------------------------------------------------------

function ConvertFrom-RegFile([string]$content) {
    $result = [ordered]@{
        IsValidRegFile     = $false
        IsEdidFound        = $false
        IsEdidOverridden   = $false
        DeviceInstancePath = ''
        EdidData           = [byte[]]@()
    }

    $content = $content.Trim()
    # merge multi-line hex continuations: "....,\" + newline + whitespace
    $content = [regex]::Replace($content, '\\\r?\n\s*', '')

    $lines = $content -split '\r?\n'
    if ($lines.Count -eq 0) { return $result }
    if ($lines[0].Trim().ToLowerInvariant() -ne 'windows registry editor version 5.00') {
        return $result
    }
    $result.IsValidRegFile = $true

    $sectionHeaderRe   = '^\[HKEY_.*?\]$'
    $deviceParamRe     = '^\[HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Enum\\(?<instancePath>DISPLAY\\.*?)\\Device Parameters\]$'
    $overrideSectionRe = '^\[HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Enum\\(?<instancePath>DISPLAY\\.*?)\\Device Parameters\\EDID_OVERRIDE\]$'
    $edidHexRe         = '"EDID"=hex:(?<edidText>([a-f\d]{2}\s*,?\s*){128,})'
    $overrideHexRe     = '"0"=hex:(?<edidText>([a-f\d]{2}\s*,?\s*){128,})'

    $currentSection = ''
    foreach ($rawLine in $lines) {
        $line = $rawLine.Trim()
        if ($line -match $sectionHeaderRe) {
            if ($line -match $deviceParamRe) {
                $currentSection = 'deviceParameters'
                $result.DeviceInstancePath = $Matches['instancePath']
                continue
            }
            if ($line -match $overrideSectionRe) {
                $currentSection = 'edidOverrideSection'
                continue
            }
            $currentSection = $line
            continue
        }

        if ($currentSection -eq 'deviceParameters' -and $line -match $edidHexRe) {
            $hexParts = $Matches['edidText'] -split ','
            $bytes = New-Object System.Collections.Generic.List[byte]
            foreach ($part in $hexParts) {
                $t = $part.Trim()
                if ($t -eq '') { continue }
                $bytes.Add([Convert]::ToByte($t, 16))
            }
            $result.EdidData = $bytes.ToArray()
            $result.IsEdidFound = $true
            continue
        }

        if ($currentSection -eq 'edidOverrideSection' -and $line -match $overrideHexRe) {
            $result.IsEdidOverridden = $true
            continue
        }
    }

    return $result
}

function New-OverrideRegContent([string]$devicePath, [byte[]]$edid) {
    $hexString = ConvertTo-EdidHexString $edid
    "Windows Registry Editor Version 5.00`r`n`r`n" +
    "[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\$devicePath\Device Parameters\EDID_OVERRIDE]`r`n" +
    "`"0`"=hex:$hexString`r`n"
}

function New-OverrideRemovalRegContent([string]$devicePath) {
    "Windows Registry Editor Version 5.00`r`n`r`n" +
    "[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\$devicePath\Device Parameters\EDID_OVERRIDE]`r`n" +
    "`"0`"=-`r`n"
}

# ----------------------------------------------------------------------------
# Application state
# ----------------------------------------------------------------------------

$script:OriginalEdidBlock0    = [byte[]]@()
$script:NewEdidBlock0         = [byte[]]@()
$script:CurrentInstancePath   = ''
$script:CurrentDeviceName     = ''
$script:CanWriteRegistryLive  = $false   # true only when loaded via live monitor detection
$script:LastBackupPath        = ''

# ----------------------------------------------------------------------------
# UI
# ----------------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Simple EDID Editor (standalone)'
$form.ClientSize = New-Object System.Drawing.Size(760, 990)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.AutoScroll = $true
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$y = 10

function Add-Label($text, $x, $refY, $width = 720, $bold = $false) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $text
    $lbl.Location = New-Object System.Drawing.Point($x, $refY.Value)
    $lbl.Size = New-Object System.Drawing.Size($width, 18)
    if ($bold) { $lbl.Font = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold) }
    $form.Controls.Add($lbl)
    $refY.Value += 20
    return $lbl
}

# --- Notice banner ---
$noticeBox = New-Object System.Windows.Forms.Label
$noticeBox.Text = "Notice: EDID Override can cause your device/monitor to misbehave. Selecting a detected monitor automatically backs up its registry key to .\Backups before any change. Read the backup / warnings before applying. You are responsible for any damage caused by using this tool."
$noticeBox.Location = New-Object System.Drawing.Point(10, $y)
$noticeBox.Size = New-Object System.Drawing.Size(720, 45)
$noticeBox.BackColor = [System.Drawing.Color]::LightYellow
$noticeBox.BorderStyle = 'FixedSingle'
$form.Controls.Add($noticeBox)
$y += 55

# --- Monitor detection group ---
$gbMonitor = New-Object System.Windows.Forms.GroupBox
$gbMonitor.Text = '1. Select a monitor detected on this PC'
$gbMonitor.Location = New-Object System.Drawing.Point(10, $y)
$gbMonitor.Size = New-Object System.Drawing.Size(720, 95)
$form.Controls.Add($gbMonitor)

$btnRefreshMonitors = New-Object System.Windows.Forms.Button
$btnRefreshMonitors.Text = 'Refresh list'
$btnRefreshMonitors.Location = New-Object System.Drawing.Point(10, 22)
$btnRefreshMonitors.Size = New-Object System.Drawing.Size(100, 26)
$gbMonitor.Controls.Add($btnRefreshMonitors)

$cmbMonitors = New-Object System.Windows.Forms.ComboBox
$cmbMonitors.Location = New-Object System.Drawing.Point(120, 24)
$cmbMonitors.Size = New-Object System.Drawing.Size(580, 24)
$cmbMonitors.DropDownStyle = 'DropDownList'
$gbMonitor.Controls.Add($cmbMonitors)

$btnLoadMonitor = New-Object System.Windows.Forms.Button
$btnLoadMonitor.Text = 'Load EDID from registry + back up'
$btnLoadMonitor.Location = New-Object System.Drawing.Point(10, 55)
$btnLoadMonitor.Size = New-Object System.Drawing.Size(260, 28)
$gbMonitor.Controls.Add($btnLoadMonitor)

$lblBackupPath = New-Object System.Windows.Forms.Label
$lblBackupPath.Text = '(no backup yet)'
$lblBackupPath.Location = New-Object System.Drawing.Point(280, 60)
$lblBackupPath.Size = New-Object System.Drawing.Size(420, 18)
$gbMonitor.Controls.Add($lblBackupPath)
$y += 105

$btnOpenReg = New-Object System.Windows.Forms.Button
$btnOpenReg.Text = 'Advanced: open a .reg file instead...'
$btnOpenReg.Location = New-Object System.Drawing.Point(10, $y)
$btnOpenReg.Size = New-Object System.Drawing.Size(280, 26)
$form.Controls.Add($btnOpenReg)

$lblLoadedFile = New-Object System.Windows.Forms.Label
$lblLoadedFile.Text = '(export/import only - not from this PC live)'
$lblLoadedFile.Location = New-Object System.Drawing.Point(300, ($y + 5))
$lblLoadedFile.Size = New-Object System.Drawing.Size(430, 18)
$lblLoadedFile.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblLoadedFile)
$y += 36

# --- Warning labels ---
$lblWarnChecksum = New-Object System.Windows.Forms.Label
$lblWarnChecksum.Text = "! Warning: This EDID data contains an invalid checksum - either the EDID is corrupt or this tool doesn't support its EDID revision. Consider using another EDID editor."
$lblWarnChecksum.Location = New-Object System.Drawing.Point(10, $y)
$lblWarnChecksum.Size = New-Object System.Drawing.Size(720, 34)
$lblWarnChecksum.BackColor = [System.Drawing.Color]::Yellow
$lblWarnChecksum.Visible = $false
$form.Controls.Add($lblWarnChecksum)
$y += 38

$lblWarnOverride = New-Object System.Windows.Forms.Label
$lblWarnOverride.Text = "! Warning: This monitor already has EDID Override data set (by the OEM or manually). The information shown below may be inaccurate; remove the existing override, reboot, and reload."
$lblWarnOverride.Location = New-Object System.Drawing.Point(10, $y)
$lblWarnOverride.Size = New-Object System.Drawing.Size(720, 34)
$lblWarnOverride.BackColor = [System.Drawing.Color]::Yellow
$lblWarnOverride.Visible = $false
$form.Controls.Add($lblWarnOverride)
$y += 38

$y += 8

# --- Original EDID info group ---
$gbOriginal = New-Object System.Windows.Forms.GroupBox
$gbOriginal.Text = 'Original EDID information of the display'
$gbOriginal.Location = New-Object System.Drawing.Point(10, $y)
$gbOriginal.Size = New-Object System.Drawing.Size(720, 100)
$form.Controls.Add($gbOriginal)

$innerY = [ref]20
$lblDeviceInstancePath = Add-Label 'Device Instance Path: (none)' 10 $innerY 690
$gbOriginal.Controls.Add($lblDeviceInstancePath)
$lblOrigPhysicalSize = Add-Label 'Screen physical dimension (Windows uses this): (none)' 10 $innerY 690
$gbOriginal.Controls.Add($lblOrigPhysicalSize)
$lblOrigPtmSize = Add-Label 'PTM screen dimension: (none)' 10 $innerY 690
$gbOriginal.Controls.Add($lblOrigPtmSize)
$y += 110

# --- PTM resolution group ---
$gbPtm = New-Object System.Windows.Forms.GroupBox
$gbPtm.Text = 'Preferred Timing Mode resolution (fix if detected incorrectly)'
$gbPtm.Location = New-Object System.Drawing.Point(10, $y)
$gbPtm.Size = New-Object System.Drawing.Size(720, 90)
$form.Controls.Add($gbPtm)

$lblHPixel = New-Object System.Windows.Forms.Label
$lblHPixel.Text = 'PTM horizontal pixel:'
$lblHPixel.Location = New-Object System.Drawing.Point(10, 25)
$lblHPixel.Size = New-Object System.Drawing.Size(140, 20)
$gbPtm.Controls.Add($lblHPixel)

$numHPixel = New-Object System.Windows.Forms.NumericUpDown
$numHPixel.Location = New-Object System.Drawing.Point(155, 23)
$numHPixel.Size = New-Object System.Drawing.Size(90, 22)
$numHPixel.Minimum = 0
$numHPixel.Maximum = 20000
$gbPtm.Controls.Add($numHPixel)

$lblVPixel = New-Object System.Windows.Forms.Label
$lblVPixel.Text = 'PTM vertical pixel:'
$lblVPixel.Location = New-Object System.Drawing.Point(260, 25)
$lblVPixel.Size = New-Object System.Drawing.Size(120, 20)
$gbPtm.Controls.Add($lblVPixel)

$numVPixel = New-Object System.Windows.Forms.NumericUpDown
$numVPixel.Location = New-Object System.Drawing.Point(390, 23)
$numVPixel.Size = New-Object System.Drawing.Size(90, 22)
$numVPixel.Minimum = 0
$numVPixel.Maximum = 20000
$gbPtm.Controls.Add($numVPixel)

$lblPtmTip = New-Object System.Windows.Forms.Label
$lblPtmTip.Text = 'Note: the PTM resolution here is only used to keep the aspect ratio consistent; it is not written back to the EDID.'
$lblPtmTip.Location = New-Object System.Drawing.Point(10, 55)
$lblPtmTip.Size = New-Object System.Drawing.Size(690, 30)
$lblPtmTip.ForeColor = [System.Drawing.Color]::DimGray
$gbPtm.Controls.Add($lblPtmTip)
$y += 100

# --- New size group ---
$gbNew = New-Object System.Windows.Forms.GroupBox
$gbNew.Text = 'Set the new screen dimension'
$gbNew.Location = New-Object System.Drawing.Point(10, $y)
$gbNew.Size = New-Object System.Drawing.Size(720, 130)
$form.Controls.Add($gbNew)

$lblDiagonal = New-Object System.Windows.Forms.Label
$lblDiagonal.Text = 'Screen physical dimension (inch):'
$lblDiagonal.Location = New-Object System.Drawing.Point(10, 25)
$lblDiagonal.Size = New-Object System.Drawing.Size(200, 20)
$gbNew.Controls.Add($lblDiagonal)

$numDiagonal = New-Object System.Windows.Forms.NumericUpDown
$numDiagonal.Location = New-Object System.Drawing.Point(215, 23)
$numDiagonal.Size = New-Object System.Drawing.Size(90, 22)
$numDiagonal.DecimalPlaces = 1
$numDiagonal.Increment = 0.1
$numDiagonal.Minimum = 0
$numDiagonal.Maximum = 200
$gbNew.Controls.Add($numDiagonal)

$chkModifyPtm = New-Object System.Windows.Forms.CheckBox
$chkModifyPtm.Text = 'Modify the screen size information in PTM too.'
$chkModifyPtm.Location = New-Object System.Drawing.Point(10, 55)
$chkModifyPtm.Size = New-Object System.Drawing.Size(400, 22)
$gbNew.Controls.Add($chkModifyPtm)

$lblNewTip = New-Object System.Windows.Forms.Label
$lblNewTip.Text = 'Windows 11 forces the touch keyboard to undock at >=18 inches; dock mode is available below 18 inches (observed as a truncation, not rounding).'
$lblNewTip.Location = New-Object System.Drawing.Point(10, 80)
$lblNewTip.Size = New-Object System.Drawing.Size(690, 30)
$lblNewTip.ForeColor = [System.Drawing.Color]::DimGray
$gbNew.Controls.Add($lblNewTip)

$lblNewSize = New-Object System.Windows.Forms.Label
$lblNewSize.Text = 'New screen dimension in EDID: (none)'
$lblNewSize.Location = New-Object System.Drawing.Point(10, 108)
$lblNewSize.Size = New-Object System.Drawing.Size(690, 20)
$lblNewSize.Font = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)
$gbNew.Controls.Add($lblNewSize)
$y += 140

# --- Hex view group ---
$gbHex = New-Object System.Windows.Forms.GroupBox
$gbHex.Text = 'Hex view (red = differs from original)'
$gbHex.Location = New-Object System.Drawing.Point(10, $y)
$gbHex.Size = New-Object System.Drawing.Size(720, 260)
$form.Controls.Add($gbHex)

$dgvHex = New-Object System.Windows.Forms.DataGridView
$dgvHex.Location = New-Object System.Drawing.Point(10, 25)
$dgvHex.Size = New-Object System.Drawing.Size(690, 195)
$dgvHex.ColumnCount = 16
$dgvHex.RowHeadersWidth = 45
$dgvHex.AllowUserToAddRows = $false
$dgvHex.AllowUserToDeleteRows = $false
$dgvHex.AllowUserToResizeRows = $false
$dgvHex.AllowUserToResizeColumns = $false
$dgvHex.ReadOnly = $true
$dgvHex.RowHeadersVisible = $true
$dgvHex.ColumnHeadersHeightSizeMode = 'DisableResizing'
$dgvHex.SelectionMode = 'CellSelect'
$dgvHex.Font = New-Object System.Drawing.Font('Consolas', 9)
$dgvHex.ScrollBars = 'None'
for ($c = 0; $c -lt 16; $c++) {
    $dgvHex.Columns[$c].Name = ConvertTo-HexByte $c
    $dgvHex.Columns[$c].HeaderText = ($dgvHex.Columns[$c].Name).ToUpperInvariant()
    $dgvHex.Columns[$c].Width = 38
    $dgvHex.Columns[$c].SortMode = 'NotSortable'
}
for ($r = 0; $r -lt 8; $r++) {
    $dgvHex.Rows.Add() | Out-Null
    $dgvHex.Rows[$r].HeaderCell.Value = (ConvertTo-HexByte ($r * 16)).ToUpperInvariant()
}
$gbHex.Controls.Add($dgvHex)

$btnCopyHex = New-Object System.Windows.Forms.Button
$btnCopyHex.Text = 'Copy to clipboard'
$btnCopyHex.Location = New-Object System.Drawing.Point(10, 225)
$btnCopyHex.Size = New-Object System.Drawing.Size(150, 26)
$gbHex.Controls.Add($btnCopyHex)
$y += 270

# --- Apply directly to registry (primary path, live monitors only) ---
$gbApply = New-Object System.Windows.Forms.GroupBox
$gbApply.Text = '2. Apply directly to the registry (requires reboot / monitor reconnect)'
$gbApply.Location = New-Object System.Drawing.Point(10, $y)
$gbApply.Size = New-Object System.Drawing.Size(720, 70)
$form.Controls.Add($gbApply)

$btnApplyOverride = New-Object System.Windows.Forms.Button
$btnApplyOverride.Text = 'Write EDID Override to registry'
$btnApplyOverride.Location = New-Object System.Drawing.Point(10, 25)
$btnApplyOverride.Size = New-Object System.Drawing.Size(260, 32)
$btnApplyOverride.Enabled = $false
$gbApply.Controls.Add($btnApplyOverride)

$btnRemoveOverride = New-Object System.Windows.Forms.Button
$btnRemoveOverride.Text = 'Remove EDID Override from registry'
$btnRemoveOverride.Location = New-Object System.Drawing.Point(280, 25)
$btnRemoveOverride.Size = New-Object System.Drawing.Size(260, 32)
$btnRemoveOverride.Enabled = $false
$gbApply.Controls.Add($btnRemoveOverride)
$y += 80

# --- Manual export (fallback / sharing) ---
$gbExport = New-Object System.Windows.Forms.GroupBox
$gbExport.Text = 'Advanced: export as .reg files instead (manual import)'
$gbExport.Location = New-Object System.Drawing.Point(10, $y)
$gbExport.Size = New-Object System.Drawing.Size(720, 70)
$form.Controls.Add($gbExport)

$btnSaveOverride = New-Object System.Windows.Forms.Button
$btnSaveOverride.Text = 'Save EDID Override .reg...'
$btnSaveOverride.Location = New-Object System.Drawing.Point(10, 25)
$btnSaveOverride.Size = New-Object System.Drawing.Size(340, 32)
$btnSaveOverride.Enabled = $false
$gbExport.Controls.Add($btnSaveOverride)

$btnSaveRemoval = New-Object System.Windows.Forms.Button
$btnSaveRemoval.Text = 'Save EDID Override removal .reg...'
$btnSaveRemoval.Location = New-Object System.Drawing.Point(360, 25)
$btnSaveRemoval.Size = New-Object System.Drawing.Size(350, 32)
$btnSaveRemoval.Enabled = $false
$gbExport.Controls.Add($btnSaveRemoval)
$y += 80

# ----------------------------------------------------------------------------
# Behaviour
# ----------------------------------------------------------------------------

function Update-HexView {
    for ($i = 0; $i -lt $script:NewEdidBlock0.Length; $i++) {
        $row = [Math]::Floor($i / 16)
        $col = $i % 16
        $val = $script:NewEdidBlock0[$i]
        $cell = $dgvHex.Rows[$row].Cells[$col]
        $cell.Value = (ConvertTo-HexByte $val).ToUpperInvariant()
        if ($script:OriginalEdidBlock0[$i] -ne $val) {
            $cell.Style.ForeColor = [System.Drawing.Color]::Red
            $cell.Style.Font = New-Object System.Drawing.Font('Consolas', 9, [System.Drawing.FontStyle]::Bold)
        } else {
            $cell.Style.ForeColor = [System.Drawing.Color]::Black
            $cell.Style.Font = New-Object System.Drawing.Font('Consolas', 9)
        }
    }
}

function Update-NewEdid {
    if ($script:OriginalEdidBlock0.Length -eq 0) { return }

    $diagInch = [double]$numDiagonal.Value
    $hPixel = [double]$numHPixel.Value
    $vPixel = [double]$numVPixel.Value

    $dim = Get-DimensionByDiagonal (Convert-InchToCm $diagInch) $hPixel $vPixel
    $script:NewEdidBlock0 = Set-EdidScreenDimension $script:OriginalEdidBlock0 $dim[0] $dim[1] $chkModifyPtm.Checked

    $applied = Get-EdidPhysicalDimension $script:NewEdidBlock0
    $appliedInch = Convert-CmToInch (Get-DiagonalSize $applied[0] $applied[1])
    $lblNewSize.Text = "New screen dimension in EDID: $($applied[0]) x $($applied[1]) cm, approx. $('{0:F1}' -f $appliedInch) inch"

    Update-HexView
}

function Reset-App {
    $script:OriginalEdidBlock0 = [byte[]]@()
    $script:NewEdidBlock0 = [byte[]]@()
    $script:CurrentInstancePath = ''
    $script:CurrentDeviceName = ''
    $script:CanWriteRegistryLive = $false
    $script:LastBackupPath = ''

    $lblWarnChecksum.Visible = $false
    $lblWarnOverride.Visible = $false

    $lblDeviceInstancePath.Text = 'Device Instance Path: (none)'
    $lblOrigPhysicalSize.Text = 'Screen physical dimension (Windows uses this): (none)'
    $lblOrigPtmSize.Text = 'PTM screen dimension: (none)'
    $lblNewSize.Text = 'New screen dimension in EDID: (none)'
    $lblBackupPath.Text = '(no backup yet)'
    $lblLoadedFile.Text = '(export/import only - not from this PC live)'

    $numHPixel.Value = 0
    $numVPixel.Value = 0
    $numDiagonal.Value = 0
    $chkModifyPtm.Checked = $false

    $btnSaveOverride.Enabled = $false
    $btnSaveRemoval.Enabled = $false
    $btnApplyOverride.Enabled = $false
    $btnRemoveOverride.Enabled = $false

    foreach ($row in $dgvHex.Rows) {
        foreach ($cell in $row.Cells) {
            $cell.Value = ''
            $cell.Style.ForeColor = [System.Drawing.Color]::Black
        }
    }
}

function Import-EdidBlock0([byte[]]$edidData) {
    # Common validation + population shared by both load paths. Returns $true on success.
    if ($edidData.Length -lt 128) {
        [System.Windows.Forms.MessageBox]::Show('EDID data is shorter than 128 bytes!', 'Parse error', 'OK', 'Error') | Out-Null
        return $false
    }
    $script:OriginalEdidBlock0 = $edidData[0..127]
    $script:NewEdidBlock0 = $edidData[0..127]

    if (-not (Test-EdidChecksum $script:OriginalEdidBlock0)) {
        $lblWarnChecksum.Visible = $true
    }

    $header = $script:OriginalEdidBlock0[0..7]
    if (($header -join ',') -ne ($EdidHeader -join ',')) {
        [System.Windows.Forms.MessageBox]::Show('ERROR: invalid EDID 1.4 header!', 'Parse error', 'OK', 'Error') | Out-Null
        return $false
    }
    $revision = $script:OriginalEdidBlock0[$AddrEdidRevision]
    if ($script:OriginalEdidBlock0[$AddrEdidVersion] -ne 1 -or ($revision -ne 3 -and $revision -ne 4)) {
        [System.Windows.Forms.MessageBox]::Show('ERROR: unsupported EDID version/revision!', 'Parse error', 'OK', 'Error') | Out-Null
        return $false
    }

    $ptmPixel = Get-EdidPtmPixelSize $script:OriginalEdidBlock0
    $numHPixel.Value = [Math]::Min([Math]::Max($ptmPixel[0], 0), $numHPixel.Maximum)
    $numVPixel.Value = [Math]::Min([Math]::Max($ptmPixel[1], 0), $numVPixel.Maximum)

    $physDim = Get-EdidPhysicalDimension $script:OriginalEdidBlock0
    $diagInch = Convert-CmToInch (Get-DiagonalSize $physDim[0] $physDim[1])
    $numDiagonal.Value = [Math]::Min([Math]::Max([Math]::Round($diagInch, 1), 0), $numDiagonal.Maximum)

    $lblDeviceInstancePath.Text = "Device Instance Path: $($script:CurrentInstancePath)"
    $lblOrigPhysicalSize.Text = "Screen physical dimension (Windows uses this): $($physDim[0]) x $($physDim[1]) cm"
    $ptmDim = Get-EdidPtmDimension $script:OriginalEdidBlock0
    $lblOrigPtmSize.Text = "PTM screen dimension: $($ptmDim[0]) x $($ptmDim[1]) cm"

    $btnSaveOverride.Enabled = $true
    $btnSaveRemoval.Enabled = $true

    Update-NewEdid
    return $true
}

# --- Monitor list ---
function Update-MonitorList {
    $cmbMonitors.Items.Clear()
    $monitors = Get-MonitorList
    if (-not $monitors) {
        [System.Windows.Forms.MessageBox]::Show('No monitors with Status=OK were found via Get-PnpDevice.', 'No monitors found', 'OK', 'Warning') | Out-Null
        return
    }
    foreach ($dev in $monitors) {
        $item = [PSCustomObject]@{ Name = $dev.Name; InstanceId = $dev.InstanceId }
        $item | Add-Member -MemberType ScriptMethod -Name ToString -Value { "$($this.Name)  [$($this.InstanceId)]" } -Force
        $cmbMonitors.Items.Add($item) | Out-Null
    }
    if ($cmbMonitors.Items.Count -gt 0) { $cmbMonitors.SelectedIndex = 0 }
}

$btnRefreshMonitors.Add_Click({ Update-MonitorList })

$btnLoadMonitor.Add_Click({
    if ($null -eq $cmbMonitors.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show('Select a monitor from the list first.', 'No monitor selected', 'OK', 'Warning') | Out-Null
        return
    }
    $sel = $cmbMonitors.SelectedItem
    Reset-App

    $edidBytes = Get-EdidFromRegistry $sel.InstanceId
    if ($null -eq $edidBytes) {
        [System.Windows.Forms.MessageBox]::Show("Could not read the EDID registry value for:`n$($sel.InstanceId)", 'Read failed', 'OK', 'Error') | Out-Null
        return
    }

    $backupPath = Backup-DeviceParameters $sel.InstanceId $sel.Name
    if ($null -eq $backupPath) {
        [System.Windows.Forms.MessageBox]::Show("Failed to create a backup of the Device Parameters registry key. Aborting for safety - no changes were loaded.", 'Backup failed', 'OK', 'Error') | Out-Null
        return
    }

    $script:CurrentInstancePath = $sel.InstanceId
    $script:CurrentDeviceName = $sel.Name
    $script:CanWriteRegistryLive = $true
    $script:LastBackupPath = $backupPath
    $lblBackupPath.Text = "Backup saved: $backupPath"
    $lblLoadedFile.Text = "Loaded live from registry: $($sel.Name)"

    if (Test-EdidOverrideExists $sel.InstanceId) {
        $lblWarnOverride.Visible = $true
    }

    if (Import-EdidBlock0 $edidBytes) {
        $btnApplyOverride.Enabled = $true
        $btnRemoveOverride.Enabled = $true
    }
})

# --- Advanced: manual .reg file (export/import only, never a direct write target) ---
$btnOpenReg.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Registry files (*.reg)|*.reg|All files (*.*)|*.*'
    $dlg.Title = 'Open exported monitor registry file'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    Reset-App

    $content = Get-Content -LiteralPath $dlg.FileName -Raw
    $parsed = ConvertFrom-RegFile $content

    if (-not $parsed.IsValidRegFile) {
        [System.Windows.Forms.MessageBox]::Show('Invalid .reg file content!', 'Parse error', 'OK', 'Error') | Out-Null
        return
    }
    if (-not $parsed.IsEdidFound) {
        [System.Windows.Forms.MessageBox]::Show('EDID information not found in .reg file!', 'Parse error', 'OK', 'Error') | Out-Null
        return
    }

    $script:CurrentInstancePath = $parsed.DeviceInstancePath
    $script:CanWriteRegistryLive = $false   # never write directly for a file loaded this way
    $lblLoadedFile.Text = "Loaded from file: $([System.IO.Path]::GetFileName($dlg.FileName)) (export/import only)"

    if ($parsed.IsEdidOverridden) { $lblWarnOverride.Visible = $true }

    Import-EdidBlock0 $parsed.EdidData | Out-Null
    # Apply/Remove-to-registry stay disabled: this data may not even be for this machine's current device.
})

$numDiagonal.Add_ValueChanged({ Update-NewEdid })
$numHPixel.Add_ValueChanged({ Update-NewEdid })
$numVPixel.Add_ValueChanged({ Update-NewEdid })
$chkModifyPtm.Add_CheckedChanged({ Update-NewEdid })

$btnCopyHex.Add_Click({
    if ($script:NewEdidBlock0.Length -eq 0) { return }
    [System.Windows.Forms.Clipboard]::SetText((ConvertTo-EdidHexString $script:NewEdidBlock0))
    [System.Windows.Forms.MessageBox]::Show('Hex string copied to clipboard!', 'Copied', 'OK', 'Information') | Out-Null
})

# --- Direct registry apply/remove (live monitors only) ---
$btnApplyOverride.Add_Click({
    if (-not $script:CanWriteRegistryLive) { return }
    $regPath = Join-Path (Get-DeviceParametersPath $script:CurrentInstancePath) 'EDID_OVERRIDE'
    $msg = "This writes the modified EDID directly to:`n$regPath`n`nBackup saved at:`n$($script:LastBackupPath)`n`nReboot (or reconnect an external monitor) is required for it to take effect. Continue?"
    $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Confirm registry write', 'YesNo', 'Warning')
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        Set-EdidOverrideInRegistry $script:CurrentInstancePath $script:NewEdidBlock0
        [System.Windows.Forms.MessageBox]::Show('EDID override written to the registry. Reboot / reconnect the monitor to apply it.', 'Done', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to write the registry value:`n$($_.Exception.Message)`n`nYou can still use the 'Save EDID Override .reg...' button below and import it manually.", 'Write failed', 'OK', 'Error') | Out-Null
    }
})

$btnRemoveOverride.Add_Click({
    if (-not $script:CanWriteRegistryLive) { return }
    $msg = "This removes the EDID_OVERRIDE value for:`n$($script:CurrentInstancePath)`n`nBackup saved at:`n$($script:LastBackupPath)`n`nReboot (or reconnect an external monitor) is required for it to take effect. Continue?"
    $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Confirm registry removal', 'YesNo', 'Warning')
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        Remove-EdidOverrideFromRegistry $script:CurrentInstancePath
        [System.Windows.Forms.MessageBox]::Show('EDID override removed. Reboot / reconnect the monitor to apply it.', 'Done', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to remove the registry value:`n$($_.Exception.Message)", 'Removal failed', 'OK', 'Error') | Out-Null
    }
})

# --- Manual export (fallback / sharing) ---
$btnSaveOverride.Add_Click({
    $devicePath = $script:CurrentInstancePath
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'Registry files (*.reg)|*.reg'
    $safeName = ($devicePath -replace '[\\/:*?"<>|]', '_')
    $dlg.FileName = "$safeName-$($numDiagonal.Value)inch-edid_override.reg"
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $content = New-OverrideRegContent $devicePath $script:NewEdidBlock0
    [System.IO.File]::WriteAllText($dlg.FileName, $content, [System.Text.Encoding]::Unicode)
    [System.Windows.Forms.MessageBox]::Show("Saved:`n$($dlg.FileName)`n`nReview it in Notepad before double-clicking to import.", 'Saved', 'OK', 'Information') | Out-Null
})

$btnSaveRemoval.Add_Click({
    $devicePath = $script:CurrentInstancePath
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'Registry files (*.reg)|*.reg'
    $safeName = ($devicePath -replace '[\\/:*?"<>|]', '_')
    $dlg.FileName = "$safeName-edid_override_removal.reg"
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $content = New-OverrideRemovalRegContent $devicePath
    [System.IO.File]::WriteAllText($dlg.FileName, $content, [System.Text.Encoding]::Unicode)
    [System.Windows.Forms.MessageBox]::Show("Saved:`n$($dlg.FileName)", 'Saved', 'OK', 'Information') | Out-Null
})

Reset-App
Update-MonitorList
[System.Windows.Forms.Application]::Run($form)
