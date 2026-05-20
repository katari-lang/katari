// Ext-agent implementation for src/main.ktr.
//
// Bundled by `katari apply` (esbuild + katari-port). Registers
// `extGreet`, which the ktr `agent main()` calls.

import katari from "@katari-lang/port";

katari.agent("extGreet", async ({ args }) => {
  const name = args["name"] as string;
  return `hello, ${name}`;
});
