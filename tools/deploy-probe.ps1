# Read-only GPU probe deployment for ASUS TUF B550M-PLUS (WI-FI) + Colorful RTX 3070 Ti.
# GPL-2.0-only, follows the Windows-GPU-UNLOCK internal-boot layout.
#
# This script ADDS two directories and ONE firmware boot entry. It never formats,
# resizes, moves or deletes any existing partition or file. The PE system already
# on the target partition is left byte-identical; nothing outside these paths is
# touched:
#
#   <probe partition>:\EFI\Probe\PROBE.EFI
#   <probe partition>:\RTX3090-UNLOCK\        (probe capture output)
#
# Elevated usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File deploy-probe.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File deploy-probe.ps1 -Rollback

param(
  [string]$Efi = 'D:\Home\Documents\Work\gpu-unlock-research\src\internal-boot\boot\build\diagnostic\DIAGNOSTIC.EFI',
  [string]$ExpectedSha256 = '50d6e73f22ef39041e605562044beb2e8b9073bcdfd373545c1b429e5060029a',
  [string]$ProbePartitionGuid = '83174347-29a4-4b33-b6c6-410766959c79',
  [string]$WindowsEspGuid = '33b8e955-346d-4e74-ade7-7b73c5112c0a',
  [string]$Description = 'GPU Probe B550M-3070Ti (read-only)',
  [int]$MinFreeMB = 100,
  [switch]$ReplaceExisting,
  [switch]$SkipBootEntry,
  [switch]$Rollback
)

$ErrorActionPreference = 'Stop'
$EspType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$GuidPattern = '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}'

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell window.'
  }
}

function Get-Guids([string]$Text) {
  $out = @()
  foreach ($m in [regex]::Matches($Text, $GuidPattern)) { $out += $m.Value.ToLowerInvariant() }
  return $out
}

