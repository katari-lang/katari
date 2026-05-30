// Metadata-only ref semantics (Phase D, sync half): equality and match
// against string literals work when a byte-sequence value is a content-
// addressed ref, by comparing hashes — no value-store fetch. file identity
// is (module, id). The fetch-requiring ops (concat / format) land with the
// async quantum (Phase E).

import { describe, expect, it } from "vitest";
import { hashText } from "../../src/storage/hash.js";
import { matchLiteral } from "../../src/engine/pattern.js";
import { valueEquals } from "../../src/engine/prim.js";
import type { RefRep, Value } from "../../src/engine/value.js";
import { mkString } from "../../src/engine/value.js";

function strRef(text: string, module: RefRep["module"] = "core", id = "r1"): Value {
  return {
    kind: "string",
    rep: { kind: "ref", module, id, hash: hashText(text), size: text.length },
  };
}

function fileRef(module: RefRep["module"], id: string, hash = "h"): Value {
  return { kind: "file", rep: { kind: "ref", module, id, hash, size: 1 } };
}

describe("ref string equality (hash-based, no fetch)", () => {
  it("inline == ref when their content hashes match", () => {
    expect(valueEquals(mkString("hello"), strRef("hello"))).toBe(true);
    expect(valueEquals(strRef("hello"), mkString("hello"))).toBe(true);
  });

  it("inline != ref when content differs", () => {
    expect(valueEquals(mkString("hello"), strRef("world"))).toBe(false);
  });

  it("ref == ref by hash regardless of which module / id holds them", () => {
    expect(valueEquals(strRef("same", "core", "a"), strRef("same", "ffi", "b"))).toBe(true);
    expect(valueEquals(strRef("a", "core", "x"), strRef("b", "core", "y"))).toBe(false);
  });
});

describe("file identity equality", () => {
  it("equal iff (module, id) match — content hash is irrelevant", () => {
    expect(valueEquals(fileRef("ffi", "f1", "h1"), fileRef("ffi", "f1", "h2"))).toBe(true);
    expect(valueEquals(fileRef("ffi", "f1"), fileRef("ffi", "f2"))).toBe(false);
    expect(valueEquals(fileRef("core", "f1"), fileRef("ffi", "f1"))).toBe(false);
  });
});

describe("match string literal against a ref subject", () => {
  it("matches when the literal's hash equals the ref's hash", () => {
    expect(matchLiteral({ kind: "literalValueString", string: "ok" }, strRef("ok"))).toBe(true);
    expect(matchLiteral({ kind: "literalValueString", string: "ok" }, strRef("no"))).toBe(false);
  });

  it("still matches inline string subjects directly", () => {
    expect(matchLiteral({ kind: "literalValueString", string: "ok" }, mkString("ok"))).toBe(true);
    expect(matchLiteral({ kind: "literalValueString", string: "ok" }, mkString("no"))).toBe(false);
  });
});
