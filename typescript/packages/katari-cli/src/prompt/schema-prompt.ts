// JSON Schema → @clack/prompts walker.
//
// 与えられた JSON Schema (Draft 2020-12 サブセット) を歩いて、各ノードに対応
// する prompt を出して、最終的に runtime の `Value` 型に変換した結果を返す。
//
// サポート:
//   - { type: "string" }        → text
//   - { type: "number" | "integer" } → text + parse
//   - { type: "boolean" }       → confirm
//   - { type: "null" }          → 自動 null
//   - { enum: [...] }           → select
//   - { type: "object", properties }     → 各 property を順次 prompt
//   - { type: "array", items }  → 個数 prompt + 各要素 prompt
//   - { oneOf | anyOf: [...] }  → variant select → 再帰
//
// `description` フィールドは prompt のヒント (subtle 表示) として使う。

import * as p from "@clack/prompts";
import pc from "picocolors";
import type { Value } from "../types.js";

export class PromptCancelled extends Error {
  constructor() {
    super("prompt cancelled by user");
    this.name = "PromptCancelled";
  }
}

type AnySchema = Record<string, unknown>;

/**
 * Top-level entry. Schema の最上位は通常 object (= agent parameters は keyword
 * 引数なので)。最上位のラベルは省略可。
 */
export async function promptForSchema(
  schema: unknown,
  opts: { label: string; description?: string } = { label: "value" },
): Promise<Value> {
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
): Promise<Value> {
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
    return { kind: "boolean", value: Boolean(value) } as Value;
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
    return { kind: "number", value: Number(txt) } as Value;
  }
  if (t === "null") {
    return { kind: "null" } as Value;
  }
  // default to string for `type: "string"` and unknown / unspecified
  const txt = await p.text({
    message: pathLabel(path, "string"),
    placeholder: typeof schema.default === "string" ? schema.default : "",
    validate: (v) => (v.length === 0 ? "required" : undefined),
  });
  if (p.isCancel(txt)) throw new PromptCancelled();
  return { kind: "string", value: String(txt) } as Value;
}

async function promptEnum(
  values: unknown[],
  path: string,
  description?: string,
): Promise<Value> {
  if (description !== undefined && description.length > 0) {
    p.note(description, path);
  }
  const choice = await p.select({
    message: pathLabel(path, "choose"),
    options: values.map((v) => ({ value: v, label: String(v) })),
  });
  if (p.isCancel(choice)) throw new PromptCancelled();
  return literalToValue(choice);
}

async function promptObject(schema: AnySchema, path: string): Promise<Value> {
  const properties = (schema.properties ?? {}) as Record<string, unknown>;
  const required = new Set(
    Array.isArray(schema.required) ? (schema.required as string[]) : [],
  );
  const fields: Record<string, Value> = {};
  // Preserve declaration order from `properties`
  for (const [propName, propSchema] of Object.entries(properties)) {
    const sub = asSchema(propSchema);
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
    const v = await walk(sub, propPath(path, propName));
    fields[propName] = v;
  }
  // Object → Value: tagged constructor convention is for known ctors. For
  // open-ended JSON Schema objects we use a synthetic kind via the `tagged`
  // shape (ctorId: 0 for "anonymous record"). The runtime treats this as
  // an opaque tagged value.
  return { kind: "tagged", ctorId: 0, fields } as Value;
}

async function promptArray(schema: AnySchema, path: string): Promise<Value> {
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
  const elements: Value[] = [];
  for (let i = 0; i < len; i++) {
    const v = await walk(items, `${path}[${i}]`);
    elements.push(v);
  }
  return { kind: "array", elements } as Value;
}

// ─── Helpers ───────────────────────────────────────────────────────────────

function pathLabel(path: string, kind: string): string {
  return `${pc.cyan(path)} ${pc.dim(`(${kind})`)}`;
}

function propPath(parent: string, prop: string): string {
  if (parent === "" || parent === "value") return prop;
  return `${parent}.${prop}`;
}

function variantLabel(variant: unknown, index: number): string {
  const s = asSchema(variant);
  if (typeof s.title === "string") return s.title;
  if (typeof s.const !== "undefined") return String(s.const);
  if (typeof s.type === "string") return `${s.type} (variant ${index})`;
  return `variant ${index}`;
}

function literalToValue(v: unknown): Value {
  if (typeof v === "string") return { kind: "string", value: v };
  if (typeof v === "number") return { kind: "number", value: v };
  if (typeof v === "boolean") return { kind: "boolean", value: v };
  if (v === null) return { kind: "null" } as Value;
  // For other JSON-encodable enum values (objects, arrays), approximate.
  return { kind: "string", value: JSON.stringify(v) };
}
