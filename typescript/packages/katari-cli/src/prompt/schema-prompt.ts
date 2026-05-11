// JSON Schema → @clack/prompts walker.
//
// 与えられた JSON Schema (Draft 2020-12 サブセット) を歩いて、各ノードに対応
// する prompt を出して、最終的に runtime の wire 表現 `RawValue` を返す。
// Wire 形式が `Value` ではなく raw である理由は (a) JSON Schema が描く対象
// と同じ shape のため変換コストがゼロ、(b) REST / sidecar / AI tool calling
// など他の境界とも揃う、の 2 点。
//
// サポート:
//   - { type: "string" }              → text
//   - { type: "number" | "integer" }  → text + parse
//   - { type: "boolean" }             → confirm
//   - { type: "null" }                → 自動 null
//   - { enum: [...] }                 → select
//   - { type: "object", properties }  → 各 property を順次 prompt
//                                       (`$ctor` / `$callable` const は
//                                        自動補完してユーザには聞かない)
//   - { type: "array", items }        → 個数 prompt + 各要素 prompt
//   - { oneOf | anyOf: [...] }        → variant select → 再帰
//
// `description` フィールドは prompt のヒント (subtle 表示) として使う。

import * as p from "@clack/prompts";
import pc from "picocolors";
import type { RawValue } from "katari-runtime";

export class PromptCancelled extends Error {
  constructor() {
    super("prompt cancelled by user");
    this.name = "PromptCancelled";
  }
}

type AnySchema = Record<string, unknown>;

const CTOR_DISCRIMINATOR = "$ctor";
const CALLABLE_DISCRIMINATOR = "$callable";

/**
 * Top-level entry. Schema の最上位は通常 object (= agent parameters は keyword
 * 引数なので)。最上位のラベルは省略可。
 */
export async function promptForSchema(
  schema: unknown,
  opts: { label: string; description?: string } = { label: "value" },
): Promise<RawValue> {
  return walk(asSchema(schema), opts.label, opts.description);
}

function asSchema(s: unknown): AnySchema {
  if (typeof s !== "object" || s === null) return {};
  return s as AnySchema;
}

async function walk(
  schema: AnySchema,
  path: string,
  parentDescription?: string,
): Promise<RawValue> {
  // enum: pick from list
  if (Array.isArray(schema.enum)) {
    return promptEnum(schema.enum, path, schema.description as string | undefined ?? parentDescription);
  }

  // oneOf / anyOf: variant select then recurse
  const variants = (schema.oneOf ?? schema.anyOf) as unknown;
  if (Array.isArray(variants) && variants.length > 0) {
    const choice = await p.select({
      message: pathLabel(path, "select variant"),
      options: variants.map((v, i) => ({
        value: i,
        label: variantLabel(v, i),
        hint: typeof (v as AnySchema).description === "string"
          ? (v as AnySchema).description as string
          : undefined,
      })),
    });
    if (p.isCancel(choice)) throw new PromptCancelled();
    return walk(asSchema(variants[choice as number]), path, parentDescription);
  }

  const t = schema.type;

  if (t === "object") {
    return promptObject(schema, path);
  }
  if (t === "array") {
    return promptArray(schema, path);
  }
  if (t === "boolean") {
    const value = await p.confirm({
      message: pathLabel(path, "boolean"),
      initialValue: typeof schema.default === "boolean" ? schema.default : true,
    });
    if (p.isCancel(value)) throw new PromptCancelled();
    return Boolean(value);
  }
  if (t === "integer" || t === "number") {
    const isInt = t === "integer";
    const txt = await p.text({
      message: pathLabel(path, isInt ? "integer" : "number"),
      placeholder: typeof schema.default === "number" ? String(schema.default) : "",
      validate: (v) => {
        if (v.length === 0) return "required";
        const n = Number(v);
        if (Number.isNaN(n)) return "not a number";
        if (isInt && !Number.isInteger(n)) return "must be an integer";
        return undefined;
      },
    });
    if (p.isCancel(txt)) throw new PromptCancelled();
    return Number(txt);
  }
  if (t === "null") {
    return null;
  }
  // default to string for `type: "string"` and unknown / unspecified
  const txt = await p.text({
    message: pathLabel(path, "string"),
    placeholder: typeof schema.default === "string" ? schema.default : "",
    validate: (v) => (v.length === 0 ? "required" : undefined),
  });
  if (p.isCancel(txt)) throw new PromptCancelled();
  return String(txt);
}

