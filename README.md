# USB Inference Key

Portable GGUF inference (llama.cpp + a public HTTPS tunnel) that runs **from the drive** on
any Windows 10/11 laptop: no install, no admin, no account, nothing left behind on the host.

This repository is the **scripts and documentation only**. `bin\` (760 MB of GPU builds) and
`models\` (gigabytes of weights, each under its own licence) are gitignored: `get-binaries.ps1`
fetches the first, the second is yours to copy. See [Make your own stick](#make-your-own-stick).

## Quick start

Plugging this in for the first time? **`QUICKSTART.txt`** in the root is the plain-text version
of this section - no markdown, readable on any machine, safe to hand to someone else.

| Double-click | What happens |
|---|---|
| **`launch.vbs`** | **Silent.** Server + tunnel + keep-awake start with **no windows at all**. |
| `run.bat` | Same, but in a visible window (shows the URL, and any error, before you walk away). |
| `status.bat` | Is it up? Local URL, **public URL**, API key, live `/v1/models` probe through the tunnel. |
| `stop.bat` | Kills what it started, closes the public URL, releases the sleep veto. |

Endpoint + key (also printed by `status.bat`, stable while running):

```
public   https://<random-words>.trycloudflare.com     <- reachable from anywhere, phone included
api key  config\api.key                               <- 48 chars, generated on first start
```

```bash
curl -X POST https://<your-host>.trycloudflare.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $(cat config/api.key)" \
  -d '{"model":"local","messages":[{"role":"user","content":"Hello"}],"max_tokens":100}'
```

`http://localhost:8080/v1/chat/completions` is the same endpoint on the laptop itself.
Requests without the key get **401** — the tunnel is a public internet address, the key is
not optional. The key never appears in any process command line (`--api-key-file`).

## Models

Drop `.gguf` files in `models/` (key root works too). On start the key picks the **biggest
model this laptop can actually hold** and says so in `logs\supervisor.log`:

```
[pre] skip Qwen3.8-27B-UD-Q4_K_M.gguf (15.33 GB): cannot load 15.33 GB into 15.7 GB RAM.
[pre] use selftest-260K.gguf (0 GB) - host RAM 15.7 GB
```

- A model bigger than **92 % of physical RAM** is skipped instead of OOM-looping all night.
- `*mtp*` / `*eagle*` / `*draft*` files count as speculative-decode drafts, not main models.
- `models/selftest-260K.gguf` (1 MB) is a toy model that proves the chain works on a machine
  too small for the real one. Delete it when you no longer want that fallback.
- Fit guide: 6 GB VRAM + 16 GB RAM → 7–9 B Q4. A 27 B Q4 (~16 GB) wants 32 GB RAM or a 24 GB
  card (a 16 GB card runs it on the edge). Default `ngl=99` offloads every layer the GPU can
  hold (~10× faster than splitting); a host whose GPU cannot fit the model falls back to
  `ngl=auto` (llama.cpp `--fit`) once and remembers it in `config\profile.txt`.
- `models/mtp-INCOMPLETE-Qwen3.8-27B-Q4_0.gguf` is 1.4 GB where a 27 B Q4_0 is ~16 GB — a truncated
  download that cannot be loaded. It is also not needed: this model carries **native MTP layers**
  (`qwen35.nextn_predict_layers`), so speculative decode is `spec_type=draft-mtp` with no second
  file. The script never passes `-md` for `draft-mtp` / `ngram-*` for exactly that reason.
- Check a download before you travel with it: `python scripts\gguf-check.py models\file.gguf` prints
  architecture, chat template and whether the file is long enough to hold every tensor (a truncated
  16 GB file is the one failure that costs you a whole trip). Optional tool, needs Python.

## When things go wrong

All logs stay on the key (`logs\supervisor.log`, `server.log`, `tunnel.log`, `power.log`).
Nothing is written to the host's temp, registry, or startup; `TEMP`/`TMP` are redirected to `tmp\`.

