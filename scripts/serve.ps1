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
    [ValidateSet('start','stop','status')][string]$Action = 'start'
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
$SessLog   = Join-Path $LogDir 'session.log'    # per-session review file, overwritten at every start
$ModelsDir = Join-Path $Root 'models'

function Log([string]$m) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -Path $SupLog -Value $line
    Add-Content -Path $SessLog -Value $line      # tiny tee: events only, ticks never log
    Write-Host $line
}

function Read-Ini {
    $cfg = [ordered]@{
        port='8080'; host='0.0.0.0'; ctx_size='8192'; ngl='auto'; batch='2048'; ubatch='512'
        threads='0'; kvct='q8_0'; flash_attn='auto'; spec_type='none'; spec_nmax='3'; spec_pmin='0.75'
        model=''; backend=''; alias='local'; webui='off'; keepawake='on'; device=''
        tunnel_token=''; tunnel_url=''
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
    # Validate before anything consumes a value: a corrupt knob shipped to llama-server as an
    # empty argument dies during load and the watchdog misreads that as a backend problem.
    # status must stay read-only, so defaults are only logged during start.
    $def = @{ port='8080'; ctx_size='8192'; batch='2048'; ubatch='512'; spec_nmax='3'; spec_pmin='0.75';
              flash_attn='auto'; webui='off'; tunnel='off'; keepawake='on'; ngl='auto' }
    foreach ($k in @($def.Keys)) {
        $v = "$($cfg[$k])"
        $ok = switch ($k) {
            port       { $v -match '^\d+$' -and [int]$v -ge 1 -and [int]$v -le 65535 }
            spec_pmin  { $v -match '^\d?\.?\d+$' }
            ngl        { $v -match '^(?i:auto|\d+)$' }
            flash_attn { $v -match '^(?i:on|off|auto)$' }
            tunnel     { $v -match '^(?i:on|off)$' }
            webui      { $v -match '^(?i:on|off)$' }
            keepawake  { $v -match '^(?i:on|off)$' }
            default    { $v -match '^\d+$' }   # ctx_size batch ubatch spec_nmax
        }
        if (-not $ok) {
            if ($Action -eq 'start') { Log ("[cfg] invalid {0}='{1}' - using default '{2}'" -f $k, $v, $def[$k]) }
            $cfg[$k] = $def[$k]
        }
    }
    $cfg.model = "$($cfg.model)".TrimEnd('\')   # a trailing backslash would break CommandLineToArgvW quoting
    return $cfg
}

function Get-Backends([string]$override) {
    # Ordered list of backends to try. Order matters: a backend that cannot load the model at all
    # (CUDA build without SASS/PTX for a Blackwell card, cudart/cublas missing on the host) must
    # fall through to vulkan -> cpu instead of burning three retries on the same dead binary.
    if ($override) { $cand = @($override -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { $cand = @()
        if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) { $cand += 'cuda' }
        if (Test-Path (Join-Path $env:SystemRoot 'System32\vulkan-1.dll')) {
            $g = (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
                  Select-Object -ExpandProperty Name) -join ' '
            if ($g -match 'Intel|NVIDIA|AMD|Radeon|Arc') { $cand += 'vulkan' }
        }
        $cand += 'cpu'
    }
    $cand = @($cand | Where-Object { Test-Path (Join-Path $Root "bin\$_\llama-server.exe") })
    # A CUDA build without SASS for this GPU (sm_86/89/120) sees zero devices and then "succeeds"
    # on CPU at a fifth of the speed, with no error anywhere. Ask the binary itself, once per run.
    if ($cand -contains 'cuda') {
        if ($null -eq $script:CudaVis) {
            $d = ''
            try { $d = (& (Join-Path $Root 'bin\cuda\llama-server.exe') --list-devices 2>$null | Out-String) } catch { }
            $script:CudaVis = ($d.Trim().Length -gt 0 -and $d -notmatch '\(none\)')
        }
        if (-not $script:CudaVis) {
            Log '[be] the cuda build sees no CUDA device here - skipping cuda (silent-CPU trap).'
            $cand = @($cand | Where-Object { $_ -ne 'cuda' })
        }
    }
    if (-not $cand.Count) { $cand = @('cpu') }   # sole requested backend ruled out: still try cpu
    return @($cand | Select-Object -Unique)
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

function Stop-OurBinaries {
    # Ours only: llama-server / cloudflared processes whose image lives under $Root.
    foreach ($n in 'llama-server','cloudflared') {
        Get-CimInstance Win32_Process -Filter "Name='$n.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($Root, 2) } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}

function Test-PortFree($cfg) {
    try {
        $c = New-Object Net.Sockets.TcpClient
        $c.Connect('127.0.0.1', [int]$cfg.port); $c.Close()
        # Taken - but it may be OURS from a crash that lost state.json. Sweep ours, re-test;
        # only a foreign holder is a reason to refuse.
        Stop-OurBinaries
        Start-Sleep -Seconds 1
        try { $c2 = New-Object Net.Sockets.TcpClient; $c2.Connect('127.0.0.1', [int]$cfg.port); $c2.Close() }
        catch { return $true }
        Log ("[pre] REFUSE: port {0} is held by a process that is not ours - free it or change 'port' in config\settings.ini." -f $cfg.port)
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
    $script:ModelGB  = [math]::Round((Get-Item $main).Length / 1GB, 1)   # feeds the stall guard's grace window
    $script:ModelFile = Split-Path -Leaf $main
    # API key comes from a file, never argv: argv is readable by any process on the host.
    $a = @('-m', $main, '--host', $cfg.host, '--port', $cfg.port, '-c', $cfg.ctx_size,
           '-b', $cfg.batch, '--ubatch-size', $cfg.ubatch,
           '--api-key-file', $KeyPath, '--log-file', $SrvLog,
           '--metrics')   # /metrics feeds the tok/s line in session.log; sampled on an existing watchdog tick
    if ($cfg.alias) { $a += @('-a', $cfg.alias) }
    # level 1 drops KV-cache quantisation: q8_0 KV needs head_dim divisible by 32 and
    # kills the context on some architectures ("K cache type q8_0 ... does not divide n_embd_head_k").
    if ($level -lt 1 -and $cfg.kvct -and $cfg.kvct -ne 'f16') { $a += @('-ctk', $cfg.kvct, '-ctv', $cfg.kvct) }
    # ngl=auto => omit -ngl entirely and let llama.cpp's --fit choose the GPU/CPU split.
    if ($cfg.ngl -and $cfg.ngl -notmatch '^(?i:auto)$') { $a += @('-ngl', $cfg.ngl) }
    if ($cfg.flash_attn -ne 'off') { $a += @('--flash-attn', $cfg.flash_attn) }
    # pin the GPU when the host has several (e.g. laptop iGPU + dGPU): llama picks Vulkan0
    # otherwise, which on Optimus laptops is the slow Intel. Bad name = fast startup abort,
    # visible in the run.bat window - that is the feedback, no extra validation needed here.
    if ($cfg.device) { $a += @('--device', $cfg.device) }
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
    if ($cfg.tunnel_token) {
        # Named tunnel (stable URL). The token travels via the ENVIRONMENT, never on a command
        # line - same rule as --api-key-file. No usable tunnel_url => do not start (fail closed).
        if ($cfg.tunnel_url -notmatch '(?i)^https://') {
            Log '[tun] tunnel_token set but tunnel_url missing/not https - NOT starting (fail closed).'
            return $null
        }
        $env:TUNNEL_TOKEN = $cfg.tunnel_token
        $ta = Quote-Args @('tunnel','--no-autoupdate','--logfile',$TunLog,'--loglevel','info','run')
        $p = Start-Process -FilePath $cf -WindowStyle Hidden -PassThru -ArgumentList $ta
        $env:TUNNEL_TOKEN = $null
        if ($p) { [IO.File]::WriteAllText($UrlPath, $cfg.tunnel_url); Log ('[tun] NAMED tunnel pid {0} - stable URL -> {1}' -f $p.Id, $cfg.tunnel_url) }
        return $p
    }
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

function Start-KeepAwake {
    $ka = Join-Path $Root 'scripts\keepawake.ps1'
    if (-not (Test-Path $ka)) { return $null }
    $p = Start-Process powershell.exe -ArgumentList (Quote-Args @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ka)) -WindowStyle Hidden -PassThru
    if ($p) { Log "[pwr] pid $($p.Id): blocks SYSTEM sleep only - display timers untouched, screen still blanks." }
    return $p
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

function Export-SessionPerf([switch]$Mid) {
    # Harvest what exists: a SIGKILLed server flushes nothing, so this is the honest ceiling.
    # Event counts come from the session file itself - zero new state to keep in sync.
    $tag = $(if ($Mid) { '[harvest]' } else { '[end]' })
    try {
        $sl = @($(if (Test-Path $SessLog) { Get-Content $SessLog } else { @() }))
        $up = -1
        if ($sl.Count) { try { $up = ((Get-Date) - [datetime]::ParseExact($sl[0].Substring(0,19),'yyyy-MM-dd HH:mm:ss',$null)).TotalMinutes } catch { } }
        Log ($tag + ' uptime {0} min | watchdog events: {1} | problem lines: {2}' -f `
            $(if ($up -ge 0) { '{0:N0}' -f $up } else { '?' }), `
            @($sl -match '\[wd\]').Count, @($sl -match '\[!\]').Count)
        if (Test-Path $SrvLog) {
            Log '--- llama.cpp timing tail (from server.log) ---'
            Select-String -Path $SrvLog -Pattern 'model loaded|loading model|eval time|t/s|print_timing' |
                Select-Object -Last 40 | ForEach-Object { Log ('    | ' + ($_.Line -replace '\x1b\[[0-9;]*m','')) }
        }
    } catch { }
}

function Stop-Everything {
    Export-SessionPerf
    $st = Load-State
    if ($st) {
        foreach ($id in @($st.server, $st.tunnel, $st.keep)) {
            if ($id) { Get-Process -Id $id -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
        }
    }
    # Ours only. Binaries via the shared sweep; powershell helpers additionally must have THIS
    # key in their command line - another stick's or a dev clone's supervisor is never touched.
    Stop-OurBinaries
    $here = '*' + $Root + '*'
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*keepawake.ps1*' -and $_.CommandLine -like $here } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    # The watchdog loop itself is a plain powershell.exe off this key: without killing it,
    # "stop" closes the endpoint and 10 s later the loop resurrects server + tunnel.
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -like $here -and
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

# Log cap: every watchdog tick appends forever and this file lives on the key.
if ((Test-Path $SupLog) -and ((Get-Item $SupLog).Length -gt 50MB)) {
    Get-Content $SupLog -Tail 2000 | Set-Content $SupLog
    Log '[cfg] supervisor.log exceeded 50 MB - trimmed to its last 2000 lines.'
}
Remove-Item (Join-Path $LogDir '*.old') -Force -ErrorAction SilentlyContinue
Remove-Item $SessLog -Force -ErrorAction SilentlyContinue   # one session per file: a new start overwrites

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
if (-not $srv) { Log '[!] cannot start - fix the above and re-run.'; exit 1 }
# --- session.log header: what this session was, for the review back home. Never keys/tokens. ---
$ramGB = [math]::Round((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1MB, 1)
Log ('[sys] host={0} user={1} RAM={2} GB' -f $env:COMPUTERNAME, $env:USERNAME, $ramGB)
Log ('[cfg] session: backend={0} level={1} ngl={2} ctx={3} kvct={4} flash_attn={5} spec={6} port={7} tunnel={8}' -f `
    $becands[$beIdx], $level, $cfg.ngl, $cfg.ctx_size, $cfg.kvct, $cfg.flash_attn, $cfg.spec_type, $cfg.port,
    $(if ($cfg.tunnel_token) { 'named' } else { $cfg.tunnel }))
Log ('[cfg] model: {0} ({1} GB)' -f $script:ModelFile, $script:ModelGB)
$loadT0 = Get-Date

$tun = $null; $keep = $null
# Only the literal 'on' may ever enable the tunnel: a blank or corrupt value stays OFF
# (fail closed - a damaged settings.ini must never expose the port).
if ($cfg.tunnel -eq 'on') {
    $tun = Start-Tunnel $cfg
    if ($tun) {
        $url = if ($cfg.tunnel_token) { if (Test-Path $UrlPath) { ([IO.File]::ReadAllText($UrlPath)).Trim() } } else { Get-TunnelUrl 60 }
        if ($url) { Log "[tun] PUBLIC  ->  $url"; Log "[tun] clients must send:  Authorization: Bearer $key" }
        else      { Log '[tun] no URL yet (offline / API blocked) - retrying in background; LAN endpoint stays up.' }
    }
}

if ($cfg.keepawake -eq 'on') { $keep = Start-KeepAwake }

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
$mtPrev = $null; $msPrev = 0.0; $mxFails = 0   # /metrics tok/s sampling state
while ($true) {
    Start-Sleep -Seconds 10

    if (Test-Health $cfg) { $fastFails = 0
        if (-not $everHealthy) {
            $everHealthy = $true
            Set-Content -Path $ProfPath -Value ($env:COMPUTERNAME + '|' + $becands[$beIdx] + '|' + $level + '|' + $cfg.ngl) -Encoding ASCII   # remember what worked
            Log ('[perf] serving after {0:N0} s' -f ((Get-Date) - $loadT0).TotalSeconds)
        }
    }

    # Alive but never healthy and server.log has not grown for ~6 min => wedged (a hung load, a
    # GPU that never answers, or something pretending to be the server). Without this the port,
    # the tunnel and the wake veto stay held all night and nothing ever says so out loud.
    $logLen = Get-LogLen
    if ((Test-Live $srv) -and -not $everHealthy) {
        if ($logLen -eq $lastLogLen) { $stallTicks++ } else { $stallTicks = 0; $lastLogLen = $logLen }
        # Grace scales with the weights: a 16 GB read over USB 2 can go quiet ~10 min mid-load,
        # and killing a healthy load burns one of the three retries. ~40 s extra per GB.
        $stallLimit = 36 + [int][math]::Ceiling($(if ($script:ModelGB) { $script:ModelGB } else { 0 }) * 4)
        if ($stallTicks -ge $stallLimit) {
            Log ('[wd] alive but no log progress for ~{0} min before ever serving - killing it and treating it as a failed load.' -f [math]::Round($stallLimit * 10 / 60))
            $stallTicks = 0
            Export-SessionPerf -Mid   # harvest timings now: the next server boot rewrites server.log
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
        $loadT0 = Get-Date
        $everHealthy = $false
        $stallTicks = 0; $lastLogLen = -1
        if (-not $srv) { Log '[wd] restart failed - retry in 30s'; Start-Sleep -Seconds 30; continue }
        Save-State $srv $tun $keep $cfg
    }

    if ($cfg.tunnel -eq 'on' -and -not (Test-Live $tun)) {
        $tun = Start-Tunnel $cfg
        if ($tun) {
            $url = if ($cfg.tunnel_token) { if (Test-Path $UrlPath) { ([IO.File]::ReadAllText($UrlPath)).Trim() } } else { Get-TunnelUrl 60 }
            # quick tunnels mint a NEW hostname per restart; status.bat always shows the live one
            if ($url) { Log "[tun] PUBLIC (renewed)  ->  $url" }
            Save-State $srv $tun $keep $cfg
        } else { Start-Sleep -Seconds 30 }
    }

    # keepawake is as replaceable as the tunnel: if it died, the sleep veto died with it and a
    # sleeping laptop at 3 am serves nobody. ($keep null = script was missing from the start.)
    if ($cfg.keepawake -eq 'on' -and $keep -and -not (Test-Live $keep)) {
        Log '[wd] keepawake died - re-arming sleep veto.'
        $keep = Start-KeepAwake
        Save-State $srv $tun $keep $cfg
    }

    # cloudflared alive but no URL yet (DNS blip at boot): the start message promised a background
    # retry - do it. Named tunnels write their URL at start, so this stays a no-op for them.
    if ($cfg.tunnel -eq 'on' -and (Test-Live $tun) -and -not (Test-Path $UrlPath)) {
        $u2 = Get-TunnelUrl 15
        if ($u2) { Log "[tun] PUBLIC (late)  ->  $u2"; Save-State $srv $tun $keep $cfg }
    }

    # tok/s, measured server-side, sampled on a tick that already runs (loopback GET, sub-ms).
    # Logs only when tokens actually moved; stops honestly after three failures.
    if ($mxFails -lt 3) {
        try {
            $mx = (Invoke-WebRequest "http://127.0.0.1:$($cfg.port)/metrics" -UseBasicParsing -TimeoutSec 2 `
                    -Headers @{ Authorization = "Bearer $key" }).Content
            $gt = 0.0; $gs = 0.0
            foreach ($l in ($mx -split "`n")) {
                if     ($l -like 'llamacpp:tokens_predicted_total *')         { $gt = [double]($l -split ' ')[1] }
                elseif ($l -like 'llamacpp:tokens_predicted_seconds_total *') { $gs = [double]($l -split ' ')[1] }
            }
            if ($null -ne $mtPrev -and $gt -gt $mtPrev -and ($gs - $msPrev) -gt 0.01) {
                Log ('[perf] ~{0:N1} tok/s server-side ({1:N0} tok this tick)' -f (($gt - $mtPrev) / ($gs - $msPrev)), ($gt - $mtPrev))
            }
            $mtPrev = $gt; $msPrev = $gs
        } catch {
            $mxFails++
            if ($mxFails -eq 3) { Log '[perf] /metrics unavailable - tok/s sampling off for this session.' }
        }
    }
}
