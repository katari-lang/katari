# 17-secret-mock-ai

End-to-end demonstration of the **secret type** + **EnvModule** +
**user-provided `http_request` sidecar** pattern. The sample is what
a real "call an AI provider with my API key" Katari program looks
like, minus the actual HTTP socket.

## What it covers

* `get_secret_env(key) -> secret with env_not_found` — read an API
  key from the host's env store. The returned value's type is
  `secret`, which is disjoint from `string` at the type level so it
  can't accidentally flow into `print`, `to_string`, or any
  HTTP-wire surface that expects plain strings.
* `request env_not_found` handle — recover locally from a missing key
  without escalating into the snapshot-error path.
* User-declared `ext agent http_request(url, auth: secret) -> string`
  — the sample's own sidecar agent. `http_request` is intentionally
  **not** part of the stdlib (it would force a sidecar implementation
  on every snapshot, even ones that don't need network access); each
  project that wants HTTP wires its own.
* The `secret` argument crosses the sidecar IPC boundary as the
  trust-boundary-only wire form `{ "$secret": "<plaintext>" }`. The
  sidecar — which is your code, inside your trust boundary — is the
  one party that consumes the cleartext (e.g. as a `Bearer ...`
  header).

## How to run

```sh
export KATARI_SECRET_KEY=$(openssl rand -hex 32)
docker compose up postgres
pnpm --filter katari-api-server dev &

# Set the env key (encrypted at rest because isSecret = true).
curl -X PUT localhost:8000/env \
  -H "X-API-Key: $KATARI_API_KEY" \
  -H "content-type: application/json" \
  -d '{"key":"MOCK_KEY","value":"sk-live-XXXXXXXX","isSecret":true}'

# Apply and run.
cd e2e/samples/17-secret-mock-ai
katari apply --api-url http://localhost:8000
katari run secret_mock_ai.main --api-url http://localhost:8000 --args '{}' --wait
```

The CLI prints the sidecar's echoed body, e.g.
`"GET https://example.com/echo (auth=sk-live-XXXXXXXX)"`. To prove
the redaction surface: `curl localhost:8000/env` will now return
`{"entries":[{"key":"MOCK_KEY","value":"<redacted>","isSecret":true,...}]}`
— the plaintext is never exposed back over HTTP.

## Files

* `src/secret_mock_ai.ktr` — the Katari program. Two `agent`
  declarations: `http_request` (ext) and `main`.
* `src/secret_mock_ai.ts` — the sidecar implementation of
  `http_request`. The mock just echoes URL + auth back as a string so
  the e2e test can assert the secret crossed the boundary intact.
* `katari.toml` — package manifest (`name = "secret_mock_ai"`).