async function promptEnum(
  values: unknown[],
  path: string,
  description?: string,
): Promise<RawValue> {
  if (description !== undefined && description.length > 0) {
    p.note(description, path);
  }
  const choice = await p.select({
    message: pathLabel(path, "choose"),
    options: values.map((v) => ({ value: v, label: String(v) })),
  });
  if (p.isCancel(choice)) throw new PromptCancelled();
  return choice as RawValue;
}

async function promptObject(schema: AnySchema, path: string): Promise<RawValue> {
  const properties = (schema.properties ?? {}) as Record<string, unknown>;
  const required = new Set(
    Array.isArray(schema.required) ? (schema.required as string[]) : [],
  );
  const out: Record<string, RawValue> = {};

  for (const [propName, propSchemaRaw] of Object.entries(properties)) {
    const sub = asSchema(propSchemaRaw);

    // Reserved discriminator fields (`$ctor` / `$callable`) carry their
    // value in `const` directly from the schema. Auto-fill them so the
    // user only sees the *meaningful* fields; they still appear in the
    // resulting raw object.
    if (propName === CTOR_DISCRIMINATOR || propName === CALLABLE_DISCRIMINATOR) {
      if (sub.const !== undefined) {
        out[propName] = sub.const as RawValue;
        continue;
      }
      // No const (rare — only when the schema is `function`-top without
      // a known callable). Fall through to the normal prompt path.
    }

    const isRequired = required.has(propName);
    if (!isRequired) {
      const include = await p.confirm({
        message: `Include optional field ${pc.cyan(propName)}?`,
        initialValue: false,
      });
      if (p.isCancel(include)) throw new PromptCancelled();
      if (!include) continue;
    }
    if (typeof sub.description === "string" && sub.description.length > 0) {
      p.note(sub.description, propPath(path, propName));
    }
    out[propName] = await walk(sub, propPath(path, propName));
  }
  return out;
}

async function promptArray(schema: AnySchema, path: string): Promise<RawValue> {
  const items = asSchema(schema.items ?? {});
  const lenStr = await p.text({
    message: pathLabel(path, "array length"),
    placeholder: "0",
    validate: (v) => {
      if (v.length === 0) return undefined;
      const n = Number(v);
      if (!Number.isInteger(n) || n < 0) return "non-negative integer";
      return undefined;
    },
  });
  if (p.isCancel(lenStr)) throw new PromptCancelled();
  const len = lenStr.length === 0 ? 0 : Number(lenStr);
  const elements: RawValue[] = [];
  for (let i = 0; i < len; i++) {
    elements.push(await walk(items, `${path}[${i}]`));
  }
  return elements;
}

// ─── Helpers ───────────────────────────────────────────────────────────────

function pathLabel(path: string, kind: string): string {
  return `${pc.cyan(path)} ${pc.dim(`(${kind})`)}`;
}

function propPath(parent: string, prop: string): string {
  if (parent === "" || parent === "value") return prop;
  return `${parent}.${prop}`;
}

/**
 * Build a human-readable label for one arm of a `oneOf` / `anyOf`. We
 * prefer the most informative source available:
 *
 *   1. `title` if present (the compiler stamps this for data ctors)
 *   2. `properties.$ctor.const` → the constructor's qualified name
 *      (e.g. `"main.point" (object)`)
 *   3. `properties.$callable.const` → the bound callable id, if any
 *   4. `const` value (for primitive const arms)
 *   5. `type` keyword
 *   6. positional fallback `"variant N"`
 */
function variantLabel(variant: unknown, index: number): string {
  const s = asSchema(variant);
  if (typeof s.title === "string" && s.title.length > 0) return s.title;
  const ctor = discriminatorConst(s, CTOR_DISCRIMINATOR);
  if (ctor !== undefined) return `${ctor} ${pc.dim("(object)")}`;
  const callable = discriminatorConst(s, CALLABLE_DISCRIMINATOR);
  if (callable !== undefined) return `${callable} ${pc.dim("(callable)")}`;
  if (typeof s.const !== "undefined") return String(s.const);
  if (typeof s.type === "string") return s.type;
  return `variant ${index}`;
}

function discriminatorConst(schema: AnySchema, key: string): string | undefined {
  const props = schema.properties as Record<string, unknown> | undefined;
  if (props === undefined) return undefined;
  const propSchema = props[key];
  if (typeof propSchema !== "object" || propSchema === null) return undefined;
  const c = (propSchema as AnySchema).const;
  return typeof c === "string" ? c : undefined;
}
