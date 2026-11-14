# night_lib.ps1
# Shared helpers for the USDT-M day trader: signed/public Binance Futures REST,
# plus EMA / RSI / ATR percent. Keys are loaded from keys.json next to this file.
# This file never logs or prints key values.
# NOTE: The original night_lib.ps1 lived only on the trading PC and could not be
# copied (PC was offline). This is a clean reimplementation of the functions
# actually called by day_trade_run.ps1: Call-S, Call-P, EMA, ATRpct, RSI.

$ErrorActionPreference = "Stop"

$script:LibDir = $PSScriptRoot
if (-not $script:LibDir) { $script:LibDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:KeysPath = Join-Path $script:LibDir "keys.json"
$script:FapiBase = "https://fapi.binance.com"
$script:RecvWindow = 10000

function Get-LocalKeys {
  if (-not (Test-Path -LiteralPath $script:KeysPath)) {
    throw "keys.json not found at $script:KeysPath (copy keys.example.json and fill in your API key and secret)."
  }
  $k = Get-Content -LiteralPath $script:KeysPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $apiKey = $null
  $apiSecret = $null
  if ($k.PSObject.Properties.Name -contains "apiKey") { $apiKey = [string]$k.apiKey }
  elseif ($k.PSObject.Properties.Name -contains "key") { $apiKey = [string]$k.key }
  if ($k.PSObject.Properties.Name -contains "apiSecret") { $apiSecret = [string]$k.apiSecret }
  elseif ($k.PSObject.Properties.Name -contains "secret") { $apiSecret = [string]$k.secret }
  if (-not $apiKey -or -not $apiSecret) {
    throw "keys.json must contain apiKey/apiSecret (or key/secret)."
  }
  return @{ key = $apiKey; secret = $apiSecret }
}

$script:Keys = Get-LocalKeys

function Sign-Query([string]$query) {
  $hmac = New-Object System.Security.Cryptography.HMACSHA256
  $hmac.Key = [Text.Encoding]::UTF8.GetBytes([string]$script:Keys.secret)
  $hash = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($query))
  $sb = New-Object System.Text.StringBuilder
  foreach ($b in $hash) { [void]$sb.Append($b.ToString("x2")) }
  return $sb.ToString()
}

function Call-P([string]$path) {
  $uri = $script:FapiBase + $path
  return Invoke-RestMethod -Uri $uri -Method GET -TimeoutSec 20
}

function Call-S([string]$method, [string]$path, [string]$q) {
  $ts = [int64](Call-P "/fapi/v1/time").serverTime
  $q2 = $q
  if (-not $q2) { $q2 = "" }
  if ($q2 -and $q2.Length -gt 0) {
    if ($q2 -notmatch "timestamp=") { $q2 = $q2 + "&timestamp=" + $ts }
  } else {
    $q2 = "timestamp=" + $ts
  }
  if ($q2 -notmatch "recvWindow=") { $q2 = $q2 + "&recvWindow=" + $script:RecvWindow }
  $sig = Sign-Query $q2
  $uri = $script:FapiBase + $path + "?" + $q2 + "&signature=" + $sig
  $headers = @{ "X-MBX-APIKEY" = [string]$script:Keys.key }
  return Invoke-RestMethod -Uri $uri -Headers $headers -Method $method -TimeoutSec 20
}

function EMA($data, [int]$period) {
  $n = @($data).Count
  $out = New-Object 'double[]' $n
  if ($n -lt $period -or $period -lt 1) { return ,$out }
  $sma = 0.0
  for ($i = 0; $i -lt $period; $i++) { $sma += [double]$data[$i] }
  $ema = $sma / $period
  for ($i = 0; $i -lt $period; $i++) { $out[$i] = $ema }
  $alpha = 2.0 / ($period + 1)
  for ($i = $period; $i -lt $n; $i++) {
    $ema = ([double]$data[$i] * $alpha) + ($ema * (1 - $alpha))
    $out[$i] = $ema
  }
  return ,$out
}

function RSI($data, [int]$period) {
  $n = @($data).Count
  $out = New-Object 'double[]' $n
  if ($n -le $period -or $period -lt 1) { return ,$out }
  $gains = 0.0
  $losses = 0.0
  for ($i = 1; $i -le $period; $i++) {
    $d = [double]$data[$i] - [double]$data[$i - 1]
    if ($d -gt 0) { $gains += $d } else { $losses -= $d }
  }
  $avgG = $gains / $period
  $avgL = $losses / $period
  if ($avgL -eq 0) { $out[$period] = 100.0 } else { $out[$period] = 100.0 - (100.0 / (1.0 + ($avgG / $avgL))) }
  for ($i = $period + 1; $i -lt $n; $i++) {
    $d = [double]$data[$i] - [double]$data[$i - 1]
    $g = 0.0
    $l = 0.0
    if ($d -gt 0) { $g = $d } elseif ($d -lt 0) { $l = -$d }
    $avgG = (($avgG * ($period - 1)) + $g) / $period
    $avgL = (($avgL * ($period - 1)) + $l) / $period
    if ($avgL -eq 0) { $out[$i] = 100.0 } else { $out[$i] = 100.0 - (100.0 / (1.0 + ($avgG / $avgL))) }
  }
  return ,$out
}

function ATRpct($klines, [int]$period) {
  $n = @($klines).Count
  if ($n -lt ($period + 1) -or $period -lt 1) { return 0.0 }
  $trs = New-Object System.Collections.Generic.List[double]
  for ($i = 1; $i -lt $n; $i++) {
    $h = [double]$klines[$i][2]
    $l = [double]$klines[$i][3]
    $pc = [double]$klines[$i - 1][4]
    $tr = [Math]::Max($h - $l, [Math]::Max([Math]::Abs($h - $pc), [Math]::Abs($l - $pc)))
    [void]$trs.Add($tr)
  }
  $atr = 0.0
  for ($i = 0; $i -lt $period; $i++) { $atr += $trs[$i] }
  $atr = $atr / $period
  for ($i = $period; $i -lt $trs.Count; $i++) {
    $atr = (($atr * ($period - 1)) + $trs[$i]) / $period
  }
  $close = [double]$klines[$n - 1][4]
  if ($close -le 0) { return 0.0 }
  return ($atr / $close) * 100.0
}
