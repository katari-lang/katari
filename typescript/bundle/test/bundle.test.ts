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
   *  `<sourceSubdirectory>` files. Returns the source root to bundle and the project dir to point
   *  `portResolveDir` at — in production the port comes from the toolchain, so a test must name the stub's
   *  location explicitly. `sourceSubdirectory` is how a test puts the package somewhere other than the
   *  project root, which is what a pnpm workspace does. */
  async function fixture(
    files: Record<string, string>,
    sourceSubdirectory = "src",
  ): Promise<{ src: string; dir: string }> {
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
    const src = join(dir, sourceSubdirectory);
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

  // ─── Containment ─────────────────────────────────────────────────────────
  //
  // `katari apply` bundles every package in the resolved dependency closure, registry-fetched ones
  // included, and the bundler is what stands between an untrusted package and the build machine's disk.
  // Both halves of that — which files the walk collects, and which files an import may reach — are
  // enforced here rather than being assumed of the caller.

  test("does not collect sources a symlink reaches outside the package root", async () => {
    const { src, dir } = await fixture({
      "main.ts": `import katari from "@katari-lang/port";\nkatari.agent("a", () => 1);`,
    });
    // A tree beside the package: the developer's other checkout, /etc, a home directory. Shipping a
    // symlink to it must not turn a source root into a licence to walk the rest of the disk — as a
    // directory link or as a file link, since the walk follows both.
    const outside = join(dir, "outside");
    await mkdir(outside, { recursive: true });
    await writeFile(
      join(outside, "secret.ts"),
      `import katari from "@katari-lang/port";\nkatari.agent("leaked", () => 1);`,
    );
    await symlink(outside, join(src, "escape"), "dir");
    await symlink(join(outside, "secret.ts"), join(src, "aliased.ts"), "file");

    const bundle = await bundleSidecar({
      packages: [{ packageName: "ext_agent", sourceRoot: src }],
      portResolveDir: dir,
    });
    const registered = await runBundle(bundle?.entry ?? "");
    expect(registered).toEqual(["main.a"]);
  });

  test("follows a symlink that stays inside the package root", async () => {
    const { src, dir } = await fixture({
      "main.ts": `import katari from "@katari-lang/port";\nkatari.agent("a", () => 1);`,
      "real/inner.ts": `import katari from "@katari-lang/port";\nkatari.agent("ping", () => 1);`,
    });
    await symlink(join(src, "real"), join(src, "linked"), "dir");

    const bundle = await bundleSidecar({
      packages: [{ packageName: "ext_agent", sourceRoot: src }],
      portResolveDir: dir,
    });
    // Contained symlinks still work; the collected path is the canonical one, so the linked copy is the
    // same module as the real one and registers once, under the real path's name.
    const registered = await runBundle(bundle?.entry ?? "");
    expect(new Set(registered)).toEqual(new Set(["main.a", "real.inner.ping"]));
  });

  test("rejects an absolute import that reads a file off the build machine", async () => {
    const { src, dir } = await fixture({});
    // esbuild resolves an absolute import as a plain file path and loads .json by default, so without a
    // resolution allowlist this file's contents land inside the bundle that gets deployed.
    const credentials = join(dir, "credentials.json");
    await writeFile(credentials, JSON.stringify({ token: "s3cret" }));
    await writeFile(
      join(src, "main.ts"),
      [
        `import katari from "@katari-lang/port";`,
        `import credentials from ${JSON.stringify(credentials)};`,
        `katari.agent("leak", () => credentials.token);`,
      ].join("\n"),
    );

    const bundling = bundleSidecar({
      packages: [{ packageName: "hostile", sourceRoot: src }],
      portResolveDir: dir,
    });
    await expect(bundling).rejects.toBeInstanceOf(BundleError);
    // The message has to name the import and the package, or a user whose legitimate layout trips this
    // has only "build failed" to go on.
    await expect(bundling).rejects.toThrow(/credentials\.json/);
    await expect(bundling).rejects.toThrow(/hostile/);
  });

  test("rejects a relative import that climbs out of the package", async () => {
    const { src, dir } = await fixture({
      "main.ts": [
        `import katari from "@katari-lang/port";`,
        `import credentials from "../credentials.json";`,
        `katari.agent("leak", () => credentials.token);`,
      ].join("\n"),
    });
    await writeFile(join(dir, "credentials.json"), JSON.stringify({ token: "s3cret" }));

    await expect(
      bundleSidecar({
        packages: [{ packageName: "hostile", sourceRoot: src }],
        portResolveDir: dir,
      }),
    ).rejects.toBeInstanceOf(BundleError);
  });

  test("bundles an npm dependency pnpm linked into a store outside the package", async () => {
    const { src, dir } = await fixture(
      {
        "main.ts": [
          `import katari from "@katari-lang/port";`,
          `import { greeting } from "greeter";`,
          `katari.agent(greeting, () => 1);`,
        ].join("\n"),
      },
      join("packages", "alpha", "src"),
    );
    // pnpm's layout, which any containment rule has to survive: `<package>/node_modules/greeter` is a link
    // into a virtual store that lives in the WORKSPACE root's node_modules, so the dependency's real path
    // is not under the package directory at all. This is how `discord.js` reaches the discord package's
    // sidecar, and a rule phrased as "must be under the package root" rejects it.
    const store = join(dir, "node_modules", ".pnpm", "greeter@1.0.0", "node_modules", "greeter");
    await mkdir(store, { recursive: true });
    await writeFile(
      join(store, "package.json"),
      JSON.stringify({ name: "greeter", type: "module", main: "index.js" }),
    );
    await writeFile(join(store, "index.js"), `export const greeting = "hello";`);
    const packageModules = join(dir, "packages", "alpha", "node_modules");
    await mkdir(packageModules, { recursive: true });
    await symlink(store, join(packageModules, "greeter"), "dir");

    const bundle = await bundleSidecar({
      packages: [{ packageName: "alpha", sourceRoot: src }],
      portResolveDir: dir,
    });
    const registered = await runBundle(bundle?.entry ?? "");
    expect(registered).toEqual(["main.hello"]);
  });

  test("keeps node built-ins resolvable", async () => {
    const { src, dir } = await fixture({
      // Both spellings a sidecar uses in practice; neither reads a file at build time, so the allowlist
      // has to let them past as externals rather than measuring them against a root.
      "main.ts": [
        `import katari from "@katari-lang/port";`,
        `import { sep } from "node:path";`,
        `import { EOL } from "os";`,
        `katari.agent("paths", () => sep + EOL);`,
      ].join("\n"),
    });

    const bundle = await bundleSidecar({
      packages: [{ packageName: "ext_agent", sourceRoot: src }],
      portResolveDir: dir,
    });
    const registered = await runBundle(bundle?.entry ?? "");
    expect(registered).toEqual(["main.paths"]);
  });
});
