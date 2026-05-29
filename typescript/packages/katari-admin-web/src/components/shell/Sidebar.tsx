import { Globe } from "lucide-react";
import { cn } from "@/lib/cn";
import { SidebarMenu } from "./SidebarMenu";
import { SidebarProjectSwitcher } from "./SidebarProjectSwitcher";

type SidebarProps = {
  open: boolean;
  onClose: () => void;
};

export function Sidebar({ open, onClose }: SidebarProps) {
  return (
    <>
      {/* Backdrop overlay -- mobile only */}
      {open && (
        <div
          className="fixed inset-0 z-40 bg-katari-950/30 backdrop-blur-sm md:hidden"
          onClick={onClose}
        />
      )}

      <aside
        className={cn(
          "fixed top-14 z-40 flex h-[calc(100vh-3.5rem)] w-64 shrink-0 flex-col bg-background transition-transform duration-200",
          "md:sticky md:translate-x-0",
          open ? "translate-x-0" : "-translate-x-full",
        )}
      >
        <div className="p-3">
          <SidebarProjectSwitcher />
        </div>
        <div className="flex-1 overflow-y-auto">
          <SidebarMenu />
        </div>
        <SidebarFooter />
      </aside>
    </>
  );
}

function GitHubMark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true" className={className}>
      <path d="M12 .5C5.73.5.67 5.56.67 11.83c0 5.01 3.24 9.25 7.74 10.75.57.11.78-.25.78-.55 0-.27-.01-1.16-.01-2.11-3.15.59-3.96-.77-4.21-1.48-.14-.36-.74-1.48-1.27-1.78-.43-.23-1.05-.79-.02-.81.97-.02 1.66.9 1.89 1.27 1.11 1.86 2.87 1.34 3.58 1.02.11-.8.43-1.34.78-1.65-2.79-.31-5.71-1.4-5.71-6.21 0-1.37.49-2.5 1.29-3.39-.13-.31-.56-1.6.12-3.33 0 0 1.05-.34 3.45 1.29.99-.28 2.06-.42 3.12-.42 1.06 0 2.13.14 3.12.42 2.4-1.64 3.45-1.29 3.45-1.29.69 1.73.25 3.02.12 3.33.81.89 1.29 2.02 1.29 3.39 0 4.83-2.93 5.9-5.72 6.21.45.39.85 1.14.85 2.3 0 1.66-.02 3-.02 3.41 0 .31.21.67.79.55 4.48-1.5 7.72-5.75 7.72-10.75C23.33 5.56 18.27.5 12 .5Z" />
    </svg>
  );
}

function SidebarFooter() {
  return (
    <div className="flex items-center gap-3 h-12 px-4 py-3 text-xs text-subtle-foreground">
      <a
        href="https://katari-lang.dev"
        target="_blank"
        rel="noreferrer noopener"
        className="inline-flex h-full items-center gap-1.5 transition-colors hover:text-foreground"
      >
        <Globe className="size-3.5" />
        katari-lang.dev
      </a>
      <a
        href="https://github.com/katari-lang/katari"
        target="_blank"
        rel="noreferrer noopener"
        aria-label="katari on GitHub"
        className="inline-flex items-center transition-colors hover:text-foreground h-full aspect-square"
      >
        <GitHubMark className="size-3.5" />
      </a>
    </div>
  );
}
