// The sidecar bundler, exercised end to end against a temp fixture. `portResolveDir` points esbuild at a
// stubbed `@katari-lang/port` it can resolve and inline (production takes the toolchain's port from the
// bundler's own dependency). The produced bundle is then imported and run, proving it is valid,
// self-contained ESM whose registrations land under the package name (the bundle↔port contract: each file
// sets `globalThis.__katariModule`, and `katari.agent` reads it).

import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises";
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
   *  `<src>` files. Returns the source root to bundle and the project dir to point `portResolveDir` at —
   *  in production the port comes from the toolchain, so a test must name the stub's location explicitly. */
  async function fixture(files: Record<string, string>): Promise<{ src: string; dir: string }> {
    const dir = await mkdtemp(join(tmpdir(), "katari-bundle-"));
    temporaryDirs.push(dir);
    const portDir = join(dir, "node_modules", "@katari-lang", "port");
    await mkdir(portDir, { recursive: true });
    await writeFile(
      join(portDir, "package.json"),
      JSON.stringify({ name: "@katari-lang/port", type: "module", main: "index.js" }),
    );
    // A minimal stand-in for the real port, faithful on the one point the bundler must respect: the
    // registry is MODULE-level state, surfaced only by `__startSidecar`. A bundle that inlines a second
    // copy of the port splits the registry, and only the served copy's registrations reach the test's
    // global — exactly how the real port would lose handlers.
    await writeFile(
      join(portDir, "index.js"),
      [
        `const registered = [];`,
        `const katari = { agent: (name) => {`,
        `  registered.push(globalThis.__katariModule + "." + name);`,
        `} };`,
        `export const __startSidecar = () => {`,
        `  globalThis.__katariServed = (globalThis.__katariServed ?? []).concat(registered);`,
        `};`,
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
    return { src, dir };
  }

  /** Write the bundle to a temp `.mjs` and import it, returning the names `__startSidecar()` SERVED — the
   *  registrations that actually reached the started sidecar, not merely ran somewhere. The port stub is
   *  inlined, so the module is fully self-contained. */
  async function runBundle(entry: string): Promise<string[]> {
    const dir = await mkdtemp(join(tmpdir(), "katari-bundle-run-"));
    temporaryDirs.push(dir);
    const path = join(dir, "sidecar.mjs");
    await writeFile(path, entry);
    (globalThis as Record<string, unknown>).__katariServed = [];
    await import(pathToFileURL(path).href);
    return (globalThis as Record<string, unknown>).__katariServed as string[];
  }

  test("imports every file equally and registers under each file's module path", async () => {
    const { src, dir } = await fixture({
      // `main.ts` registers under module `main` and imports a helper that `export`s (a layout main's
      // function-wrapping broke: an export can't live in a wrapper). A nested file registers under its
      // dotted module path (`sub/extra.ts` → `sub.extra`). There is no privileged entry.
      "main.ts": [
        `import katari from "@katari-lang/port";`,
        `import { topic } from "./shared.js";`,
        `katari.agent("greet_" + topic, () => "hi");`,
      ].join("\n"),
      "shared.ts": `export const topic = "world";`,
      "sub/extra.ts": `import katari from "@katari-lang/port";\nkatari.agent("ping", () => 1);`,
    });

    const bundle = await bundleSidecar({
      packages: [{ packageName: "ext_agent", sourceRoot: src }],
      portResolveDir: dir,
    });
    expect(bundle).not.toBeNull();
    expect(bundle?.runtime).toBe("node");
    expect(bundle?.entry).toContain("__startSidecar()");

    const registered = await runBundle(bundle?.entry ?? "");
    expect(new Set(registered)).toEqual(new Set(["main.greet_world", "sub.extra.ping"]));
  });

  // Each fixture carries its OWN copy of the port stub (like a vendored package's `node_modules`), so this
  // also pins the port-singleton invariant: the plugin resolves every port import to the one `portResolveDir`
  // names, so beta's import lands on alpha's stub rather than beta's own — without that, beta would register
  // into an unserved copy and its agent would vanish from the served set.
  test("namespaces by module path across several packages", async () => {
    const a = await fixture({
      "alpha.ts": `import katari from "@katari-lang/port";\nkatari.agent("ping", () => 1);`,
    });
    const b = await fixture({
      "beta.ts": `import katari from "@katari-lang/port";\nkatari.agent("pong", () => 2);`,
    });

    const bundle = await bundleSidecar({
      packages: [
        { packageName: "alpha", sourceRoot: a.src },
        { packageName: "beta", sourceRoot: b.src },
      ],
      portResolveDir: a.dir,
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

  test("terminates on a symlink cycle in the source tree", async () => {
    const { src, dir } = await fixture({
      "main.ts": `import katari from "@katari-lang/port";\nkatari.agent("a", () => 1);`,
    });
    // A subdirectory symlinked back to the source root loops forever without the cycle guard.
    await symlink(src, join(src, "loop"), "dir");
    const bundle = await bundleSidecar({
      packages: [{ packageName: "ext_agent", sourceRoot: src }],
      portResolveDir: dir,
    });
    const registered = await runBundle(bundle?.entry ?? "");
    expect(registered).toEqual(["main.a"]); // walked once, registered once — no hang, no dup
  });

  test("surfaces an esbuild failure as a BundleError", async () => {
    const { src } = await fixture({ "broken.ts": `katari.agent(` }); // unterminated — a parse error
    await expect(
      bundleSidecar({ packages: [{ packageName: "ext_agent", sourceRoot: src }] }),
    ).rejects.toBeInstanceOf(BundleError);
  });
});
