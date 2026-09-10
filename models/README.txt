PUT YOUR .gguf MODELS IN THIS FOLDER
====================================

serve.ps1 uses the LARGEST model in here that the current laptop can actually hold, and skips
(with a reason in ..\logs\supervisor.log) anything too big for the RAM. So you can carry several
quants of the same model and the stick picks the right one per machine. No renaming, no config.

Download from Hugging Face (or wherever). The "UD" / "GGUF" quantised releases are what you want;
Q4_K_M is the usual balance of size and quality.

Rough fit guide (weights, before the KV cache - leave headroom for the OS and context):

    model size          needs at least            note
    -----------------   ----------------------    -------------------------------------------
    7-9 B   Q4 (~5 GB)  8 GB RAM                  runs anywhere, slow without a GPU
    14 B    Q4 (~9 GB)  16 GB RAM                 comfortable on a 8 GB card
    27-32 B Q4 (~17 GB) 32 GB RAM                 wants 16 GB+ VRAM to be quick
    70 B    Q4 (~40 GB) 64 GB RAM + big GPU       a laptop is the wrong tool

Filesystem: a single .gguf over 4 GB needs exFAT or NTFS, never FAT32 (format_exfat.bat).

Check a download BEFORE you rely on it (needs Python, optional):

    python ..\scripts\gguf-check.py mymodel.gguf

It prints the architecture (with layer count and trained context length), whether a chat template
is present, and whether the file is long enough to hold every tensor - which is how you catch a
"16 GB" file that stopped at 1.4 GB.

Files with mtp / eagle / draft in the name are treated as speculative-decode drafts, not as main
models. Models carrying their own MTP layers do not need one of those at all - set
spec_type=draft-mtp in ..\config\settings.ini and nothing else.

This folder and its contents are gitignored. Do not commit weights: they are gigabytes, and each
model carries its own licence.
