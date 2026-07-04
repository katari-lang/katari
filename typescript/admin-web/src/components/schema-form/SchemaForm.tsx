// Schema-driven input form: renders a JSON Schema (the canonical shapes the compiler emits) as
// typed fields and assembles the Json argument. Every branch the pretty fields cannot express
// falls back to a raw-JSON editor, so any schema stays fillable.

import {
  AGENT_KEY,
  CONSTRUCTOR_KEY,
  CONTENT_TYPE_KEY,
  FILE_KEY,
  HASH_KEY,
  SIZE_KEY,
  SNAPSHOT_KEY,
} from "@katari-lang/types";
import { Plus, Trash2, Upload } from "lucide-react";
import { type ReactNode, useState } from "react";
import { api } from "../../api/client";
import type { Json, JsonSchema } from "../../api/types";
import { useToast } from "../../lib/toast";
import { Button } from "../ui/Button";
import { Input, Select, TextArea } from "../ui/Field";

/** What the special reference fields need from the invocation site. */
export interface FormContext {
  projectId: string;
  snapshotId: string;
}

export function SchemaForm({
  schema,
  value,
  onChange,
  context,
}: {
  schema: JsonSchema;
  value: Json | undefined;
  onChange: (next: Json | undefined) => void;
  context: FormContext;
}) {
  return (
    <SchemaField
      schema={schema}
      value={value}
      onChange={onChange}
      context={context}
    />
  );
}

interface FieldProps {
  schema: Json;
  value: Json | undefined;
  onChange: (next: Json | undefined) => void;
  context: FormContext;
}

function SchemaField(props: FieldProps) {
  const { schema } = props;
  if (typeof schema !== "object" || schema === null || Array.isArray(schema)) {
    return <JsonField {...props} />;
  }
  const node = schema as JsonSchema;

  if (isReferenceSchema(node, FILE_KEY)) return <FileField {...props} />;
  if (isReferenceSchema(node, AGENT_KEY)) return <AgentField {...props} />;
  if (node.const !== undefined)
    return <ConstField {...props} constant={node.const} />;
  if (Array.isArray(node.enum))
    return <EnumField {...props} options={node.enum} />;
  if (Array.isArray(node.anyOf))
    return <UnionField {...props} branches={node.anyOf} />;

  switch (node.type) {
    case "null":
      return <ConstField {...props} constant={null} />;
    case "boolean":
      return <BooleanField {...props} />;
    case "integer":
    case "number":
      return <NumberField {...props} integer={node.type === "integer"} />;
    case "string":
      return <StringField {...props} />;
    case "array":
      return Array.isArray(node.prefixItems) ? (
        <TupleField {...props} elements={node.prefixItems} />
      ) : (
        <ArrayField {...props} itemSchema={node.items ?? true} />
      );
    case "object": {
      const properties = node.properties;
      if (
        typeof properties === "object" &&
        properties !== null &&
        !Array.isArray(properties)
      ) {
        return (
          <ObjectField
            {...props}
            properties={properties as { [name: string]: Json }}
            required={
              new Set(
                Array.isArray(node.required) ? (node.required as string[]) : [],
              )
            }
          />
        );
      }
      return (
        <RecordField
          {...props}
          valueSchema={node.additionalProperties ?? true}
        />
      );
    }
    default:
      return <JsonField {...props} />;
  }
}

/** The `$ref` / `$agent` reference schemas are objects requiring exactly that discriminator key. */
function isReferenceSchema(
  node: JsonSchema,
  key: typeof FILE_KEY | typeof AGENT_KEY,
): boolean {
  return Array.isArray(node.required) && node.required.includes(key);
}

// ---------------------------------------------------------------------------
// Scalars
// ---------------------------------------------------------------------------

function ConstField({
  value,
  onChange,
  constant,
}: FieldProps & { constant: Json }) {
  if (value === undefined) onChange(constant);
  return (
    <span className="font-mono text-xs text-fg-faint">
      {JSON.stringify(constant)}
    </span>
  );
}

function BooleanField({ value, onChange }: FieldProps) {
  return (
    <Select
      value={value === undefined ? "" : String(value)}
      onChange={(event) => onChange(event.target.value === "true")}
    >
      <option value="" disabled>
        —
      </option>
      <option value="true">true</option>
      <option value="false">false</option>
    </Select>
  );
}

function NumberField({
  value,
  onChange,
  integer,
}: FieldProps & { integer: boolean }) {
  return (
    <Input
      type="number"
      step={integer ? 1 : "any"}
      value={typeof value === "number" ? value : ""}
      onChange={(event) => {
        const parsed = integer
          ? parseInt(event.target.value, 10)
          : Number(event.target.value);
        onChange(Number.isNaN(parsed) ? undefined : parsed);
      }}
    />
  );
}

