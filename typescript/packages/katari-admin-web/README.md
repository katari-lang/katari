# @katari-lang/admin-web

Web admin UI for the Katari runtime: manage projects, snapshots, agents,
escalations, and the env / secret store.

Built with Vite + React 19 + Tailwind v4. Reuses the `paper` / `katari` /
`highlight` color palette from [katari-web](../../../../katari-web) so the
admin tool feels like it's the same product.

## Quick start

### Dev mode (Vite, hot reload)

```sh
# In one terminal: katari-api-server on :8000 (with KATARI_API_KEY set)
pnpm --filter @katari-lang/api-server dev

# In another: vite dev server with /api proxied to :8000
pnpm --filter @katari-lang/admin-web dev
# → http://localhost:5173
```

To point dev at a remote API:

```sh
KATARI_API_URL=https://your-katari.example.com pnpm --filter @katari-lang/admin-web dev
```

### Production (served by api-server)

```sh
pnpm --filter @katari-lang/admin-web build
export KATARI_ADMIN_WEB_DIST=$PWD/typescript/packages/katari-admin-web/dist
pnpm --filter @katari-lang/api-server dev
# → http://localhost:8000/admin/
```

When `KATARI_ADMIN_WEB_DIST` is unset, the api-server boots without the
UI (= JSON-only mode).

## Auth model

The SPA is served as static assets (no auth needed for HTML / CSS / JS).
On first load it bounces to `/admin/login` where the operator enters:

- **Base URL** of the api-server (default = current origin)
- **API key** matching `KATARI_API_KEY` on the server

Both are stored in this browser's `localStorage` and added to every
subsequent JSON request as `Authorization: Bearer <key>`.

## Secret display

The api-server's wire layer replaces every `secret` Value with the
placeholder `<redacted:hash8>` before the response leaves the server.
That means the admin UI can safely render agent args / results / wire
payloads — secrets are physically not present in the data the browser
receives. The viewer highlights the placeholder in the danger color so
operators can see "this field WAS sensitive."

When uploading new secrets (via the Env page), plaintext flows from the
browser → api-server in the PUT body. Use HTTPS in production.

## Component layout

```
src/
  components/
    shell/        # AppShell, Sidebar, TopBar, Logo, UserMenu
    ui/           # Button, Input, Card, Dialog, Table, ... (primitives)
    domain/       # AgentTable, EnvUpsertDialog, ValueViewer, ... (feature)
    schema-form/  # JSON Schema → React form (used by Agents invoke)
  pages/          # Route entry points
  api/            # Typed fetch client
  contexts/       # ApiKey context
  lib/            # cn, format, useCurrentProjectId
  styles/         # globals.css (Tailwind + @theme tokens)
```
