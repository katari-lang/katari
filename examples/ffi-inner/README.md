# ffi-inner — FFI inner delegation

`main` (in [`src/main.ktr`](src/main.ktr)) calls `external agent compute`, whose FFI implementation
([`src/main.ts`](src/main.ts)) calls the ordinary katari agent `main.double` *back through the runtime*
with `context.call` — an inner delegation over the sidecar protocol — and finishes the computation on
the FFI side. The round trip is katari → sidecar → katari → sidecar:

```
agent double(x: integer) -> integer { x * 2 }        // main.ktr — runs in the runtime
agent main(x: integer) -> integer { compute(x = x) } // main.ktr

katari.agent("compute", async ({ x }, context) => {  // main.ts — runs in the sidecar
  const doubled = await context.call("main.double", { x });
  return doubled + 1;
});
```

`compute(5)` = `double(5) + 1` = `11`, so the result proves both directions ran.

## Run it

Same setup as [`ffi-hello`](../ffi-hello/README.md) (Postgres + runtime server + `KATARI_BUNDLE_BIN`),
then:

```sh
stack exec katari -- apply -C examples/ffi-inner
stack exec katari -- run main.main --arg '{"x":5}' --project ffi_inner
# => 11
```
