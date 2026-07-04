import { Outlet, useLocation } from "react-router-dom";
import { ErrorBoundary } from "./ErrorBoundary";
import { Sidebar } from "./Sidebar";
import { TopBar } from "./TopBar";

/** Frame of every project-scoped page: top bar, project sidebar, scrolling content. */
export function AppShell() {
  const location = useLocation();
  return (
    <div className="flex h-dvh flex-col">
      <TopBar />
      <div className="flex min-h-0 grow">
        <Sidebar />
        <main className="min-w-0 grow overflow-y-auto">
          <div className="mx-auto max-w-6xl p-6">
            {/* Keyed by path so navigating away from a crashed page recovers on its own. */}
            <ErrorBoundary key={location.pathname}>
              <Outlet />
            </ErrorBoundary>
          </div>
        </main>
      </div>
    </div>
  );
}
