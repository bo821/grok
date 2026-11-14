# day_trade_status.ps1
# Read-only snapshot: wallet, open USDT-M positions, and open algo (stop) orders.
$ErrorActionPreference = "Stop"
$BaseDir = $PSScriptRoot
if (-not $BaseDir) { $BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $BaseDir) { $BaseDir = (Get-Location).Path }
. (Join-Path $BaseDir "night_lib.ps1")

$acc = Call-S "GET" "/fapi/v2/account" ""
$wallet = [decimal]$acc.totalWalletBalance
$avail = [decimal]$acc.availableBalance
$upnl = [decimal]$acc.totalUnrealizedProfit
Write-Output ("WALLET=" + $wallet)
Write-Output ("AVAIL=" + $avail)
Write-Output ("UPNL=" + $upnl)

$pos = Call-S "GET" "/fapi/v2/positionRisk" ""
$openPos = @($pos | Where-Object { [decimal]$_.positionAmt -ne 0 })
Write-Output ("OPEN_POS_COUNT=" + $openPos.Count)
foreach ($p in $openPos) {
  Write-Output ("POS symbol=" + $p.symbol + " amt=" + $p.positionAmt + " entry=" + $p.entryPrice + " mark=" + $p.markPrice + " upnl=" + $p.unRealizedProfit + " lev=" + $p.leverage + " marginType=" + $p.marginType + " liq=" + $p.liquidationPrice + " iso=" + $p.isolatedMargin)
}

$algos = Call-S "GET" "/fapi/v1/openAlgoOrders" ""
Write-Output ("OPEN_ALGO_COUNT=" + @($algos).Count)
foreach ($a in @($algos)) {
  Write-Output ("ALGO symbol=" + $a.symbol + " side=" + $a.side + " type=" + $a.orderType + " trigger=" + $a.triggerPrice + " qty=" + $a.quantity + " reduceOnly=" + $a.reduceOnly + " status=" + $a.algoStatus)
}
Write-Output "DONE"