function StringField({ value, onChange }: FieldProps) {
  return (
    <Input
      value={typeof value === "string" ? value : ""}
      onChange={(event) => onChange(event.target.value)}
    />
  );
}

function EnumField({
  value,
  onChange,
  options,
}: FieldProps & { options: Json[] }) {
  const index = options.findIndex(
    (option) => JSON.stringify(option) === JSON.stringify(value),
  );
  return (
    <Select
      value={index === -1 ? "" : String(index)}
      onChange={(event) => onChange(options[Number(event.target.value)])}
    >
      <option value="" disabled>
        —
      </option>
      {options.map((option, optionIndex) => (
        <option key={JSON.stringify(option)} value={optionIndex}>
          {JSON.stringify(option)}
        </option>
      ))}
    </Select>
  );
}

// ---------------------------------------------------------------------------
// Composites
// ---------------------------------------------------------------------------

function ObjectField({
  value,
  onChange,
  context,
  properties,
  required,
}: FieldProps & {
  properties: { [name: string]: Json };
  required: Set<string>;
}) {
  const record =
    typeof value === "object" && value !== null && !Array.isArray(value)
      ? value
      : {};
  const setField = (name: string, next: Json | undefined) => {
    const updated = { ...record };
    if (next === undefined) {
      delete updated[name];
    } else {
      updated[name] = next;
    }
    onChange(updated);
  };
  return (
    <Nested>
      {Object.entries(properties).map(([name, childSchema]) => (
        <div key={name} className="flex flex-col gap-1">
          <span className="text-xs font-medium text-fg-muted">
            {name}
            {!required.has(name) && (
              <span className="text-fg-faint"> (optional)</span>
            )}
          </span>
          <SchemaField
            schema={childSchema}
            value={record[name]}
            onChange={(next) => setField(name, next)}
            context={context}
          />
        </div>
      ))}
    </Nested>
  );
}

function RecordField({
  value,
  onChange,
  context,
  valueSchema,
}: FieldProps & { valueSchema: Json }) {
  const record =
    typeof value === "object" && value !== null && !Array.isArray(value)
      ? value
      : {};
  const entries = Object.entries(record);
  const rename = (from: string, to: string) => {
    const updated: { [key: string]: Json } = {};
    for (const [key, child] of entries)
      updated[key === from ? to : key] = child;
    onChange(updated);
  };
  return (
    <Nested>
      {entries.map(([key, child]) => (
        <div key={key} className="flex items-start gap-2">
          <Input
            defaultValue={key}
            onBlur={(event) => rename(key, event.target.value)}
            className="w-40"
            placeholder="key"
          />
          <div className="grow">
            <SchemaField
              schema={valueSchema}
              value={child}
              onChange={(next) => onChange({ ...record, [key]: next ?? null })}
              context={context}
            />
          </div>
          <RemoveButton
            onClick={() => {
              const { [key]: _removed, ...rest } = record;
              onChange(rest);
            }}
          />
        </div>
      ))}
      <AddButton
        label="Add entry"
        onClick={() => onChange({ ...record, "": null })}
      />
    </Nested>
  );
}

function ArrayField({
  value,
  onChange,
  context,
  itemSchema,
}: FieldProps & { itemSchema: Json }) {
  const items = Array.isArray(value) ? value : [];
  return (
    <Nested>
      {items.map((item, index) => (
        // Order is the identity of an array element being edited in place.
        // biome-ignore lint/suspicious/noArrayIndexKey: positional data
        <div key={index} className="flex items-start gap-2">
          <div className="grow">
            <SchemaField
              schema={itemSchema}
              value={item}
              onChange={(next) =>
                onChange(
                  items.map((old, at) => (at === index ? (next ?? null) : old)),
                )
              }
              context={context}
            />
          </div>
          <RemoveButton
            onClick={() => onChange(items.filter((_, at) => at !== index))}
          />
        </div>
      ))}
      <AddButton label="Add item" onClick={() => onChange([...items, null])} />
    </Nested>
  );
}

function TupleField({
  value,
  onChange,
  context,
  elements,
}: FieldProps & { elements: Json[] }) {
  const items = Array.isArray(value) ? value : elements.map(() => null);
  return (
    <Nested>
      {elements.map((elementSchema, index) => (
        <SchemaField
          // Fixed positional slots of the tuple type.
          // biome-ignore lint/suspicious/noArrayIndexKey: positional data
          key={index}
          schema={elementSchema}
          value={items[index]}
          onChange={(next) =>
            onChange(
              items.map((old, at) => (at === index ? (next ?? null) : old)),
            )
          }
          context={context}
        />
      ))}
    </Nested>
  );
}

