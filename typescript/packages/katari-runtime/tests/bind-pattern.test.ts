import { describe, expect, it } from "vitest";
import {
  applyEvent,
  createMachine,
  type MachineEvent,
  type Value,
} from "../src/index.js";
import type {
  Block,
  CtorId,
  IRMetadata,
  IRModule,
  MatchPattern,
  VarId,
} from "../src/ir/types.js";
import type { DelegationId } from "../src/machine/id.js";
import { tryMatch } from "../src/machine/pattern.js";

// ─── helpers ────────────────────────────────────────────────────────────────

function metadata(): IRMetadata {
  return { schemaVersion: 1 };
}

function makeIR(
  blocks: Record<number, Block>,
  entryName: string,
  entryBlockId: number,
): IRModule {
  return {
    metadata: metadata(),
    name: "test",
    blocks: Object.fromEntries(
      Object.entries(blocks).map(([k, v]) => [k, v]),
    ),
    entries: { [entryName]: entryBlockId },
    nameTable: { varNames: {}, blockNames: {} },
  };
}

function delegate(
  qualifiedName: string,
  args: Record<string, Value> = {},
): MachineEvent {
  return {
    from: "API",
    to: "CORE",
    kind: "delegate",
    qualifiedName,
    args,
    delegationId: ("d-" + Math.random().toString(36).slice(2)) as DelegationId,
  };
}

function lastDelegateAck(events: MachineEvent[]): Value {
  const ack = [...events].reverse().find((e) => e.kind === "delegateAck");
  if (!ack || ack.kind !== "delegateAck") {
    throw new Error("no delegateAck found");
  }
  return ack.value;
}

// ─── tryMatch direct tests ──────────────────────────────────────────────────
//
// These exercise the pattern module without spinning up a machine. They cover
// the unit-level invariants — full IR-level prelude execution is tested in the
// "via UserThread" suite below.

