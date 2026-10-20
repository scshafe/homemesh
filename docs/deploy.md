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

## The capture app's sign-in (owner session)

Decision (2026-10-20): the iOS app signs in through Pocket ID and uploads through
the normal door. No route skips the door and the backend has no upload token.
The app does the OIDC authorization-code flow with PKCE as a public client,
and sends `Authorization: Bearer <id token>` on every upload. The door
(oauth2-proxy) accepts a Pocket ID-issued JWT as a bearer token and sets
`X-Forwarded-User` exactly as it does for a browser session, so the backend
sees one kind of caller. The app never reads `Authorization`.

```
app --ASWebAuthenticationSession, PKCE S256--> Pocket ID  (user passkey login)
app <--homemesh-capture://oauth?code=...-------
app --code + verifier--> Pocket ID token endpoint --> id token (JWT)
app --POST /api/... Authorization: Bearer <id token>--> tailscale serve --> oauth2-proxy
oauth2-proxy: verifies signature, issuer, audience, expiry, allowed user --> X-Forwarded-User --> homemesh
```

### Status: done (2026-10-20, door PR #21)

Pocket ID public client `homemesh-capture`, callback `homemesh-capture://oauth`,
refresh tokens on (Pocket ID 2.13). The door accepts only that client's tokens
and sets `X-Forwarded-User`; upstream timeout 600 s; 200 MB bodies pass. One
deviation from the list below: oauth2-proxy 7.15.3 forwards the client's
`Authorization` even with `--pass-authorization-header` off, so the door
overwrites it with `Basic base64(<sub>:none)` (`PASS_BASIC_AUTH=true`). The app
never reads or trusts `Authorization`. Not yet checked: a scan from a real
device (owner check).

### What the owner session changed

Done 2026-10-20 (what was set is in "As set" below the checklist).

In Pocket ID:

1. Create an OIDC client "homemesh capture": **public client** (no secret), PKCE
   on, callback URL `homemesh-capture://oauth` (the app's custom scheme).
   Note its client id (not a secret).
2. Allow only the owner's user group for it, as for the web client.
3. Scopes: `openid profile email`. If this Pocket ID version can issue refresh
   tokens to public clients, enable that (see "Token expiry"); if not, leave
   it, the app falls back to signing in again.

On the door (oauth2-proxy):

4. `--skip-jwt-bearer-tokens=true`.
5. Pin the issuer and the audience: the main `--oidc-issuer-url` stays as is;
   accept the app's tokens with `--extra-jwt-issuers=<pocket-id-issuer-url>=<capture-client-id>`
   (or `--oidc-extra-audiences=<capture-client-id>` if the installed version
   prefers it; check against the deployed oauth2-proxy version). Do not set
   `--insecure-oidc-skip-issuer-verification`. A token for any other issuer or
   client id must get 401.
6. Make sure the same authorization applies to bearer sessions as to browser
   ones (the allowed user, email or group setting), and that the user claim
   that becomes `X-Forwarded-User` is the same one (`--user-id-claim`) so the
   audit identity is identical.
7. Do not forward the `Authorization` header to homemesh (leave
   `--pass-authorization-header` off) and keep stripping client-supplied
   `X-Forwarded-*`.
8. Remove the skip-auth route for the capture paths, if one was added.
9. Body size and timeouts for the USDZ upload (up to 200 MB, see below):
   oauth2-proxy streams request bodies and has no body limit of its own; raise
   `--upstream-timeout` (default 30 s) to at least 600 s; if anything else sits
   between (a Caddy or nginx), allow 200 MB and a 600 s read timeout there.
   `tailscale serve` is a plain TCP/HTTP reverse proxy and sets no body limit;
   check that a 200 MB POST passes end to end (step 11).

Then check (the app is not needed for these; a token from a test client works):

10. No token: 302/401 as before. A token from the wrong client id, wrong issuer
    or expired: 401. A valid token of another Pocket ID user: refused.
11. A valid token with a 200 MB body to
    `POST /api/houses/<house>/captures/<id>/usdz` reaches the backend (a 422
    "not a USDZ" for junk is the success signal); the backend's limits are
    30 MB for the capture JSON and 200 MB for the USDZ.

### As set (2026-10-20)

- Pocket ID client id `homemesh-capture` ("homemesh capture"): public, PKCE,
  callback `homemesh-capture://oauth`, skip consent, allowed to the same group
  as `homemesh`. Pocket ID issues it a refresh token on the code exchange (no
  `offline_access` needed) and refreshes it with `client_id` alone; there is no
  per-client switch. Enter this id in the app's settings.
- The door (`deploy/stack/compose.yaml`), on oauth2-proxy v7.15.3:
  `OAUTH2_PROXY_SKIP_JWT_BEARER_TOKENS=true` and
  `OAUTH2_PROXY_EXTRA_JWT_ISSUERS=${OIDC_ISSUER}=${OIDC_CAPTURE_CLIENT_ID}`
  (the id in the host's `.env`, `stack env-set homemesh OIDC_CAPTURE_CLIENT_ID`).
  The extra-issuer verifier checks signature (the issuer's JWKS), issuer,
  expiry and `aud` = the capture client; the provider's own verifier also
  accepts `aud` = `homemesh`, whose tokens never leave the door. A JWT that
  fails both is no session (`--bearer-token-login-fallback` stays on), so
  `/api/` answers 401. `X-Forwarded-User` is the token's `sub`, the same claim
  a browser session uses. The capture client's access token (also a JWT with
  that audience) passes too. `--oidc-extra-audience` is not used (it would widen
  the browser login's audience too).
- `Authorization`: with `--pass-authorization-header` and
  `--pass-basic-auth` both off, oauth2-proxy forwards the caller's own
  `Authorization` untouched (it strips the header only when it sets it). So
  the door sets it: `--pass-basic-auth=true` with the fixed, non-secret
  password `none` replaces the caller's header with `Basic base64(<sub>:none)`.
  The app never reads it.
- `--upstream-timeout` 600 s. oauth2-proxy, `tailscale serve` and uvicorn set
  no request-body limit; the app's own limits apply.

### Token expiry

- The id token is short-lived (Pocket ID default about one hour). The door
  checks `exp` when a request starts; a transfer that began in time is not cut
  off mid-body.
- The app checks `exp` before every request and refuses to start one with less
  than two minutes left. With a refresh token it refreshes silently; without
  one it re-runs the authorization flow (Pocket ID's browser session usually
  makes this one tap). The JSON and the USDZ are two requests, each checked.
- A 401 from the door during upload is shown as "sign in again", the scan is
  kept on the device until an upload succeeds, and the upload retries after
  sign-in.
- Tokens are stored only in the Keychain; the app stores no password and no
  long-lived upload secret, so there is nothing to revoke except the Pocket ID
  client or the user's session.
