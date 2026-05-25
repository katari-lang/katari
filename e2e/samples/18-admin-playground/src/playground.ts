// Sidecar for the admin playground sample.
//
// Provides host-side primitives that make the admin's tree view actually
// interesting to watch:
//
//   - `sleep_ms`: a plain delay. Each call shows up as one ext-call node
//     in the run tree for the duration of `ms`, then disappears on
//     `ipcDelegateAck`. Chain a few of these together and you can see
//     the tree mutate as you poll.
//   - `fan_out`: takes a callback (= a Katari agent value) and spawns it
//     `count` times concurrently from the ext side via
//     `katari.delegate(...)`. The tree view shows the ext call PLUS all
//     N CORE-side children in flight simultaneously — that's the
//     visualization payoff (sequential calls only ever show one node).

import katari from "@katari-lang/port";
import type { RawValue } from "@katari-lang/port";

katari.agent("sleep_ms", async ({ args, signal }) => {
  const ms = args["ms"] as number;
  // Respect cancellation so a run-cancel actually unblocks the ext
  // promptly (= without it the promise would resolve only after `ms`
  // elapsed even though the delegation is already cancelled).
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => resolve(), ms);
    signal.addEventListener("abort", () => {
      clearTimeout(timer);
      reject(new Error("sleep_ms: cancelled"));
    });
  });
  return null;
});

katari.agent("fan_out", async ({ args, signal }) => {
  const callbackRaw = args["callback"];
  // The wire shape for a Katari callable arg is `{$agent: "qname"}`
  // (= per value-codec.ts). `katari.delegate` expects the bare qname
  // string, so unwrap here before forwarding.
  const callable =
    typeof callbackRaw === "string"
      ? callbackRaw
      : isCallableEnvelope(callbackRaw)
        ? callbackRaw.$agent
        : null;
  if (callable === null) {
    throw new Error(
      `fan_out: callback must be a callable, got ${JSON.stringify(callbackRaw)}`,
    );
  }
  const count = args["count"] as number;
  // Spawn `count` independent child delegations on the CORE side and
  // wait for all of them. Each child is a real delegation so the tree
  // view fans out into N siblings under this ext call. If the run is
  // cancelled, signal aborts and Promise.race short-circuits → the
  // child terminates propagate naturally via katari.delegate's signal.
  const childSignal = signal;
  const children = Array.from({ length: count }, () =>
    katari.delegate(callable as RawValue, {}, { signal: childSignal }),
  );
  const results = await Promise.all(children);
  return results.length;
});

function isCallableEnvelope(
  v: RawValue,
): v is { $agent: string } {
  return (
    typeof v === "object" &&
    v !== null &&
    !Array.isArray(v) &&
    typeof (v as Record<string, unknown>).$agent === "string"
  );
}
