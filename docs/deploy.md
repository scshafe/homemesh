# Deploying homemesh

Live since M3: `https://homemesh.<tailnet>/`, behind the Pocket ID door. The
design is `design.md` section 12; the owner's answers are in its decisions
table (D1, D2, D11). Nothing here contains a hostname, a secret or house data.

## How a change reaches production

Every merge to `main` deploys (`dev.toml [deploy]`, lane `runner`):

1. `.github/workflows/deploy.yml` runs `./scripts/verify` on a GitHub-hosted
   runner.
2. The deploy job runs on the self-hosted runner `pc-homemesh-prod` (label
   `homemesh-prod`) and calls the host entrypoint, which fetches `main`, checks
   the commit's ancestry against what is live, backs up, builds the image from
   `Dockerfile` and starts the stack from `deploy/stack/`.
3. A read-only health check probes `/api/health` through the door.

Watch it: `gh run list -w deploy`, `gh run watch <id>`. The full log stays on
the host; a public repository's job shows stage lines and the result. Roll
back by merging a `git revert`, or `gh workflow run deploy.yml -f sha=<sha>
-f allow_rollback=true`. No self-hosted job runs for pull requests (D11).

## The stack (`deploy/stack/`, owned by the owner session)

| Part | What it is |
|---|---|
| `homemesh` container | This repository's image. Stateless; unprivileged user; port 8000 on the stack network only. |
| Door | oauth2-proxy with Pocket ID in front, plus the tailnet node (sidecar). Authenticates the owner and sets `X-Forwarded-User`; strips client-supplied `X-Forwarded-*`. |
| Data | `/data` in the container = `/srv/stacks/homemesh/state/data` on the host, owned by the app's uid, covered by `stack-backup@homemesh`. |

## What the app enforces (defence in depth)

| Setting | Meaning |
|---|---|
| `HOMEMESH_DATA=/data` | The data directory. The app refuses to start if it is unset, relative or inside the checkout. |
| `HOMEMESH_AUTH_HEADER=X-Forwarded-User` | Every `/api` call without it gets 401. The app refuses to start without it (`HOMEMESH_DEV=1` is for local loopback development only). |
| `HOMEMESH_DOOR_ADDR` | Comma-separated peer addresses allowed to call `/api`; default `10.253.93.10`, the door on the stack network. Any other peer gets 403 before the header is read, so a forged header from another container or host is useless. |
| `HOMEMESH_WEB_DIST` | Where the built front end is; set by the image. |

`/api/health` carries no house data and answers any peer (the container's own
health check calls it on loopback).

## Data on the live site

The synthetic demo houses are not seeded automatically. For a first look,
`docker exec` is not available to the agent: the owner session can run
`python -m homemesh.seed` in the container. Real houses are created and edited
in the app (New, Plan editor, blueprint upload) and live only under `/data`.

## Local run (development, synthetic data only)

```sh
export HOMEMESH_DATA=$(mktemp -d) HOMEMESH_DEV=1
.venv/bin/python -m homemesh.seed
.venv/bin/python -m uvicorn --factory homemesh.api:app_factory --port 8000
# front end with hot reload: cd web && npm install && npm run dev
```

## The capture app's upload path (owner session)

The iOS app (`ios/`) uploads scans with a bearer token instead of the door's
browser login. The backend accepts the token for `POST /api/houses/<id>/captures`
and `POST /api/houses/<id>/captures/<id>/usdz` only (and still only from the
door's address). For the app to get there, the door must pass requests to those
two paths without the OIDC login (a skip-auth route like `/api/health`), and the
reverse proxy must allow bodies up to about 200 MB. Tokens: `python -m
homemesh.tokens create|revoke|list` inside the container (stored hashed in
`/data/tokens.json`).
