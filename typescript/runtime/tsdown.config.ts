import { defineConfig } from "tsdown";

export default defineConfig({
  entry: ["src/index.ts", "src/bin.ts"],
  format: "esm",
  platform: "node",
  // The runtime is an application (a server + its bin), not an imported library — nothing in the
  // workspace consumes its types. So it ships JS only (no `.d.mts`) and inlines its one workspace
  // dependency, @katari-lang/types (type-only + the wire-convention constants), into its own bundle.
  // That makes the built runtime self-contained: the deployed image never has to resolve
  // @katari-lang/types' raw `src/*.ts` (which Node cannot execute) at run time.
  dts: false,
  deps: { alwaysBundle: ["@katari-lang/types"] },
});
