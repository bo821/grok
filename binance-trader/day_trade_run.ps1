$ErrorActionPreference = "Stop"
$BaseDir = $PSScriptRoot
if (-not $BaseDir) { $BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $BaseDir) { $BaseDir = (Get-Location).Path }
. (Join-Path $BaseDir "night_lib.ps1")
$base = $BaseDir
$statePath = Join-Path $base "day_state.json"
$csvPath = Join-Path $base "day_trades.csv"
$SessionName = "day_session"
$nowLocal = Get-Date
$today = $nowLocal.ToString("yyyy-MM-dd")
$hour = [int]$nowLocal.ToString("HH")

function Save-State($s) {
  ($s | ConvertTo-Json -Depth 10) | Set-Content -Path $statePath -Encoding UTF8
}
function Log-Day([string]$line) {
  if (!(Test-Path $csvPath)) { "time,action,symbol,side,qty,price,stop,note" | Set-Content $csvPath -Encoding UTF8 }
  ((Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "," + $line) | Add-Content $csvPath -Encoding UTF8
}
function Round-Tick([double]$px, [double]$tick) {
  if ($tick -le 0) { return $px }
  return [math]::Round([math]::Floor(($px / $tick) + 0.5) * $tick, 8)
}
function Floor-Step([double]$q, [double]$step) {
  if ($step -le 0) { return $q }
  return [math]::Floor($q / $step) * $step
}

function Ensure-Prop($obj, $name, $val) {
  if (-not ($obj.PSObject.Properties.Name -contains $name)) {
    $obj | Add-Member -NotePropertyName $name -NotePropertyValue $val -Force
  }
}

function Get-Filters([string]$sym, $ex) {
  $s = $ex.symbols | Where-Object { $_.symbol -eq $sym } | Select-Object -First 1
  $tick = 0.0001; $step = 0.001; $minQty = 0.001; $minNot = 5.0
  foreach ($f in $s.filters) {
    if ($f.filterType -eq "PRICE_FILTER") { $tick = [double]$f.tickSize }
    if ($f.filterType -eq "LOT_SIZE") { $step = [double]$f.stepSize; $minQty = [double]$f.minQty }
    if ($f.filterType -eq "MIN_NOTIONAL") { $minNot = [double]$f.notional }
  }
  return @{ tick=$tick; step=$step; minQty=$minQty; minNot=$minNot }
}
function Place-Stop([string]$sym, [string]$side, [double]$stopPx, [double]$qty) {
  $q = "algoType=CONDITIONAL&symbol=" + $sym + "&side=" + $side + "&type=STOP_MARKET&triggerPrice=" + $stopPx + "&quantity=" + $qty + "&reduceOnly=true&workingType=MARK_PRICE"
  return Call-S "POST" "/fapi/v1/algoOrder" $q
}
function Cancel-Algo([string]$algoId) {
  $q = "algoId=" + $algoId
  return Call-S "DELETE" "/fapi/v1/algoOrder" $q
}
function Close-Market([string]$sym, [string]$side, [double]$qty) {
  $q = "symbol=" + $sym + "&side=" + $side + "&type=MARKET&quantity=" + $qty + "&reduceOnly=true"
  return Call-S "POST" "/fapi/v1/order" $q
}

if (-not (Test-Path $statePath)) {
  $state = [pscustomobject]@{ trades=0; realized=0.0; cooldown_until=$null; reported=@(); watchlist=@(); last_fail_count=0; last_run=$null; open=$null; day=$today; handoff=$null; last_scan_at=$null }
} else {
  $state = Get-Content $statePath -Raw | ConvertFrom-Json
}
if (-not $state.day -or $state.day -ne $today) {
  $state.trades = 0
  $state.realized = 0.0
  $state.cooldown_until = $null
  $state.reported = @()
  $state.day = $today
  $state.open = $null
}
Ensure-Prop $state "session" ""
if ([string]$state.session -ne $SessionName) {  # reset counters when $SessionName changes
  $state.trades = 0
  $state.realized = 0.0
  $state.cooldown_until = $null
  $state.reported = @()
  $state.open = $null
  $state.last_scan_at = $null
  $state.handoff = $null
  $state.session = $SessionName
}
if (-not $state.reported) { $state | Add-Member -NotePropertyName reported -NotePropertyValue @() -Force }
Ensure-Prop $state "last_scan_at" $null
Ensure-Prop $state "last_fail_count" 0
Ensure-Prop $state "handoff" $null
Ensure-Prop $state "wallet" 0
Ensure-Prop $state "avail" 0
Ensure-Prop $state "action" "noop"
$reported = @($state.reported)
$handoff = $null
$action = "noop"

try {
  $acc = Call-S "GET" "/fapi/v2/account" ""
  $wallet = [double]$acc.totalWalletBalance
  $avail = [double]$acc.availableBalance
  $posAll = Call-S "GET" "/fapi/v2/positionRisk" ""
  $openPos = @($posAll | Where-Object { [double]$_.positionAmt -ne 0 -and $_.symbol -ne "ETHUSDT" })
  $ethPos = @($posAll | Where-Object { [double]$_.positionAmt -ne 0 -and $_.symbol -eq "ETHUSDT" })
  $algos = @()
  try { $rawAlgos = Call-S "GET" "/fapi/v1/openAlgoOrders" ""; if ($null -ne $rawAlgos) { $algos = @($rawAlgos) } else { $algos = @() } } catch { $algos = @() }

  Write-Output ("ACCOUNT wallet={0:N4} avail={1:N4}" -f $wallet, $avail)
  Write-Output ("POS nonETH={0} eth={1} algos={2}" -f $openPos.Count, $ethPos.Count, $algos.Count)
  foreach ($p in $openPos) {
    Write-Output ("POS {0} amt={1} entry={2} mark={3} uPnl={4} lev={5} margin={6} liq={7}" -f $p.symbol,$p.positionAmt,$p.entryPrice,$p.markPrice,$p.unRealizedProfit,$p.leverage,$p.isolatedMargin,$p.liquidationPrice)
  }
  foreach ($a in $algos) {
    if ($a.symbol -eq "ETHUSDT") { continue }
    Write-Output ("ALGO {0} id={1} side={2} type={3} trigger={4} qty={5} status={6}" -f $a.symbol,$a.algoId,$a.side,$a.orderType,$a.triggerPrice,$a.quantity,$a.algoStatus)
  }

  $state.last_fail_count = 0
  $state.last_run = $nowLocal.ToString("o")

  if ($state.open -and $openPos.Count -eq 0) {
    $sym = [string]$state.open.symbol
    $side = [string]$state.open.side
    $entry = [double]$state.open.entry
    $qty = [double]$state.open.qty
    $pnlEst = 0.0
    try {
      $inc = Call-S "GET" "/fapi/v1/income" ("incomeType=REALIZED_PNL&symbol=" + $sym + "&limit=5")
      if ($inc -and $inc.Count -gt 0) { $pnlEst = [double]$inc[0].income }
    } catch {}
    $state.realized = [math]::Round(([double]$state.realized) + $pnlEst, 4)
    $cdMin = if ($pnlEst -ge 0) { 15 } else { 20 }
    $state.cooldown_until = $nowLocal.AddMinutes($cdMin).ToString("o")
    $evt = ("close_" + $sym + "_" + (Get-Date).ToString("HHmmss"))
    $msg = "白天单平仓：" + $sym + " " + $side + " 估盈亏约 " + ([math]::Round($pnlEst,2)) + "U，钱包约 " + ([math]::Round($wallet,2)) + "U。冷却 " + $cdMin + " 分钟。"
    $stopEvt = ("stopped_" + $sym)
    if ($reported -notcontains $evt -and $reported -notcontains $stopEvt) {
      $handoff = $msg
      $reported += $stopEvt
      $reported += $evt
    }
    Log-Day ("CLOSE," + $sym + "," + $side + "," + $qty + ",,," + $pnlEst + " stop-or-flat")
    $state.open = $null
    $action = "closed_detected"
  }

  if ($openPos.Count -gt 0) {
    $p = $openPos | Select-Object -First 1
    $sym = $p.symbol
    $amt = [double]$p.positionAmt
    $entry = [double]$p.entryPrice
    $mark = [double]$p.markPrice
    $uPnl = [double]$p.unRealizedProfit
    $isLong = $amt -gt 0
    $qty = [math]::Abs($amt)
    $sideClose = if ($isLong) { "SELL" } else { "BUY" }
    $pnlPct = if ($isLong) { ($mark - $entry) / $entry * 100 } else { ($entry - $mark) / $entry * 100 }

    if (-not $state.open -or $state.open.symbol -ne $sym) {
      $state.open = [pscustomobject]@{
        symbol=$sym; side=$(if($isLong){"LONG"}else{"SHORT"}); entry=$entry; qty=$qty
        opened_at=$nowLocal.ToString("o"); stop=$null; algoId=$null; be_locked=$false; profit_locked=$false; max_uPnl=$uPnl
      }
    } else {
      if ([double]$state.open.max_uPnl -lt $uPnl) { $state.open.max_uPnl = $uPnl }
      if (-not $state.open.opened_at) { $state.open.opened_at = $nowLocal.ToString("o") }
    }

    $myAlgos = @($algos | Where-Object { $_.symbol -eq $sym })
    $curAlgo = $myAlgos | Select-Object -First 1
    $curStop = if ($curAlgo) { [double]$curAlgo.triggerPrice } else { $null }
    $curAlgoId = if ($curAlgo) { [string]$curAlgo.algoId } else { $null }
    $state.open.algoId = $curAlgoId
    $state.open.stop = $curStop

    $h1 = Call-P ("/fapi/v1/klines?symbol=" + $sym + "&interval=1h&limit=80")
    $cl1 = @($h1 | ForEach-Object { [double]$_[4] })
    $e20 = EMA $cl1 20; $e50 = EMA $cl1 50; $n=$cl1.Count
    $trendUp = ($e20[$n-1] -gt $e50[$n-1])
    $m15 = Call-P ("/fapi/v1/klines?symbol=" + $sym + "&interval=15m&limit=40")
    $last15o = [double]$m15[$m15.Count-2][1]
    $last15c = [double]$m15[$m15.Count-2][4]
    $strongAgainst = ($isLong -and $last15c -lt $last15o -and (($last15o-$last15c)/$last15o*100) -ge 0.4) -or ((-not $isLong) -and $last15c -gt $last15o -and (($last15c-$last15o)/$last15o*100) -ge 0.4)
    $trendFlip = ($isLong -and -not $trendUp) -or ((-not $isLong) -and $trendUp)
    $openedAt = [datetime]::Parse($state.open.opened_at)
    $holdMin = ($nowLocal - $openedAt).TotalMinutes
    $profitLocked = [bool]$state.open.profit_locked
    $beLocked = [bool]$state.open.be_locked

    $doClose = $false
    $closeReason = ""
    if ($strongAgainst -and $holdMin -ge 15) { $doClose = $true; $closeReason = "15m_against" }  # first 15 min: stop only (Bo 2026-11-12)
    elseif ($trendFlip -and $uPnl -lt 0.15 -and $holdMin -ge 15) { $doClose = $true; $closeReason = "1h_flip" }
    elseif ($holdMin -ge 90 -and -not $profitLocked) { $doClose = $true; $closeReason = "max_hold" }
    elseif ($pnlPct -ge 3.0 -and -not ($profitLocked -and $uPnl -gt 0.4)) { $doClose = $true; $closeReason = "tp_3pct" }

    if ($doClose) {
      foreach ($a in $myAlgos) { try { Cancel-Algo ([string]$a.algoId) | Out-Null } catch {} }
      $ord = Close-Market $sym $sideClose $qty
      Start-Sleep -Seconds 1
      $pnlEst = $uPnl
      try {
        $inc = Call-S "GET" "/fapi/v1/income" ("incomeType=REALIZED_PNL&symbol=" + $sym + "&limit=3")
        if ($inc -and $inc.Count -gt 0) { $pnlEst = [double]$inc[0].income }
      } catch {}
      $state.realized = [math]::Round(([double]$state.realized) + $pnlEst, 4)
      $cdMin = if ($pnlEst -ge 0) { 15 } else { 20 }
      $state.cooldown_until = $nowLocal.AddMinutes($cdMin).ToString("o")
      $evt = ("manualclose_" + $sym + "_" + $closeReason)
      $dirCn = if ($isLong) { "多" } else { "空" }
      $msg = "白天平仓：" + $sym + " " + $dirCn + " 原因 " + $closeReason + "，浮盈约 " + ([math]::Round($uPnl,2)) + "U，钱包约 " + ([math]::Round($wallet,2)) + "U。"
      if ($reported -notcontains $evt) { $handoff = $msg; $reported += $evt }
      $sideEn = if ($isLong) { "LONG" } else { "SHORT" }
      Log-Day ("CLOSE," + $sym + "," + $sideEn + "," + $qty + "," + $mark + ",," + $closeReason + " uPnl=" + $uPnl)
      $state.open = $null
      $action = ("closed_" + $closeReason)
    } else {
      $ex = Call-P "/fapi/v1/exchangeInfo"
      $filt = Get-Filters $sym $ex
      $feeBuf = $entry * 0.0008
      $newStop = $null
      $note = ""

      $oldEntry = [double]$state.open.entry
      $oldQty = [double]$state.open.qty
      $entryChanged = [math]::Abs($entry - $oldEntry) -gt ($filt.tick * 0.5)
      $qtyChanged = [math]::Abs($qty - $oldQty) -gt ($filt.step * 0.5)
      if ($entryChanged -or $qtyChanged) {
        if ($oldQty -gt 0 -and (([math]::Abs($qty - $oldQty) / $oldQty) -ge 0.10)) {
          $state.open.profit_locked = $false
        }
        $state.open.entry = $entry
        $state.open.qty = $qty
        Write-Output ("ADD_SYNC oldEntry={0} newEntry={1} oldQty={2} newQty={3}" -f $oldEntry, $entry, $oldQty, $qty)
        if ($isLong) { $bePx = Round-Tick ($entry + $feeBuf) $filt.tick } else { $bePx = Round-Tick ($entry - $feeBuf) $filt.tick }
        $needBe = $false
        if (-not $curStop) { $needBe = $true }
        elseif ($isLong -and $curStop -lt ($entry + $feeBuf)) { $needBe = $true }
        elseif ((-not $isLong) -and $curStop -gt ($entry - $feeBuf)) { $needBe = $true }
        if ($needBe) {
          $newStop = $bePx
          $note = "ADD_BE"
          $state.open.be_locked = $true
          $beLocked = $true
        }
      }

      if ($pnlPct -ge 0.5 -and -not $beLocked) {  # BE trigger widened to +0.5% (Bo 2026-11-11)
        if ($isLong) { $newStop = Round-Tick ($entry + $feeBuf) $filt.tick } else { $newStop = Round-Tick ($entry - $feeBuf) $filt.tick }
        $state.open.be_locked = $true
        $note = "BE_LOCK"
        $evt = ("be_" + $sym)
        if ($reported -notcontains $evt) {
          $handoff = "白天单 " + $sym + " 已挪止损到保本（浮盈约 " + ([math]::Round($pnlPct,2)) + "% / " + ([math]::Round($uPnl,2)) + "U）。"
          $reported += $evt
        }
      }

      $hitProfit = ($uPnl -ge 0.5) -or (([double]$state.open.max_uPnl) -ge 0.5)
      if ($hitProfit) {
        if ($isLong) { $beFloor = Round-Tick ($entry + $feeBuf) $filt.tick } else { $beFloor = Round-Tick ($entry - $feeBuf) $filt.tick }
        if ($uPnl -ge 0.5) {
          if ($isLong) { $lockFloor = Round-Tick ($entry + (0.3 / $qty)) $filt.tick } else { $lockFloor = Round-Tick ($entry - (0.3 / $qty)) $filt.tick }
        } else {
          $lockFloor = $beFloor
        }
        if ($isLong) {
          if ($lockFloor -lt $beFloor) { $lockFloor = $beFloor }
        } else {
          if ($lockFloor -gt $beFloor) { $lockFloor = $beFloor }
        }
        $trailPct = 0.006
        $atr = ATRpct $h1 14
        # Volatile coins: trail tighter/faster, never wider than 0.8% (Bo 2026-11-11)
        if ($atr -ge 1.2) { $trailPct = [math]::Max(0.005, [math]::Min(0.008, $atr / 250.0)) }
        $peakU = [double]$state.open.max_uPnl
        $keepRatio = 0.5
        if ($atr -ge 1.5) { $keepRatio = 0.6 }
        if ($peakU -ge 0.5) {
          $keepU = [math]::Max(0.3, $peakU * $keepRatio)
          if ($isLong) { $peakFloor = Round-Tick ($entry + ($keepU / $qty)) $filt.tick; if ($peakFloor -gt $lockFloor -and $peakFloor -lt $mark) { $lockFloor = $peakFloor } } else { $peakFloor = Round-Tick ($entry - ($keepU / $qty)) $filt.tick; if ($peakFloor -lt $lockFloor -and $peakFloor -gt $mark) { $lockFloor = $peakFloor } }
        }
        if ($uPnl -ge 0.5) {
          if ($isLong) { $trailStop = Round-Tick ($mark * (1 - $trailPct)) $filt.tick } else { $trailStop = Round-Tick ($mark * (1 + $trailPct)) $filt.tick }
          $cand = $trailStop
        } else {
          $cand = $lockFloor
        }
        if ($isLong) {
          if ($lockFloor -gt $cand) { $cand = $lockFloor }
          if ($curStop -and $cand -lt $curStop) { $cand = $curStop }
          if (-not $newStop -or $cand -gt $newStop) { $newStop = $cand }
        } else {
          if ($lockFloor -lt $cand) { $cand = $lockFloor }
          if ($curStop -and $cand -gt $curStop) { $cand = $curStop }
          if (-not $newStop -or $cand -lt $newStop) { $newStop = $cand }
        }
        $state.open.profit_locked = $true
        if ($note -eq "" -or $note -eq "ADD_BE") { $note = "PROFIT_LOCK" }
        $evt = ("lock_" + $sym)
        if ($reported -notcontains $evt) {
          $handoff = "白天单 " + $sym + " 已锁利（浮盈约 " + ([math]::Round($uPnl,2)) + "U，最高约 " + ([math]::Round([double]$state.open.max_uPnl,2)) + "U），止损跟到 " + $newStop + "。"
          $reported += $evt
        }
      }

      if ($newStop) {
        $favorable = $false
        if (-not $curStop) { $favorable = $true }
        elseif ($isLong -and $newStop -gt $curStop) { $favorable = $true }
        elseif ((-not $isLong) -and $newStop -lt $curStop) { $favorable = $true }

        if ($favorable -and ([math]::Abs($newStop - $(if($curStop){$curStop}else{0})) -gt ($filt.tick * 0.5))) {
          $placed = Place-Stop $sym $sideClose $newStop $qty
          $newId = [string]$placed.algoId
          if ($curAlgoId) { try { Cancel-Algo $curAlgoId | Out-Null } catch {} }
          $state.open.stop = $newStop
          $state.open.algoId = $newId
          $sideEn = if ($isLong) { "LONG" } else { "SHORT" }
          Log-Day ("STOP," + $sym + "," + $sideEn + "," + $qty + "," + $mark + "," + $newStop + "," + $note)
          $action = ("stop_" + $note)
          Write-Output ("STOP_MOVED to={0} id={1} note={2}" -f $newStop, $newId, $note)
        } else {
          $action = "hold"
          Write-Output ("HOLD pnlPct={0:N2} uPnl={1:N3} stop={2}" -f $pnlPct, $uPnl, $curStop)
        }
      } else {
        $action = "hold"
        Write-Output ("HOLD pnlPct={0:N2} uPnl={1:N3} stop={2} holdMin={3:N0}" -f $pnlPct, $uPnl, $curStop, $holdMin)
        if (-not $curAlgoId) {
          $sdist = 0.008
          if ($isLong) { $emergency = Round-Tick ($entry * (1 - $sdist)) $filt.tick } else { $emergency = Round-Tick ($entry * (1 + $sdist)) $filt.tick }
          $placed = Place-Stop $sym $sideClose $emergency $qty
          $state.open.stop = $emergency
          $state.open.algoId = [string]$placed.algoId
          $action = "stop_placed_missing"
          $evt = ("emergencystop_" + $sym)
          if ($reported -notcontains $evt) {
            $handoff = "白天单 " + $sym + " 缺少止损，已补挂 " + $emergency + "。"
            $reported += $evt
          }
          $sideEn = if ($isLong) { "LONG" } else { "SHORT" }
          Log-Day ("STOP," + $sym + "," + $sideEn + "," + $qty + "," + $mark + "," + $emergency + ",MISSING_STOP")
        }
      }
    }
  }
  elseif ($hour -ge 21) {  # 2026-11-12 session: no new entries from 21:00
    $action = "after_hours_no_open"
    Write-Output "AFTER_2100_NO_NEW"
    if (([double]$state.trades -gt 0 -or [double]$state.realized -ne 0) -and ($reported -notcontains ("session_summary_" + $today))) {
      $handoff = "今日交易结束：共 " + ([int]$state.trades) + " 单，净盈亏约 " + ([math]::Round([double]$state.realized,2)) + "U，钱包约 " + ([math]::Round($wallet,2)) + "U。"
      $reported += ("session_summary_" + $today)
      $action = "day_done"
    }
  }
  else {
    $cdOk = $true
    if ($state.cooldown_until) {
      $cdUntil = [datetime]::Parse([string]$state.cooldown_until)
      if ($nowLocal -lt $cdUntil) {
        $cdOk = $false
        Write-Output ("COOLDOWN until " + $cdUntil.ToString("HH:mm:ss"))
        $action = "cooldown"
      }
    }
    $realized = [double]$state.realized
    $trades = [int]$state.trades
    # Daily loss cap waived for testing (Bo 2026-11-10 12:48); keep per-trade 0.5-0.7U
    $dayLossCap = $null
    $remain = $null
    # Daily 6-trade cap waived for testing (Bo 2026-11-10 16:56); keep per-trade 0.5-0.7U
    # if ($trades -ge 6) { Write-Output "MAX_TRADES"; $action = "max_trades"; $cdOk = $false }
    if ($avail -lt 1.5) { Write-Output "LOW_AVAIL"; $action = "low_avail"; $cdOk = $false }

    if ($cdOk) {
      $scanOk = $true
      if ($state.last_scan_at) {
        try {
          $lastScan = [datetime]::Parse([string]$state.last_scan_at)
          if (($nowLocal - $lastScan).TotalMinutes -lt 5) {
            $scanOk = $false
            Write-Output "SCAN_SKIPPED reason=interval"
            $action = "scan_skipped"
          }
        } catch {}
      }
      if ($scanOk) {
      $state.last_scan_at = $nowLocal.ToString("o")
      Write-Output "SCANNING..."
      $ex = Call-P "/fapi/v1/exchangeInfo"
      $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      $okSym = @{}
      foreach ($s in $ex.symbols) {
        if ($s.contractType -eq "PERPETUAL" -and $s.quoteAsset -eq "USDT" -and $s.status -eq "TRADING" -and ($nowMs - [double]$s.onboardDate) -gt 14*86400000) {
          $okSym[$s.symbol] = $s
        }
      }
      $t = Call-P "/fapi/v1/ticker/24hr"
      $cands = @($t | Where-Object {
        $okSym.ContainsKey($_.symbol) -and ([double]$_.quoteVolume -ge 10000000 -or $_.symbol -eq "ACEUSDT") -and [math]::Abs([double]$_.priceChangePercent) -lt 40 -and $_.symbol -ne "ETHUSDT"
      } | Sort-Object { if ($_.symbol -eq "ACEUSDT") { -1e18 } else { -[double]$_.quoteVolume } } | Select-Object -First 200)  # full pool again, ACE always included (Bo 2026-11-12 13:17)

      $gradeA = @()
      $idx = 0
      foreach ($c in $cands) {
        $idx++
        try {
          $sym = $c.symbol
          $h1 = Call-P ("/fapi/v1/klines?symbol=" + $sym + "&interval=1h&limit=80")
          $cl1 = @($h1 | ForEach-Object { [double]$_[4] })
          $e20 = EMA $cl1 20; $e50 = EMA $cl1 50; $n=$cl1.Count
          $tr = 0
          if ($e20[$n-1] -gt $e50[$n-1] -and $e20[$n-1] -gt $e20[$n-4]) { $tr = 1 }
          if ($e20[$n-1] -lt $e50[$n-1] -and $e20[$n-1] -lt $e20[$n-4]) { $tr = -1 }
          if ($tr -eq 0) { continue }
          $sep = ($e20[$n-1]-$e50[$n-1])/$e50[$n-1]*100
          $atr = ATRpct $h1 14
          $m15 = Call-P ("/fapi/v1/klines?symbol=" + $sym + "&interval=15m&limit=60")
          $cl15 = @($m15 | ForEach-Object { [double]$_[4] }); $e15 = EMA $cl15 20
          $e15_50 = EMA $cl15 50
          $n15 = $cl15.Count
          $tr15 = 0
          if ($e15[$n15-1] -gt $e15_50[$n15-1] -and $e15[$n15-1] -gt $e15[$n15-4]) { $tr15 = 1 }
          if ($e15[$n15-1] -lt $e15_50[$n15-1] -and $e15[$n15-1] -lt $e15[$n15-4]) { $tr15 = -1 }
          if ($tr15 -ne $tr) { continue }
          $closed15o = [double]$m15[$m15.Count-2][1]
          $closed15c = [double]$m15[$m15.Count-2][4]
          $body15 = 0
          if ($closed15o -ne 0) { $body15 = ($closed15c - $closed15o) / $closed15o * 100 }
          $dir15closed = if ($closed15c -gt $closed15o) { 1 } else { -1 }
          $m5 = Call-P ("/fapi/v1/klines?symbol=" + $sym + "&interval=5m&limit=60")
          $cl5 = @($m5 | ForEach-Object { [double]$_[4] }); $r = RSI $cl5 7
          $px = $cl5[$cl5.Count-1]
          $d15 = ($px - $e15[$e15.Count-1]) / $e15[$e15.Count-1] * 100
          $d1h = ($px - $e20[$n-1]) / $e20[$n-1] * 100
          $rn=$r[$r.Count-1]; $rp=$r[$r.Count-2]
          $rmin=($r[($r.Count-4)..($r.Count-1)] | Measure-Object -Minimum).Minimum
          $rmax=($r[($r.Count-4)..($r.Count-1)] | Measure-Object -Maximum).Maximum

          $grade = $null
          $rsiHook = $false
          if ($tr -eq 1) {
            $rsiHook = ($rmin -le 30 -and $rn -gt $rp -and $rn -le 45)
            $emaTouch = ($d15 -le 0.15 -and $d15 -ge -1.2) -or ($d1h -le 0.2 -and $d1h -ge -1.5)
            $confirm = ($dir15closed -eq 1)
            $notChase = $d15 -lt 0.8 -and $rn -lt 65 -and $body15 -lt 0.8
            if ($confirm -and $notChase -and ($rsiHook -or $emaTouch) -and [math]::Abs($sep) -ge 0.25) { $grade = "A" }
          } elseif ($tr -eq -1) {
            $rsiHook = ($rmax -ge 70 -and $rn -lt $rp -and $rn -ge 55)
            $emaTouch = ($d15 -ge -0.15 -and $d15 -le 1.2) -or ($d1h -ge -0.2 -and $d1h -le 1.5)
            $confirm = ($dir15closed -eq -1)
            $notChase = $d15 -gt -0.8 -and $rn -gt 35 -and $body15 -gt -0.8
            if ($confirm -and $notChase -and ($rsiHook -or $emaTouch) -and [math]::Abs($sep) -ge 0.25) { $grade = "A" }
          }
          if ($grade -eq "A") {
            $book = Call-P ("/fapi/v1/ticker/bookTicker?symbol=" + $sym)
            $bid=[double]$book.bidPrice; $ask=[double]$book.askPrice
            $spread = ($ask - $bid) / (($ask + $bid)/2) * 100
            $rank = $idx
            if ($spread -ge 0.1) { continue }
            if ($atr -gt 3.2) { continue }
            $score = [math]::Min([math]::Abs($sep), 2.0)
            if ($rsiHook) { $score += 0.5 }
            if ($atr -ge 0.6 -and $atr -le 3) { $score += 0.3 }
            $score += (0.8 - [math]::Min([math]::Abs($d15), 0.8))
            $candObj = [pscustomobject]@{ sym=$sym; tr=$tr; sep=[math]::Round($sep,2); atr=[math]::Round($atr,2); d15=[math]::Round($d15,2); rsi=[math]::Round($rn,1); spread=[math]::Round($spread,3); rank=$rank; px=$px; score=$score }
            $gradeA += $candObj
            Write-Output ("CAND A {0} tr={1} sep={2} atr={3} d15={4} rsi={5} spr={6} rank={7} score={8}" -f $sym,$tr,$candObj.sep,$candObj.atr,$candObj.d15,$candObj.rsi,$candObj.spread,$rank,$score)
          }
        } catch {}
      }

      $openedNow = $false
      $gradeA = @($gradeA | Sort-Object { -$_.score })
      foreach ($best in $gradeA) {
        $sym = $best.sym
        $isLong = $best.tr -eq 1
        $filt = Get-Filters $sym $ex
        $mark = [double](Call-P ("/fapi/v1/premiumIndex?symbol=" + $sym)).markPrice
        $sdistWide = 0.008
        if ($best.atr -ge 1.5) { $sdistWide = 0.010 }
        if ($best.atr -le 0.7) { $sdistWide = 0.006 }
        if ($best.atr -ge 2.5) { $sdistWide = 0.012 }
        $sdist = $sdistWide

        $maxLoss = 0.6
        if ($best.rank -gt 100) { $maxLoss = 0.5 }
        $maxLossCap = 0.7
        # Two-tier sizing (Bo 2026-11-11): only top-conviction setups risk ~1.0U; normal stay 0.5-0.7U
        $topTier = ($best.sym -ne "ACEUSDT" -and $best.score -ge 2.6 -and $best.spread -le 0.02 -and $best.rank -le 100 -and $best.atr -ge 0.6 -and $best.atr -le 2.5 -and [math]::Abs($best.d15) -le 0.3)
        if ($topTier) { $maxLoss = 1.0; $maxLossCap = 1.0; Write-Output ("TIER TOP " + $best.sym) } else { Write-Output ("TIER NORMAL " + $best.sym) }
        $feeSlip = 0.0025
        $lossBudget = $maxLoss
        if ($lossBudget -gt $maxLossCap) { $lossBudget = $maxLossCap }
        # remain no longer caps size (daily loss cap waived)
        $maxLev = 20
        try {
          $brRaw = Call-S "GET" "/fapi/v1/leverageBracket" ("symbol=" + $sym)
          $br0 = @($brRaw)[0]
          $brs = $br0.brackets
          if (-not $brs) { $brs = $br0 }
          $maxLev = [int]($brs | Measure-Object -Property initialLeverage -Maximum).Maximum
        } catch {
          Write-Output ("LEV_LOOKUP_WARN {0} {1}" -f $sym, $_.Exception.Message)
          $maxLev = 10
        }
        if ($maxLev -gt 20) { $maxLev = 20 }
        if ($maxLev -lt 1) { $maxLev = 10 }
        $lev = $maxLev
        Write-Output ("LEV {0}={1}" -f $sym, $lev)
        # Target ~65% of available margin; tighten stop to keep net max loss in budget (Bo 2026-11-11)
        $targetPct = 0.65
        $maxMargin = $avail * 0.9
        $targetMargin = $avail * $targetPct
        if ($targetMargin -gt $maxMargin) { $targetMargin = $maxMargin }

        $sdist = $sdistWide  # ATR-appropriate stop; shrink size, never tighten stop to fill margin (Bo 2026-11-12)
        $sdistMin = 0.004
        if ($sdist -lt $sdistMin) { $sdist = $sdistMin }
        $qty = Floor-Step ($lossBudget / (($sdist + $feeSlip) * $mark)) $filt.step
        if ($qty -lt $filt.minQty) { $qty = $filt.minQty }
        $notional = $qty * $mark
        if ($notional -lt $filt.minNot) {
          $qty = [math]::Ceiling($filt.minNot / $mark / $filt.step) * $filt.step
          $notional = $qty * $mark
        }
        $margin = $notional / $lev
        if ($margin -gt $targetMargin -and $mark -gt 0) {
          $qty = Floor-Step (($targetMargin * $lev) / $mark) $filt.step
          $notional = $qty * $mark
          $margin = $notional / $lev
        }
        if ($margin -gt $maxMargin -and $mark -gt 0) {
          $qty = Floor-Step (($maxMargin * $lev) / $mark) $filt.step
          $notional = $qty * $mark
          $margin = $notional / $lev
        }
        $maxLossActual = $qty * ($sdist + $feeSlip) * $mark
        if ($maxLossActual -gt $maxLossCap -and ($sdist + $feeSlip) -gt 0) {
          $qty = Floor-Step ($maxLossCap / (($sdist + $feeSlip) * $mark)) $filt.step
          $notional = $qty * $mark
          $margin = $notional / $lev
          $maxLossActual = $qty * ($sdist + $feeSlip) * $mark
        }
        $pctAvail = 0
        if ($avail -gt 0) { $pctAvail = $margin / $avail }
        Write-Output ("SIZE {0} sdist={1:N4} margin={2:N2} pctAvail={3:N0}% netMax={4:N2} lev={5}" -f $sym, $sdist, $margin, ($pctAvail*100), $maxLossActual, $lev)
        if ($qty -lt $filt.minQty -or $notional -lt $filt.minNot -or $maxLossActual -gt ($maxLossCap + 0.05) -or $margin -lt 0.5) {
          Write-Output ("SKIP_SIZE sym={0} qty={1} margin={2} maxLoss={3}" -f $sym,$qty,$margin,$maxLossActual)
          continue
        }
        try {
          try { Call-S "POST" "/fapi/v1/leverage" ("symbol=" + $sym + "&leverage=" + $lev) | Out-Null } catch {
            $det = $_.Exception.Message
            if ($_.ErrorDetails) { $det = $det + " " + $_.ErrorDetails.Message }
            Write-Output ("LEV_WARN " + $det)
          }
          try { Call-S "POST" "/fapi/v1/marginType" ("symbol=" + $sym + "&marginType=ISOLATED") | Out-Null } catch {
            $m = $_.Exception.Message
            if ($_.ErrorDetails) { $m = $m + " " + $_.ErrorDetails.Message }
            if ($m -notmatch "4046" -and $m -notmatch "No need") { Write-Output ("MARGIN_WARN " + $m) }
          }
          $levNow = 0
          try {
            $prLev = Call-S "GET" "/fapi/v2/positionRisk" ("symbol=" + $sym)
            $pLev = @($prLev | Where-Object { $_.symbol -eq $sym }) | Select-Object -First 1
            if ($pLev) { $levNow = [int]$pLev.leverage }
          } catch {}
          if ($levNow -ne $lev) {
            Write-Output ("LEV_SET_WARN {0} wanted={1} now={2}" -f $sym, $lev, $levNow)
            if ($levNow -ge 1) { $lev = $levNow; $margin = $notional / $lev }
            if ($levNow -lt 1 -or $margin -gt $maxMargin) {
              Write-Output ("SKIP_LEV_SET {0} lev={1}" -f $sym, $levNow)
              continue
            }
          }
          $side = if ($isLong) { "BUY" } else { "SELL" }
          $closeSide = if ($isLong) { "SELL" } else { "BUY" }
          $ord = Call-S "POST" "/fapi/v1/order" ("symbol=" + $sym + "&side=" + $side + "&type=MARKET&quantity=" + $qty)
          Start-Sleep -Milliseconds 800
          $pos2 = Call-S "GET" "/fapi/v2/positionRisk" ("symbol=" + $sym)
          $p2 = @($pos2 | Where-Object { $_.symbol -eq $sym }) | Select-Object -First 1
          $entry = [double]$p2.entryPrice
          if ($entry -le 0) { $entry = $mark }
          $qtyLive = [math]::Abs([double]$p2.positionAmt)
          if ($qtyLive -le 0) { $qtyLive = $qty }
          if ($isLong) { $stopPx = Round-Tick ($entry * (1 - $sdist)) $filt.tick } else { $stopPx = Round-Tick ($entry * (1 + $sdist)) $filt.tick }
          $algo = Place-Stop $sym $closeSide $stopPx $qtyLive
          $algoId = [string]$algo.algoId
          $sideEn = if ($isLong) { "LONG" } else { "SHORT" }
          $state.open = [pscustomobject]@{
            symbol=$sym; side=$sideEn; entry=$entry; qty=$qtyLive
            opened_at=$nowLocal.ToString("o"); stop=$stopPx; algoId=$algoId; be_locked=$false; profit_locked=$false; max_uPnl=0
          }
          $state.trades = [int]$state.trades + 1
          $evt = ("open_" + $sym + "_" + $nowLocal.ToString("HHmm"))
          $dir = if ($isLong) { "多" } else { "空" }
          $msg = "白天开仓：" + $sym + " " + $dir + " " + $qtyLive + " @ " + ([math]::Round($entry,6)) + "，" + $lev + "x 逐仓，止损 " + $stopPx + "（约 " + ([math]::Round($maxLossActual,2)) + "U），钱包约 " + ([math]::Round($wallet,2)) + "U。"
          if ($reported -notcontains $evt) { $handoff = $msg; $reported += $evt }
          Log-Day ("OPEN," + $sym + "," + $sideEn + "," + $qtyLive + "," + $entry + "," + $stopPx + ",rank=" + $best.rank + " atr=" + $best.atr + " sep=" + $best.sep)
          $action = "opened"
          Write-Output ("OPENED {0} {1} qty={2} entry={3} stop={4} algo={5}" -f $sym,$sideEn,$qtyLive,$entry,$stopPx,$algoId)
          $openedNow = $true
          break
        } catch {
          $em = $_.Exception.Message; if ($_.ErrorDetails) { $em = $em + " " + $_.ErrorDetails.Message }; Write-Output ("OPEN_FAIL {0} {1}" -f $sym, $em)
          try {
            $posFail = Call-S "GET" "/fapi/v2/positionRisk" ("symbol=" + $sym)
            $pFail = @($posFail | Where-Object { $_.symbol -eq $sym -and [math]::Abs([double]$_.positionAmt) -gt 0 }) | Select-Object -First 1
            if ($pFail) {
              $entry = [double]$pFail.entryPrice
              if ($entry -le 0) { $entry = $mark }
              $qtyLive = [math]::Abs([double]$pFail.positionAmt)
              $closeSide = if ($isLong) { "SELL" } else { "BUY" }
              if ($isLong) { $stopPx = Round-Tick ($entry * (1 - $sdist)) $filt.tick } else { $stopPx = Round-Tick ($entry * (1 + $sdist)) $filt.tick }
              $algo = Place-Stop $sym $closeSide $stopPx $qtyLive
              $algoId = [string]$algo.algoId
              $sideEn = if ($isLong) { "LONG" } else { "SHORT" }
              $state.open = [pscustomobject]@{
                symbol=$sym; side=$sideEn; entry=$entry; qty=$qtyLive
                opened_at=$nowLocal.ToString("o"); stop=$stopPx; algoId=$algoId; be_locked=$false; profit_locked=$false; max_uPnl=0
              }
              $state.trades = [int]$state.trades + 1
              $evt = ("open_" + $sym + "_" + $nowLocal.ToString("HHmm"))
              $dir = if ($isLong) { "多" } else { "空" }
          $msg = "白天开仓：" + $sym + " " + $dir + " " + $qtyLive + " @ " + ([math]::Round($entry,6)) + "，" + $lev + "x 逐仓，止损 " + $stopPx + "（约 " + ([math]::Round($maxLossActual,2)) + "U），钱包约 " + ([math]::Round($wallet,2)) + "U。"
              if ($reported -notcontains $evt) { $handoff = $msg; $reported += $evt }
              Log-Day ("OPEN," + $sym + "," + $sideEn + "," + $qtyLive + "," + $entry + "," + $stopPx + ",rank=" + $best.rank + " atr=" + $best.atr + " sep=" + $best.sep + " recovered")
              $action = "opened"
              Write-Output ("OPENED_RECOVER {0} {1} qty={2} entry={3} stop={4} algo={5}" -f $sym,$sideEn,$qtyLive,$entry,$stopPx,$algoId)
              $openedNow = $true
              break
            }
          } catch {
            Write-Output ("OPEN_RECOVER_FAIL {0} {1}" -f $sym, $_.Exception.Message)
            throw
          }
        }
      }
      if (-not $openedNow) {
        if ($gradeA.Count -gt 0) {
          Write-Output "NO_VALID_SIZE"
          $action = "no_size"
        } else {
          Write-Output "NO_A_SETUP"
          $action = "no_setup"
        }
      }
      }
    }
  }

  Ensure-Prop $state "reported" @()
  Ensure-Prop $state "handoff" $null
  Ensure-Prop $state "wallet" 0
  Ensure-Prop $state "avail" 0
  Ensure-Prop $state "action" "noop"
  Ensure-Prop $state "open" $null
  Ensure-Prop $state "trades" 0
  Ensure-Prop $state "realized" 0.0
  Ensure-Prop $state "cooldown_until" $null
  Ensure-Prop $state "last_fail_count" 0
  Ensure-Prop $state "last_run" $null
  Ensure-Prop $state "last_scan_at" $null
  Ensure-Prop $state "day" $today
  Ensure-Prop $state "session" $SessionName
  $state.session = $SessionName
  $state.reported = $reported
  $state.handoff = $handoff
  $state.wallet = $wallet
  $state.avail = $avail
  $state.action = $action
  Save-State $state
  Write-Output "===RESULT==="
  Write-Output ("action=" + $action)
  Write-Output ("handoff=" + $(if ($handoff) { $handoff } else { "" }))
  Write-Output ("trades=" + $state.trades + " realized=" + $state.realized)
  Write-Output "===OK==="
} catch {
  $em = $_.Exception.Message; if ($_.ErrorDetails) { $em = $em + " " + $_.ErrorDetails.Message }; Write-Output ("===ERROR===" + $em)
  if (-not $state.last_fail_count) { $state.last_fail_count = 0 }
  Ensure-Prop $state "last_fail_count" 0
  Ensure-Prop $state "last_run" $null
  Ensure-Prop $state "action" "noop"
  Ensure-Prop $state "handoff" $null
  $state.last_fail_count = [int]$state.last_fail_count + 1
  $state.last_run = $nowLocal.ToString("o")
  $state.action = "error"
  $state.handoff = $null
  if ([int]$state.last_fail_count -ge 2) {
    $state.handoff = "白天自动交易连续两次连不上电脑/币安，本轮未改仓。请检查交易电脑是否在线。"
  }
  Save-State $state
  Write-Output ("fail_count=" + $state.last_fail_count)
  exit 2
}

