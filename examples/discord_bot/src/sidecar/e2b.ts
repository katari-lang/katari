// The e2b tool primitive: run Python in a sandbox and return its output. The
// `run_python` capability agent in discord_bot.e2b wraps this.

import { Sandbox } from "@e2b/code-interpreter";
import katari, { type KatariString } from "@katari-lang/port";

type Secret = { $secret: string };

katari.agent<{ code: KatariString; api_key: Secret }>("e2b_exec", async (ctx) => {
  const code = await ctx.readString(ctx.args.code);
  const apiKey = ctx.args.api_key?.$secret;
  if (typeof apiKey !== "string" || apiKey === "") {
    throw new Error("e2b_exec: missing api key (expected api_key as a secret)");
  }
  const sandbox = await Sandbox.create({ apiKey });
  try {
    const execution = await sandbox.runCode(code);
    const out: string[] = [];
    const stdout = execution.logs.stdout.join("");
    if (stdout !== "") out.push(stdout.trimEnd());
    if (execution.text != null && execution.text !== "") out.push(`=> ${execution.text}`);
    if (execution.error) out.push(`ERROR ${execution.error.name}: ${execution.error.value}`);
    const stderr = execution.logs.stderr.join("");
    if (stderr !== "") out.push(`stderr: ${stderr.trimEnd()}`);
    return out.length > 0 ? out.join("\n") : "(no output)";
  } finally {
    await sandbox.kill();
  }
});
