// MatchThread tests via applyEvent. tryMatch's pure-pattern semantics are
// covered in detail by tests/bind-pattern.test.ts; here we focus on the
// MatchThread <-> arm-body integration: subject lookup from scope, arm
// dispatch, default arm fallback, and value propagation.

import { describe, expect, it } from "vitest";
import {
  applyEvent,
  createMachine,
  RecoverableEngineError,
  type MachineEvent,
  type Value,
} from "../src/index.js";
import type {
  Block,
  CtorId,
  IRMetadata,
  IRModule,
  VarId,
} from "../src/ir/types.js";
import type { DelegationId } from "../src/machine/id.js";

function metadata(): IRMetadata {
  return { schemaVersion: 1 };
}
function makeIR(blocks: Record<number, Block>, entryName: string, entryBlockId: number): IRModule {
  return {
    metadata: metadata(),
    name: "test",
    blocks: Object.fromEntries(Object.entries(blocks).map(([k, v]) => [k, v])),
    entries: { [entryName]: entryBlockId },
    nameTable: { varNames: {}, blockNames: {} },
  };
}
function delegate(qualifiedName: string, args: Record<string, Value> = {}): MachineEvent {
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
  if (!ack || ack.kind !== "delegateAck") throw new Error("no ack");
  return ack.value;
}

/**
 * Inline arm body that loads a literal string and trails it. Used as the
 * body of a `MatchArm` in the tests below.
 */
function armReturningString(
  s: string,
  varBase: number,
): Block {
  return {
    kind: "blockUser",
    body: {
      kind: "blockKindInline",
      parameters: [],
      statements: [
        {
          kind: "statementLoadLiteral",
          body: {
            output: varBase as VarId,
            value: { kind: "literalValueString", string: s },
          },
        },
      ],
      trailing: varBase as VarId,
    },
  };
}

