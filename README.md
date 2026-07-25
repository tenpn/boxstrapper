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

1. **`bootstrap.ps1`** (the line above) — enables TLS 1.2, checks for admin, **asks what to do with
   any offsite backup** (see [Restoring from backup](#restoring-from-backup)), installs **Chocolatey**
   and **git** if they're missing, clones this repo, then runs `Update-Box.ps1`.
2. **`packages.config`** — the Chocolatey manifest: the list of packages to install.
3. **`Update-Box.ps1`** — the idempotent setup script. Applies the manifest
   (`choco install packages.config -y`, skipping anything already present) and installs the
   VS Code extensions in **`vs-extensions.txt`**. Re-run it any time to bring the box up to date.
4. **`secrets.ini`** — your secrets (git-ignored). On first run `Update-Box.ps1` creates it from
   **`secrets.example`** and **stops** so you can fill it in; leave a key blank to skip that
   feature, then re-run.

## Day-to-day

- **Add a tool:** add a `<package id="..." />` line to `packages.config`.
- **Add a VS Code extension:** add its id to `vs-extensions.txt`.
- **Change a secret:** edit `secrets.ini` (see `secrets.example` for the keys), then re-run `Update-Box.ps1`.
- **Apply changes on an existing box:**

  ```powershell
  & "$env:USERPROFILE\boxstrapper\Update-Box.ps1"
  ```

## Restoring from backup

Gitea and Jenkins back up to Cloudflare R2 (restic). On a rebuild you choose what to restore. The
default is **not to restore** — a fresh box comes up empty but with backups configured.

`bootstrap.ps1` (the `irm | iex` one-liner can't take flags) **prompts** for the choice. Running
`Update-Box.ps1` directly, pass `-Restore`:

```powershell
& "$env:USERPROFILE\boxstrapper\Update-Box.ps1" -Restore None            # default: set up backups, don't restore
& "$env:USERPROFILE\boxstrapper\Update-Box.ps1" -Restore Latest          # restore the most recent snapshot
& "$env:USERPROFILE\boxstrapper\Update-Box.ps1" -Restore Before -BeforeDate 2026-07-15
& "$env:USERPROFILE\boxstrapper\Update-Box.ps1" -Restore ShowSnapshots   # list snapshot dates, then stop
```

- **`Latest`** restores the most recent snapshot (falls back to "nothing to restore" on an empty repo).
- **`Before`** restores the most recent snapshot strictly before `-BeforeDate` (an ISO `yyyy-MM-dd`,
  local midnight). If a service has snapshots but none before the date, it stops with a clear error
  and changes nothing, so you can re-run with a corrected date.
- **`ShowSnapshots`** prints the available snapshot dates per service and stops — use it to pick a
  `-BeforeDate`.
- Restore only ever runs onto an **empty** box; a box that already has data is never clobbered.
  Passing `-Restore` to `bootstrap.ps1` as a file (e.g. `.\bootstrap.ps1 -Restore Latest`) skips the
  prompt.

## Requirements

- Windows 10/11 with Windows PowerShell 5+ (built in).
- An **elevated** shell — Chocolatey needs administrator rights.
- Internet access.
