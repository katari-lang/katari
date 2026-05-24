import { useQuery } from "@tanstack/react-query";
import { Camera, Check, History } from "lucide-react";
import { useApiClient } from "@/contexts/ApiKeyContext";
import { Dropdown, DropdownDivider, DropdownItem, DropdownLabel } from "@/components/ui/Dropdown";
import { shortId, relativeTime, formatDateTime } from "@/lib/format";
import { Button } from "@/components/ui/Button";
import type { ProjectId, SnapshotId } from "@/api/types";

type Props = {
  projectId: ProjectId;
  selected: SnapshotId | null;
  resolvedId: SnapshotId | null;
  onSelect: (snapshotId: SnapshotId | null) => void;
};

/**
 * Snapshot picker for the Definitions page header.
 *
 * `selected` is the operator's choice (= URL `?snapshot=...`); `null` =
 * "use latest". `resolvedId` is the actually-loaded snapshot id (latest
 * or the one chosen). Showing both lets the user see "you're viewing
 * snap_abc — which is also currently the latest".
 */
export function DefinitionsSnapshotPicker({ projectId, selected, resolvedId, onSelect }: Props) {
  const client = useApiClient();
  const { data } = useQuery({
    queryKey: ["snapshots", projectId],
    queryFn: () => client.listSnapshots(projectId, { limit: 200 }),
  });
  const snapshots = data?.snapshots ?? [];
  const resolvedSnap = snapshots.find((s) => s.id === resolvedId);

  const label = selected === null ? "Latest" : shortId(selected, 8, 4);

  const trigger = (
    <button
      type="button"
      className="inline-flex items-center gap-2  border border-border  px-3 py-1.5 text-sm transition-colors hover:bg-muted hover:cursor-pointer"
    >
      <Camera className="size-3.5 text-muted-foreground" />
      <span className="font-mono text-xs text-foreground">{label}</span>
      {resolvedSnap !== undefined && (
        <span className="text-[11px] text-subtle-foreground">
          {relativeTime(resolvedSnap.createdAt)}
        </span>
      )}
      <History className="size-3.5 text-subtle-foreground" />
    </button>
  );

  return (
    <div className="flex items-center gap-2">
      <Dropdown trigger={trigger} align="end" className="w-72">
        {(close) => (
          <div>
            <DropdownLabel>Snapshot history</DropdownLabel>
            <DropdownItem
              active={selected === null}
              onSelect={() => {
                close();
                onSelect(null);
              }}
            >
              <span className="flex-1">Latest</span>
              {selected === null && <Check className="size-4" />}
            </DropdownItem>
            <DropdownDivider />
            {snapshots.length === 0 ? (
              <p className="px-3 py-3 text-xs text-subtle-foreground">No snapshots.</p>
            ) : (
              <div className="max-h-80 overflow-y-auto">
                {snapshots.map((s) => (
                  <DropdownItem
                    key={s.id}
                    active={s.id === selected}
                    onSelect={() => {
                      close();
                      onSelect(s.id);
                    }}
                  >
                    <div className="flex-1">
                      <div className="font-mono text-xs text-foreground">
                        {shortId(s.id, 12, 4)}
                      </div>
                      <div
                        className="mt-0.5 text-[11px] text-subtle-foreground"
                        title={formatDateTime(s.createdAt)}
                      >
                        {relativeTime(s.createdAt)}
                      </div>
                    </div>
                    {s.id === selected && <Check className="size-4" />}
                  </DropdownItem>
                ))}
              </div>
            )}
          </div>
        )}
      </Dropdown>
      {selected !== null && (
        <Button variant="ghost" size="sm" onClick={() => onSelect(null)}>
          Reset to latest
        </Button>
      )}
    </div>
  );
}