describe("MatchThread", () => {
  it("integer literal arms — first match wins", () => {
    // agent main(n: integer) -> string {
    //   match n {
    //     1 => "one"
    //     2 => "two"
    //     _ => "other"
    //   }
    // }
    const blocks: Record<number, Block> = {
      0: {
        kind: "blockUser",
        body: {
          kind: "blockKindAgent",
          parameters: [{ label: "n", var: 1 as VarId }],
          statements: [
            {
              kind: "statementCall",
              body: {
                target: { kind: "callTargetBlock", block: 1 },
                arguments: [],
                output: 2 as VarId,
              },
            },
            {
              kind: "statementExit",
              body: { exitKind: "exitKindReturn", value: 2 as VarId },
            },
          ],
        },
      },
      1: {
        kind: "blockMatch",
        body: {
          subject: 1 as VarId,
          arms: [
            {
              pattern: {
                kind: "matchPatternLiteral",
                body: { kind: "literalValueInteger", integer: 1 },
              },
              body: 10,
            },
            {
              pattern: {
                kind: "matchPatternLiteral",
                body: { kind: "literalValueInteger", integer: 2 },
              },
              body: 11,
            },
          ],
          defaultArm: 12,
        },
      },
      10: armReturningString("one", 100),
      11: armReturningString("two", 101),
      12: armReturningString("other", 102),
    };
    const ir = makeIR(blocks, "main", 0);

    const m1 = createMachine(ir);
    expect(
      lastDelegateAck(
        applyEvent(m1, delegate("main", { n: { kind: "number", value: 1 } })),
      ),
    ).toEqual({ kind: "string", value: "one" });

    const m2 = createMachine(ir);
    expect(
      lastDelegateAck(
        applyEvent(m2, delegate("main", { n: { kind: "number", value: 2 } })),
      ),
    ).toEqual({ kind: "string", value: "two" });

    const m3 = createMachine(ir);
    expect(
      lastDelegateAck(
        applyEvent(m3, delegate("main", { n: { kind: "number", value: 99 } })),
      ),
    ).toEqual({ kind: "string", value: "other" });
  });

  it("constructor pattern matches the right arm", () => {
    // agent main(p: Pair) -> string {
    //   match p {
    //     Pair(_, _) => "pair"
    //     _ => "no"
    //   }
    // }
    //
    // We use a default arm + a single Pair pattern so this stays small.
    // The Pair value is constructed via args.
    const blocks: Record<number, Block> = {
      0: {
        kind: "blockUser",
        body: {
          kind: "blockKindAgent",
          parameters: [{ label: "p", var: 1 as VarId }],
          statements: [
            {
              kind: "statementCall",
              body: {
                target: { kind: "callTargetBlock", block: 1 },
                arguments: [],
                output: 2 as VarId,
              },
            },
            {
              kind: "statementExit",
              body: { exitKind: "exitKindReturn", value: 2 as VarId },
            },
          ],
        },
      },
      1: {
        kind: "blockMatch",
        body: {
          subject: 1 as VarId,
          arms: [
            {
              pattern: {
                kind: "matchPatternConstructor",
                body: [
                  77 as CtorId,
                  [],
                ],
              },
              body: 10,
            },
          ],
          defaultArm: 11,
        },
      },
      10: armReturningString("pair", 100),
      11: armReturningString("no", 101),
    };
    const ir = makeIR(blocks, "main", 0);
    const machine = createMachine(ir);
    const out = applyEvent(
      machine,
      delegate("main", {
        p: { kind: "tagged", ctorId: 77 as CtorId, fields: {} },
      }),
    );
    expect(lastDelegateAck(out)).toEqual({ kind: "string", value: "pair" });
  });

  it("variable pattern binds the subject and the bound name is visible in the arm body", () => {
    // agent main(x: integer) -> integer {
    //   match x { y => y + 1 }
    // }
    // To stay independent of prim implementation we just return `y` as-is.
    const blocks: Record<number, Block> = {
      0: {
        kind: "blockUser",
        body: {
          kind: "blockKindAgent",
          parameters: [{ label: "x", var: 1 as VarId }],
          statements: [
            {
              kind: "statementCall",
              body: {
                target: { kind: "callTargetBlock", block: 1 },
                arguments: [],
                output: 2 as VarId,
              },
            },
            {
              kind: "statementExit",
              body: { exitKind: "exitKindReturn", value: 2 as VarId },
            },
          ],
        },
      },
      1: {
        kind: "blockMatch",
        body: {
          subject: 1 as VarId,
          arms: [
            {
              pattern: { kind: "matchPatternVariable", body: 9 as VarId },
              body: 10,
            },
          ],
        },
      },
      // arm body trails on the bound var (9)
      10: {
        kind: "blockUser",
        body: {
          kind: "blockKindInline",
          parameters: [],
          statements: [],
          trailing: 9 as VarId,
        },
      },
    };
    const ir = makeIR(blocks, "main", 0);
    const machine = createMachine(ir);
    const out = applyEvent(
      machine,
      delegate("main", { x: { kind: "number", value: 42 } }),
    );
    expect(lastDelegateAck(out)).toEqual({ kind: "number", value: 42 });
  });

  it("no arm matches and no default → RecoverableEngineError", () => {
    const blocks: Record<number, Block> = {
      0: {
        kind: "blockUser",
        body: {
          kind: "blockKindAgent",
          parameters: [{ label: "x", var: 1 as VarId }],
          statements: [
            {
              kind: "statementCall",
              body: {
                target: { kind: "callTargetBlock", block: 1 },
                arguments: [],
                output: 2 as VarId,
              },
            },
            {
              kind: "statementExit",
              body: { exitKind: "exitKindReturn", value: 2 as VarId },
            },
          ],
        },
      },
      1: {
        kind: "blockMatch",
        body: {
          subject: 1 as VarId,
          arms: [
            {
              pattern: {
                kind: "matchPatternLiteral",
                body: { kind: "literalValueInteger", integer: 5 },
              },
              body: 10,
            },
          ],
          // no defaultArm
        },
      },
      10: armReturningString("five", 100),
    };
    const ir = makeIR(blocks, "main", 0);
    const machine = createMachine(ir);
    expect(() =>
      applyEvent(
        machine,
        delegate("main", { x: { kind: "number", value: 99 } }),
      ),
    ).toThrowError(RecoverableEngineError);
  });
});
