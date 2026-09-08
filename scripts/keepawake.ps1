# keepawake.ps1 -- veto SYSTEM sleep while the key serves; let the SCREEN turn off.
#
# SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) is the OS-sanctioned
# veto (same call media players use). ES_DISPLAY_REQUIRED is deliberately NOT set:
# that flag is the only thing that would hold the backlight on, so the display and
# monitor power timers keep working exactly as configured. Nothing in the power
# plan is modified; releasing the veto happens automatically when this process exits.
#
# Started hidden by scripts\serve.ps1. Safe to run manually.

# EXECUTION_STATE is a DWORD. PS 5.1 cannot cast the literal 0x80000000 to UInt32
# (it overflows Int32 first and throws, leaving the variable $null - which silently
# drops ES_CONTINUOUS and makes the veto one-shot). Use Int32 bit patterns instead:
# the P/Invoke marshals the same 4 bytes.
$ES_CONTINUOUS       = [Int32]::MinValue        # 0x80000000
$ES_SYSTEM_REQUIRED  = 0x00000001
$ES_DISPLAY_REQUIRED = 0x00000002   # referenced only by the guard below

# NB: no -UsingNamespace here - Add-Type already inserts
# "using System.Runtime.InteropServices;" and asking again is a fatal
# "using directive appeared previously" compile error under PS 5.1.
Add-Type -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern int SetThreadExecutionState(int esFlags);
'@ -Name Power -Namespace Win32

$Root = Split-Path -Parent $PSScriptRoot
$Log  = Join-Path $Root 'logs\power.log'
function PLog([string]$m) {
    $l = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -Path $Log -Value $l
    Write-Host $l
}

function Hold-Awake {
    try {
        $rc = [Win32.Power]::SetThreadExecutionState($script:MASK)
        if ($rc -eq 0) { PLog '[keepawake] WARNING: SetThreadExecutionState returned 0 - veto NOT held.' }
    } catch { PLog ("[keepawake] BUG: {0} - veto NOT held." -f $_.Exception.Message) }
}
function Release-Awake {
    try { [void][Win32.Power]::SetThreadExecutionState($ES_CONTINUOUS) } catch { }
}

# If the type did not compile, every call below is a silent no-op: say so loudly.
if (-not ('Win32.Power' -as [type])) { PLog '[keepawake] BUG: Win32.Power unavailable - veto NOT held.'; exit 1 }

# --- self-check: the mask we hold must not contain the display bit -------------
$MASK = $ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED
if (($MASK -band $ES_DISPLAY_REQUIRED) -ne 0) { PLog '[keepawake] BUG: display bit set, aborting.'; exit 1 }
if ($MASK -eq $ES_SYSTEM_REQUIRED)           { PLog '[keepawake] BUG: ES_CONTINUOUS missing, veto would not persist.'; exit 1 }

# --- report (do not change) the display idle timers so the blanking is verifiable
function Get-VideoIdle([string]$which) {
    try {
        $o = powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 2>$null | Out-String
        $line = ($o -split "`r?`n" | Select-String -Pattern "Current $which Power Setting Index" | Select-Object -First 1).ToString()
        if ($line -match '0x([0-9a-fA-F]{8})') { return [int]('0x' + $Matches[1]) / 60 }
    } catch { }
    return $null
}
$idleAC = Get-VideoIdle 'AC'
$idleDC = Get-VideoIdle 'DC'

# Wait up to 90s for llama-server to appear (serve.ps1 starts it just before us).
$deadline = (Get-Date).AddSeconds(90)
while (-not (Get-Process llama-server -ErrorAction SilentlyContinue)) {
    if ((Get-Date) -gt $deadline) { PLog '[keepawake] no llama-server after 90s - nothing to do.'; exit 0 }
    Start-Sleep -Seconds 1
}

Hold-Awake
PLog ('[keepawake] VETO HELD 0x{0:X8} (ES_CONTINUOUS|ES_SYSTEM_REQUIRED; display bit NOT set -> screen may still blank).' -f $MASK)
PLog ('[keepawake] display idle from your power plan: AC {0} min / DC {1} min (read-only, nothing changed).' -f $(if($null -ne $idleAC){$idleAC}else{'?'}), $(if($null -ne $idleDC){$idleDC}else{'?'}))
if ($idleAC -eq 0) { PLog '[keepawake] NOTE: plan says AC display = Never, so the screen stays on. Change it in Power Options if that matters.' }

$bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
if ($bat -and $bat.BatteryStatus -ne 2) { PLog '[keepawake] WARNING: on battery - a 27B model will drain it fast.' }
PLog '[keepawake] lid close still sleeps the PC unless Power Options > lid close = Do nothing.'

# Hold while the server lives; if a crash takes it down, allow sleep briefly and RE-ARM
# when the watchdog brings it back (otherwise an overnight crash silently ends the veto).
$held = $true
while ($true) {
    if (Get-Process llama-server -ErrorAction SilentlyContinue) {
        if (-not $held) { PLog '[keepawake] llama-server back - veto re-armed.'; $held = $true }
        Hold-Awake
        Start-Sleep -Seconds 45
    } else {
        if ($held) { Release-Awake; PLog '[keepawake] llama-server gone - normal power behaviour restored (will re-arm on restart).'; $held = $false }
        Start-Sleep -Seconds 5
    }
}
