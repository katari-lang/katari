import { useMemo, useState } from "react";
import { SelectMenu } from "@/components/ui/SelectMenu";
import { SchemaField } from "../SchemaField";
import { branchLabel, type JsonSchema, schemaInitialValue, taggedCtorOf } from "../schema-utils";

/**
 * Generic union picker. Renders a dropdown of branch labels plus the
 * SchemaField for the selected branch. Tagged unions (= every branch is
 * a `data` ctor with `$constructor: {const: "..."}`) get ctor-named options;
 * other unions fall back to type names / titles.
 *
 * Switching branches resets the value to that branch's initial — there's
 * no general way to convert between branches' shapes.
 */
export function UnionField({
  branches,
  value,
  onChange,
}: {
  branches: JsonSchema[];
  value: unknown;
  onChange: (v: unknown) => void;
}) {
  // Initial branch: if value carries a $constructor tag matching one branch,
  // use that. Otherwise default to the first.
  const initialIdx = useMemo(() => detectBranch(value, branches), [value, branches]);
  const [branchIdx, setBranchIdx] = useState(initialIdx);

  function selectBranch(idx: number) {
    setBranchIdx(idx);
    onChange(schemaInitialValue(branches[idx]!));
  }

  const labels = useMemo(() => branches.map((b, i) => branchLabel(b, i)), [branches]);

  return (
    <div className="space-y-2">
      <div className="flex items-center gap-2">
        <div className="w-fit min-w-48">
          <SelectMenu
            value={String(branchIdx)}
            options={labels.map((label, i) => ({ key: String(i), label }))}
            onChange={(key) => selectBranch(Number(key))}
          />
        </div>
      </div>
      <SchemaField schema={branches[branchIdx]!} value={value} onChange={onChange} />
    </div>
  );
}

function detectBranch(value: unknown, branches: JsonSchema[]): number {
  if (value !== null && typeof value === "object" && !Array.isArray(value)) {
    const v = value as Record<string, unknown>;
    const tag = v["$constructor"];
    if (typeof tag === "string") {
      const idx = branches.findIndex((b) => taggedCtorOf(b) === tag);
      if (idx >= 0) return idx;
    }
  }
  // No tag match → first branch.
  return 0;
}
