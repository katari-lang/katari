import { cn } from "@/lib/cn";

type Schema = Record<string, unknown>;

/**
 * Visual display for JSON Schema objects. Renders the schema as a
 * structured tree with type badges and border-l-2 indentation for
 * nested properties.
 */
export function SchemaViewer({
  schema,
  className,
}: {
  schema: unknown;
  className?: string;
}) {
  if (schema === undefined || schema === null) {
    return <span className="text-xs text-subtle-foreground italic">none</span>;
  }

  const schemaObj =
    typeof schema === "object" && !Array.isArray(schema)
      ? (schema as Schema)
      : null;

  if (schemaObj === null) {
    return (
      <span className="text-xs font-mono text-foreground">
        {JSON.stringify(schema)}
      </span>
    );
  }

  return (
    <div className={cn("relative", className)}>
      <SchemaNode schema={schemaObj} />
    </div>
  );
}

function TypeBadge({
  children,
  className,
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <span className={cn("text-xs font-mono text-muted-foreground", className)}>
      {children}
    </span>
  );
}

function RequiredBadge() {
  return (
    <span className="text-xs uppercase tracking-wider text-danger font-medium">
      required
    </span>
  );
}

function Description({ text }: { text: string }) {
  return <p className="text-xs text-subtle-foreground mt-0.5">{text}</p>;
}

