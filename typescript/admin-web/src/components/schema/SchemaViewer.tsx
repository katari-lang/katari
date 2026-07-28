// Visual display for a JSON Schema (Draft 2020-12 canonical shapes, as the compiler emits them):
// a structured tree with type badges and border-l indentation for nested properties — far easier to
// scan than raw schema JSON, which stays one copy-click away.
//
// The Katari wire shapes a schema can carry (a `data` value's tagged object, a `file` handle, a callable
// reference) are recognised through `wire-shape.ts`, which derives them from `@katari-lang/types`' own
// discriminator constants and `wireKindOf` recogniser — the same single definition the runtime codec and
// the FFI port encode against, and the same one `ValueViewer` reads. So this viewer cannot drift from what
// the compiler emits.

import type { ReactNode } from "react";
import type { Json, JsonSchema } from "../../api/types";
import { CopyButton } from "../ui/Copy";
import {
  asObject,
  schemaConstructorFieldsOf,
  schemaConstructorNameOf,
  schemaWireKindOf,
} from "./wire-shape";

export function SchemaViewer({ schema }: { schema: JsonSchema }) {
  return (
    <div className="flex items-start justify-between gap-2">
      <div className="min-w-0 flex-1">
        <SchemaNode schema={schema} />
      </div>
      <CopyButton value={JSON.stringify(schema, null, 2)} label="Copy schema JSON" />
    </div>
  );
}

function TypeBadge({ children, className }: { children: ReactNode; className?: string }) {
  return <span className={`font-mono text-xs text-fg-muted ${className ?? ""}`}>{children}</span>;
}

function RequiredBadge() {
  return <span className="text-xs font-medium uppercase tracking-wider text-danger">required</span>;
}

function Description({ text }: { text: string }) {
  return <p className="mt-0.5 text-xs text-fg-faint">{text}</p>;
}

