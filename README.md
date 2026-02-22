# GitLab Container Manager

A Dockerized GitLab CE instance managed via a cross-platform PowerShell script.
GitLab runs in a single isolated container; all internal state lives inside it —
destroying the container resets GitLab completely.

## Architecture

```
┌──────────────────────────────────────┐
│  Host Machine                        │
│                                      │
│  ┌────────────────────────────────┐  │
│  │  gitlab-tfs-mirror (container) │  │
│  │                                │  │
│  │  GitLab CE  (port 8081)        │  │
│  │  Image: gitlab-gitlab:latest   │  │
│  └────────────────────────────────┘  │
└──────────────────────────────────────┘
```

**Isolation model:**
- No named Docker volumes — container is fully disposable
- No host bind-mounts — all GitLab state lives inside the container

## Prerequisites

- Docker Engine 20.10+ with Docker Compose v2
- Git
- **PowerShell 7+** — pre-installed on Windows; on Linux/macOS:
  ```bash
  snap install powershell   # Linux
  brew install powershell   # macOS
  ```

## Quick Start

### 1. First-time setup

```powershell
./gitlab-tfs.ps1 -Setup
```

Checks prerequisites, creates `.env` from `.env.example`, and builds the image.

### 2. Configure environment

Edit `.env` — at minimum set:

```bash
GITLAB_ROOT_PASSWORD=YourSecurePassword123!
GITLAB_HTTP_PORT=8081        # change if 8081 is already in use
```

### 3. Start

```powershell
./gitlab-tfs.ps1 -Start
```

The script returns immediately. GitLab takes **3–5 minutes** to fully initialize.
Your default browser opens automatically once GitLab is ready.

### 4. Log in

- URL: `http://localhost:8081`
- Username: `root`
- Password: value of `GITLAB_ROOT_PASSWORD` in `.env`

## Management Script

`gitlab-tfs.ps1` works on Windows, macOS, and Linux.
Run with **no arguments** for an interactive menu, or use a named parameter directly:

```powershell
./gitlab-tfs.ps1              # interactive menu

./gitlab-tfs.ps1 -Setup       # check prereqs, create .env, build image
./gitlab-tfs.ps1 -Start       # start container (detached), open browser when ready
./gitlab-tfs.ps1 -Stop        # stop and remove container
./gitlab-tfs.ps1 -Restart     # restart running container
./gitlab-tfs.ps1 -Logs        # stream container logs (Ctrl+C to exit)
./gitlab-tfs.ps1 -Status      # show container state and health
./gitlab-tfs.ps1 -Backup      # save .env to backups/<timestamp>/
./gitlab-tfs.ps1 -Destroy     # remove container + image (prompts for confirmation)
./gitlab-tfs.ps1 -Help        # show usage
```

Tab-completion works for all parameters in PowerShell.

### Interactive menu

```
+==============================+
|   GitLab Container Manager   |
+==============================+

  1) Setup    - First-time build
  2) Start    - Start container
  3) Stop     - Stop container
  4) Restart  - Restart container
  5) Logs     - View container logs
  6) Status   - Show health
  7) Backup   - Backup .env
  8) Destroy  - Remove container
  0) Exit
```

## Environment Variables (`.env`)

| Variable | Default | Description |
|----------|---------|-------------|
| `GITLAB_HTTP_PORT` | `8081` | Host port GitLab is published on |
| `GITLAB_SSH_PORT` | `2222` | Host port for Git-over-SSH |
| `GITLAB_ROOT_PASSWORD` | `ChangeMe123!` | Initial root password |
| `GITLAB_HOSTNAME` | `gitlab.local` | Hostname used in `external_url` |
| `GITLAB_TIMEZONE` | `UTC` | GitLab time zone |

## Backup & Restore

`-Backup` saves only `.env` to `backups/<timestamp>/`.
GitLab's internal data (database, uploaded files, repositories) lives inside the
container. For a full GitLab backup use the built-in tool:

```bash
docker exec gitlab-tfs-mirror gitlab-backup create
```

Backups are written inside the container at `/var/opt/gitlab/backups/`.
Copy them out with `docker cp` before running `-Destroy`.

## Troubleshooting

### Port already in use

```
Bind for 0.0.0.0:8081 failed: port is already allocated
```

Change `GITLAB_HTTP_PORT` in `.env` to a free port, then run `-Start` again.

### GitLab not ready after 5 minutes

```powershell
./gitlab-tfs.ps1 -Logs          # look for errors
```

```bash
docker stats gitlab-tfs-mirror  # check memory — GitLab needs at least 4 GB RAM
```

### Browser doesn't open

The script tries browser binaries directly (`firefox`, `google-chrome`, `chromium`, etc.)
before falling back to `xdg-open`. If none are found, open the URL manually:
`http://localhost:<GITLAB_HTTP_PORT>`.

## Resource Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU      | 2 cores | 4 cores     |
| RAM      | 4 GB    | 8 GB        |
| Disk     | 10 GB   | 50 GB+      |

## Security Notes

- `.env` contains your root password — never commit it to version control
- Container is fully isolated — `-Destroy` removes all internal GitLab state
- Rotate the root password after first login
