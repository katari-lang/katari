// agent def id snapshot encoding. The agent def id is the one identifier that
// loads versioned code on the receiver, so a CORE/FFI agent (qname-form)
// carries the snapshot as `qname@<snapshot>`. The compiled schema / closure /
// request / constructor ids stay bare (no `@`).

import { describe, expect, it } from "vitest";
import type { QualifiedName } from "../src/ir/types.js";
import {
  decodeCoreAgentDefId,
  decodeFfiAgentDefId,
  encodeCoreAgentDefId,
  encodeFfiAgentDefId,
} from "../src/agent-def-id.js";
import type { ClosureId } from "../src/engine/id.js";

const SNAP = "11111111-2222-3333-4444-555555555555";

describe("CoreAgentDefId snapshot", () => {
  it("round-trips a qname with a snapshot as qname@snapshot", () => {
    const wire = encodeCoreAgentDefId({ kind: "qname", value: "main.foo" as QualifiedName, snapshot: SNAP });
    expect(wire).toBe(`main.foo@${SNAP}`);
    expect(decodeCoreAgentDefId(wire)).toEqual({
      kind: "qname",
      value: "main.foo",
      snapshot: SNAP,
    });
  });

  it("a bare qname (compiled schema / get_metadata) has no snapshot", () => {
    const wire = encodeCoreAgentDefId({ kind: "qname", value: "main.foo" as QualifiedName });
    expect(wire).toBe("main.foo");
    expect(decodeCoreAgentDefId(wire)).toEqual({ kind: "qname", value: "main.foo" });
  });

  it("closures never carry a snapshot (snapshot-independent, run in scope)", () => {
    const wire = encodeCoreAgentDefId({ kind: "closure", value: 7 as ClosureId });
    expect(wire).toBe("closure:7");
    expect(decodeCoreAgentDefId(wire)).toEqual({ kind: "closure", value: 7 });
  });

  it("a primitive used as an escalate request stays bare", () => {
    // `primitive.throw` rides an escalate (a request, not a delegate target),
    // so it is never stamped.
    const wire = encodeCoreAgentDefId({ kind: "qname", value: "primitive.throw" as QualifiedName });
    expect(wire).toBe("primitive.throw");
    expect(decodeCoreAgentDefId(wire).kind === "qname" && decodeCoreAgentDefId(wire)).toMatchObject({
      value: "primitive.throw",
    });
  });
});

describe("FfiAgentDefId snapshot", () => {
  it("round-trips qname@snapshot (identical wire to CORE qname)", () => {
    const wire = encodeFfiAgentDefId({ kind: "qname", value: "ext.tool" as QualifiedName, snapshot: SNAP });
    expect(wire).toBe(`ext.tool@${SNAP}`);
    expect(decodeFfiAgentDefId(wire)).toEqual({ kind: "qname", value: "ext.tool", snapshot: SNAP });
    // CORE and FFI qname encodings match, so one stamp path serves both.
    expect(wire).toBe(
      encodeCoreAgentDefId({ kind: "qname", value: "ext.tool" as QualifiedName, snapshot: SNAP }),
    );
  });

  it("a bare ext qname has no snapshot", () => {
    expect(decodeFfiAgentDefId(encodeFfiAgentDefId({ kind: "qname", value: "ext.tool" as QualifiedName }))).toEqual({
      kind: "qname",
      value: "ext.tool",
    });
  });
});