function Find-FreeDriveLetter {
  foreach ($c in [char[]]'ZYXWVUTSRQ') {
    if (-not (Test-Path -LiteralPath "${c}:\")) { return "$c" }
  }
  throw 'No free drive letter available for the temporary mount.'
}

Assert-Admin

# ---------------------------------------------------------------- locate partitions
$probePart = @(Get-Partition | Where-Object { $_.Guid -and ([guid]$_.Guid).ToString() -eq ([guid]$ProbePartitionGuid).ToString() })
if ($probePart.Count -ne 1) { throw "Probe partition GUID not found exactly once: $ProbePartitionGuid" }
$probePart = $probePart[0]

if ($probePart.IsSystem) { throw 'Refusing: the selected partition is reported as the system partition.' }
if ($probePart.GptType -ne $EspType) { throw "Refusing: partition type is not EFI System Partition ($($probePart.GptType))." }
if ($probePart.Size -lt 1GB) { throw "Refusing: partition is smaller than 1 GiB ($($probePart.Size) bytes)." }
if (([guid]$probePart.Guid).ToString() -eq ([guid]$WindowsEspGuid).ToString()) { throw 'Refusing: the probe partition is the Windows ESP.' }

$winEsp = @(Get-Partition | Where-Object { $_.Guid -and ([guid]$_.Guid).ToString() -eq ([guid]$WindowsEspGuid).ToString() })
if ($winEsp.Count -ne 1 -or -not $winEsp[0].IsSystem) { throw 'WindowsEspGuid must identify the current system EFI partition.' }

Write-Host "Probe partition : disk $($probePart.DiskNumber) part $($probePart.PartitionNumber), $([math]::Round($probePart.Size/1GB,2)) GiB, type $($probePart.GptType)"
Write-Host "Windows ESP     : disk $($winEsp[0].DiskNumber) part $($winEsp[0].PartitionNumber)"

# ---------------------------------------------------------------- rollback
if ($Rollback) {
  $fw = (& bcdedit /enum firmware 2>&1 | Out-String)
  $idx = $fw.IndexOf($Description, [StringComparison]::Ordinal)
  if ($idx -lt 0) { Write-Host 'No firmware entry with that description found; nothing to remove.'; return }
  $guidsBefore = @(Get-Guids $fw.Substring(0, $idx))
  if ($guidsBefore.Count -eq 0) { throw 'Could not locate the entry GUID preceding the description.' }
  $target = $guidsBefore[$guidsBefore.Count - 1]
  & bcdedit /delete $target
  if ($LASTEXITCODE -ne 0) { throw 'bcdedit /delete failed' }
  Write-Host "Deleted firmware entry $target"
  Write-Host 'Files under \EFI\Probe and \RTX3090-UNLOCK were left in place; remove them manually if desired.'
  return
}

# ---------------------------------------------------------------- verify payload
if (-not (Test-Path -LiteralPath $Efi -PathType Leaf)) { throw "EFI not found: $Efi" }
$sha = (Get-FileHash -LiteralPath $Efi -Algorithm SHA256).Hash.ToLowerInvariant()
if ($sha -ne $ExpectedSha256.ToLowerInvariant()) { throw "EFI SHA256 mismatch: got $sha, expected $ExpectedSha256" }
Write-Host "EFI verified   : $sha"

# ---------------------------------------------------------------- mount if needed
$letter = $null
if ($probePart.DriveLetter -and $probePart.DriveLetter -ne [char]0) {
  $letter = [string]$probePart.DriveLetter
  $mounted = $false
  Write-Host "Partition already has drive letter ${letter}:; using it as-is."
} else {
  $letter = Find-FreeDriveLetter
  $vol = "\\?\Volume{$(([guid]$probePart.Guid).ToString())}\"
  Write-Host "Mounting $vol as ${letter}: ..."
  & mountvol "${letter}:" $vol
  if ($LASTEXITCODE -ne 0) { throw "mountvol failed with exit code $LASTEXITCODE" }
  $mounted = $true
  Start-Sleep -Milliseconds 800
}

$new = $null
try {
  if (-not (Test-Path -LiteralPath "${letter}:\")) { throw "Volume not present at ${letter}:" }

  $freeMB = [math]::Round((Get-Volume -DriveLetter $letter).SizeRemaining / 1MB)
  $fs = (Get-Volume -DriveLetter $letter).FileSystem
  Write-Host "File system    : $fs"
  Write-Host "Free space     : $freeMB MB"
  if ($fs -notin @('FAT32','FAT')) { throw "Refusing: $fs is not a FAT file system; firmware cannot read it as an ESP." }
  if ($freeMB -lt $MinFreeMB) { throw "Only $freeMB MB free; refusing to write (minimum $MinFreeMB MB). Nothing was changed." }

  $efiDir = "${letter}:\EFI\Probe"
  $capDir = "${letter}:\RTX3090-UNLOCK"
  if (-not (Test-Path -LiteralPath $efiDir)) { New-Item -ItemType Directory -Path $efiDir -Force | Out-Null }
  if (-not (Test-Path -LiteralPath $capDir)) { New-Item -ItemType Directory -Path $capDir -Force | Out-Null }

  $dest = Join-Path $efiDir 'PROBE.EFI'
  if (Test-Path -LiteralPath $dest) {
    $oldSha = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($oldSha -ne $ExpectedSha256.ToLowerInvariant()) {
      if (-not $ReplaceExisting) {
        throw "Refusing: $dest already exists with a different hash ($oldSha). Pass -ReplaceExisting for a new build; nothing was changed."
      }
      Write-Host "Existing       : $dest has a different hash ($oldSha); replacing because -ReplaceExisting was given."
    } else {
      Write-Host "Existing       : $dest already matches; replacing with a fresh copy."
    }
  }
  # On this volume an in-place overwrite of an existing file is refused while
  # create and delete are both allowed (write-open is denied even for an
  # Archive-only file). Delete first, then create.
  $copied = $false
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    try {
      if (Test-Path -LiteralPath $dest) { [IO.File]::Delete($dest) }
      Copy-Item -LiteralPath $Efi -Destination $dest -Force -ErrorAction Stop
      $copied = $true
      break
    } catch {
      Write-Host "Copy attempt $attempt failed: $($_.Exception.Message)"
      Start-Sleep -Seconds 1
    }
  }
  if (-not $copied) { throw "Could not copy the EFI to $dest after 5 attempts." }
  $destSha = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($destSha -ne $ExpectedSha256.ToLowerInvariant()) { throw "Copy verification failed: $destSha" }
  Write-Host "Installed      : ${letter}:\EFI\Probe\PROBE.EFI (verified)"

  if ($SkipBootEntry) {
    Write-Host 'Skipping boot-entry registration (-SkipBootEntry).'
    return
  }

  # -------------------------------------------------------------- register boot entry
  # Refuse to accumulate duplicate entries on repeated runs.
  $existingFw = (& bcdedit /enum firmware 2>&1 | Out-String)
  if ($existingFw.IndexOf($Description, [StringComparison]::Ordinal) -ge 0) {
    throw "Refusing: a firmware entry named '$Description' already exists. Run with -Rollback first."
  }

  # Snapshot identifiers, copy, then take the difference. Parsing bcdedit's
  # localized success message is fragile, and a single match unrolls to a plain
  # string under PowerShell indexing, which silently yields the first character.
  $idsBefore = @([regex]::Matches($existingFw, $GuidPattern) |
                 ForEach-Object { $_.Value.ToLowerInvariant() } | Sort-Object -Unique)
  $null = (& bcdedit /copy '{bootmgr}' /d "$Description" 2>&1)
  if ($LASTEXITCODE -ne 0) { throw 'bcdedit /copy failed' }
  $idsAfter = @([regex]::Matches((& bcdedit /enum firmware 2>&1 | Out-String), $GuidPattern) |
                ForEach-Object { $_.Value.ToLowerInvariant() } | Sort-Object -Unique)
  $created = @($idsAfter | Where-Object { $idsBefore -notcontains $_ })
  if ($created.Count -ne 1) { throw "Expected exactly one new firmware entry, found $($created.Count)." }
  $new = $created[0]
  Write-Host "New entry      : $new"

  & bcdedit /set $new device "partition=${letter}:" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'bcdedit /set device failed' }
  & bcdedit /set $new path '\EFI\Probe\PROBE.EFI' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'bcdedit /set path failed' }
  & bcdedit /set $new description "$Description" | Out-Null

  & bcdedit /set '{fwbootmgr}' displayorder $new /addlast | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'bcdedit displayorder /addlast failed' }

  $after = (& bcdedit /enum firmware 2>&1 | Out-String)
  if ($after -notmatch [regex]::Escape($new)) { throw 'New entry missing from firmware enumeration after registration' }
  Write-Host ''
  Write-Host 'Firmware boot order now:'
  & bcdedit /enum '{fwbootmgr}'
  Write-Host ''
  Write-Host 'Entry appended at the END. Default boot is unchanged.'
}
catch {
  if ($new) {
    Write-Host "Cleaning up partially registered entry $new ..."
    & bcdedit /delete $new 2>&1 | Out-Null
  }
  throw
}
finally {
  if ($mounted) {
    Write-Host "Unmounting ${letter}: ..."
    & mountvol "${letter}:" /D | Out-Null
  }
}

Write-Host ''
Write-Host 'Done. Next steps:'
Write-Host '  1. Shut down completely (shutdown, not restart) so the GPU is in its power-on state.'
Write-Host '  2. Power on, press F8, select the entry named above.'
Write-Host '  3. The probe writes DIAG00.TXT / PROM.BIN / IMGnn.BIN, then boots Windows by itself.'
Write-Host '  4. Undo with: -Rollback (removes the entry; files stay).'
