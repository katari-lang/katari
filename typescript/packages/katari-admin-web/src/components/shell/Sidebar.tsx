import { SidebarProjectSwitcher } from "./SidebarProjectSwitcher";
import { SidebarMenu } from "./SidebarMenu";

export function Sidebar() {
  return (
    <aside className="sticky top-14 flex h-[calc(100vh-3.5rem)] w-64 shrink-0 flex-col">
      <div className="p-3">
        <SidebarProjectSwitcher />
      </div>
      <div className="flex-1 overflow-y-auto">
        <SidebarMenu />
      </div>
    </aside>
  );
}
