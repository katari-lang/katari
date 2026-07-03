// The sidecar half of `e2b.ktr` — run Python in a fresh e2b sandbox per call and hand back
// whatever it printed / evaluated / raised, as one text block for the model.

import { Sandbox } from "@e2b/code-interpreter";
import { katari } from "@katari-lang/port";

katari.agent<{ code: string; api_key: string }>("e2b_exec", async ({ code, api_key }) => {
  const sandbox = await Sandbox.create({ apiKey: api_key });
  try {
    const execution = await sandbox.runCode(code);
    const parts = [
      ...execution.logs.stdout,
      ...(execution.text === undefined ? [] : [execution.text]),
      ...execution.logs.stderr,
    ];
    if (execution.error !== undefined) {
      parts.push(`${execution.error.name}: ${execution.error.value}`);
    }
    const output = parts.join("\n").trim();
    return output === "" ? "(no output)" : output;
  } finally {
    await sandbox.kill();
  }
});
