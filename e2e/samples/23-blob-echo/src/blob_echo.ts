// Ext implementation for blob_echo.ktr.
//
// `makeBlob` produces a value-store blob from text and returns a file ref;
// `readBlob` consumes that ref back to text. Together they exercise the Katari
// Protocol data plane end to end (katari.value.put → store → katari.value.text),
// reading the protocol coordinates (URL / token / project / owner) from the env
// the host stamps onto the sidecar.

import katari from "@katari-lang/port";

katari.agent("makeBlob", async ({ args }) => {
  const text = args.text as string;
  const bytes = new TextEncoder().encode(text);
  return await katari.value.put(bytes, { contentType: "text/plain" });
});

katari.agent("readBlob", async ({ args }) => {
  return await katari.value.text(args.blob);
});
