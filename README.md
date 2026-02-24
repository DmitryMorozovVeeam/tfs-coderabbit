# GitLab Container Manager

Dockerized **GitLab CE 18.9** managed by a cross-platform PowerShell 7 script.

## Architecture

```
┌──────────────────────────────────┐
│  Host                            │
│  ┌────────────────────────────┐  │
│  │  gitlab-tfs-mirror         │  │
│  │  GitLab CE · port 8081     │  │
│  │  Image: gitlab-gitlab      │  │
│  └─────────────┬──────────────┘  │
│                │ webhooks        │
└────────────────┼─────────────────┘
                 │
                 ▼
        ┌────────────────┐
        │ CodeRabbit.ai  │
        │ (AI PR review) │
        └────────────────┘
```

**Storage:** three named Docker volumes (`gitlab_config`, `gitlab_logs`, `gitlab_data`).
Data survives container restarts; `-Destroy` removes the container and image but **not** volumes.
To wipe everything: `docker compose down -v --rmi local`.

## Prerequisites

- Docker Engine 20.10+ with Compose v2
- Git
- PowerShell 7+ (`snap install powershell` / `brew install powershell`)

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

## CodeRabbit (AI Code Review)

```powershell
./gitlab-tfs.ps1 -CodeRabbit
```

Creates a Personal Access Token and prints setup steps for [app.coderabbit.ai](https://app.coderabbit.ai).
If GitLab is not publicly reachable, expose it first with `ngrok http 8081`.
Copy `.coderabbit.yaml` to each repo root to customise review behaviour.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Port already in use | Change `GITLAB_HTTP_PORT` in `.env` |
| Not ready after 5 min | Check `-Logs`; GitLab needs ≥ 4 GB RAM |
| Browser doesn't open | Open `http://localhost:<port>` manually |

## Requirements

4 GB RAM minimum (8 GB recommended), 2+ CPU cores, 10 GB disk.

## Security

- `.env` holds the root password — **never commit it**
- Rotate the root password after first login