- **Watchdog (10 s):** restarts `llama-server` and the tunnel if either dies. A new
  `trycloudflare.com` hostname is captured and written to `config\public_url.txt` on its own.
- **Stall guard:** if the server stays alive but never serves a request and stops writing to
  `server.log` for ~6 minutes, it is killed and treated as a failed load. Otherwise a wedged load
  would hold the port, the tunnel and the wake veto all night with nothing to show for it.
- **Backend failover:** if the server binary cannot run on this machine at all - it dies without
  writing anything (missing `cudart64_12` / `cublas64_12`, no kernels for the GPU) or the log shows
  a backend/driver error - the key moves to the next backend (`cuda` -> `vulkan` -> `cpu`) instead
  of retrying the same dead binary. A config argument the model rejects is *not* a backend problem,
  so that path escalates optimisation instead of hopping.
- **Degrade ladder:** if the server dies *before ever serving a request*, it retries with less
  optimisation — level 1 drops KV-cache quantisation (`q8_0` KV is invalid for some head
  widths), level 2 also drops speculative decoding. **3 further failures → it gives up and
  shuts down**: a model that cannot load twice will not load at 4 am either. What worked is
  remembered in `config\profile.txt` (as ` COMPUTERNAME|backend|level`) so a restart does not
  repeat doomed attempts and **a weak laptop never handicaps a strong one** — it is keyed by host.
  Delete that file after changing models or settings to try full optimisation again.
- **Tunnel**: Cloudflare quick tunnel (`bin\tools\cloudflared.exe`, no account, works behind
  NAT/CGNAT). The hostname is random and **changes whenever cloudflared restarts** — check
  `status.bat` after a restart, or set up a named tunnel + your own domain for a stable address.
- **Keep-awake:** blocks **system sleep only** (`ES_CONTINUOUS | ES_SYSTEM_REQUIRED`).
  `ES_DISPLAY_REQUIRED` is never set, so **the screen still turns off** on your normal
  power-plan timer (this laptop: 10 min AC / 4 min DC) and wakes back on mouse/keyboard.
  No power-plan setting is modified; the veto is released as soon as the server stops, and is
  re-armed if the watchdog brings the server back. Caveat: closing the **lid** still sleeps the
  PC unless Power Options → lid close = *Do nothing*. Keep it plugged in.
- **Second start** while already running just reports the existing pid (no port fight).
- **Port already taken** by another program → refuses and says so, instead of serving nothing.

## Agentic coding (pi-agent / Aider / Cline / Continue)

Point the client at the public URL with `model: "local"` and the bearer key. Settings that
actually matter for long code contexts, already in `settings.ini`:

- `batch=2048` / `ubatch=512` — prefill throughput sweet spot.
- `kvct=q8_0` — KV-cache quantisation; without it, prefill on ~80 K context falls to ~70 tok/s.
  (If a model rejects it, the watchdog drops it automatically — level 1.)
- `flash_attn=auto` — faster long context; set `off` if you ever see output artifacts.
- Client sampling for code: temp 0.7, top-p 0.8, top-k 20.
- **Speculative decoding is off by default** (`spec_type=none`). It is the single biggest win
  here (~21 vs ~12 tok/s on Qwen3.8-27B-MTP with long context) but needs a model that really
  carries MTP heads: put e.g. `Qwen3.6-27B-MTP-UD-Q4_K_XL.gguf` in `models/` and set
  `spec_type=draft-mtp`. Right now the only MTP file on the key is a truncated download, so
  turning it on would just crash the load — the ladder would switch it back off.

## Make your own stick

Wants: a USB stick of 32 GB or more (exFAT or NTFS - FAT32 cannot hold a model over 4 GB;
`format_exfat.bat` reformats one), any Windows 10/11 laptop, and internet once.

