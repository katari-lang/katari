import { useCallback, useMemo, useState } from "react";
import type { SnapshotId } from "@/api/types";
import { SchemaFormProvider } from "./context";
import { SchemaField } from "./SchemaField";
import {
  isFileRefSchema,
  type JsonSchema,
  schemaInitialValue,
  singleType,
  unionBranches,
} from "./schema-utils";

type SchemaFormProps = {
  schema: JsonSchema;
  onSubmit: (value: unknown) => void;
  submitLabel?: string;
  renderActions?: (ctx: { submit: () => void; value: unknown }) => React.ReactNode;
  /** The snapshot this form's run targets. Threaded to fields (an AgentField
   *  stamps it into the external agent id). */
  snapshotId?: SnapshotId;
};

// ---------------------------------------------------------------------------
// Lightweight client-side schema validation
// ---------------------------------------------------------------------------

/** Validate `value` against `schema`. Returns an array of human-readable
 * error strings (empty = valid). Covers the subset Katari actually emits. */
function validateSchema(schema: JsonSchema, value: unknown, path = ""): string[] {
  const errors: string[] = [];
  const at = path || "root";

  // const
  if (schema.const !== undefined) {
    if (value !== schema.const) {
      errors.push(`${at}: expected constant ${JSON.stringify(schema.const)}`);
    }
    return errors;
  }

  // enum
  if (Array.isArray(schema.enum)) {
    if (!schema.enum.some((e) => e === value)) {
      errors.push(`${at}: value must be one of ${JSON.stringify(schema.enum)}`);
    }
    return errors;
  }

  // file ref: the FileField yields the `$ref` envelope or null. Validate
  // "a file is picked" rather than recursing into the object's $ref/hash/size
  // (which the picker fills atomically), so the message stays operator-facing.
  if (isFileRefSchema(schema)) {
    if (value === null || typeof value !== "object" || !("$ref" in value)) {
      return [`${at}: select a file`];
    }
    return errors;
  }

  // anyOf / oneOf
  const branches = unionBranches(schema);
  if (branches !== null) {
    const branchValid = branches.some((b) => validateSchema(b, value, path).length === 0);
    if (!branchValid) {
      errors.push(`${at}: value does not match any branch of the union`);
    }
    return errors;
  }

  const type = singleType(schema);
  if (type === undefined) return errors; // untyped / multi-type — skip

  switch (type) {
    case "string":
      if (typeof value !== "string") {
        errors.push(`${at}: expected string`);
      }
      break;
    case "number":
    case "integer":
      if (typeof value !== "number") {
        errors.push(`${at}: expected ${type}`);
      } else {
        if (type === "integer" && !Number.isInteger(value)) {
          errors.push(`${at}: expected integer`);
        }
        if (schema.minimum !== undefined && value < schema.minimum) {
          errors.push(`${at}: must be >= ${schema.minimum}`);
        }
        if (schema.maximum !== undefined && value > schema.maximum) {
          errors.push(`${at}: must be <= ${schema.maximum}`);
        }
      }
      break;
    case "boolean":
      if (typeof value !== "boolean") {
        errors.push(`${at}: expected boolean`);
      }
      break;
    case "null":
      if (value !== null) {
        errors.push(`${at}: expected null`);
      }
      break;
    case "object": {
      if (value === null || typeof value !== "object" || Array.isArray(value)) {
        errors.push(`${at}: expected object`);
        break;
      }
      const obj = value as Record<string, unknown>;
      const requiredSet = new Set(schema.required ?? []);
      for (const key of requiredSet) {
        if (obj[key] === undefined) {
          errors.push(`${at}.${key}: required`);
        }
      }
      const properties = schema.properties ?? {};
      for (const [key, sub] of Object.entries(properties)) {
        if (obj[key] !== undefined) {
          errors.push(...validateSchema(sub, obj[key], path ? `${path}.${key}` : key));
        }
      }
      break;
    }
    case "array": {
      if (!Array.isArray(value)) {
        errors.push(`${at}: expected array`);
        break;
      }
      if (Array.isArray(schema.prefixItems)) {
        for (let i = 0; i < schema.prefixItems.length; i++) {
          if (i < value.length) {
            errors.push(...validateSchema(schema.prefixItems[i]!, value[i], `${at}[${i}]`));
          }
        }
      } else if (schema.items !== undefined) {
        for (let i = 0; i < value.length; i++) {
          errors.push(...validateSchema(schema.items, value[i], `${at}[${i}]`));
        }
      }
      break;
    }
  }
  return errors;
}

/**
 * Top-level form for any schema shape. Manages the form value in local
 * state; calls `onSubmit` with whatever value the inner fields produced
 * when the operator clicks Run. Caller is free to render its own submit
 * button via `renderActions`.
 *
 * Schema is rendered verbatim — admin-web does not distinguish decl kinds
 * (agent / ext / data / req) and does not assume the root is an object
 * schema (escalation answers are typed by the request's return type,
 * which is often a primitive).
 */
export function SchemaForm({ schema, onSubmit, renderActions, snapshotId }: SchemaFormProps) {
  const initial = useMemo<unknown>(() => schemaInitialValue(schema), [schema]);
  const [value, setValue] = useState<unknown>(initial);
  const [validationErrors, setValidationErrors] = useState<string[]>([]);

  const submit = useCallback(() => {
    const errors = validateSchema(schema, value);
    setValidationErrors(errors);
    if (errors.length > 0) return;
    onSubmit(value);
  }, [onSubmit, value, schema]);

  return (
    <SchemaFormProvider value={{ snapshotId }}>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
        className="space-y-4"
      >
        <SchemaField schema={schema} value={value} onChange={setValue} />
        {validationErrors.length > 0 && (
          <div className="border border-danger/30 bg-danger/10 px-3 py-2 text-xs text-danger">
            <ul className="list-inside list-disc space-y-0.5">
              {validationErrors.map((error, index) => (
                <li key={index}>{error}</li>
              ))}
            </ul>
          </div>
        )}
        {renderActions?.({ submit, value })}
      </form>
    </SchemaFormProvider>
  );
}
