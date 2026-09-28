# Keycloak integration

This is Phase 2 of ADR-0006's two-phase auth model. Phase 1 (Traefik
`basicAuth`, `TRAEFIK_BASIC_AUTH_USERS` in `.env`) is what
`scripts/bootstrap-monitoring-vm.sh` sets up by default and is enough to
deploy and validate the whole stack before any of this exists. Do this
once you have a Keycloak realm available (this doc doesn't cover standing
up Keycloak itself — only wiring this stack to an existing realm).

## 1. Create a Keycloak client

In your Keycloak admin console, in the realm you'll use for this stack:

1. Create a confidential OIDC client (e.g. `proxmox-monitoring`) with
   "Client authentication" on and "Standard flow" enabled.
2. Add valid redirect URIs for every service that will authenticate
   directly against Keycloak:
   - `https://grafana.${BASE_DOMAIN}/login/generic_oauth`
   - `https://pdm.${BASE_DOMAIN}/*`, and for each PVE node both
     `https://<pve-node>:8006` and `https://<pve-node>:8006/*` (PVE sends
     the bare origin as its redirect URI — see step 3)
   - `https://<service>.${BASE_DOMAIN}/oauth2/callback` for **each**
     ForwardAuth-protected hostname (`audit`, `prometheus`,
     `alertmanager`, `traefik`). Keycloak only accepts a wildcard at the
     end of a redirect URI, never in the host, so `https://*.${BASE_DOMAIN}/…`
     does not match anything.
3. Note the client ID and client secret — these go into `.env`'s
   `KEYCLOAK_CLIENT_ID` / `KEYCLOAK_CLIENT_SECRET`.
4. Set `KEYCLOAK_ISSUER_URL` in `.env` to
   `https://<keycloak-host>/realms/<realm-name>` — no `/auth/` prefix on
   current Keycloak versions (that path segment was dropped; using it
   produces an "Unexpected error when handling authentication request"
   redirect loop — see `docs/troubleshooting.md`).

## 2. Grafana — native OIDC

Grafana has first-class OIDC support (`auth.generic_oauth`) — no
oauth2-proxy needed for it. Add to the `grafana` service's `environment:`
in `docker-compose.yml` (or a `docker-compose.override.yml` if you'd
rather not edit the tracked file):

```yaml
GF_AUTH_GENERIC_OAUTH_ENABLED: "true"
GF_AUTH_GENERIC_OAUTH_NAME: "Keycloak"
GF_AUTH_GENERIC_OAUTH_CLIENT_ID: "${KEYCLOAK_CLIENT_ID}"
GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET: "${KEYCLOAK_CLIENT_SECRET}"
GF_AUTH_GENERIC_OAUTH_SCOPES: "openid email profile"
GF_AUTH_GENERIC_OAUTH_AUTH_URL: "${KEYCLOAK_ISSUER_URL}/protocol/openid-connect/auth"
GF_AUTH_GENERIC_OAUTH_TOKEN_URL: "${KEYCLOAK_ISSUER_URL}/protocol/openid-connect/token"
GF_AUTH_GENERIC_OAUTH_API_URL: "${KEYCLOAK_ISSUER_URL}/protocol/openid-connect/userinfo"
GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP: "true"
```

Since Grafana handles its own login, remove `basic-auth@file` from its
Traefik router's `middlewares` label (it currently has none —
`security-headers@file` only — so no change needed there; Grafana was
deliberately left off Traefik-level auth from the start since it always
had its own login screen).

## 3. Proxmox VE — native OIDC realm via `pveum`

Run on any PVE node (propagates cluster-wide via `/etc/pve`):

```bash
pveum realm add keycloak \
  --type openid \
  --issuer-url "${KEYCLOAK_ISSUER_URL}" \
  --client-id "${KEYCLOAK_CLIENT_ID}" \
  --client-key "${KEYCLOAK_CLIENT_SECRET}" \
  --username-claim preferred_username \
  --autocreate 1
```

