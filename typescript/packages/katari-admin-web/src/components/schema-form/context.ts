import { createContext, useContext } from "react";
import type { SnapshotId } from "@/api/types";

/**
 * Ambient context a SchemaForm makes available to its fields. Carries the
 * snapshot the form's run will execute on so an agent picker can build the
 * external agent id (`qualified.name@snapshot`). Empty (no snapshot) outside
 * an invoke / answer form — an AgentField then falls back to the latest.
 */
export type SchemaFormContextValue = { snapshotId?: SnapshotId };

const SchemaFormContext = createContext<SchemaFormContextValue>({});

export const SchemaFormProvider = SchemaFormContext.Provider;

export function useSchemaFormContext(): SchemaFormContextValue {
  return useContext(SchemaFormContext);
}
