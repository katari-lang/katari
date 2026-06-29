# ffi-blob — an FFI blob (file) end-to-end example

Two FFI handlers in [`src/main.ts`](src/main.ts) move a blob's **bytes** over the runtime's HTTP side channel
(out of band from the one-shot stdio reply that carries only the handler's JSON result):

- **`makeGreeting`** _produces_ a file: it generates bytes and `context.uploadBlob`s them, returning a `file`
  handle. The blob is owned by the FFI call; on the call's return it ascends to the calling agent.
- **`byteLength`** _consumes_ a file: it `context.downloadBlob`s the received file's bytes and returns the
  length.

```
external agent makeGreeting(name: string) -> file        // uploads bytes, returns a file
external agent byteLength(content: file) -> integer       // downloads bytes, returns the length

agent main(name: string) -> integer {                     // main.ktr
  let greeting = makeGreeting(name = name)
  byteLength(content = greeting)
}
```

`main` returns the byte length and **never returns the file**, so the blob's bytes are reclaimed (freed from
the blob store) when `main`'s instance tears down — the producer that makes the symmetric blob ascent and the
post-commit byte reclaim fire end to end.

## Run it

From the repo root (same shape as [`ffi-hello`](../ffi-hello/README.md), plus optional MinIO to watch the
bytes get reclaimed):

```sh
# 1. Postgres (the runtime auto-migrates on boot).
docker run -d --name katari-pg \
  -e POSTGRES_USER=katari -e POSTGRES_PASSWORD=katari -e POSTGRES_DB=katari \
  -p 5432:5432 postgres:16

# 2. (Optional) MinIO, to observe the blob bytes — set BLOB_S3_* so the runtime uses S3 instead of the
#    in-memory dev store. Without this the bytes still upload / download / reclaim, just in-process.
docker run -d --name katari-minio -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER=minio -e MINIO_ROOT_PASSWORD=minio12345 \
  minio/minio server /data --console-address ":9001"
# create the bucket once (via the MinIO console at :9001, or mc), e.g. `katari-blobs`, then:
export BLOB_S3_BUCKET=katari-blobs BLOB_S3_ENDPOINT=http://localhost:9000 \
       BLOB_S3_FORCE_PATH_STYLE=true AWS_ACCESS_KEY_ID=minio AWS_SECRET_ACCESS_KEY=minio12345

# 3. Build the bundler CLI and start the runtime server (listens on :3000).
pnpm --filter @katari-lang/bundle build
pnpm --filter @katari-lang/runtime exec tsx src/bin.ts &

# 4. Deploy and run. The agent's qualified name is <module>.<agent> = main.main.
export KATARI_BUNDLE_BIN="$PWD/typescript/bundle/dist/cli.mjs"
export KATARI_API_URL="http://localhost:3000"
stack exec katari -- apply --project examples/ffi-blob
stack exec katari -- run main.main --arg '{"name":"world"}' --project examples/ffi-blob
# => Result: 13            ("Hello, world!" is 13 bytes)

# 5. Tear down.
docker rm -f katari-pg katari-minio
```

With MinIO configured, the greeting object appears under the bucket during the run and is **gone after it
completes** — the post-commit byte reclaim freeing the bytes once `main` (which never returned the file) tears
down.
