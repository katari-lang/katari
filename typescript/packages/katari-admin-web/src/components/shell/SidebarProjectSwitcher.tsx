import { useQuery } from "@tanstack/react-query";
import { Check, ChevronsUpDown, Folder } from "lucide-react";
import { useNavigate } from "react-router-dom";
import { Dropdown, DropdownDivider, DropdownItem, DropdownLabel } from "@/components/ui/Dropdown";
import { useApiClient, useApiKey } from "@/contexts/ApiKeyContext";
import { useStickyProjectId } from "@/lib/useStickyProjectId";

export function SidebarProjectSwitcher() {
  const { apiKey } = useApiKey();
  const client = useApiClient();
  const stickyId = useStickyProjectId();
  const navigate = useNavigate();

  const { data } = useQuery({
    queryKey: ["projects", "sidebar"],
    queryFn: () => client.listProjects({ limit: 200 }),
    enabled: apiKey !== null,
  });

  const projects = data?.projects ?? [];
  const current = projects.find((p) => p.id === stickyId);

  const trigger = (
    <button
      type="button"
      className="flex w-full items-center gap-2 border border-border bg-transparent px-2.5 py-2 text-left text-sm transition-colors hover:bg-muted hover:border-border-strong hover:cursor-pointer"
    >
      <Folder className="size-4 shrink-0 text-muted-foreground" />
      <span className="flex-1 truncate text-foreground">{current?.name ?? "All projects"}</span>
      <ChevronsUpDown className="size-3.5 shrink-0 text-subtle-foreground" />
    </button>
  );

  return (
    <Dropdown trigger={trigger} className="w-58">
      {(close) => (
        <div>
          <DropdownLabel>Switch project</DropdownLabel>
          {projects.length === 0 ? (
            <div className="px-3 py-3 text-xs text-subtle-foreground">No projects yet.</div>
          ) : (
            <div className="max-h-72 overflow-y-auto">
              {projects.map((p) => (
                <DropdownItem
                  key={p.id}
                  active={p.id === stickyId}
                  onSelect={() => {
                    close();
                    navigate(`/project/${p.id}`);
                  }}
                >
                  <span className="flex-1 truncate">{p.name}</span>
                  {p.id === stickyId && <Check className="size-4" />}
                </DropdownItem>
              ))}
            </div>
          )}
          <DropdownDivider />
          <DropdownItem
            onSelect={() => {
              close();
              navigate("/projects");
            }}
          >
            View all projects →
          </DropdownItem>
        </div>
      )}
    </Dropdown>
  );
}
