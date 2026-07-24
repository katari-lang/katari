// The admin store `set` boundary refuses raw callable decode (M2-7 / wire callable authz). A payload that
// carries a callable discriminator (`$katari_agent` / `$katari_closure` / `$katari_tool`), anywhere in the
// tree, is a 400 before it reaches the store — `jsonToValue` would otherwise reconstruct a real,
// dispatchable target from hand-written JSON. Inert markers (a `$katari_ref` file handle, a
// `$katari_constructor` data value) and ordinary nested values still write. The `upsert` port is spied so
// these assertions need no database (a rejected write never reaches it; an accepted one is intercepted).

import {
  AGENT_KEY,
  CLOSURE_KEY,
  CONSTRUCTOR_KEY,
  CONTEXT_KEY,
  DESCRIPTION_KEY,
  FILE_KEY,
  type Json,
  MODULE_KEY,
  REACTOR_KEY,
  SCOPE_KEY,
  SEMANTIC_KIND_KEY,
  SNAPSHOT_KEY,
  TOOL_KEY,
  VALUE_KEY,
} from "@katari-lang/types";
import { afterEach, describe, expect, test, vi } from "vitest";
import { BadRequestError } from "../src/lib/errors.js";
import { storeRows, storeService } from "../src/modules/store/store.service.js";

const PROJECT_ID = "00000000-0000-0000-0000-000000000000";

const callablePayloads: Array<[string, Json]> = [
  ["agent", { [AGENT_KEY]: "acme.bot", [SNAPSHOT_KEY]: "snap-1" }],
  [
    "closure",
    { [CLOSURE_KEY]: 1, [SCOPE_KEY]: 2, [SNAPSHOT_KEY]: "snap-1", [MODULE_KEY]: "main" },
  ],
  [
    "tool",
    {
      [TOOL_KEY]: "search",
      [REACTOR_KEY]: "core",
      [CONTEXT_KEY]: null,
      [SNAPSHOT_KEY]: "snap-1",
      [DESCRIPTION_KEY]: "a tool",
    },
  ],
];

describe("storeService.set — callable decode is refused", () => {
  afterEach(() => vi.restoreAllMocks());

  test.each(callablePayloads)(
    "rejects a top-level %s reference before it reaches the store",
    async (_kind, payload) => {
      const upsert = vi.spyOn(storeRows, "upsert");
      await expect(storeService.set(PROJECT_ID, "key", payload)).rejects.toBeInstanceOf(
        BadRequestError,
      );
      expect(upsert).not.toHaveBeenCalled();
    },
  );

  test("rejects a callable smuggled deep inside an otherwise-plain value", async () => {
    const upsert = vi.spyOn(storeRows, "upsert");
    const payload: Json = {
      profile: { name: "x", hooks: [{ note: "run" }, { [AGENT_KEY]: "acme.bot", [SNAPSHOT_KEY]: "s" }] },
    };
    await expect(storeService.set(PROJECT_ID, "config", payload)).rejects.toBeInstanceOf(
      BadRequestError,
    );
    expect(upsert).not.toHaveBeenCalled();
  });

  test("accepts an ordinary value with nested objects and arrays", async () => {
    const upsert = vi.spyOn(storeRows, "upsert").mockResolvedValue(undefined);
    const payload: Json = {
      title: "hi",
      tags: ["a", "b"],
      meta: { count: 1, nested: { deep: [1, 2, { flag: true }] } },
    };
    await expect(storeService.set(PROJECT_ID, "profile/main", payload)).resolves.toEqual({
      key: "profile/main",
    });
    expect(upsert).toHaveBeenCalledOnce();
  });

  test("accepts inert markers: a data value and a file reference", async () => {
    const upsert = vi.spyOn(storeRows, "upsert").mockResolvedValue(undefined);
    await expect(
      storeService.set(PROJECT_ID, "data", { [CONSTRUCTOR_KEY]: "Some", [VALUE_KEY]: { x: 1 } }),
    ).resolves.toEqual({ key: "data" });
    await expect(
      storeService.set(PROJECT_ID, "file", { [FILE_KEY]: "blob-1", [SEMANTIC_KIND_KEY]: "file" }),
    ).resolves.toEqual({ key: "file" });
    expect(upsert).toHaveBeenCalledTimes(2);
  });
});
