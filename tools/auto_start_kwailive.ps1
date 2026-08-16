# ASCII-only script. Chinese UI text is built from Unicode code points
# so Windows PowerShell 5 (ANSI/GBK default) will not mojibake the source.
$ErrorActionPreference = 'Continue'
try {
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
  $OutputEncoding = [Console]::OutputEncoding
} catch {}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

function U([int[]]$codes) {
  return -join ($codes | ForEach-Object { [char]$_ })
}

# startLive / kaiBo / liJiKaiBo / queRenKaiBo / kaiShi
$startLive   = U @(0x5F00, 0x59CB, 0x76F4, 0x64AD)
$kaiBo       = U @(0x5F00, 0x64AD)
$liJiKaiBo   = U @(0x7ACB, 0x5373, 0x5F00, 0x64AD)
$queRenKaiBo = U @(0x786E, 0x8BA4, 0x5F00, 0x64AD)
$kaiShi      = U @(0x5F00, 0x59CB)
$targets = @($startLive, $kaiBo, $liJiKaiBo, $queRenKaiBo, $kaiShi)

$root = [System.Windows.Automation.AutomationElement]::RootElement
$wins = $root.FindAll(
  [System.Windows.Automation.TreeScope]::Children,
  [System.Windows.Automation.Condition]::TrueCondition
)

$clicked = $false
$log = New-Object System.Collections.Generic.List[string]

function Try-Invoke($el, $label) {
  try {
    $inv = $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    if ($null -ne $inv) {
      $inv.Invoke()
      $script:log.Add("INVOKED:$label")
      return $true
    }
  } catch {}
  try {
    $el.SetFocus()
    Start-Sleep -Milliseconds 100
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    $script:log.Add("ENTER:$label")
    return $true
  } catch {}
  return $false
}

foreach ($w in $wins) {
  try {
    $name = $w.Current.Name
    $pid = $w.Current.ProcessId
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
    if ($null -eq $proc) { continue }
    if ($proc.ProcessName -notmatch 'kwailive') { continue }
    $log.Add("WIN:$name pid=$pid")

    $all = $w.FindAll(
      [System.Windows.Automation.TreeScope]::Descendants,
      [System.Windows.Automation.Condition]::TrueCondition
    )
    foreach ($el in $all) {
      $n = $el.Current.Name
      if ([string]::IsNullOrWhiteSpace($n)) { continue }
      foreach ($t in $targets) {
        if ($n -eq $t -or $n.Contains($t)) {
          $ctype = $el.Current.ControlType.ProgrammaticName
          $log.Add("FOUND:$n type=$ctype")
          if ($n.Contains($startLive) -or $n.Contains($kaiBo) -or $n.Contains($liJiKaiBo) -or $n.Contains($queRenKaiBo)) {
            if (Try-Invoke $el $n) {
              $clicked = $true
              Start-Sleep -Milliseconds 800
            }
          }
        }
      }
    }
  } catch {
    $log.Add("ERR:$($_.Exception.Message)")
  }
}

if (-not $clicked) {
  foreach ($w in $wins) {
    try {
      $proc = Get-Process -Id $w.Current.ProcessId -ErrorAction SilentlyContinue
      if ($null -eq $proc -or $proc.ProcessName -notmatch 'kwailive') { continue }
      $btnCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, $startLive)
      $btn = $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $btnCond)
      if ($null -ne $btn) {
        $log.Add("FOUND_EXACT:$startLive")
        if (Try-Invoke $btn $startLive) { $clicked = $true }
      }
    } catch {}
  }
}

$result = @{
  ok = $clicked
  log = ($log -join "`n")
}
($result | ConvertTo-Json -Compress)
