// Ext-agent implementation for 12-ext-cron.
//
// The ext receives a callback (= `notify_scheduled` agent), delegates
// it as a CORE-side child agent, and then blocks forever. In a real
// cron we'd loop, but for the sample one tick is enough — the parent
// handler observes the `scheduled` ask and `break`s the handle scope,
// which terminates this delegation upstream. We wait on the signal so
// the cancellation arrives cleanly.

import type { RawValue } from "@katari-lang/port";
import katari from "@katari-lang/port";

katari.agent("cron_impl", async ({ args, signal }) => {
  const callback = args["callback"];
  await katari.delegate(callback as RawValue, {});
  return new Promise<RawValue>((_resolve, reject) => {
    signal.addEventListener("abort", () =>
      reject(new Error("cron_impl: terminated by handler `break`")),
    );
  });
});
