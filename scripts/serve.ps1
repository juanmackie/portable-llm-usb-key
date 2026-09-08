#Requires -Version 5.1
# serve.ps1 -- USB Inference Key supervisor (silent, self-healing, portable).
#
#   start   : load model, open a public HTTPS endpoint, keep it alive until stopped
#   status  : backend / pid / local + public URL / api key / end-to-end probe
#   stop    : kill our llama-server + cloudflared + keepawake, close the endpoint
#
# Nothing installs: no service, no scheduled task, no registry write, no startup
# entry. Logs, temp files and state all stay on this key.

[CmdletBinding()]
param(
    [ValidateSet('start','stop','status')][string]$Action = 'start',
    [switch]$Visible
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# Key root = first ancestor holding bin\ (this script lives in scripts\).
$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
while ($Root -and -not (Test-Path (Join-Path $Root 'bin'))) { $Root = Split-Path -Parent $Root }
if (-not $Root) { $Root = $PSScriptRoot }

$LogDir = Join-Path $Root 'logs'
$TmpDir = Join-Path $Root 'tmp'
$CfgDir = Join-Path $Root 'config'
foreach ($d in @($LogDir, $TmpDir, $CfgDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

# Every scratch byte stays on the key instead of the host's %TEMP%.
$env:TEMP = $TmpDir; $env:TMP = $TmpDir; $env:TMPDIR = $TmpDir

$IniPath   = Join-Path $CfgDir 'settings.ini'
$StatePath = Join-Path $CfgDir 'state.json'
$UrlPath   = Join-Path $CfgDir 'public_url.txt'
$KeyPath   = Join-Path $CfgDir 'api.key'
$SrvLog    = Join-Path $LogDir 'server.log'
$TunLog    = Join-Path $LogDir 'tunnel.log'
$SupLog    = Join-Path $LogDir 'supervisor.log'
$ModelsDir = Join-Path $Root 'models'

function Log([string]$m) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -Path $SupLog -Value $line
    Write-Host $line
}

function Read-Ini {
    $cfg = [ordered]@{
        port='8080'; host='0.0.0.0'; ctx_size='8192'; ngl='auto'; batch='2048'; ubatch='512'
        threads='0'; kvct='q8_0'; flash_attn='auto'; spec_type='none'; spec_nmax='3'; spec_pmin='0.75'
        model=''; backend=''; alias='local'; webui='off'; keepawake='on'
        # tunnel defaults OFF on purpose: if settings.ini is missing or unreadable we must
        # never expose the port. config\settings.ini ships with tunnel=on.
        tunnel='off'
    }
    if (Test-Path $IniPath) {
        foreach ($l in Get-Content $IniPath) {
            if ($l -match '^\s*[#;]') { continue }
            if ($l -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$') { $cfg[$Matches[1].ToLower()] = $Matches[2] }
        }
    }
    return $cfg
}

function Get-Backends([string]$override) {
    # Ordered list of backends to try. Order matters: a backend that cannot load the model at all
    # (CUDA build without SASS/PTX for a Blackwell card, cudart/cublas missing on the host) must
    # fall through to vulkan -> cpu instead of burning three retries on the same dead binary.
    if ($override) { return @($override -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $list = @()
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) { $list += 'cuda' }
    if (Test-Path (Join-Path $env:SystemRoot 'System32\vulkan-1.dll')) {
        $g = (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
              Select-Object -ExpandProperty Name) -join ' '
        if ($g -match 'Intel|NVIDIA|AMD|Radeon|Arc') { $list += 'vulkan' }
    }
    $list += 'cpu'
    return @($list | Where-Object { Test-Path (Join-Path $Root "bin\$_\llama-server.exe") })
}

function Get-Backend([string]$override) { return @(Get-Backends $override)[0] }

function Find-Models {
    # draft = first *MTP*/*eagle* file; main candidates = everything else, biggest first
    # (models\ wins over key root). serve.ps1 takes the biggest one this host can hold.
    $all = @()
    foreach ($dir in @($ModelsDir, $Root)) {
        $all += Get-ChildItem -Path $dir -Filter '*.gguf' -File -ErrorAction SilentlyContinue
    }
    $all = @($all | Sort-Object -Property @{e={ $_.Directory.FullName.ToLower() -ne $ModelsDir.ToLower() }}, @{e={$_.Length}; desc=$true})
    $draft = $all | Where-Object { $_.Name -match '(?i)mtp|eagle|draft' } | Select-Object -First 1
    $mains = @($all | Where-Object { $_.FullName -ne $draft.FullName })
    return @{ Mains = $mains; Draft = $draft }
}

function Get-ApiKey {
    if (-not (Test-Path $KeyPath)) {
        $b = New-Object byte[] 24
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($b); $rng.Dispose()
        [IO.File]::WriteAllText($KeyPath, (($b | ForEach-Object { '{0:x2}' -f $_ }) -join ''))
    }
    return ([IO.File]::ReadAllText($KeyPath)).Trim()
}

function Quote-Args([string[]]$a) {
    # CommandLineToArgvW quoting: model paths carry spaces and "(1)" suffixes.
    # Only " needs escaping here (backslashes are literal unless they precede a quote).
    ($a | ForEach-Object {
        if ($_ -match '[\s()]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ }
    }) -join ' '
}

function Test-Fits([string]$main) {
    # Will this host hold these weights? Fail loudly instead of watchdog-looping overnight.
    $size   = (Get-Item $main).Length
    $sizeGB = [math]::Round($size/1GB, 2)
    $os     = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $ramGB  = [math]::Round($os.TotalVisibleMemorySize/1MB, 1)
    if ($size -gt 0.92 * $ramGB * 1GB) {
        Log ('[pre] skip {0} ({1} GB): cannot load {1} GB into {2} GB RAM.' -f (Split-Path -Leaf $main), $sizeGB, $ramGB)
        return $false
    }
    Log ('[pre] use {0} ({1} GB) - host RAM {2} GB' -f (Split-Path -Leaf $main), $sizeGB, $ramGB)
    $vramMiB = $null
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        $t = nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1
        if ($t -match '\d+') { $vramMiB = [int]$Matches[0] }
    }
    if ($null -ne $vramMiB -and $size -gt $vramMiB * 1MB) {
        Log ('[pre] {0} GB weights > {1} GB VRAM -> partial offload, --fit picks the split (ngl=auto).' -f $sizeGB, [math]::Round($vramMiB/1024, 1))
    }
    return $true
}

function Test-PortFree($cfg) {
    try {
        $c = New-Object Net.Sockets.TcpClient
        $c.Connect('127.0.0.1', [int]$cfg.port); $c.Close()
        Log ("[pre] REFUSE: port {0} is already taken by another process - free it or change 'port' in config\settings.ini." -f $cfg.port)
        return $false
    } catch { return $true }
}

function Start-Server($cfg, [int]$level, [bool]$checkPort = $true, [string]$be = '') {
    if (-not $be) { $be = @(Get-Backends $cfg.backend)[0] }
    $script:BeUsed = $be
    $bin = Join-Path $Root "bin\$be"
    $exe = Join-Path $bin 'llama-server.exe'
    if (-not (Test-Path $exe)) { Log "[!] missing $exe"; return $null }
    if ($checkPort -and -not (Test-PortFree $cfg)) { return $null }

    $m = Find-Models
    if ($cfg.model) { $cands = @($cfg.model) } else { $cands = @($m.Mains | ForEach-Object { $_.FullName }) }
    $main = $null
    foreach ($c in $cands) {
        if (-not (Test-Path $c)) { Log ("[pre] skip missing model: {0}" -f $c); continue }
        if (Test-Fits $c) { $main = $c; break }
    }
    if (-not $main) {
        Log '[!] no GGUF on this key fits this host. Fix: put a smaller quant in models\ (6 GB VRAM / 16 GB RAM runs a 7-9B Q4 well).'
        return $null
    }
    # API key comes from a file, never argv: argv is readable by any process on the host.
    $a = @('-m', $main, '--host', $cfg.host, '--port', $cfg.port, '-c', $cfg.ctx_size,
           '-b', $cfg.batch, '--ubatch-size', $cfg.ubatch, '-a', $cfg.alias,
           '--api-key-file', $KeyPath, '--log-file', $SrvLog)
    # level 1 drops KV-cache quantisation: q8_0 KV needs head_dim divisible by 32 and
    # kills the context on some architectures ("K cache type q8_0 ... does not divide n_embd_head_k").
    if ($level -lt 1 -and $cfg.kvct -and $cfg.kvct -ne 'f16') { $a += @('-ctk', $cfg.kvct, '-ctv', $cfg.kvct) }
    # ngl=auto => omit -ngl entirely and let llama.cpp's --fit choose the GPU/CPU split.
    if ($cfg.ngl -and $cfg.ngl -notmatch '^(?i:auto)$') { $a += @('-ngl', $cfg.ngl) }
    if ($cfg.flash_attn -ne 'off') { $a += @('--flash-attn', $cfg.flash_attn) }
    if ($cfg.webui -eq 'off')      { $a += '--no-webui' }
    if ($cfg.threads -ne '0')      { $a += @('-t', $cfg.threads) }
    # level 2 also drops speculative decoding (needs matching MTP/draft heads).
    if ($level -lt 2 -and $cfg.spec_type -and $cfg.spec_type -ne 'off' -and $cfg.spec_type -ne 'none') {
        # draft-mtp uses the main model's own MTP layers and ngram-* needs no draft file at all;
        # passing -md there would point at whatever file happens to have "mtp" in its name.
        if ($m.Draft -and $cfg.spec_type -notmatch '^(draft-mtp|ngram)') { $a += @('-md', $m.Draft.FullName) }
        $a += @('--spec-type', $cfg.spec_type, '--spec-draft-n-max', $cfg.spec_nmax,
                '--spec-draft-p-min', $cfg.spec_pmin)
    } else {
        $a += @('--spec-type', 'none')
    }

    $p = Start-Process -FilePath $exe -ArgumentList (Quote-Args $a) -WorkingDirectory $bin `
                       -WindowStyle Hidden -PassThru
    if ($p) {
        $deg = @('as configured', 'no KV quant', 'no KV quant + no spec decode', 'no spec decode')[$level]
        Log ('[srv] llama-server ({0}) pid {1}  model={2}  level={3}' -f $be, $p.Id, (Split-Path -Leaf $main), $deg)
    }
    return $p
}

function Show-ServerError([int]$lines) {
    if (-not (Test-Path $SrvLog)) { return }
    Get-Content $SrvLog -Tail $lines -ErrorAction SilentlyContinue |
        Select-String -Pattern '^\x1b\[3[15]m|error|failed|invalid|abort' |
        Select-Object -Last 4 |
        ForEach-Object { Log ('    | ' + ($_.ToString() -replace '\x1b\[[0-9;]*m','')) }
}

function Get-LogLen { if (Test-Path $SrvLog) { (Get-Item $SrvLog).Length } else { 0 } }

function Test-BackendFatal {
    # Only strong signatures: a backend/driver that cannot serve this GPU at all, as opposed to a
    # config argument the model rejects. Misfiring here would abandon a perfectly good backend.
    if (-not (Test-Path $SrvLog)) { return $false }
    $t = ((Get-Content $SrvLog -Tail 150 -ErrorAction SilentlyContinue) -join ' ') -replace '\x1b\[[0-9;]*m', ''
    return [bool]($t -match '(?i)no kernel image|CUDA error|cudaError|ggml_cuda_init|initialize CUDA|cublas|cudart|vk::|VkResult')
}

function Start-Tunnel($cfg) {
    $cf = Join-Path $Root 'bin\tools\cloudflared.exe'
    if (-not (Test-Path $cf)) { Log '[tun] bin\tools\cloudflared.exe missing - LAN only.'; return $null }
    Remove-Item $TunLog -Force -ErrorAction SilentlyContinue   # never report a dead URL as live
    $a = @('tunnel', '--no-autoupdate', '--url', "http://127.0.0.1:$($cfg.port)",
           '--logfile', $TunLog, '--loglevel', 'info')
    $p = Start-Process -FilePath $cf -ArgumentList (Quote-Args $a) -WindowStyle Hidden -PassThru
    if ($p) { Log "[tun] cloudflared pid $($p.Id) - requesting quick tunnel..." }
    return $p
}

function Get-TunnelUrl([int]$timeoutSec = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $TunLog) {
            $u = Select-String -Path $TunLog -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' -AllMatches -ErrorAction SilentlyContinue |
                 ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } | Select-Object -Last 1
            if ($u) { [IO.File]::WriteAllText($UrlPath, $u); return $u }
        }
        Start-Sleep -Milliseconds 700
    }
    Remove-Item $UrlPath -Force -ErrorAction SilentlyContinue
    return $null
}

function Test-Live($p) { $p -and (Get-Process -Id $p.Id -ErrorAction SilentlyContinue) }

function Test-Health($cfg) {
    try { (Invoke-WebRequest "http://127.0.0.1:$($cfg.port)/health" -UseBasicParsing -TimeoutSec 4).StatusCode -eq 200 }
    catch { $false }
}

function Save-State($srv, $tun, $keep, $cfg) {
    @{ server=$(if($srv){$srv.Id}else{$null}); tunnel=$(if($tun){$tun.Id}else{$null});
       keep=$(if($keep){$keep.Id}else{$null}); self=$PID; port=$cfg.port; backend=$(if($script:BeUsed){$script:BeUsed}else{Get-Backend $cfg.backend})
    } | ConvertTo-Json -Compress | Set-Content -Path $StatePath -Encoding ASCII
}

function Load-State {
    if (Test-Path $StatePath) { try { Get-Content $StatePath -Raw | ConvertFrom-Json } catch { $null } }
}

function Stop-Everything {
    $st = Load-State
    if ($st) {
        foreach ($id in @($st.server, $st.tunnel, $st.keep)) {
            if ($id) { Get-Process -Id $id -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
        }
    }
    # Ours only: processes whose image or command line points at this key.
    foreach ($n in 'llama-server','cloudflared') {
        Get-CimInstance Win32_Process -Filter "Name='$n.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($Root, 2) } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*keepawake.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    # The watchdog loop itself is a plain powershell.exe off this key: without killing it,
    # "stop" closes the endpoint and 10 s later the loop resurrects server + tunnel.
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and
                       $_.CommandLine -like '*serve.ps1*' -and $_.CommandLine -like '* start*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Remove-Item $StatePath, $UrlPath -Force -ErrorAction SilentlyContinue
    Log '[!] stopped - endpoint closed, sleep veto released.'
}

if ($Action -eq 'stop') { Stop-Everything; exit 0 }

if ($Action -eq 'status') {
    $cfg = Read-Ini
    $st  = Load-State
    $url = if (Test-Path $UrlPath) { [IO.File]::ReadAllText($UrlPath).Trim() } else { '(none)' }
    $key = if (Test-Path $KeyPath) { Get-ApiKey } else { '(none)' }
    $up  = if ($st -and $st.server -and (Get-Process -Id $st.server -ErrorAction SilentlyContinue)) { 'RUNNING pid ' + $st.server } else { 'DOWN' }
    '{0,-20}: {1}' -f 'server', $up
    '{0,-20}: {1}' -f 'local health', $(if (Test-Health $cfg) { 'ok' } else { 'loading / down' })
    '{0,-20}: {1}' -f 'local', "http://localhost:$($cfg.port)/v1/chat/completions"
    '{0,-20}: {1}' -f 'public', $url
    '{0,-20}: {1}' -f 'api key', $key
    if ($url -ne '(none)') {
        try {
            $r = Invoke-WebRequest "$url/v1/models" -UseBasicParsing -TimeoutSec 20 -Headers @{ Authorization = "Bearer $key" }
            '{0,-20}: HTTP {1} {2}' -f 'public /v1/models', $r.StatusCode, $r.Content
        } catch {
            $c = try { $_.Exception.Response.StatusCode.value__ } catch { 'unreachable' }
            '{0,-20}: HTTP {1}' -f 'public /v1/models', $c
        }
    }
    exit 0
}

# --------------------------- start ---------------------------
$cfg = Read-Ini
if (-not $cfg.port -or $cfg.port -notmatch '^\d+$') { $cfg.port = '8080' }

$prev = Load-State
if ($prev -and $prev.self -and (Get-Process -Id $prev.self -ErrorAction SilentlyContinue)) {
    Log "[srv] already running (supervisor pid $($prev.self)) - use status.bat or stop.bat."
    exit 0
}
if ($prev -and $prev.server -and (Get-Process -Id $prev.server -ErrorAction SilentlyContinue)) {
    Log "[srv] server from an earlier run still up (pid $($prev.server)) - stopping it, then starting fresh."
    Stop-Everything
}

$key  = Get-ApiKey
Log "=== start  backend=$(Get-Backend $cfg.backend)  port=$($cfg.port)  tunnel=$($cfg.tunnel) ==="
Log "[env] host=$env:COMPUTERNAME user=$env:USERNAME  (portable: nothing installed, no host-side state)"

# Remember what actually worked ON THIS HOST: which backend could load the model, and which
# optimisation level survived. A doomed attempt costs a whole model read off USB (minutes), and a
# weak laptop must never handicap a strong one, so the file is keyed by computer name.
# Delete config\profile.txt after changing models/settings to retry everything.
$ProfPath = Join-Path $CfgDir 'profile.txt'
$becands  = @(Get-Backends $cfg.backend)   # @() is required: a single-item return unwraps to a string
if (-not $becands -or $becands.Count -eq 0) { Log '[!] no usable llama-server.exe under bin\ (cpu / vulkan / cuda)'; exit 1 }
$beIdx = 0; $level = 0
$prof = "$((Get-Content $ProfPath -ErrorAction SilentlyContinue))"
if ($prof) {
    $f = $prof.Split('|')
    if ($f.Count -ge 3 -and $f[0] -eq $env:COMPUTERNAME) {
        $i = $becands.IndexOf($f[1]); if ($i -ge 0) { $beIdx = $i }
        if ($f[2] -match '^[012]$') { $level = [int]$f[2] }
        if ($f.Count -ge 4 -and $f[3] -match '^(?i:auto|\d+)$') { $cfg.ngl = $f[3] }
        Log "[cfg] last run here worked: backend=$($becands[$beIdx]) level=$level ngl=$($cfg.ngl) - delete config\profile.txt to retry everything"
    }
}
# Snapshot the log size before launching: llama.cpp rewrites --log-file, so an exactly unchanged
# size after a death is the signal that the binary never wrote anything (see the watchdog).
$attemptLogLen = Get-LogLen
$srv = Start-Server $cfg $level $true $becands[$beIdx]
if (-not $srv) { Log '[!] cannot start - fix the above and re-run.'; if ($Visible) { pause }; exit 1 }

$tun = $null; $keep = $null
if ($cfg.tunnel -ne 'off') {
    $tun = Start-Tunnel $cfg
    if ($tun) {
        $url = Get-TunnelUrl 60
        if ($url) { Log "[tun] PUBLIC  ->  $url"; Log "[tun] clients must send:  Authorization: Bearer $key" }
        else      { Log '[tun] no URL yet (offline / API blocked) - retrying in background; LAN endpoint stays up.' }
    }
}

if ($cfg.keepawake -ne 'off') {
    $ka = Join-Path $Root 'scripts\keepawake.ps1'
    if (Test-Path $ka) {
        $keep = Start-Process powershell.exe -ArgumentList (Quote-Args @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ka)) -WindowStyle Hidden -PassThru
        Log "[pwr] pid $($keep.Id): blocks SYSTEM sleep only - display timers untouched, screen still blanks."
    }
}

Save-State $srv $tun $keep $cfg
'  local    http://localhost:{0}/v1/chat/completions' -f $cfg.port
'  api key  {0}' -f $key
'  stop     stop.bat       status   status.bat'
Log '[wd] watchdog armed (10s): restarts server and tunnel on death.'

$liveSince = Get-Date
$everHealthy = $false      # escalation is driven by "never served a request", not by a stopwatch
$fastFails = 0
$stallTicks = 0
$lastLogLen = -1
while ($true) {
    Start-Sleep -Seconds 10

    if (Test-Health $cfg) { $fastFails = 0
        if (-not $everHealthy) { $everHealthy = $true; Set-Content -Path $ProfPath -Value ($env:COMPUTERNAME + '|' + $becands[$beIdx] + '|' + $level + '|' + $cfg.ngl) -Encoding ASCII }  # remember what worked
    }

    # Alive but never healthy and server.log has not grown for ~6 min => wedged (a hung load, a
    # GPU that never answers, or something pretending to be the server). Without this the port,
    # the tunnel and the wake veto stay held all night and nothing ever says so out loud.
    $logLen = Get-LogLen
    if ((Test-Live $srv) -and -not $everHealthy) {
        if ($logLen -eq $lastLogLen) { $stallTicks++ } else { $stallTicks = 0; $lastLogLen = $logLen }
        if ($stallTicks -ge 36) {
            Log '[wd] alive but no log progress for ~6 min before ever serving - killing it and treating it as a failed load.'
            $stallTicks = 0
            Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Live $srv)) {
        $young = -not $everHealthy     # died during load => backend or config problem, not a crash
        Show-ServerError 80
        # A binary whose run leaves server.log at exactly the size it had before launch cannot run
        # here (missing cudart/cublas, wrong CPU/GPU arch). That, or an explicit backend/driver
        # error, is the only reason to abandon a backend early; anything else is more likely a
        # config argument, which no backend change can fix.
        $noOutput = ((Get-LogLen) -eq $attemptLogLen)
        $beFatal = ($noOutput -or (Test-BackendFatal))
        # A forced numeric ngl died before ever serving: almost always "model won't fit this GPU's
        # VRAM", not a dead backend. Retry the SAME backend at ngl=auto - the branches below would
        # abandon a perfectly good GPU (changing backend, or giving up after three fast fails).
        # Bounded: ngl becomes 'auto', so this branch fires at most once per load.
        if ($young -and $cfg.ngl -match '^\d+$') {
            Log ("[wd] ngl={0} cannot fit this GPU -> retrying ngl=auto (host remembers in profile.txt)" -f $cfg.ngl)
            $cfg.ngl = 'auto'; $level = 0
        } elseif ($young -and $beFatal -and $beIdx -lt ($becands.Count - 1)) {
            Log ('[wd] {0} cannot run here ({1}) -> backend {2}' -f $becands[$beIdx], $(if ($noOutput) { 'binary produced no output' } else { 'backend/driver error in server.log' }), $becands[$beIdx + 1])
            $beIdx++; $level = 0
        } elseif ($young -and $level -lt 2) {
            $level++
            Log ('[wd] died during load ({0} s) -> level {1}: {2}' -f [int]((Get-Date) - $liveSince).TotalSeconds, $level, @('none','no KV quant','no KV quant + no spec decode')[$level])
        } elseif ($young -and $beIdx -lt ($becands.Count - 1)) {
            Log ('[wd] {0} cannot load this model even with every optimisation off -> backend {1}' -f $becands[$beIdx], $becands[$beIdx + 1])
            $beIdx++; $level = 0
        } elseif ($young) {
            $fastFails++
            if ($fastFails -ge 3) {
                Log '[wd] GIVING UP: no backend and no optimisation level loaded this model here - not burning the laptop all night.'
                Stop-Everything
                exit 1
            }
            Log '[wd] retry.'
        } else {
            $fastFails = 1
            Log '[wd] died after a long run (crash / OOM / host slept) - restarting at the same level.'
        }
        $attemptLogLen = Get-LogLen
        $srv = Start-Server $cfg $level $false $becands[$beIdx]
        $liveSince = Get-Date
        $everHealthy = $false
        $stallTicks = 0; $lastLogLen = -1
        if (-not $srv) { Log '[wd] restart failed - retry in 30s'; Start-Sleep -Seconds 30; continue }
        Save-State $srv $tun $keep $cfg
    }

    if ($cfg.tunnel -ne 'off' -and -not (Test-Live $tun)) {
        $tun = Start-Tunnel $cfg
        if ($tun) {
            $url = Get-TunnelUrl 60
            # quick tunnels mint a NEW hostname per restart; status.bat always shows the live one
            if ($url) { Log "[tun] PUBLIC (renewed)  ->  $url" }
            Save-State $srv $tun $keep $cfg
        } else { Start-Sleep -Seconds 30 }
    }
}
