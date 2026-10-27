# Deploy the experimental B550M / RTX 3070 Ti unlock package to the dedicated ESP.
# GPL-2.0-only, follows the Windows-GPU-UNLOCK internal-boot layout.
#
# Adds, and never removes, existing content:
#   <ESP>:\EFI\Unlock\UNLOCK.EFI
#   <ESP>:\RTX3090-UNLOCK\ASSETS\<5 firmware assets> + NVIDIA-LICENSE
#   one firmware boot entry appended at the END of the boot order
#
# The read-only probe package (\EFI\Probe, \RTX3090-UNLOCK DIAG/PROM/IMG) is
# untouched and keeps its own boot entry.
#
# Elevated usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File deploy-unlock.ps1 -AssetDir <dir>
#   ... -SkipBootEntry     # refresh files only
#   ... -Rollback          # remove the boot entry (files stay)

param(
  [string]$Efi = 'D:\Home\Documents\Work\gpu-unlock-research\Release\EFI\Unlock\UNLOCK.EFI',
  [string]$AssetDir = 'D:\Home\Documents\Work\gpu-unlock-research\Release\RTX3090-UNLOCK\ASSETS',
  [string]$AssetManifest = 'D:\Home\Documents\Work\gpu-unlock-research\src\unlock\assets.json',
  [string]$ProbePartitionGuid = '83174347-29a4-4b33-b6c6-410766959c79',
  [string]$WindowsEspGuid = '33b8e955-346d-4e74-ade7-7b73c5112c0a',
  [string]$Description = 'GPU Unlock B550M-3070Ti (EXPERIMENTAL)',
  [int]$MinFreeMB = 120,
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
function Find-FreeDriveLetter {
  foreach ($c in [char[]]'ZYXWVUTSRQ') { if (-not (Test-Path -LiteralPath "${c}:\")) { return "$c" } }
  throw 'No free drive letter available.'
}
# In-place overwrite is refused on this volume, and [IO.File]::Delete is refused
# too; only Remove-Item succeeds. It routes deletions into the volume's
# $RECYCLE.BIN, so large assets are skipped when their hash already matches and
# this path is only used for small files.
function Put-File([string]$Source, [string]$Dest) {
  for ($a = 1; $a -le 5; $a++) {
    try {
      if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force -ErrorAction Stop }
      Copy-Item -LiteralPath $Source -Destination $Dest -Force -ErrorAction Stop
      return
    } catch {
      Write-Host "  write attempt ${a} failed for $(Split-Path $Dest -Leaf): $($_.Exception.Message)"
      Start-Sleep -Seconds 1
    }
  }
  throw "Could not write $Dest after 5 attempts."
}

Assert-Admin

$probePart = @(Get-Partition | Where-Object { $_.Guid -and ([guid]$_.Guid).ToString() -eq ([guid]$ProbePartitionGuid).ToString() })
if ($probePart.Count -ne 1) { throw "Target partition GUID not found exactly once: $ProbePartitionGuid" }
$probePart = $probePart[0]
if ($probePart.IsSystem) { throw 'Refusing: selected partition is the system partition.' }
if ($probePart.GptType -ne $EspType) { throw 'Refusing: partition type is not EFI System Partition.' }
if ($probePart.Size -lt 1GB) { throw 'Refusing: partition smaller than 1 GiB.' }
if (([guid]$probePart.Guid).ToString() -eq ([guid]$WindowsEspGuid).ToString()) { throw 'Refusing: target is the Windows ESP.' }
$winEsp = @(Get-Partition | Where-Object { $_.Guid -and ([guid]$_.Guid).ToString() -eq ([guid]$WindowsEspGuid).ToString() })
if ($winEsp.Count -ne 1 -or -not $winEsp[0].IsSystem) { throw 'WindowsEspGuid must identify the current system EFI partition.' }

# ---------------------------------------------------------------- rollback
if ($Rollback) {
  $fw = (& bcdedit /enum firmware 2>&1 | Out-String)
  $idx = $fw.IndexOf($Description, [StringComparison]::Ordinal)
  if ($idx -lt 0) { Write-Host 'No firmware entry with that description found.'; return }
  $before = @([regex]::Matches($fw.Substring(0, $idx), $GuidPattern) | ForEach-Object { $_.Value.ToLowerInvariant() })
  if ($before.Count -eq 0) { throw 'Could not locate the entry GUID.' }
  $target = $before[$before.Count - 1]
  & bcdedit /delete $target | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'bcdedit /delete failed' }
  Write-Host "Deleted firmware entry $target"
  Write-Host 'Files under \EFI\Unlock and \RTX3090-UNLOCK\ASSETS were left in place.'
  return
}

# ---------------------------------------------------------------- verify payload
if (-not (Test-Path -LiteralPath $Efi -PathType Leaf)) { throw "EFI not found: $Efi" }
if (-not (Test-Path -LiteralPath $AssetManifest -PathType Leaf)) { throw "Asset manifest not found: $AssetManifest" }
$efiSha = (Get-FileHash -LiteralPath $Efi -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "EFI            : $(Split-Path $Efi -Leaf)  $efiSha  ($((Get-Item $Efi).Length) bytes)"

$manifest = Get-Content -LiteralPath $AssetManifest -Raw | ConvertFrom-Json
$checks = @()
$total = 0
foreach ($entry in $manifest) {
  $src = Join-Path $AssetDir $entry.Name
  if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "Missing asset: $src" }
  $len = (Get-Item -LiteralPath $src).Length
  if ($len -ne [int64]$entry.Bytes) { throw "Size mismatch for $($entry.Name): got $len, expected $($entry.Bytes)" }
  $h = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($h -ne $entry.Sha256.ToLowerInvariant()) { throw "SHA256 mismatch for $($entry.Name): got $h" }
  $checks += [pscustomobject]@{ Name = $entry.Name; Bytes = $len; Sha256 = $h }
  $total += $len
  Write-Host "  asset ok     : $($entry.Name)  $len bytes"
}
$license = Join-Path $AssetDir 'NVIDIA-LICENSE'
if (-not (Test-Path -LiteralPath $license -PathType Leaf)) { Write-Host '  note         : NVIDIA-LICENSE not present; copying without it' }
Write-Host "Assets total   : $([math]::Round($total/1MB,1)) MB"

# ---------------------------------------------------------------- mount
$letter = $null
if ($probePart.DriveLetter -and $probePart.DriveLetter -ne [char]0) {
  $letter = [string]$probePart.DriveLetter; $mounted = $false
} else {
  $letter = Find-FreeDriveLetter
  & mountvol "${letter}:" "\\?\Volume{$(([guid]$probePart.Guid).ToString())}\"
  if ($LASTEXITCODE -ne 0) { throw "mountvol failed with exit code $LASTEXITCODE" }
  $mounted = $true; Start-Sleep -Milliseconds 800
}

$new = $null
try {
  if (-not (Test-Path -LiteralPath "${letter}:\")) { throw "Volume not present at ${letter}:" }
  $fs = (Get-Volume -DriveLetter $letter).FileSystem
  $freeMB = [math]::Round((Get-Volume -DriveLetter $letter).SizeRemaining / 1MB)
  Write-Host "Target         : ${letter}: $fs, free ${freeMB} MB"
  if ($fs -notin @('FAT32','FAT')) { throw "Refusing: $fs is not a FAT file system." }
  if ($freeMB -lt $MinFreeMB) { throw "Refusing: only $freeMB MB free, need $MinFreeMB MB." }

  $efiDir = "${letter}:\EFI\Unlock"
  $assetOut = "${letter}:\RTX3090-UNLOCK\ASSETS"
  foreach ($d in @($efiDir, $assetOut)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

  Put-File $Efi (Join-Path $efiDir 'UNLOCK.EFI')
  $destSha = (Get-FileHash -LiteralPath (Join-Path $efiDir 'UNLOCK.EFI') -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($destSha -ne $efiSha) { throw 'UNLOCK.EFI copy verification failed.' }
  Write-Host "Installed      : ${letter}:\EFI\Unlock\UNLOCK.EFI (verified)"

  foreach ($c in $checks) {
    $dest = Join-Path $assetOut $c.Name
    if (Test-Path -LiteralPath $dest) {
      $have = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($have -eq $c.Sha256) {
        Write-Host "Present        : ASSETS\$($c.Name) (hash matches, not rewritten)"
        continue
      }
    }
    Put-File (Join-Path $AssetDir $c.Name) $dest
    $dh = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($dh -ne $c.Sha256) { throw "Copy verification failed for $($c.Name)" }
    Write-Host "Installed      : ASSETS\$($c.Name) (verified)"
  }
  if (Test-Path -LiteralPath $license -PathType Leaf) { Put-File $license (Join-Path $assetOut 'NVIDIA-LICENSE') }

  if ($SkipBootEntry) { Write-Host 'Skipping boot-entry registration (-SkipBootEntry).'; return }

  $existingFw = (& bcdedit /enum firmware 2>&1 | Out-String)
  if ($existingFw.IndexOf($Description, [StringComparison]::Ordinal) -ge 0) {
    throw "Refusing: a firmware entry named '$Description' already exists. Run with -Rollback first."
  }
  $idsBefore = @([regex]::Matches($existingFw, $GuidPattern) | ForEach-Object { $_.Value.ToLowerInvariant() } | Sort-Object -Unique)
  $null = (& bcdedit /copy '{bootmgr}' /d "$Description" 2>&1)
  if ($LASTEXITCODE -ne 0) { throw 'bcdedit /copy failed' }
  $idsAfter = @([regex]::Matches((& bcdedit /enum firmware 2>&1 | Out-String), $GuidPattern) | ForEach-Object { $_.Value.ToLowerInvariant() } | Sort-Object -Unique)
  $created = @($idsAfter | Where-Object { $idsBefore -notcontains $_ })
  if ($created.Count -ne 1) { throw "Expected exactly one new firmware entry, found $($created.Count)." }
  $new = $created[0]

  & bcdedit /set $new device "partition=${letter}:" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'bcdedit /set device failed' }
  & bcdedit /set $new path '\EFI\Unlock\UNLOCK.EFI' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'bcdedit /set path failed' }
  & bcdedit /set $new description "$Description" | Out-Null
  & bcdedit /set '{fwbootmgr}' displayorder $new /addlast | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'bcdedit displayorder /addlast failed' }

  $after = (& bcdedit /enum firmware 2>&1 | Out-String)
  if ($after -notmatch [regex]::Escape($new)) { throw 'New entry missing after registration.' }
  Write-Host "New entry      : $new (appended at the END)"
  Write-Host ''
  & bcdedit /enum '{fwbootmgr}'
}
catch {
  if ($new) { Write-Host "Cleaning up partially registered entry $new ..."; & bcdedit /delete $new 2>&1 | Out-Null }
  throw
}
finally {
  if ($mounted) { & mountvol "${letter}:" /D | Out-Null }
}

Write-Host ''
Write-Host 'Done. The unlock entry is registered but the default boot order is unchanged.'
Write-Host 'Undo the boot entry with -Rollback; the files stay on the ESP.'
