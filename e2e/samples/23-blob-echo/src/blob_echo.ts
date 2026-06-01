// Ext implementation for blob_echo.ktr.
//
// `makeBlob` produces a value-store blob from text and returns a file ref;
// `readBlob` consumes that ref back to text. Together they exercise the Katari
// Protocol data plane end to end (katari.makeFile → store → katari.readString),
// reading the protocol coordinates (URL / token / project / owner) from the env
// the host stamps onto the sidecar.

import katari, { type KatariFile } from "@katari-lang/port";

katari.agent<{ text: string }>("makeBlob", async ({ args }) => {
  const bytes = new TextEncoder().encode(args.text);
  // A `file` ref (matches the ktr `-> file` return), named + typed.
  return await katari.makeFile(bytes, { name: "blob.txt", contentType: "text/plain" });
});

katari.agent<{ blob: KatariFile }>("readBlob", async ({ args }) => {
  return await katari.readString(args.blob);
});
