// Unit tests for the unified-lattice match semantics (`tryMatch`):
//   - seq layer: a tuple pattern names the FIRST n positions of an array
//     value; minimum-elements means a longer value still matches.
//   - map layer: object / data / record share one `record` Value, so a record
//     pattern matches a bare record OR a data value (which carries a `ctor`),
//     while a constructor pattern additionally pins the ctor.

import { describe, expect, it } from "vitest";
import type { MatchPattern } from "../../src/ir/types.js";
import { tryMatch } from "../../src/engine/pattern.js";
import { mkString, type Value } from "../../src/engine/value.js";

const num = (value: number): Value => ({ kind: "number", value });
const arr = (...elements: Value[]): Value => ({ kind: "array", elements });
const record = (entries: Record<string, Value>): Value => ({ kind: "record", entries });
const data = (ctor: string, entries: Record<string, Value>): Value => ({
  kind: "record",
  entries,
  ctor,
});

const varP = (id: number): MatchPattern => ({ kind: "matchPatternVariable", body: id });

describe("tryMatch — seq layer (tuple / array)", () => {
  const tuplePat: MatchPattern = { kind: "matchPatternTuple", body: [varP(0), varP(1)] };

  it("binds the first n positions of an exact-arity array", () => {
    expect(tryMatch(tuplePat, arr(num(1), num(2)))).toEqual({ 0: num(1), 1: num(2) });
  });

  it("matches a LONGER array (minimum-elements), binding only the named positions", () => {
    expect(tryMatch(tuplePat, arr(num(1), num(2), num(3)))).toEqual({ 0: num(1), 1: num(2) });
  });

  it("fails on a shorter array (fewer than the named positions)", () => {
    expect(tryMatch(tuplePat, arr(num(1)))).toBeNull();
  });

  it("fails on a non-array value", () => {
    expect(tryMatch(tuplePat, record({ x: num(1) }))).toBeNull();
  });
});

describe("tryMatch — map layer (object / data / record)", () => {
  const recordPat: MatchPattern = {
    kind: "matchPatternRecord",
    body: [["x", varP(0)]],
  };

  it("matches a bare record on the named key", () => {
    expect(tryMatch(recordPat, record({ x: num(7), y: num(8) }))).toEqual({ 0: num(7) });
  });

  it("matches a DATA value on the named field (object pattern over data value)", () => {
    expect(tryMatch(recordPat, data("main.point", { x: num(7), y: num(8) }))).toEqual({
      0: num(7),
    });
  });

  it("fails when the named key is absent", () => {
    expect(tryMatch(recordPat, record({ y: num(8) }))).toBeNull();
  });

  it("fails on a non-map value", () => {
    expect(tryMatch(recordPat, arr(num(1)))).toBeNull();
  });
});

describe("tryMatch — constructor pattern pins the ctor", () => {
  const ctorPat: MatchPattern = {
    kind: "matchPatternConstructor",
    body: ["main.point", [["x", varP(0)]]],
  };

  it("matches a data value with the matching ctor", () => {
    expect(tryMatch(ctorPat, data("main.point", { x: num(1), y: num(2) }))).toEqual({ 0: num(1) });
  });

  it("fails on a data value with a different ctor", () => {
    expect(tryMatch(ctorPat, data("main.circle", { x: num(1) }))).toBeNull();
  });

  it("fails on a bare record (no ctor)", () => {
    expect(tryMatch(ctorPat, record({ x: num(1) }))).toBeNull();
  });
});

describe("tryMatch — nested cross-shape", () => {
  it("matches a tuple-of-data with a record sub-pattern over the data element", () => {
    const pat: MatchPattern = {
      kind: "matchPatternTuple",
      body: [{ kind: "matchPatternRecord", body: [["label", varP(0)]] }, varP(1)],
    };
    const value = arr(data("main.tag", { label: mkString("hi") }), num(9));
    expect(tryMatch(pat, value)).toEqual({ 0: mkString("hi"), 1: num(9) });
  });
});