`--autocreate 1` creates PVE user entries automatically on first login —
authentication happens at Keycloak, but PVE's own permission model
(`pveum acl`) still governs what an autocreated user can do, so assign
roles/ACLs to autocreated users (or a group they map into via
`--groups-claim`, PVE 8.4+) before relying on this in production.

## 3b. PDM — native OpenID realm via its API (there is no CLI for it)

PDM supports an `openid` realm, but **`proxmox-datacenter-manager-admin`
has no `realm` command** (checked on PDM 1.x in `tests/lab`: its command
list is `acme`, `remote`, `report`, `support-status`, `versions`). Add the
realm in the web UI (Configuration → Access Control → Authentication
Realms → Add → OpenID Connect) or through the API, which is what the UI
calls. As root on the PDM host:

```bash
jar=$(mktemp)
csrf=$(curl -sk -c "$jar" https://127.0.0.1:8443/api2/json/access/ticket \
  -d username=root@pam --data-urlencode password='<root password>' \
  | jq -r .data.CSRFPreventionToken)
curl -sk -b "$jar" -H "CSRFPreventionToken: $csrf" -X POST \
  https://127.0.0.1:8443/api2/json/config/access/openid \
  -d realm=keycloak --data-urlencode "issuer-url=${KEYCLOAK_ISSUER_URL}" \
  -d client-id="${KEYCLOAK_CLIENT_ID}" -d client-key="${KEYCLOAK_CLIENT_SECRET}" \
  -d username-claim=preferred_username -d autocreate=true
rm -f "$jar"
```

PDM's ticket arrives as an HttpOnly cookie (`__Host-PDMAuthCookie`), not
in the JSON body, hence the cookie jar. `tests/e2e/t3-pdm-oidc.sh` runs
exactly this and then completes a full login (Keycloak form, authorization
code, `POST /access/openid/login`), which returns a ticket for
`<user>@keycloak`. Add `https://pdm.${BASE_DOMAIN}/` to the Keycloak
client's redirect URIs. As with PVE, autocreated users have no privileges
until you grant them ACLs.

## 4. oauth2-proxy — everything else

Services with no native OIDC support — PDM (if step 3b's realm add doesn't
pan out on your PDM version) and cv4pve-diag's static HTML compliance
reports served by `audit-report-server` — are covered by
**oauth2-proxy** as a Traefik `forwardAuth` middleware instead. This is
the gap ADR-0006 calls out
explicitly: without this, those two surfaces would stay on local/basic
auth forever even after Keycloak is otherwise live everywhere else.

1. Fill in `KEYCLOAK_ISSUER_URL`, `KEYCLOAK_CLIENT_ID`,
   `KEYCLOAK_CLIENT_SECRET` in `.env` (shared with steps 2-3 above), and
   generate `OAUTH2_PROXY_COOKIE_SECRET`:

   ```bash
   python3 -c 'import secrets,base64;print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())'
   ```

2. Start the `keycloak` profile:

   ```bash
   docker compose --profile keycloak up -d
   ```

3. In `docker-compose.yml`, swap `basic-auth@file` for
   `oauth2-proxy-auth@file` in the `middlewares` label of each router you
   want migrated (`pdm`, `audit-reports`, `traefik-dashboard`,
   `prometheus`, `alertmanager` — pick per your rollout order, they don't
   need to move all at once). Both middlewares already exist in
   `config/traefik/dynamic/middlewares.yml` — this is a one-line label
   edit per service, no other config changes.
4. `docker compose up -d` to apply the label change, then verify: hitting
   the router's hostname should redirect to Keycloak's login page instead
   of prompting for basic-auth credentials.

## Rollback

Flipping a router's `middlewares` label back to `basic-auth@file` and
`docker compose up -d` reverts that one service to Phase 1 auth
immediately — the htpasswd file from `scripts/generate-secrets.sh` is
still there and unaffected by any of the above.
