<#
  get-binaries.ps1 - fill in the parts a git clone cannot carry (bin\ is 760 MB and gitignored).

  Downloads llama.cpp release builds and cloudflared onto this stick. Run it from the stick:

      powershell -NoProfile -ExecutionPolicy Bypass -File get-binaries.ps1
      powershell -NoProfile -ExecutionPolicy Bypass -File get-binaries.ps1 -Cuda
      powershell -NoProfile -ExecutionPolicy Bypass -File get-binaries.ps1 -All

  Default = cpu (17 MB) + vulkan (34 MB) + cloudflared (60 MB). That combination needs no CUDA
  install and no CUDA kernels for a specific GPU, which is why it is the default: Vulkan serves
  NVIDIA (including RTX 50-series), AMD and Intel with a current driver.

  -Cuda     adds the CUDA 12.4 build (242 MB). Needs cudart64_12 + cublas64_12 on the host unless
            you also pass -Cudart. Contains SASS only for sm_50/61/70/75/80/90, no PTX, so it
            cannot serve a Blackwell (RTX 50xx) GPU - that card uses vulkan with these binaries.
  -Cudart   adds the CUDA 12.4 runtime bundle (373 MB) so CUDA works on a machine with nothing
            but the GPU driver installed.
  -All      both of the above.
#>
param(
    [switch]$Cuda,
    [switch]$Cudart,
    [switch]$All,
    [string]$Build = '',
    [string]$Root  = (Split-Path -Parent $PSCommandPath)
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest's progress bar slows big downloads ~10x
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if ($All) { $Cuda = $true; $Cudart = $true }

# Default to the newest llama.cpp release; the pinned build is only the offline fallback.
if (-not $Build) {
    try {
        $rel = Invoke-RestMethod 'https://api.github.com/repos/ggml-org/llama.cpp/releases/latest' -Headers @{ 'User-Agent' = 'usb-inference-key' } -UseBasicParsing
        if ($rel.tag_name -match '^b\d+$') { $Build = $rel.tag_name }
    } catch { Write-Host ('  latest-release query failed: ' + $_.Exception.Message) }
    if (-not $Build) { $Build = 'b10797'; Write-Host ('  falling back to pinned build ' + $Build) }
}

$tmp = Join-Path $Root 'tmp'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$base = "https://github.com/ggml-org/llama.cpp/releases/download/$Build"

function Get-Asset([string]$url) {
    $z = Join-Path $tmp ([IO.Path]::GetFileName($url))
    Write-Host ('  downloading {0}' -f (Split-Path -Leaf $z))
    # Hotel Wi-Fi dies mid-download: three tries, partial file never lingers.
    for ($try = 1; $try -le 3; $try++) {
        try { Invoke-WebRequest -Uri $url -OutFile $z -UseBasicParsing; return $z }
        catch {
            Remove-Item $z -Force -ErrorAction SilentlyContinue
            if ($try -eq 3) { throw }
            Write-Host ('     failed, retry {0}/2 in 5 s' -f $try); Start-Sleep -Seconds 5
        }
    }
}

function Install-Asset([string]$zip, [string]$into, [string]$marker) {
    $x = Join-Path $tmp ('x_' + [IO.Path]::GetFileNameWithoutExtension($zip))
    if (Test-Path $x) { Remove-Item $x -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $x -Force
    $hit = Get-ChildItem $x -Recurse -Filter $marker | Select-Object -First 1
    if (-not $hit) { throw "$marker not found inside $zip" }
    $src = if ($hit.Directory.FullName -eq $x) { $x } else { Split-Path -Parent $hit.FullName }
    New-Item -ItemType Directory -Force -Path $into | Out-Null
    Move-Item -Path (Join-Path $src '*') -Destination $into -Force
    Remove-Item $x -Recurse -Force
    Write-Host ('     -> {0}' -f $into.Replace($Root, '.'))
}

Write-Host "llama.cpp $Build -> $Root\bin"
$picks = @(
    @{ u = "$base/llama-$Build-bin-win-cpu-x64.zip";    d = 'cpu';    m = 'llama-server.exe' },
    @{ u = "$base/llama-$Build-bin-win-vulkan-x64.zip"; d = 'vulkan'; m = 'llama-server.exe' }
)
if ($Cuda)   { $picks += @{ u = "$base/llama-$Build-bin-win-cuda-12.4-x64.zip";      d = 'cuda'; m = 'llama-server.exe' } }
if ($Cudart) { $picks += @{ u = "$base/cudart-llama-bin-win-cuda-12.4-x64.zip";      d = 'cuda'; m = 'cudart64_12.dll' } }

foreach ($p in $picks) {
    $into = Join-Path $Root ('bin\' + $p.d)
    Install-Asset (Get-Asset $p.u) $into $p.m
}

$cf = Join-Path $Root 'bin\tools\cloudflared.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cf) | Out-Null
Move-Item -Force (Get-Asset 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe') $cf

Remove-Item (Join-Path $tmp '*.zip') -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host 'installed backends (serve.ps1 tries cuda -> vulkan -> cpu and switches on its own):'
foreach ($b in @('cuda', 'vulkan', 'cpu')) {
    $e = Join-Path $Root "bin\$b\llama-server.exe"
    if (Test-Path $e) {
        $rt = if (Test-Path (Join-Path $Root 'bin\cuda\cudart64_12.dll')) { '  + CUDA runtime' } else { '' }
        Write-Host ('  {0,-7} {1,7:N0} MB{2}' -f $b, ((Get-ChildItem (Join-Path $Root "bin\$b") | Measure-Object Length -Sum).Sum / 1MB), $rt)
    }
}
Write-Host ''
Write-Host 'Next: copy .gguf models into models\ (see models\README.txt), then double-click launch.vbs'