describe("tryMatch (pattern module)", () => {
  it("matchPatternAny binds nothing and matches everything", () => {
    const pat: MatchPattern = { kind: "matchPatternAny" };
    const r = tryMatch(pat, { kind: "string", value: "x" });
    expect(r).not.toBeNull();
    expect(r!.size).toBe(0);
  });

  it("matchPatternVariable binds the value", () => {
    const pat: MatchPattern = {
      kind: "matchPatternVariable",
      contents: 7 as VarId,
    };
    const r = tryMatch(pat, { kind: "number", value: 42 });
    expect(r).not.toBeNull();
    expect(r!.get(7 as VarId)).toEqual({ kind: "number", value: 42 });
  });

  it("matchPatternTuple destructures by index", () => {
    const pat: MatchPattern = {
      kind: "matchPatternTuple",
      contents: [
        { kind: "matchPatternVariable", contents: 1 as VarId },
        { kind: "matchPatternVariable", contents: 2 as VarId },
      ],
    };
    const value: Value = {
      kind: "tuple",
      elements: [
        { kind: "number", value: 10 },
        { kind: "string", value: "x" },
      ],
    };
    const r = tryMatch(pat, value);
    expect(r).not.toBeNull();
    expect(r!.get(1 as VarId)).toEqual({ kind: "number", value: 10 });
    expect(r!.get(2 as VarId)).toEqual({ kind: "string", value: "x" });
  });

  it("matchPatternTuple returns null on length mismatch", () => {
    const pat: MatchPattern = {
      kind: "matchPatternTuple",
      contents: [
        { kind: "matchPatternVariable", contents: 1 as VarId },
        { kind: "matchPatternVariable", contents: 2 as VarId },
      ],
    };
    const value: Value = {
      kind: "tuple",
      elements: [{ kind: "number", value: 1 }],
    };
    expect(tryMatch(pat, value)).toBeNull();
  });

  it("matchPatternConstructor matches ctorId + field patterns", () => {
    const pat: MatchPattern = {
      kind: "matchPatternConstructor",
      contents: [
        9 as CtorId,
        [
          ["fst", { kind: "matchPatternVariable", contents: 1 as VarId }],
          ["snd", { kind: "matchPatternVariable", contents: 2 as VarId }],
        ],
      ],
    };
    const value: Value = {
      kind: "tagged",
      ctorId: 9 as CtorId,
      fields: {
        fst: { kind: "number", value: 11 },
        snd: { kind: "number", value: 22 },
      },
    };
    const r = tryMatch(pat, value);
    expect(r).not.toBeNull();
    expect(r!.get(1 as VarId)).toEqual({ kind: "number", value: 11 });
    expect(r!.get(2 as VarId)).toEqual({ kind: "number", value: 22 });
  });

  it("matchPatternConstructor rejects different ctorId", () => {
    const pat: MatchPattern = {
      kind: "matchPatternConstructor",
      contents: [9 as CtorId, []],
    };
    expect(
      tryMatch(pat, { kind: "tagged", ctorId: 10 as CtorId, fields: {} }),
    ).toBeNull();
  });

  it("nested constructor + tuple destructure flattens into one bindings map", () => {
    // pattern: Pair { fst = (a, b), snd = c }
    const pat: MatchPattern = {
      kind: "matchPatternConstructor",
      contents: [
        1 as CtorId,
        [
          [
            "fst",
            {
              kind: "matchPatternTuple",
              contents: [
                { kind: "matchPatternVariable", contents: 1 as VarId },
                { kind: "matchPatternVariable", contents: 2 as VarId },
              ],
            },
          ],
          ["snd", { kind: "matchPatternVariable", contents: 3 as VarId }],
        ],
      ],
    };
    const value: Value = {
      kind: "tagged",
      ctorId: 1 as CtorId,
      fields: {
        fst: {
          kind: "tuple",
          elements: [
            { kind: "number", value: 1 },
            { kind: "number", value: 2 },
          ],
        },
        snd: { kind: "string", value: "z" },
      },
    };
    const r = tryMatch(pat, value);
    expect(r).not.toBeNull();
    expect(r!.size).toBe(3);
    expect(r!.get(1 as VarId)).toEqual({ kind: "number", value: 1 });
    expect(r!.get(2 as VarId)).toEqual({ kind: "number", value: 2 });
    expect(r!.get(3 as VarId)).toEqual({ kind: "string", value: "z" });
  });

  it("linear-pattern violation (same VarId twice) throws", () => {
    // pattern: (x, x) — VarId 1 bound twice
    const pat: MatchPattern = {
      kind: "matchPatternTuple",
      contents: [
        { kind: "matchPatternVariable", contents: 1 as VarId },
        { kind: "matchPatternVariable", contents: 1 as VarId },
      ],
    };
    const value: Value = {
      kind: "tuple",
      elements: [
        { kind: "number", value: 1 },
        { kind: "number", value: 2 },
      ],
    };
    expect(() => tryMatch(pat, value)).toThrowError(/VarId 1 bound more than once/);
  });

  it("literal pattern matches by value", () => {
    const pat: MatchPattern = {
      kind: "matchPatternLiteral",
      contents: { kind: "literalValueInteger", integer: 5 },
    };
    expect(tryMatch(pat, { kind: "number", value: 5 })).not.toBeNull();
    expect(tryMatch(pat, { kind: "number", value: 6 })).toBeNull();
  });
});

// ─── statementBindPattern via UserThread ────────────────────────────────────
//
// These build a minimal IR that uses StatementBindPattern after a literal load
// to destructure the value into local bindings. The agent then returns one of
// the destructured locals to verify the binding succeeded.

