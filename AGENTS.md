# portable-llm-usb-key agent contract

## Operating Standard
- Apply `C:\Users\juanm\Documents\GitHub\Vibe Coding Rules 10.md` (V10) as the repository operating standard; read it in full before substantive work.
- This file is the nearest-owning contract. It refines the parent policy with repository-specific facts and cannot weaken a mandatory parent rule; conflicts resolve to the parent.

## Scope and Ownership
This repo is a USB inference key: scripts and docs only that run llama.cpp and a Cloudflare quick tunnel off a Windows 10/11 laptop with no install, no admin, no account, nothing left on the host. `bin\` and `models\` are gitignored binaries/weights, fetched or copied in per stick.

- Root `*.bat` / `launch.vbs` are the only user entry points: `launch.vbs` (silent start), `run.bat` (visible start), `status.bat` (probes and prints state), `stop.bat` (clean shutdown), `copy_models.bat`, `format_exfat.bat` (guarded reformatter), `autorun.inf`. `get-binaries.ps1` downloads llama.cpp builds into `bin\cpu|vulkan|cuda` and `cloudflared` into `bin\tools\` — default cpu+vulkan+cloudflared (~200 MB), with `-Cuda` / `-Cudart` / `-All` options.
- `config\settings.ini` owns every runtime knob: port, host, tunnel, alias, webui, ngl, ctx_size, batch, ubatch, kvct, flash_attn, threads, model, backend, device, spec_type, keepawake. Runtime state is generated in this same folder: `api.key`, `public_url.txt`, `state.json`, `profile.txt`.
- `scripts\serve.ps1` is the supervisor (`start | stop | status`); `keepawake.ps1` is the sleep veto; `gguf-check.py` verifies a `.gguf` download (truncation, architecture, chat template).
- `models\*.gguf` are user-supplied weights (gitignored; `models\README.txt` is the fit guide). `logs\` and `tmp\` stay on the key only.
- Docs: `QUICKSTART.txt` is the plain-text end-user path; `README.md` is the detailed manual.

## Constraints
- Host hygiene is the product: nothing is written to host temp, registry, or startup (TEMP/TMP redirected to `tmp\`), nothing is installed, no admin. Preserve this in every change.
- Fail-closed exposure: if `settings.ini` is missing or corrupt, the tunnel stays OFF so the port can never be exposed by accident. Never default the tunnel on.
- The public URL is a real internet address: requests without the bearer key get 401, and the key is mandatory. The key must never appear on any process command line (`--api-key-file`).
- Keep-awake blocks system sleep only (`ES_SYSTEM_REQUIRED`, never `ES_DISPLAY_REQUIRED`), is released when the server stops, and never modifies the power plan.
- Model fit is enforced at startup: a model over 92% of physical RAM is skipped rather than OOM-looping; `*mtp*` / `*eagle*` / `*draft*` files count as speculative-decode drafts, not main models; `models\selftest-260K.gguf` is a 1 MB toy model that proves the chain and is safe to delete.
- `config\profile.txt` records what worked, keyed by `COMPUTERNAME` (`backend|level`), so a weak laptop never handicaps a strong one. Delete it after changing models/settings to retry full optimisation.
- Tuning defaults are deliberate: `ngl=99` offloads every layer the GPU can hold and falls back to `ngl=auto` once, remembered in `profile.txt`; `ctx_size=8192` is deliberately conservative; `kvct=q8_0` and `flash_attn=auto` are the long-context prefill settings; `spec_type=none` is the default because speculative decoding needs a model that genuinely carries MTP heads.
- Physical limits are not bugs: a 27 B Q4 needs ~17 GB of weights plus KV cache (~32 GB RAM) and only runs fast when most layers fit in VRAM; preflight deliberately skips models the machine cannot hold rather than swapping it to death.
- Backend failover is cuda → vulkan → cpu. The CUDA build carries SASS only for sm_50/61/70/75/80/90 (no PTX), so RTX 30xx-laptop (sm_86) and RTX 50xx (sm_120) must be served by vulkan; `bin\cuda` also needs `cudart64_12`/`cublas64_12` on the host. A wrong-arch CUDA build sees zero devices and silently runs CPU at ~1/5 speed with no error — `Get-Backends` probes `--list-devices` once per start and skips cuda on `(none)`; `device=` (settings.ini) pins the exact GPU when a host has iGPU+dGPU.
- The tunnel hostname is random and changes whenever cloudflared restarts — never assume the URL is stable; check `status.bat`.
- Filesystem limits: FAT32 cannot hold a model over 4 GB; use NTFS or exFAT. `format_exfat.bat` refuses to run from a network share.
- A second start while already running just reports the existing pid (no port fight); a taken port makes the key refuse rather than serve nothing.
- `bin\`, `models\`, `logs\`, `tmp\` are gitignored; never commit weights (each carries its own licence) or downloaded binaries.

## Verification
There is no automated test harness in this repo (no package.json, pyproject, tests, or Makefile). Use the smallest real checks below; GPU, backend, and tunnel behavior is only verifiable on a physical stick plus a Windows host.

- `python scripts\gguf-check.py models\<file>.gguf` — checks a download before relying on it: prints architecture, chat template, and whether the file is long enough to hold every tensor (the truncated-16-GB file failure mode). Needs Python; script exists at `scripts\gguf-check.py`.
- Manual hardware check is the real acceptance path: run `run.bat` once on a new laptop (the visible window shows what it decided and why), then `status.bat` (prints local + public URL and key, proves the public URL answers via a live `/v1/models` probe through the tunnel), then `stop.bat` (kills what it started, closes the tunnel, releases the sleep veto). Confirm the story in `logs\supervisor.log`.

## Documentation index
- `README.md` — full manual (layout, settings, failover, honest limits)
- `QUICKSTART.txt` — plain-text end-user start-here
- `models\README.txt` — fit guide + download check
- `config\settings.ini` — inline comments per knob

## Known gaps
- No automated tests; the degrade ladder, watchdog, stall guard, and backend failover can only be exercised on a real machine with a GPU.
- After a fresh clone there is no `bin\` (gitignored) — `get-binaries.ps1` must be run and models copied in before anything above can execute.
