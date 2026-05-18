// Ext-agent that unconditionally throws to exercise the
// ipcDelegateError → prim.throw escalate path.

import katari from "katari-port";

katari.agent("boomExt", async () => {
  throw new Error("kaboom from JS");
});
