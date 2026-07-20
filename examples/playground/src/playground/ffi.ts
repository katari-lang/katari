// The sidecar half of `ffi.ktr` — every handler registers under this file's module path
// (`playground.ffi.*`), exactly the keys the compiler lowers the external agents to.

import { katari, KatariData, type KatariFile } from "@katari-lang/port";

katari.agent<{ name: string }>("greet", ({ name }) => `Hello, ${name}!`);

katari.agent<{ name: string }>("make_greeting", ({ name }, context) =>
  context.file(`Hello, ${name}!`, { contentType: "text/plain" }),
);

katari.agent<{ content: KatariFile }>(
  "byte_length",
  async ({ content }) => (await content.bytes()).length,
);

katari.agent<{ x: number }>("compute", async ({ x }, context) => {
  const doubled = await context.call<number>("playground.ffi.double", { x });
  return doubled + 1;
});

katari.agent<{ text: string }>("parse_port", ({ text }) => {
  const port = Number.parseInt(text, 10);
  if (Number.isNaN(port)) {
    katari.throw(new KatariData("playground.ffi.parse_error", { message: `not a number: ${text}` }));
  }
  return port;
});
