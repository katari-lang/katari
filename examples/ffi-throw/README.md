# ffi-throw — typed errors across the FFI boundary

`main` (in [`src/main.ktr`](src/main.ktr)) calls `external agent parse_port`, whose FFI implementation
([`src/main.ts`](src/main.ts)) fails a malformed input with `katari.throw` — a typed
`prelude.throw[parse_error]`, declared on the external agent like any other effect. `main` catches it
with an ordinary throw handler and falls back to the default port:

```
data parse_error(message: string)                                              // main.ktr
external agent parse_port(text: string) -> integer with prelude.throw[parse_error]
agent main(text: string) -> integer {
  use handler { request prelude.throw(error: parse_error) -> never { break 8080 } }
  parse_port(text = text)
}

katari.agent("parse_port", ({ text }) => {                                     // main.ts — the sidecar
  const port = Number.parseInt(text, 10);
  if (Number.isNaN(port)) {
    katari.throw(new KatariData("main.parse_error", { message: `not a number: ${text}` }));
  }
  return port;
});
```

A well-formed input parses; a malformed one takes the typed error path — sidecar → runtime → the katari
handler — and lands on the fallback. Any other JS error in the sidecar stays a panic (an infrastructure
failure, which the throw handler must not catch).

## Run it

Same setup as [`ffi-hello`](../ffi-hello/README.md) (Postgres + runtime server + `KATARI_BUNDLE_BIN`),
then:

```sh
stack exec katari -- apply -C examples/ffi-throw
stack exec katari -- run main.main --arg '{"text":"3000"}' --project ffi_throw
# => 3000
stack exec katari -- run main.main --arg '{"text":"oops"}' --project ffi_throw
# => 8080 (the typed throw was caught)
```