describe("statementBindPattern (UserThread)", () => {
  it("variable pattern is a no-op alias", () => {
    // agent main() -> string {
    //   var0 = "hi"
    //   bindPattern source=var0 pattern=Variable(var1)
    //   exit return var1
    // }
    const blocks: Record<number, Block> = {
      0: {
        kind: "blockUser",
        body: {
          kind: "blockKindAgent",
          parameters: [],
          statements: [
            {
              kind: "statementLoadLiteral",
              contents: {
                output: 0 as VarId,
                value: { kind: "literalValueString", string: "hi" },
              },
            },
            {
              kind: "statementBindPattern",
              contents: {
                source: 0 as VarId,
                pattern: {
                  kind: "matchPatternVariable",
                  contents: 1 as VarId,
                },
              },
            },
            {
              kind: "statementExit",
              contents: { exitKind: "exitKindReturn", value: 1 as VarId },
            },
          ],
        },
      },
    };
    const ir = makeIR(blocks, "main", 0);
    const machine = createMachine(ir);
    const out = applyEvent(machine, delegate("main"));
    expect(lastDelegateAck(out)).toEqual({ kind: "string", value: "hi" });
  });

  it("any pattern discards binding silently", () => {
    // agent main() -> string {
    //   var0 = "kept"
    //   bindPattern source=var0 pattern=Any   (binds nothing)
    //   exit return var0                       (var0 still readable)
    // }
    const blocks: Record<number, Block> = {
      0: {
        kind: "blockUser",
        body: {
          kind: "blockKindAgent",
          parameters: [],
          statements: [
            {
              kind: "statementLoadLiteral",
              contents: {
                output: 0 as VarId,
                value: { kind: "literalValueString", string: "kept" },
              },
            },
            {
              kind: "statementBindPattern",
              contents: {
                source: 0 as VarId,
                pattern: { kind: "matchPatternAny" },
              },
            },
            {
              kind: "statementExit",
              contents: { exitKind: "exitKindReturn", value: 0 as VarId },
            },
          ],
        },
      },
    };
    const ir = makeIR(blocks, "main", 0);
    const machine = createMachine(ir);
    const out = applyEvent(machine, delegate("main"));
    expect(lastDelegateAck(out)).toEqual({ kind: "string", value: "kept" });
  });

  it("tuple destructure binds component vars", () => {
    // agent main(pair: (number, number)) -> number {
    //   bindPattern source=pair_var pattern=(a, b)
    //   exit return b
    // }
    //
    // We pass `pair` via args, so param.var=10 receives the tuple via the
    // UserThread parameter binding; the body's prelude statementBindPattern
    // then destructures it into var1 (a) and var2 (b).
    const blocks: Record<number, Block> = {
      0: {
        kind: "blockUser",
        body: {
          kind: "blockKindAgent",
          parameters: [{ label: "pair", var: 10 as VarId }],
          statements: [
            {
              kind: "statementBindPattern",
              contents: {
                source: 10 as VarId,
                pattern: {
                  kind: "matchPatternTuple",
                  contents: [
                    { kind: "matchPatternVariable", contents: 1 as VarId },
                    { kind: "matchPatternVariable", contents: 2 as VarId },
                  ],
                },
              },
            },
            {
              kind: "statementExit",
              contents: { exitKind: "exitKindReturn", value: 2 as VarId },
            },
          ],
        },
      },
    };
    const ir = makeIR(blocks, "main", 0);
    const machine = createMachine(ir);
    const args: Record<string, Value> = {
      pair: {
        kind: "tuple",
        elements: [
          { kind: "number", value: 100 },
          { kind: "number", value: 999 },
        ],
      },
    };
    const out = applyEvent(machine, delegate("main", args));
    expect(lastDelegateAck(out)).toEqual({ kind: "number", value: 999 });
  });

  it("constructor field destructure binds named fields", () => {
    // agent main(p: Pair) -> string {
    //   bindPattern source=p pattern=Pair{first=fv, second=sv}
    //   exit return sv
    // }
    const blocks: Record<number, Block> = {
      0: {
        kind: "blockUser",
        body: {
          kind: "blockKindAgent",
          parameters: [{ label: "p", var: 10 as VarId }],
          statements: [
            {
              kind: "statementBindPattern",
              contents: {
                source: 10 as VarId,
                pattern: {
                  kind: "matchPatternConstructor",
                  contents: [
                    42 as CtorId,
                    [
                      [
                        "first",
                        {
                          kind: "matchPatternVariable",
                          contents: 1 as VarId,
                        },
                      ],
                      [
                        "second",
                        {
                          kind: "matchPatternVariable",
                          contents: 2 as VarId,
                        },
                      ],
                    ],
                  ],
                },
              },
            },
            {
              kind: "statementExit",
              contents: { exitKind: "exitKindReturn", value: 2 as VarId },
            },
          ],
        },
      },
    };
    const ir = makeIR(blocks, "main", 0);
    const machine = createMachine(ir);
    const args: Record<string, Value> = {
      p: {
        kind: "tagged",
        ctorId: 42 as CtorId,
        fields: {
          first: { kind: "number", value: 1 },
          second: { kind: "string", value: "yes" },
        },
      },
    };
    const out = applyEvent(machine, delegate("main", args));
    expect(lastDelegateAck(out)).toEqual({ kind: "string", value: "yes" });
  });

  it("nested constructor + tuple destructure works in one statement", () => {
    // agent main(p: Pair{ fst = (a, b), snd = s }) -> string {
    //   bindPattern source=p pattern=Pair{fst=(a, b), snd=s}
    //   exit return s
    // }
    const blocks: Record<number, Block> = {
      0: {
        kind: "blockUser",
        body: {
          kind: "blockKindAgent",
          parameters: [{ label: "p", var: 10 as VarId }],
          statements: [
            {
              kind: "statementBindPattern",
              contents: {
                source: 10 as VarId,
                pattern: {
                  kind: "matchPatternConstructor",
                  contents: [
                    1 as CtorId,
                    [
                      [
                        "fst",
                        {
                          kind: "matchPatternTuple",
                          contents: [
                            { kind: "matchPatternVariable", contents: 1 as VarId },
                            { kind: "matchPatternVariable", contents: 2 as VarId },
                          ],
                        },
                      ],
                      [
                        "snd",
                        {
                          kind: "matchPatternVariable",
                          contents: 3 as VarId,
                        },
                      ],
                    ],
                  ],
                },
              },
            },
            {
              kind: "statementExit",
              contents: { exitKind: "exitKindReturn", value: 3 as VarId },
            },
          ],
        },
      },
    };
    const ir = makeIR(blocks, "main", 0);
    const machine = createMachine(ir);
    const args: Record<string, Value> = {
      p: {
        kind: "tagged",
        ctorId: 1 as CtorId,
        fields: {
          fst: {
            kind: "tuple",
            elements: [
              { kind: "number", value: 11 },
              { kind: "number", value: 22 },
            ],
          },
          snd: { kind: "string", value: "deep" },
        },
      },
    };
    const out = applyEvent(machine, delegate("main", args));
    expect(lastDelegateAck(out)).toEqual({ kind: "string", value: "deep" });
  });

  it("refutable pattern (literal) reaching runtime throws as compiler bug", () => {
    // agent main() -> string {
    //   var0 = "x"
    //   bindPattern source=var0 pattern=Literal("y")  -- mismatch on purpose
    //   exit return var0
    // }
    //
    // Maranget-irrefutability is a compiler invariant; reaching runtime with
    // a refutable bind site is itself a compiler bug. We exercise the
    // runtime guard by hand-crafting such an IR.
    const blocks: Record<number, Block> = {
      0: {
        kind: "blockUser",
        body: {
          kind: "blockKindAgent",
          parameters: [],
          statements: [
            {
              kind: "statementLoadLiteral",
              contents: {
                output: 0 as VarId,
                value: { kind: "literalValueString", string: "x" },
              },
            },
            {
              kind: "statementBindPattern",
              contents: {
                source: 0 as VarId,
                pattern: {
                  kind: "matchPatternLiteral",
                  contents: { kind: "literalValueString", string: "y" },
                },
              },
            },
            {
              kind: "statementExit",
              contents: { exitKind: "exitKindReturn", value: 0 as VarId },
            },
          ],
        },
      },
    };
    const ir = makeIR(blocks, "main", 0);
    const machine = createMachine(ir);
    expect(() => applyEvent(machine, delegate("main"))).toThrowError(
      /refutable pattern reached runtime/,
    );
  });
});
