# Fixed-payload prefill/decode probe against a running llama.cpp server.
# Run it once per boot so the unlocked and baseline boots are compared with an
# identical request. Appends one JSON line per run; never overwrites.
#
#   powershell -NoProfile -File bench_llama_prefill.ps1 -Label unlocked
#   ... reboot normally ...
#   powershell -NoProfile -File bench_llama_prefill.ps1 -Label baseline
#   powershell -NoProfile -File bench_llama_prefill.ps1 -Compare

param(
  [string]$Endpoint = 'http://127.0.0.1:2333/completion',
  [int]$Repeat = 900,            # "The quick brown fox..." repetitions -> ~9001 prompt tokens
  [int]$NPredict = 32,
  [string]$Label = '',
  [string]$Log = 'D:\Home\Documents\Work\gpu-unlock-research\evidence\llama-prefill.jsonl',
  [switch]$Compare
)

$ErrorActionPreference = 'Stop'

if ($Compare) {
  if (-not (Test-Path -LiteralPath $Log)) { throw "No measurements yet: $Log" }
  $rows = Get-Content -LiteralPath $Log | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }
  $rows | Select-Object label, boot, prompt_n, prompt_per_second, predicted_per_second, gpu |
    Format-Table -AutoSize
  $pair = $rows | Group-Object { $_.prompt_n } | Where-Object { $_.Count -ge 2 } | Select-Object -First 1
  if ($pair) {
    $vals = $pair.Group | Sort-Object label
    if ($vals.Count -ge 2) {
      $a = [double]$vals[0].prompt_per_second; $b = [double]$vals[1].prompt_per_second
      "prefill: {0} = {1:N1} tok/s | {2} = {3:N1} tok/s | delta = {4:+0.0;-0.0}%" -f `
        $vals[0].label, $a, $vals[1].label, $b, (($b / $a - 1) * 100)
    }
  }
  return
}

if (-not $Label) { $Label = 'run' }

$body = @{
  prompt     = ('The quick brown fox jumps over the lazy dog. ' * $Repeat)
  n_predict  = $NPredict
  temperature = 0
  cache_prompt = $false
} | ConvertTo-Json -Compress

$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$gpu = (nvidia-smi --query-gpu=name,clocks.sm,clocks.mem --format=csv,noheader 2>$null) -join ' | '

$r = Invoke-RestMethod -Uri $Endpoint -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 600

$row = [ordered]@{
  label                  = $Label
  at                     = (Get-Date).ToString('o')
  boot                   = $boot.ToString('o')
  gpu                    = $gpu
  prompt_n               = $r.timings.prompt_n
  prompt_ms              = [math]::Round($r.timings.prompt_ms, 1)
  prompt_per_second      = [math]::Round($r.timings.prompt_per_second, 2)
  predicted_n            = $r.timings.predicted_n
  predicted_ms           = [math]::Round($r.timings.predicted_ms, 1)
  predicted_per_second   = [math]::Round($r.timings.predicted_per_second, 2)
}

$dir = Split-Path -Parent $Log
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
($row | ConvertTo-Json -Compress) | Add-Content -LiteralPath $Log -Encoding utf8

"label      : $Label"
"boot       : $boot"
"gpu        : $gpu"
"prefill    : $($row.prompt_per_second) tok/s   ($($row.prompt_n) tokens in $($row.prompt_ms) ms)"
"decode     : $($row.predicted_per_second) tok/s"
"logged to  : $Log"
