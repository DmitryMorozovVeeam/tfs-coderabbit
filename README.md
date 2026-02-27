# TFS / Azure DevOps → GitLab Mirror with CodeRabbit AI Review

Mirrors **TFS / Azure DevOps** Git repositories into a self-hosted **GitLab CE 18.9** instance,
exposes it through a **Cloudflare Tunnel**, and feeds **CodeRabbit AI** review comments
back to the originating TFS pull requests — all managed by a cross-platform PowerShell 7 script.

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
│  │  gitlab-tfs-sync               │  │
│  │  git mirror + PR bridge        │  │
│  └───┬───────────────────┬────────┘  │
│      │ git fetch         │ REST API  │
│      ▼                   ▼           │
│  TFS / Azure DevOps Git Repos        │
│                                      │
│  ┌────────────────────────────────┐  │
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
| `-TFSSetup` | Configure TFS/Azure DevOps mirroring |
| `-TFSStatus` | Show TFS sync container status + recent log |
| `-TFSSyncNow` | Restart sync container (triggers immediate sync) |
| `-TFSLogs` | Stream TFS sync container logs |
| `-Help` | Show usage |

## Environment Variables (`.env`)

| Variable | Default | Description |
|----------|---------|-------------|
| `GITLAB_HTTP_PORT` | `8081` | Host HTTP port |
| `GITLAB_SSH_PORT` | `2244` | Host SSH port |
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

## TFS / Azure DevOps Integration

```powershell
./gitlab-tfs.ps1 -TFSSetup    # one-time wizard: configure, build, start
./gitlab-tfs.ps1 -TFSStatus   # show sync health + recent log
./gitlab-tfs.ps1 -TFSSyncNow  # trigger an immediate sync cycle
./gitlab-tfs.ps1 -TFSLogs     # stream live sync logs
```

### What `-TFSSetup` does
1. Prompts for TFS URL, team project name, and a PAT (input is masked)
2. Tests connectivity and lists all available repos in the project
3. Lets you choose which repos to mirror (or mirror all)
4. Creates a dedicated scoped GitLab token for the sync container via the Rails console
5. Saves all settings to `.env`
6. Builds the `sync` Docker image and starts the `gitlab-tfs-sync` container

### How the sync works

The `gitlab-tfs-sync` container runs a continuous loop (default: every 60 s) that:

| Step | What happens |
|------|--------------|
| Git mirror | `git clone --mirror` / `git fetch` from TFS → `git push --mirror` to GitLab, all branches and tags |
| PR bridge | For every active TFS PR without a GitLab MR: creates a mirror MR tagged `tfs-pr` with the TFS PR id embedded in the description |
| Review feedback | For every GitLab MR with new CodeRabbit comments: posts them as thread comments on the originating TFS PR |
| Cleanup | Closes GitLab MRs whose TFS PRs have been completed / abandoned |

### Required TFS PAT scopes

| Scope | Used for |
|-------|----------|
| Code (read) | `git fetch` + REST API to list repos / PRs |
| Pull Request Threads (read + write) | Post CodeRabbit review comments back to TFS |

### Environment variables

All TFS variables are written to `.env` by `-TFSSetup`. They can also be set manually:

| Variable | Description |
|----------|-------------|
| `TFS_URL` | TFS server URL including collection |
| `TFS_PROJECT` | Team project name |
| `TFS_PAT` | TFS / Azure DevOps Personal Access Token |
| `TFS_REPOS` | Comma-separated repo list (empty = all) |
| `GITLAB_TFS_TOKEN` | GitLab PAT for the sync container (created by `-TFSSetup`) |
| `GITLAB_TFS_NAMESPACE` | GitLab group for mirrors (default: `tfs-mirrors`) |
| `TFS_SYNC_INTERVAL` | Seconds between sync cycles (default: `60`) |

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