function SchemaNode({ schema }: { schema: Json }): ReactNode {
  const node = asObject(schema);
  if (node === null) {
    return <span className="font-mono text-xs text-fg">{JSON.stringify(schema)}</span>;
  }
  const description = typeof node.description === "string" ? node.description : null;

  // never: `not: {}` or an empty anyOf / oneOf.
  if (isNeverSchema(node)) {
    return (
      <div>
        {description !== null && <Description text={description} />}
        <TypeBadge className="text-warning">never</TypeBadge>
      </div>
    );
  }

  // anyOf / oneOf union.
  const branches = Array.isArray(node.anyOf)
    ? node.anyOf
    : Array.isArray(node.oneOf)
      ? node.oneOf
      : null;
  if (branches !== null && branches.length > 0) {
    return (
      <div>
        {description !== null && <Description text={description} />}
        <span className="text-xs font-medium text-fg-muted">one of</span>
        <div className="mt-2 border-l border-edge">
          <div className="space-y-2 pl-3">
            {branches.map((branch, index) => (
              // biome-ignore lint/suspicious/noArrayIndexKey: a schema's branches are a stable positional list
              <SchemaNode key={index} schema={branch} />
            ))}
          </div>
        </div>
      </div>
    );
  }

  // enum.
  if (Array.isArray(node.enum) && node.enum.length > 0) {
    return (
      <div>
        <span className="mr-1.5 text-xs font-medium text-fg-muted">enum</span>
        {description !== null && <Description text={description} />}
        <span className="inline-flex flex-wrap items-center gap-1">
          {node.enum.map((value, index) => (
            // biome-ignore lint/suspicious/noArrayIndexKey: an enum's values are a stable positional list
            <TypeBadge key={index}>{JSON.stringify(value)}</TypeBadge>
          ))}
        </span>
      </div>
    );
  }

  // const.
  if (node.const !== undefined) {
    return (
      <div>
        <span className="mr-1.5 text-xs font-medium text-fg-muted">const</span>
        {description !== null && <Description text={description} />}
        <TypeBadge>{JSON.stringify(node.const)}</TypeBadge>
      </div>
    );
  }

  const type = singleType(node);

  if (type === "object") {
    return <ObjectNode node={node} description={description} />;
  }

  if (type === "array") {
    const items = asObject(node.items);
    const prefixItems = Array.isArray(node.prefixItems) ? node.prefixItems : null;
    return (
      <div>
        {description !== null && <Description text={description} />}
        <TypeBadge>array</TypeBadge>
        {prefixItems !== null && prefixItems.length > 0 && (
          <div className="mt-2 border-l border-edge">
            <div className="space-y-2 pl-3">
              {prefixItems.map((itemSchema, index) => (
                // biome-ignore lint/suspicious/noArrayIndexKey: a tuple's elements are a stable positional list
                <div key={index}>
                  <span className="mb-1 inline-flex items-center bg-sunken px-1.5 py-0.5 font-mono text-xs text-fg-muted">
                    {index}
                  </span>
                  <div className="mt-1">
                    <SchemaNode schema={itemSchema} />
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}
        {items !== null && prefixItems === null && (
          <div className="mt-1 border-l border-edge pl-3">
            <span className="text-xs text-fg-muted">items</span>
            <SchemaNode schema={items} />
          </div>
        )}
      </div>
    );
  }

  // Primitive types: string, number, integer, boolean, null.
  if (type !== undefined) {
    return (
      <div>
        {description !== null && <Description text={description} />}
        <TypeBadge>{type}</TypeBadge>
      </div>
    );
  }

  // Empty schema is `unknown`.
  const meaningfulKeys = Object.keys(node).filter(
    (key) => key !== "description" && key !== "title" && key !== "default",
  );
  if (meaningfulKeys.length === 0) {
    return (
      <div>
        {description !== null && <Description text={description} />}
        <TypeBadge className="text-fg-faint">unknown</TypeBadge>
      </div>
    );
  }

  // Fallback: render the raw schema.
  return (
    <pre className="whitespace-pre-wrap font-mono text-xs text-fg">
      {JSON.stringify(node, null, 2)}
    </pre>
  );
}

function ObjectNode({
  node,
  description,
}: {
  node: JsonSchema;
  description: string | null;
}): ReactNode {
  const properties = asObject(node.properties);
  const wireKind = schemaWireKindOf(properties);

  // Every wire variant but `data` is an opaque REFERENCE — a blob handle, a runtime-supplied callable.
  // Its reserved properties are machinery the reader has no use for, so surface the semantic type name
  // alone (`file`, `agent`, …) rather than the object it is carried as.
  if (wireKind !== null && wireKind !== "data") {
    return (
      <div>
        {description !== null && <Description text={description} />}
        <TypeBadge>{wireKind}</TypeBadge>
      </div>
    );
  }

  // A `data` value's own fields nest one level down, under `$katari_value`, so the properties worth
  // displaying are that inner object's — never the outer two reserved keys. The discriminator's `const`
  // becomes the type label. A `data` schema missing its nesting falls back to the outer object, which
  // shows the raw wire rather than nothing.
  const constructorName = wireKind === "data" ? schemaConstructorNameOf(properties) : null;
  const shape = (wireKind === "data" ? schemaConstructorFieldsOf(properties) : null) ?? node;
  const shapeProperties = wireKind === "data" ? asObject(shape.properties) : properties;
  const requiredSet = new Set(Array.isArray(shape.required) ? shape.required.filter(isString) : []);

  const displayProperties = shapeProperties !== null ? Object.entries(shapeProperties) : [];
  const additionalSchema = asObject(shape.additionalProperties);
  const hasAdditional =
    shape.additionalProperties !== undefined && shape.additionalProperties !== false;
  const isRecord = displayProperties.length === 0 && hasAdditional;
  const typeLabel = constructorName ?? (isRecord ? "record" : "object");

  return (
    <div>
      {description !== null && <Description text={description} />}
      <TypeBadge>{typeLabel}</TypeBadge>
      {displayProperties.length > 0 && (
        <div className="mt-1 border-l border-edge">
          <div className="space-y-2 pl-3">
            {displayProperties.map(([key, propertySchema]) => (
              <div key={key}>
                <div className="flex items-baseline gap-1.5">
                  <span className="text-sm font-medium text-fg">{key}</span>
                  {requiredSet.has(key) && <RequiredBadge />}
                </div>
                <SchemaNode schema={propertySchema} />
              </div>
            ))}
          </div>
        </div>
      )}
      {isRecord && additionalSchema !== null && (
        <div className="mt-2 border-l border-edge pl-3">
          <span className="text-xs text-fg-muted">values</span>
          <div className="mt-1">
            <SchemaNode schema={additionalSchema} />
          </div>
        </div>
      )}
      {displayProperties.length === 0 && !isRecord && (
        <span className="ml-1.5 text-xs italic text-fg-faint">empty object</span>
      )}
    </div>
  );
}

function isString(value: Json): value is string {
  return typeof value === "string";
}

function singleType(node: JsonSchema): string | undefined {
  if (typeof node.type === "string") return node.type;
  if (Array.isArray(node.type)) {
    const nonNull = node.type.filter(
      (entry): entry is string => isString(entry) && entry !== "null",
    );
    if (nonNull.length === 1) return nonNull[0];
  }
  return undefined;
}

function isNeverSchema(node: JsonSchema): boolean {
  const not = asObject(node.not);
  if (not !== null && Object.keys(not).length === 0) return true;
  if (Array.isArray(node.anyOf) && node.anyOf.length === 0) return true;
  if (Array.isArray(node.oneOf) && node.oneOf.length === 0) return true;
  return false;
}