```bat
git clone https://github.com/juanmackie/portable-llm-usb-key D:\usb-key
cd D:\usb-key
powershell -NoProfile -ExecutionPolicy Bypass -File get-binaries.ps1
```

That pulls the **cpu + vulkan** llama.cpp builds and `cloudflared` (~200 MB total) into `bin\`. Add
`-Cuda` for the NVIDIA build, `-Cudart` for the CUDA runtime DLLs (so CUDA works with nothing but
a GPU driver installed), or `-All`. Vulkan is the default because it serves NVIDIA - including
RTX 50-series, which this CUDA build cannot - plus AMD and Intel, with no CUDA install.

Then put `.gguf` files in `models\` ([fit guide and download check](models/README.txt)) and
double-click `launch.vbs`. Nothing is installed on the host, and the same folder plugged into a
different laptop re-detects the GPU, the RAM and which model fits, on its own.

## Layout

```
launch.vbs  run.bat  stop.bat  status.bat     copy_models.bat  format_exfat.bat
bin\cpu | vulkan | cuda      llama-server.exe per backend (b10797)
bin\tools\cloudflared.exe    public tunnel
config\settings.ini          all knobs (port, tunnel, ctx, spec, keepawake, ...)
config\api.key               bearer key clients must send   (generated)
config\public_url.txt        current public URL             (generated)
config\state.json            pids of what is running        (generated)
config\profile.txt             what worked on THIS host: COMPUTERNAME|backend|level (generated)
models\*.gguf                your models
scripts\serve.ps1            supervisor: start | stop | status
scripts\keepawake.ps1        sleep veto, screen-off preserved
logs\  tmp\                  temporary stuff stays on the key
legacy\                      superseded scripts, kept for reference
```

## Notes

- **Filesystem is NTFS** — required for >4 GB model files (exFAT also fine, FAT32 not).
- **USB 2 vs 3**: reading a 16 GB model over USB 2 takes ~10 min, USB 3 ~90 s. For real use run
  the key from a USB3 SSD. `status.bat` showing "loading / down" for the first minutes is normal.
- **Inference needs no internet** — only the tunnel does. Set `tunnel=off` for LAN-only
  (`http://<laptop-ip>:8080`); with `settings.ini` missing the tunnel stays **off** by design,
  so a damaged config can never expose the port by accident.
- **Which GPU path you get**: `bin\cuda` imports `cudart64_12.dll` + `cublas64_12.dll` (so the host
  needs a CUDA 12 runtime installed) and carries SASS **only for sm_50/61/70/75/80/90, no PTX**.
  That means Ampere/Ada/Hopper go CUDA; **RTX 50-series (sm_120) cannot use this CUDA build** and is
  served by `bin\vulkan` automatically — fine, Vulkan is close behind CUDA and needs no CUDA install,
  just a current GPU driver. Pin `backend=vulkan` to skip the first probing attempt.
- **Expected performance**, honest version: a 27 B Q4 model wants ~17 GB for weights plus KV cache,
  so it needs 32 GB system RAM, and it only *runs fast* when most layers fit in VRAM (16 GB+ card,
  or 8 GB + aggressive CPU offload). Big-GPU laptop: thousands of tok/s prefill, tens of tok/s
  generation. 6 GB card + 16 GB RAM: the preflight skips the model by design rather than swapping
  the machine to death — put a smaller quant (`Q3`/`IQ4_XS` of the same model, or a 7–14 B model)
  in `models\` for that class of laptop. That is physics, not the script.
- **`ctx_size=8192` is deliberately conservative.** On 32 GB RAM + a 12 GB+ card, `32768` is
  comfortable for agentic work, and that is exactly where `kvct=q8_0` starts to matter a lot.
- **Honest limits of "no trace"**: nothing is installed and no host file/registry/startup entry
  is written, but Windows itself still records the device (USBSTOR), Prefetch, and AV/proxy
  visibility — and a public tunnel on a machine you do not own can violate employer policy.
  Run this on hardware you control.
