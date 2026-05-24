import { NavLink } from "react-router-dom";
import {
  LayoutDashboard,
  Activity,
  Boxes,
  MessageCircleQuestion,
  KeyRound,
  Settings,
} from "lucide-react";
import { cn } from "@/lib/cn";
import { useStickyProjectId } from "@/lib/useStickyProjectId";
import type { ComponentType, SVGProps } from "react";

type MenuItem = {
  to: string;
  label: string;
  icon: ComponentType<SVGProps<SVGSVGElement>>;
};

function projectItems(projectId: string): MenuItem[] {
  return [
    { to: `/project/${projectId}`, label: "Dashboard", icon: LayoutDashboard },
    { to: `/project/${projectId}/runs`, label: "Runs", icon: Activity },
    {
      to: `/project/${projectId}/definitions`,
      label: "Definitions",
      icon: Boxes,
    },
    {
      to: `/project/${projectId}/escalations`,
      label: "Escalations",
      icon: MessageCircleQuestion,
    },
  ];
}

const globalItems: MenuItem[] = [
  { to: "/env", label: "Env", icon: KeyRound },
  { to: "/settings", label: "Settings", icon: Settings },
];

export function SidebarMenu() {
  const projectId = useStickyProjectId();
  const projectMenu = projectId === null ? [] : projectItems(projectId);

  return (
    <nav className="flex flex-col gap-4 p-3">
      <div className="space-y-1">
        <SectionLabel>Project</SectionLabel>
        {projectId === null ? (
          <p className="px-2 py-1.5 text-xs text-subtle-foreground">
            Select a project to navigate.
          </p>
        ) : (
          <ul>
            {projectMenu.map((item) => (
              <MenuLink
                key={item.to}
                item={item}
                end={item.to === `/project/${projectId}`}
              />
            ))}
          </ul>
        )}
      </div>
      <div className="space-y-1">
        <SectionLabel>Runtime</SectionLabel>
        <ul>
          {globalItems.map((item) => (
            <MenuLink key={item.to} item={item} />
          ))}
        </ul>
      </div>
    </nav>
  );
}

function SectionLabel({ children }: { children: React.ReactNode }) {
  return (
    <p className="px-2 text-[10px] font-semibold uppercase tracking-wider text-muted-foreground">
      {children}
    </p>
  );
}

function MenuLink({ item, end }: { item: MenuItem; end?: boolean }) {
  const Icon = item.icon;
  return (
    <li>
      <NavLink
        to={item.to}
        end={end}
        className={({ isActive }) =>
          cn(
            // Left-border highlight (katari-web docs sidebar style) — no fill.
            "-ml-px flex items-center gap-2 py-2 pl-3 text-sm transition-colors",
            isActive
              ? "bg-accent font-medium text-accent-foreground"
              : "text-muted-foreground hover:border-border-strong hover:text-foreground",
          )
        }
      >
        <Icon className="size-4" />
        {item.label}
      </NavLink>
    </li>
  );
}
