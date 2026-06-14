# boxstrapper

Take a fresh Windows machine to a configured dev box with one command.

## Quick start

Open an **elevated** PowerShell (Start menu → PowerShell → _Run as administrator_) and run:

```powershell
irm https://raw.githubusercontent.com/tenpn/boxstrapper/wildblue/bootstrap.ps1 | iex
```

> Use `irm` (Invoke-RestMethod) — it returns the script body, which is what `| iex`
> needs. `iwr` returns a response object and would need `(iwr ...).Content | iex`.

That's it. The bootstrap is safe to re-run.

## What it does

1. **`bootstrap.ps1`** (the line above) — enables TLS 1.2, checks for admin, installs
   **Chocolatey** and **git** if they're missing, clones this repo, then runs `Update-Box.ps1`.
2. **`packages.config`** — the Chocolatey manifest: the list of packages to install.
3. **`Update-Box.ps1`** — the idempotent setup script. Applies the manifest
   (`choco install packages.config -y`, skipping anything already present) and installs the
   VS Code extensions in **`vs-extensions.txt`**. Re-run it any time to bring the box up to date.

## Day-to-day

- **Add a tool:** add a `<package id="..." />` line to `packages.config`.
- **Add a VS Code extension:** add its id to `vs-extensions.txt`.
- **Apply changes on an existing box:**

  ```powershell
  & "$env:USERPROFILE\boxstrapper\Update-Box.ps1"
  ```

## Requirements

- Windows 10/11 with Windows PowerShell 5+ (built in).
- An **elevated** shell — Chocolatey needs administrator rights.
- Internet access.