function UnionField({
  value,
  onChange,
  context,
  branches,
}: FieldProps & { branches: Json[] }) {
  const [selected, setSelected] = useState(0);
  return (
    <Nested>
      <Select
        value={selected}
        onChange={(event) => {
          setSelected(Number(event.target.value));
          onChange(undefined);
        }}
      >
        {branches.map((branch, index) => (
          // Union branches are a fixed positional list from the schema.
          // biome-ignore lint/suspicious/noArrayIndexKey: positional data
          <option key={index} value={index}>
            {branchLabel(branch)}
          </option>
        ))}
      </Select>
      {branches[selected] !== undefined && (
        <SchemaField
          schema={branches[selected]}
          value={value}
          onChange={onChange}
          context={context}
        />
      )}
    </Nested>
  );
}

function branchLabel(branch: Json): string {
  if (typeof branch !== "object" || branch === null || Array.isArray(branch))
    return "…";
  const node = branch as JsonSchema;
  const properties = node.properties;
  if (
    typeof properties === "object" &&
    properties !== null &&
    !Array.isArray(properties) &&
    typeof (properties as { [key: string]: Json })[CONSTRUCTOR_KEY] === "object"
  ) {
    const tag = (properties as { [key: string]: JsonSchema })[CONSTRUCTOR_KEY];
    if (tag !== undefined && typeof tag.const === "string") return tag.const;
  }
  if (node.const !== undefined) return JSON.stringify(node.const);
  if (typeof node.type === "string") return node.type;
  return "…";
}

// ---------------------------------------------------------------------------
// Reference fields (file upload / agent handle) and the raw fallback
// ---------------------------------------------------------------------------

function FileField({ value, onChange, context }: FieldProps) {
  const toast = useToast();
  const [busy, setBusy] = useState(false);
  const current =
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value) &&
    FILE_KEY in value
      ? value
      : null;
  return (
    <div className="flex items-center gap-2">
      {current !== null && (
        <span className="font-mono text-xs text-fg-muted">
          file {String(current[FILE_KEY])}
        </span>
      )}
      <label className="inline-flex cursor-pointer items-center gap-1.5 border border-edge-strong px-2.5 py-1 text-xs text-fg hover:bg-sunken">
        <Upload className="size-3.5" />
        {busy ? "Uploading…" : current === null ? "Upload file" : "Replace"}
        <input
          type="file"
          className="hidden"
          disabled={busy}
          onChange={(event) => {
            const file = event.target.files?.[0];
            if (file === undefined) return;
            setBusy(true);
            api
              .uploadFile(context.projectId, file)
              .then((handle) =>
                onChange({
                  [FILE_KEY]: handle.id,
                  [SIZE_KEY]: handle.size,
                  [HASH_KEY]: handle.hash,
                  [CONTENT_TYPE_KEY]: file.type || "application/octet-stream",
                }),
              )
              .catch(() => toast("Upload failed.", "error"))
              .finally(() => setBusy(false));
          }}
        />
      </label>
    </div>
  );
}

function AgentField({ value, onChange, context }: FieldProps) {
  const current =
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value) &&
    AGENT_KEY in value
      ? String(value[AGENT_KEY])
      : "";
  return (
    <Input
      placeholder="qualified agent name (e.g. main.helper)"
      value={current}
      onChange={(event) =>
        onChange(
          event.target.value === ""
            ? undefined
            : {
                [AGENT_KEY]: event.target.value,
                [SNAPSHOT_KEY]: context.snapshotId,
              },
        )
      }
    />
  );
}

function JsonField({ value, onChange }: FieldProps) {
  const [text, setText] = useState(
    value === undefined ? "" : JSON.stringify(value, null, 2),
  );
  const [invalid, setInvalid] = useState(false);
  return (
    <TextArea
      value={text}
      placeholder="raw JSON"
      aria-invalid={invalid}
      className={invalid ? "border-danger" : undefined}
      onChange={(event) => {
        setText(event.target.value);
        if (event.target.value.trim() === "") {
          setInvalid(false);
          onChange(undefined);
          return;
        }
        try {
          onChange(JSON.parse(event.target.value) as Json);
          setInvalid(false);
        } catch {
          setInvalid(true);
        }
      }}
    />
  );
}

// ---------------------------------------------------------------------------
// Layout helpers local to the form
// ---------------------------------------------------------------------------

function Nested({ children }: { children: ReactNode }) {
  return (
    <div className="flex flex-col gap-2 border-l border-edge pl-3">
      {children}
    </div>
  );
}

function AddButton({ label, onClick }: { label: string; onClick: () => void }) {
  return (
    <Button size="sm" onClick={onClick} className="self-start">
      <Plus className="size-3.5" /> {label}
    </Button>
  );
}

function RemoveButton({ onClick }: { onClick: () => void }) {
  return (
    <Button size="sm" variant="ghost" onClick={onClick} title="Remove">
      <Trash2 className="size-3.5" />
    </Button>
  );
}
