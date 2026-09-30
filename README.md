# Odoo Auto-Installer for Windows 11

PowerShell script that sets up **Odoo 20 (Community)** with Docker Desktop on a Windows 11 computer – including WSL 2, Docker Desktop, PostgreSQL and a ready-to-use configuration.

Current version: **2.1 (2026-09-29)**

## Requirements

| Requirement | Minimum |
| --- | --- |
| Operating system | Windows 11 64-bit, version 23H2 or newer (Home or Pro) |
| Processor | x64 (Intel/AMD) or ARM64 with hardware virtualization enabled |
| Memory | 8 GB recommended |
| Disk space | 30 GB free |
| Permissions | Local administrator rights |

## Quick start

1. Download `install-odoo20.ps1` (open the file → **Download raw file**).
2. Right-click the file → **Properties** → tick **Unblock** at the bottom → OK.
   (Alternatively in PowerShell: `Unblock-File .\install-odoo20.ps1`)
3. Open PowerShell in the download folder and run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install-odoo20.ps1
   ```

4. Confirm the administrator prompt, read the summary and continue with **Y**.
5. At the end `http://localhost:8069` opens. Create the first database there using the master password shown.
   The “Email” field only needs a login name (e.g. `admin`); it does not have to be a real address.

If a reboot is required (WSL), the script continues automatically after the next sign-in.

## What the script does

1. Checks requirements (Windows version, processor, virtualization, disk space, RAM)
2. Enables and updates WSL 2
3. Uses a running Docker engine – or downloads Docker Desktop, **verifies the Docker Inc. signature** and installs it silently
4. Starts Docker and switches to Linux containers if needed
5. Creates `C:\odoo20` with `compose.yaml` and `odoo.conf` (random passwords)
6. Pulls and starts Odoo 20 + PostgreSQL 16

The script is safe to run multiple times; completed steps are skipped and existing files are kept.

## Options

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-OdooVersion` | `20.0` | Image tag, e.g. `19.0` |
| `-Port` | `8069` | Port on this computer |
| `-InstallDir` | `C:\odoo20` | Project folder |
| `-PostgresVersion` | `16` | PostgreSQL version |
| `-WslMemoryGB` | `8` | RAM limit for WSL; `0` = do not create `.wslconfig` |
| `-AllowNetworkAccess` | off | Make Odoo reachable from other devices on the network (not recommended) |
| `-IgnoreOtherEngines` | off | Install Docker Desktop even if Rancher Desktop/Podman is present |
| `-Force` | off | Rewrite `compose.yaml` and `odoo.conf` |
| `-Yes` | off | Skip confirmation prompts |

## Security

- By default Odoo is reachable **from this computer only** (`127.0.0.1`).
- The script runs with administrator rights. Only use it from this repository.
- Database and master passwords are newly generated for each installation and stored in `C:\odoo20\config\odoo.conf`.

## Docker Desktop license

The installation accepts the Docker Desktop license. Docker Desktop is free for personal use, education and businesses with **fewer than 250 employees and less than USD 10 million in annual revenue** – otherwise a paid Docker subscription is required.
Details: https://www.docker.com/legal/docker-subscription-service-agreement/

## After the installation

| Task | Command (in `C:\odoo20`) |
| --- | --- |
| Start | `docker compose up -d` |
| Stop | `docker compose stop` |
| View log | `docker compose logs --tail 20 web` |
| Update to the latest 20.0 build | `docker compose pull` and `docker compose up -d` |
| Show master password | `Get-Content config\odoo.conf` |

After a reboot, Odoo starts automatically together with Docker Desktop (wait about one minute).

## Test status

Version 1 ran successfully on a Lenovo ThinkPad L14 (Windows 11 Pro). Versions 2.0 and 2.1 have been syntax-checked but not yet tested on other machines. Please report bugs and feedback as an issue.

## License

This project is licensed under the [MIT License](LICENSE). You may freely use, modify and share the script as long as the copyright notice is kept. It is provided without any warranty; use at your own risk.

The license covers this script only. Docker Desktop, Odoo and PostgreSQL have their own licenses (see above for Docker Desktop; Odoo Community: LGPL-3.0).
