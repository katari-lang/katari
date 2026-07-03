import { katari, type KatariFile } from "@katari-lang/port";

// `makeGreeting` (registers as `main.makeGreeting`): produce a file from generated text. `context.file`
// uploads the bytes to the runtime over the blob side channel and returns the `KatariFile`, which — returned
// from the handler — becomes the `file` value the program receives.
katari.agent<{ name: string }>("makeGreeting", ({ name }, context) =>
  context.file(`Hello, ${name}!`, { contentType: "text/plain" }),
);

// `byteLength` (registers as `main.byteLength`): read a received file's bytes back and return their length.
// The argument's `content` arrives as a `KatariFile` — its bytes download over the same side channel on
// demand, so the handler never touches a raw blob reference.
katari.agent<{ content: KatariFile }>(
  "byteLength",
  async ({ content }) => (await content.bytes()).length,
);
