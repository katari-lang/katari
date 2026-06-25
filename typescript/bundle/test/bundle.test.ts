// The sidecar bundler, exercised end to end against a temp fixture — including a stubbed
// `@katari-lang/port` so esbuild can resolve and inline it. The produced bundle is then imported and run,
// proving it is valid, self-contained ESM whose registrations land under the package name (the bundle↔port
// contract: each file sets `globalThis.__katariModule`, and `katari.agent` reads it).

import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { afterEach, describe, expect, test } from "vitest";
import { BundleError, bundleSidecar } from "../src/index.js";

describe("bundleSidecar", () => {
  const temporaryDirs: string[] = [];

  afterEach(async () => {
    await Promise.all(temporaryDirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
  });

  /** A project dir with a stub `@katari-lang/port` (so esbuild resolves + inlines it) and the given
   *  `<src>` files. Returns the absolute source root to hand to the bundler. */
  async function fixture(files: Record<string, string>): Promise<string> {
    const dir = await mkdtemp(join(tmpdir(), "katari-bundle-"));
    temporaryDirs.push(dir);
    const portDir = join(dir, "node_modules", "@katari-lang", "port");
    await mkdir(portDir, { recursive: true });
    await writeFile(
      join(portDir, "package.json"),
      JSON.stringify({ name: "@katari-lang/port", type: "module", main: "index.js" }),
    );
    // A minimal stand-in for the real port: `katari.agent` records `<module>.<name>` on a global the test
    // can read, reading the ambient package name the bundle set. `__startSidecar` is a no-op here.
    await writeFile(
      join(portDir, "index.js"),
      [
        `const katari = { agent: (name) => {`,
        `  (globalThis.__katariRegistered ??= []).push(globalThis.__katariModule + "." + name);`,
        `} };`,
        `export const __startSidecar = () => {};`,
        `export default katari;`,
      ].join("\n"),
    );
    const src = join(dir, "src");
    await mkdir(src, { recursive: true });
    for (const [name, contents] of Object.entries(files)) {
      const path = join(src, name);
      await mkdir(join(path, ".."), { recursive: true });
      await writeFile(path, contents);
    }
    return src;
  }

  /** Write the bundle to a temp `.mjs` and import it, returning the names its registrations recorded. The
   *  port stub is inlined, so the module is fully self-contained. */
  async function runBundle(entry: string): Promise<string[]> {
    const dir = await mkdtemp(join(tmpdir(), "katari-bundle-run-"));
    temporaryDirs.push(dir);
    const path = join(dir, "sidecar.mjs");
    await writeFile(path, entry);
    (globalThis as Record<string, unknown>).__katariRegistered = [];
    await import(pathToFileURL(path).href);
    return (globalThis as Record<string, unknown>).__katariRegistered as string[];
  }

  test("bundles a multi-file package into runnable ESM whose registrations land under the package name", async () => {
    const src = await fixture({
      // The entry registers an agent and imports a helper that itself exports — a layout main's
      // function-wrapping broke (an `export` cannot live inside the wrapper).
      "ext_agent.ts": [
        `import katari from "@katari-lang/port";`,
        `import { topic } from "./helper.js";`,
        `katari.agent("greet_" + topic, () => "hi");`,
      ].join("\n"),
      "helper.ts": `export const topic = "world";`,
    });

    const bundle = await bundleSidecar({ packages: [{ packageName: "ext_agent", sourceRoot: src }] });
    expect(bundle).not.toBeNull();
    expect(bundle?.runtime).toBe("node");
    expect(bundle?.entry).toContain("__startSidecar()");

    const registered = await runBundle(bundle?.entry ?? "");
    expect(registered).toEqual(["ext_agent.greet_world"]);
  });

  test("namespaces each package's registrations independently when several are bundled", async () => {
    const a = await fixture({
      "alpha.ts": `import katari from "@katari-lang/port";\nkatari.agent("ping", () => 1);`,
    });
    const b = await fixture({
      "beta.ts": `import katari from "@katari-lang/port";\nkatari.agent("pong", () => 2);`,
    });

    const bundle = await bundleSidecar({
      packages: [
        { packageName: "alpha", sourceRoot: a },
        { packageName: "beta", sourceRoot: b },
      ],
    });
    const registered = await runBundle(bundle?.entry ?? "");
    expect(new Set(registered)).toEqual(new Set(["alpha.ping", "beta.pong"]));
  });

  test("returns null when no package has a sidecar source", async () => {
    const bundle = await bundleSidecar({
      packages: [{ packageName: "empty", sourceRoot: join(tmpdir(), "katari-does-not-exist-xyz") }],
    });
    expect(bundle).toBeNull();
  });

  test("rejects an ambiguous multi-file package with no named entry", async () => {
    const src = await fixture({
      "alpha.ts": `export const a = 1;`,
      "beta.ts": `export const b = 2;`,
    });
    await expect(
      bundleSidecar({ packages: [{ packageName: "ext_agent", sourceRoot: src }] }),
    ).rejects.toBeInstanceOf(BundleError);
  });
});
