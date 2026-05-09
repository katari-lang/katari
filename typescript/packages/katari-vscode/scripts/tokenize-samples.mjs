// Sanity-check the Katari TextMate grammar against representative samples.
// Tokenizes a small Katari snippet and asserts that key spans receive the
// expected scopes. Exits non-zero if any assertion fails.

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { createRequire } from "node:module";

import oniguruma from "vscode-oniguruma";
import vsctm from "vscode-textmate";

const here = dirname(fileURLToPath(import.meta.url));
const grammarPath = resolve(here, "../syntaxes/katari.tmLanguage.json");

const require_ = createRequire(import.meta.url);
const onigWasmPath = require_.resolve("vscode-oniguruma/release/onig.wasm");
const wasmBin = await readFile(onigWasmPath);

await oniguruma.loadWASM(wasmBin.buffer);
const onigLib = Promise.resolve({
  createOnigScanner: (sources) => new oniguruma.OnigScanner(sources),
  createOnigString: (s) => new oniguruma.OnigString(s),
});

const grammarSource = await readFile(grammarPath, "utf8");
const rawGrammar = vsctm.parseRawGrammar(grammarSource, grammarPath);

const registry = new vsctm.Registry({
  onigLib,
  loadGrammar: async (scopeName) =>
    scopeName === "source.katari" ? rawGrammar : null,
});

const grammar = await registry.loadGrammar("source.katari");

function tokenize(source) {
  const lines = source.split("\n");
  let ruleStack = vsctm.INITIAL;
  const out = [];
  for (const line of lines) {
    const r = grammar.tokenizeLine(line, ruleStack);
    out.push({ line, tokens: r.tokens });
    ruleStack = r.ruleStack;
  }
  return out;
}

function find(result, predicate) {
  for (const { line, tokens } of result) {
    for (const t of tokens) {
      const text = line.slice(t.startIndex, t.endIndex);
      if (predicate(text, t.scopes)) {
        return { text, scopes: t.scopes };
      }
    }
  }
  return null;
}

function expectScope(result, text, scopeFragment, label) {
  const hit = find(
    result,
    (t, scopes) => t === text && scopes.some((s) => s.includes(scopeFragment)),
  );
  if (!hit) {
    const closest = find(result, (t) => t === text);
    console.error(
      `FAIL: ${label}\n  expected token "${text}" with scope containing "${scopeFragment}"\n  got: ${
        closest ? closest.scopes.join(", ") : "<token not found>"
      }`,
    );
    process.exitCode = 1;
    return false;
  }
  return true;
}

const samples = [
  {
    name: "agent declaration with annotation",
    source: '@"Returns the canonical greeting."\nagent main() -> string {\n  "hello, world"\n}\n',
    checks: [
      ["agent", "keyword.declaration", "agent keyword"],
      ["main", "entity.name.function", "agent name"],
      ["->", "keyword.operator.arrow", "return arrow"],
      ["string", "support.type.primitive", "primitive type"],
      ["hello, world", "string.quoted.double", "string literal content"],
    ],
  },
  {
    name: "data + match",
    source: '@"point"\ndata point(x: integer, y: integer)\nagent project_x(p = pt: point) -> integer {\n  match (pt) {\n    case point(x = xv, y = _) => { xv }\n  }\n}\n',
    checks: [
      ["data", "keyword.declaration", "data keyword"],
      ["point", "entity.name.type", "data type name"],
      ["match", "keyword.control", "match keyword"],
      ["case", "keyword.control", "case keyword"],
      ["=>", "keyword.operator.arrow", "fat arrow"],
      ["integer", "support.type.primitive", "integer type"],
    ],
  },
  {
    name: "handle + req",
    source: 'req fetch_answer() -> integer\nagent main() -> integer {\n  handle {\n    req fetch_answer() { 42 }\n  }\n  fetch_answer()\n}\n',
    checks: [
      ["req", "keyword.declaration", "req keyword"],
      ["handle", "keyword.control", "handle keyword"],
      ["42", "constant.numeric", "integer literal"],
    ],
  },
  {
    name: "for loop with template literal",
    source: 'agent main() -> string {\n  for (x in xs, var acc = "") {\n    next with { acc = acc ++ f"item: ${x}" }\n  }\n}\n',
    checks: [
      ["for", "keyword.control", "for keyword"],
      ["in", "keyword.control", "in keyword"],
      ["var", "keyword.declaration", "var keyword"],
      ["next", "keyword.control", "next keyword"],
      ["with", "keyword.control", "with keyword"],
      ["++", "keyword.operator.concat", "concat operator"],
    ],
  },
  {
    name: "constants and comments",
    source: '// line comment\n/* block /* nested */ comment */\nagent main() {\n  let x = true\n  let y = null\n  let z = false\n}\n',
    checks: [
      ["// line comment", "comment.line", "line comment"],
      ["true", "constant.language", "true literal"],
      ["null", "constant.language", "null literal"],
      ["false", "constant.language", "false literal"],
      ["let", "keyword.declaration", "let keyword"],
    ],
  },
  {
    name: "ext agent",
    source: 'ext agent http_get(url: string) -> string with { req http() }\n',
    checks: [
      ["ext", "storage.modifier.external", "ext modifier"],
      ["agent", "keyword.declaration.agent", "agent keyword in ext"],
      ["http_get", "entity.name.function", "external agent name"],
    ],
  },
];

let passed = 0;
let total = 0;
for (const s of samples) {
  const result = tokenize(s.source);
  for (const [text, scopeFragment, label] of s.checks) {
    total += 1;
    if (expectScope(result, text, scopeFragment, `[${s.name}] ${label}`)) {
      passed += 1;
    }
  }
}

console.log(`${passed}/${total} grammar checks passed`);
if (passed !== total) {
  process.exit(1);
}
