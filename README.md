# GitLab Container Manager

Dockerized **GitLab CE 18.9** managed by a cross-platform PowerShell 7 script.

## Architecture

```
┌──────────────────────────────────────┐
│  Host                                │
│  ┌────────────────────────────────┐  │
│  │  gitlab-tfs-mirror             │  │
│  │  GitLab CE · port 8081         │  │
│  │  (mirror of TFS/Azure repos)   │  │
│  └───────────────┬────────────────┘  │
│                  │                   │
│  ┌───────────────┴────────────────┐  │
│  │  gitlab-tunnel (cloudflared)   │  │
│  │  outbound tunnel → Cloudflare  │  │
│  └───────────────┬────────────────┘  │
└──────────────────┼───────────────────┘
                   │ https://*.trycloudflare.com
                   ▼
          ┌────────────────┐
          │ CodeRabbit.ai  │
          │ (AI MR review) │
          └────────────────┘
```

**Storage:** three named Docker volumes (`gitlab_config`, `gitlab_logs`, `gitlab_data`).
Data survives container restarts; `-Destroy` removes the container and image but **not** volumes.
To wipe everything: `docker compose down -v --rmi local`.

## Prerequisites

- Docker Engine 20.10+ with Compose v2
- Git
- PowerShell 7+ (`snap install powershell` / `brew install powershell`)
- `curl` (used by health checks and tunnel connectivity tests; pre-installed on macOS and most Linux distros)

## Quick Start

```powershell
./gitlab-tfs.ps1 -Setup        # check prereqs, create .env, build image
# edit .env — set GITLAB_ROOT_PASSWORD at minimum
./gitlab-tfs.ps1 -Start        # start container, auto-opens browser when ready
```

Login: `http://localhost:8081` · user `root` · password from `.env`

## Commands

Run with no arguments for an interactive menu, or pass a flag directly:

| Flag | Description |
|------|-------------|
| `-Setup` | Check prereqs, create `.env`, build image |
| `-Start` | Start container (detached), open browser when ready |
| `-Stop` | Stop and remove container |
| `-Restart` | Restart container |
| `-Logs` | Stream container logs |
| `-Status` | Show container state and health |
| `-Backup` | Save `.env` to `backups/<timestamp>/` |
| `-Export` | Save Docker image to `.tar.gz` |
| `-Import -File <path>` | Load Docker image from `.tar.gz` |
| `-CodeRabbit` | Set up CodeRabbit AI code review |
| `-Tunnel` | Start Cloudflare tunnel & test connectivity |
| `-Destroy` | Remove container + image (confirms first) |
| `-Help` | Show usage |

## Environment Variables (`.env`)

| Variable | Default | Description |
|----------|---------|-------------|
| `GITLAB_HTTP_PORT` | `8081` | Host HTTP port |
| `GITLAB_SSH_PORT` | `2222` | Host SSH port |
| `GITLAB_ROOT_PASSWORD` | `ChangeMe123!` | Initial root password |
| `GITLAB_HOSTNAME` | `gitlab.local` | Hostname in `external_url` |
| `GITLAB_TIMEZONE` | `UTC` | Time zone |

## Backup & Restore

`-Backup` saves `.env` only. For a full GitLab backup:

```bash
docker exec gitlab-tfs-mirror gitlab-backup create
docker cp gitlab-tfs-mirror:/var/opt/gitlab/backups/ ./backups/
```

## Cloudflare Tunnel

The machine running GitLab is not directly accessible from the internet.
A **Cloudflare Tunnel** (`cloudflared`) runs as a sidecar container and creates
an outbound-only connection to Cloudflare's edge, giving you a public
`https://*.trycloudflare.com` URL — no inbound ports, no account needed.

```powershell
./gitlab-tfs.ps1 -Tunnel       # start tunnel, show URL, test connectivity
```

The tunnel service starts on demand (Docker Compose profile `tunnel`) and
does **not** launch with `-Start`. The URL changes on each restart; for a
permanent URL, configure a named Cloudflare Tunnel with a custom domain.

## CodeRabbit (AI Code Review)

```powershell
./gitlab-tfs.ps1 -CodeRabbit   # full setup: tunnel → PAT → browser
```

`-CodeRabbit` is a single end-to-end command that:
1. Verifies GitLab is healthy
2. Starts the Cloudflare tunnel if not already running and retrieves its public URL
3. Tests that the tunnel is reachable from the internet
4. Creates a scoped Personal Access Token (`api`, `read_user`, `read_repository`) via the GitLab Rails console
5. Opens `https://app.coderabbit.ai` and displays the exact values to paste:
   - **GitLab URL** — the `*.trycloudflare.com` tunnel address
   - **Access Token** — the generated PAT

CodeRabbit registers a webhook in GitLab automatically; every new Merge Request then receives an AI code review.

> **Note:** The tunnel URL changes on each restart. For a permanent URL, configure a
> [named Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) with a custom domain.

Copy `.coderabbit.yaml` to each repo root to customise review behaviour.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Port already in use | Change `GITLAB_HTTP_PORT` in `.env` |
| Not ready after 5 min | Check `-Logs`; GitLab needs ≥ 4 GB RAM |
| Browser doesn't open | Open `http://localhost:<port>` manually |
| `-CodeRabbit` / `-Status` reports NOT READY despite container being healthy | GitLab 18.x removed the `/-/readiness` endpoint; ensure you are on the latest script version which uses `curl` for health checks |

## Requirements

4 GB RAM minimum (8 GB recommended), 2+ CPU cores, 10 GB disk.

## Security

- `.env` holds the root password — **never commit it**
- Rotate the root password after first login
