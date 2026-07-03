import { katari } from "@katari-lang/port";

// The FFI implementation of `external agent compute` (declared in main.ktr). It delegates back into the
// runtime — `context.call` runs the core agent `main.double` as an inner delegation over the sidecar
// protocol — and adds one on the FFI side, so the result proves both directions ran: compute(5) =
// double(5) + 1 = 11.
katari.agent<{ x: number }>("compute", async ({ x }, context) => {
  const doubled = await context.call<number>("main.double", { x });
  return doubled + 1;
});