function SchemaNode({ schema }: { schema: Schema }) {
  const description =
    typeof schema.description === "string" ? schema.description : null;

  // never: empty anyOf / oneOf
  if (isNeverSchema(schema)) {
    return (
      <div>
        <TypeBadge className="text-warning">never</TypeBadge>
        {description !== null && <Description text={description} />}
      </div>
    );
  }

  // anyOf / oneOf union
  const anyOf = Array.isArray(schema.anyOf) ? (schema.anyOf as Schema[]) : null;
  const oneOf = Array.isArray(schema.oneOf) ? (schema.oneOf as Schema[]) : null;
  const branches = anyOf ?? oneOf;
  if (branches !== null && branches.length > 0) {
    return (
      <div>
        <span className="text-xs font-medium text-muted-foreground">
          one of
        </span>
        {description !== null && <Description text={description} />}
        <div className="border-l-2 border-border mt-2">
          <div className="space-y-2 pl-3">
            {branches.map((branch, index) => (
              <div key={index}>
                <SchemaNode schema={branch} />
              </div>
            ))}
          </div>
        </div>
      </div>
    );
  }

  // enum
  if (Array.isArray(schema.enum) && schema.enum.length > 0) {
    return (
      <div>
        <span className="text-xs font-medium text-muted-foreground mr-1.5">
          enum
        </span>
        <span className="inline-flex flex-wrap items-center gap-1">
          {(schema.enum as unknown[]).map((value, index) => (
            <TypeBadge key={index}>{JSON.stringify(value)}</TypeBadge>
          ))}
        </span>
        {description !== null && <Description text={description} />}
      </div>
    );
  }

  // const
  if (schema.const !== undefined) {
    return (
      <div>
        <span className="text-xs font-medium text-muted-foreground mr-1.5">
          const
        </span>
        <TypeBadge>{JSON.stringify(schema.const)}</TypeBadge>
        {description !== null && <Description text={description} />}
      </div>
    );
  }

  const type = singleType(schema);

  // object — check for $constructor const pattern
  if (type === "object") {
    const properties =
      typeof schema.properties === "object" && schema.properties !== null
        ? (schema.properties as Record<string, Schema>)
        : null;
    const requiredSet = new Set(
      Array.isArray(schema.required) ? (schema.required as string[]) : [],
    );

    // Detect $constructor with const value
    const constructorSchema = properties?.$constructor;
    const constructorName =
      constructorSchema !== undefined &&
      constructorSchema.const !== undefined &&
      typeof constructorSchema.const === "string"
        ? constructorSchema.const
        : null;

    const displayProperties =
      properties !== null
        ? Object.entries(properties).filter(([key]) =>
            constructorName !== null ? key !== "$constructor" : true,
          )
        : [];
    const hasAdditional =
      schema.additionalProperties !== undefined &&
      schema.additionalProperties !== false;
    const isRecord = displayProperties.length === 0 && hasAdditional;
    const typeLabel = constructorName ?? (isRecord ? "record" : "object");
    const additionalSchema =
      typeof schema.additionalProperties === "object" &&
      schema.additionalProperties !== null
        ? (schema.additionalProperties as Schema)
        : null;

    return (
      <div>
        <TypeBadge>{typeLabel}</TypeBadge>
        {description !== null && <Description text={description} />}
        {displayProperties.length > 0 && (
          <div className="border-l-2 border-border mt-1">
            <div className="space-y-2 pl-3">
              {displayProperties.map(([key, propSchema]) => (
                <div key={key}>
                  <div className="flex items-baseline gap-1.5">
                    <span className="text-sm font-medium text-foreground">
                      {key}
                    </span>
                    {requiredSet.has(key) && <RequiredBadge />}
                  </div>
                  <div>
                    <SchemaNode schema={propSchema} />
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}
        {isRecord && additionalSchema !== null && (
          <div className="border-l-2 border-border mt-2">
            <div className="pl-3">
              <span className="text-xs text-muted-foreground">values</span>
              <div className="mt-1">
                <SchemaNode schema={additionalSchema} />
              </div>
            </div>
          </div>
        )}
        {displayProperties.length === 0 && !isRecord && (
          <span className="text-xs italic text-subtle-foreground ml-1.5">
            Empty object
          </span>
        )}
      </div>
    );
  }

  // array
  if (type === "array") {
    const items =
      typeof schema.items === "object" &&
      schema.items !== null &&
      !Array.isArray(schema.items)
        ? (schema.items as Schema)
        : null;
    const prefixItems = Array.isArray(schema.prefixItems)
      ? (schema.prefixItems as Schema[])
      : null;

    return (
      <div>
        <TypeBadge>array</TypeBadge>
        {description !== null && <Description text={description} />}
        {prefixItems !== null && prefixItems.length > 0 && (
          <div className="border-l-2 border-border mt-2">
            <div className="space-y-2 pl-3">
              {prefixItems.map((itemSchema, index) => (
                <div key={index}>
                  <span className="inline-flex items-center px-1.5 py-0.5 text-xs font-mono text-muted-foreground bg-muted mb-1">
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
          <div className="border-l-2 border-border pl-3 mt-2">
            <span className="text-xs text-muted-foreground">items</span>
            <div className="mt-1">
              <SchemaNode schema={items} />
            </div>
          </div>
        )}
      </div>
    );
  }

  // Primitive types: string, number, integer, boolean, null
  if (type !== undefined) {
    return (
      <div>
        <TypeBadge>{type}</TypeBadge>
        {description !== null && <Description text={description} />}
      </div>
    );
  }

  // Unknown / empty schema (= "any")
  const keys = Object.keys(schema).filter(
    (k) => k !== "description" && k !== "title" && k !== "default",
  );
  if (keys.length === 0) {
    return (
      <div>
        <TypeBadge className="text-subtle-foreground">any</TypeBadge>
        {description !== null && <Description text={description} />}
      </div>
    );
  }

  // Fallback: render as JSON
  return (
    <div>
      <pre className="text-xs font-mono text-foreground whitespace-pre-wrap">
        {JSON.stringify(schema, null, 2)}
      </pre>
    </div>
  );
}

// --- local helpers (duplicated from schema-utils to avoid coupling
//     read-only viewer to form-field internals) ---

function singleType(schema: Schema): string | undefined {
  if (typeof schema.type === "string") return schema.type;
  if (Array.isArray(schema.type)) {
    const nonNull = (schema.type as string[]).filter((t) => t !== "null");
    if (nonNull.length === 1) return nonNull[0];
  }
  return undefined;
}

function isNeverSchema(schema: Schema): boolean {
  // `not: {}` is the canonical never
  if (
    typeof schema.not === "object" &&
    schema.not !== null &&
    Object.keys(schema.not).length === 0
  ) {
    return true;
  }
  // empty anyOf / oneOf = never
  if (Array.isArray(schema.anyOf) && schema.anyOf.length === 0) return true;
  if (Array.isArray(schema.oneOf) && schema.oneOf.length === 0) return true;
  return false;
}
