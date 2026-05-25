// Ext-agent that unconditionally throws to exercise the
// ipcDelegateError → primitive.throw escalate path.

import katari from "@katari-lang/port";

katari.agent("boomExt", async () => {
  throw new Error("kaboom from JS");
});
