// Ext implementation for blob_echo.ktr.
//
// `makeBlob` produces a value-store blob from text and returns a file ref;
// `readBlob` consumes that ref back to text. Together they exercise the Katari
// Protocol data plane end to end (ctx.makeFile → store → ctx.readString),
// reading the protocol coordinates (URL / token / project / owner) from the env
// the host stamps onto the sidecar.

import katari, { type KatariFile } from "@katari-lang/port";

katari.agent<{ text: string }>("makeBlob", async (ctx) => {
  const bytes = new TextEncoder().encode(ctx.args.text);
  // A `file` ref (matches the ktr `-> file` return), named + typed.
  return await ctx.makeFile(bytes, { name: "blob.txt", contentType: "text/plain" });
});

katari.agent<{ blob: KatariFile }>("readBlob", async (ctx) => {
  return await ctx.readString(ctx.args.blob);
});
