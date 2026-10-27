# Collect the read-only GPU probe capture out of the PE partition.
# GPL-2.0-only. Read-only with respect to the source partition: it copies files
# out and never deletes or modifies anything on the ESP.
#
# Elevated usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File collect-probe.ps1

param(
  [string]$ProbePartitionGuid = '83174347-29a4-4b33-b6c6-410766959c79',
  [string]$OutRoot = 'D:\Home\Documents\Work\gpu-unlock-research\evidence\probe-captures'
)

$ErrorActionPreference = 'Stop'
$ProbePartitionGuid = $ProbePartitionGuid

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

Assert-Admin

$probePart = @(Get-Partition | Where-Object { $_.Guid -and ([guid]$_.Guid).ToString() -eq ([guid]$ProbePartitionGuid).ToString() })
if ($probePart.Count -ne 1) { throw "Probe partition GUID not found exactly once: $ProbePartitionGuid" }
$probePart = $probePart[0]

$letter = $null
if ($probePart.DriveLetter -and $probePart.DriveLetter -ne [char]0) {
  $letter = [string]$probePart.DriveLetter
  $mounted = $false
} else {
  $letter = Find-FreeDriveLetter
  $vol = "\\?\Volume{$(([guid]$probePart.Guid).ToString())}\"
  & mountvol "${letter}:" $vol
  if ($LASTEXITCODE -ne 0) { throw "mountvol failed with exit code $LASTEXITCODE" }
  $mounted = $true
  Start-Sleep -Milliseconds 800
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dest = Join-Path $OutRoot "run-$stamp"
try {
  $src = "${letter}:\RTX3090-UNLOCK"
  if (-not (Test-Path -LiteralPath $src)) { throw "No capture directory at ${letter}:\RTX3090-UNLOCK - the probe may not have run." }
  $files = @(Get-ChildItem -LiteralPath $src -File)
  if ($files.Count -eq 0) { throw 'Capture directory is empty.' }
  New-Item -ItemType Directory -Path $dest -Force | Out-Null
  # -LiteralPath does not expand wildcards; enumerate and copy instead.
  Get-ChildItem -LiteralPath $src -File | Copy-Item -Destination $dest -Force
  Write-Host "Copied $($files.Count) file(s) to $dest"
}
finally {
  if ($mounted) { & mountvol "${letter}:" /D | Out-Null }
}

Write-Host ''
Write-Host '--- capture inventory ---'
Get-ChildItem -LiteralPath $dest -File |
  Sort-Object Name |
  Select-Object Name, @{n='KB';e={[math]::Round($_.Length/1KB,1)}} |
  Format-Table -AutoSize

$diag = Join-Path $dest 'DIAG00.TXT'
if (Test-Path -LiteralPath $diag) {
  Write-Host '--- key lines from DIAG00.TXT ---'
  $keys = 'probe status','probe-target','probe targets','probe-inventory','subsystem','probe-bar0','mmio off','prom',
          'chip','memory','gops=','console-out','conin','probe-unreviewed','probe-identity','problem'
  Get-Content -LiteralPath $diag | Where-Object {
    $line = $_
    $hit = $false
    foreach ($k in $keys) { if ($line -match [regex]::Escape($k)) { $hit = $true; break } }
    $hit
  } | Select-Object -First 200
}
Write-Host ''
Write-Host "Full capture: $dest"
