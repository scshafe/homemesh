# Deploying homemesh (M3)

The design is `design.md` section 12; the owner's answers are in its decisions
table (D1, D2, D11). This file is the runbook the owner session needs. Nothing
here contains a hostname, a secret or house data.

## The image

`Dockerfile` builds the front end (node stage) and the backend (python stage)
into one image. It runs as an unprivileged user, serves the API and the static
front end on port 8000, and holds **no data**.

| Setting | Meaning |
|---|---|
| `HOMEMESH_DATA=/data` | The data directory. Mount the stack's `/srv` volume path here (D2). The app refuses to start if it is unset, relative or inside the checkout. |
| `HOMEMESH_AUTH_HEADER=<name>` | The request header the door adds after Pocket ID has authenticated the user. Every `/api` request without it gets 401. The app refuses to start without it (`HOMEMESH_DEV=1` is for local loopback development only). |
| `HOMEMESH_WEB_DIST` | Where the built front end is; set by the image. |

`/api/health` is open (no data) for the stack's health check. Bind the
container port to the door's network only, never to a public interface.

First run: `docker exec <container> python -m homemesh.seed` puts the four
synthetic demo houses into the data directory (it never overwrites). A real
house enters later through the editor/import milestones, never through git.

## What the owner session provisions (needs from the owner)

1. The stack: where it lives in infra, the compose service, the `/srv` path for
   the data volume and its inclusion in the stack-backup timer.
2. The door: the Pocket ID client and door container in front of the app, and
   **the exact identity header name** the door sets (to put in
   `HOMEMESH_AUTH_HEADER`). The door must strip any client-supplied copy of
   that header.
3. The runner lane: registered self-hosted runner on the PC, then
   `dev.toml [deploy]` set to `lane = "runner"` with stack and host. D11 holds:
   deploy only on push to `main`, no self-hosted jobs for pull requests.
4. The deploy workflow, a separate reviewed file. Proposed shape (not active;
   it is added with the lane so `dev check` and the runner agree):

```yaml
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  deploy:
    runs-on: [self-hosted, <runner-label>]
    steps:
      - uses: actions/checkout@<sha>
        with: { persist-credentials: false }
      - run: ./scripts/verify
      - run: docker build -t homemesh:${{ github.sha }} .
      - run: <stack's redeploy command with the new image tag>
```

## Local run (development, synthetic data only)

```sh
export HOMEMESH_DATA=$(mktemp -d) HOMEMESH_DEV=1
.venv/bin/python -m homemesh.seed
.venv/bin/python -m uvicorn --factory homemesh.api:app_factory --port 8000
# front end with hot reload: cd web && npm install && npm run dev
```
