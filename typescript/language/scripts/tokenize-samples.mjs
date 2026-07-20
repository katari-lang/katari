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
const grammarPath = resolve(here, "../katari.tmLanguage.json");

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
      ["Returns the canonical greeting.", "comment.documentation", "annotation body"],
    ],
  },
  {
    name: "data + match",
    source: 'data point(x: integer, y: integer)\nagent project_x(pt: point) -> integer {\n  match (pt) {\n    case point(x => xv) -> { xv }\n  }\n}\n',
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
    name: "use handler + request",
    source: 'request fetch_answer() -> integer\nagent main() -> integer {\n  use handler {\n    request fetch_answer() { next 42 }\n  }\n  fetch_answer()\n}\n',
    checks: [
      ["request", "keyword.declaration", "request keyword"],
      ["use", "keyword.control", "use keyword"],
      ["handler", "keyword.control", "handler keyword"],
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
    name: "external agent",
    source: 'external agent http_get(url: string) -> string from "http"\n',
    checks: [
      ["external", "storage.modifier.external", "external modifier"],
      ["agent", "keyword.declaration", "agent keyword after modifier"],
      ["http_get", "entity.name.function", "external agent name"],
      ["from", "keyword.declaration", "from keyword"],
    ],
  },
  {
    name: "attributes and generics",
    source: "agent redact[T extends string of private](value: T) -> string of public {\n  \"hidden\"\n}\n",
    checks: [
      ["extends", "keyword.declaration", "extends keyword"],
      ["of", "keyword.declaration", "of keyword"],
      ["private", "support.type.attribute", "private attribute"],
      ["public", "support.type.attribute", "public attribute"],
    ],
  },
  {
    name: "forever is positional",
    source: 'agent main() -> integer {\n  forever {\n    break 42\n  }\n}\nagent retried() -> integer with replay.interrupted {\n  use replay.forever()\n  main()\n}\n',
    checks: [
      // The loop head is a keyword; the stdlib provider of the same name stays a plain call.
      ["forever", "keyword.control", "forever loop head"],
      ["forever", "entity.name.function.call", "replay.forever stays a call"],
      ["break", "keyword.control", "break keyword"],
    ],
  },
  {
    name: "finally and parallel",
    source: 'agent main(sources: array[string]) -> string {\n  finally { let _note = "bookkeeping" }\n  parallel for (let source in sources) {\n    next source\n  }\n}\n',
    checks: [
      ["finally", "keyword.control", "finally keyword"],
      ["parallel", "keyword.control", "parallel keyword"],
      ["array", "support.type.primitive", "array type"],
    ],
  },
  {
    name: "parameter defaults and holes",
    source: 'agent decorate(prefix: string, body: string, suffix: string ?= "!") -> string {\n  concat(prefix, body, suffix)\n}\nagent main() -> string {\n  let residual = decorate(prefix = ">", body = _, suffix = _)\n  residual(body = "x")\n}\n',
    checks: [
      ["?=", "keyword.operator.default", "parameter default operator"],
      ["_", "variable.language.hole", "partial-application hole"],
    ],
  },
  {
    name: "literal-binding generics",
    source: 'agent remember[literal name extends string](value: name) -> name { value }\nagent main() -> string {\n  let literal = "not a keyword"\n  literal\n}\n',
    checks: [
      ["literal", "storage.modifier.literal", "literal generic-kind marker"],
      ["literal", "variable.other", "ordinary identifier named literal"],
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

// Tripwire: every word the compiler reserves must be matched somewhere in the grammar, so a
// keyword added to the language cannot silently render as a plain identifier again (this is
// exactly how `finally` slipped through once). Mirrors `reservedWords` in
// haskell/compiler/src/Katari/Parser/Lexer.hs, plus the positional words the lexer deliberately
// leaves unreserved (`forever`, `extends`, `literal`) but the grammar still highlights.
const reservedWords = [
  "agent", "request", "external", "primitive", "data", "type", "import", "from", "as",
  "use", "handler", "for", "parallel", "if", "else", "match", "case", "return", "next",
  "break", "var", "let", "finally", "then", "in", "with", "of", "true", "false", "null",
];
const positionalWords = ["forever", "extends", "literal"];

function collectMatchSources(node, out) {
  if (Array.isArray(node)) {
    for (const item of node) collectMatchSources(item, out);
    return;
  }
  if (node !== null && typeof node === "object") {
    for (const [key, value] of Object.entries(node)) {
      if ((key === "match" || key === "begin" || key === "end") && typeof value === "string") {
        out.push(value);
      } else {
        collectMatchSources(value, out);
      }
    }
  }
}

const matchSources = [];
collectMatchSources(JSON.parse(grammarSource), matchSources);
// `\b` assertions in a pattern would glue their literal `b` onto the word ("\bforever\b" contains
// "bforeverb"), so strip them before the word-boundary search.
const normalizedSources = matchSources.map((source) => source.replaceAll("\\b", " "));
for (const word of [...reservedWords, ...positionalWords]) {
  total += 1;
  const covered = normalizedSources.some((source) => new RegExp(`\\b${word}\\b`).test(source));
  if (covered) {
    passed += 1;
  } else {
    console.error(
      `FAIL: [keyword coverage] "${word}" is reserved by the compiler's lexer but no grammar rule matches it`,
    );
    process.exitCode = 1;
  }
}

console.log(`${passed}/${total} grammar checks passed`);
if (passed !== total) {
  process.exit(1);
}
