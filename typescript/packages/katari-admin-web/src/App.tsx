import { Navigate, Outlet, Route, Routes, useLocation } from "react-router-dom";
import { AppShell } from "@/components/shell/AppShell";
import { ErrorBoundary } from "@/components/shell/ErrorBoundary";
import { ApiKeyProvider, useApiKey } from "@/contexts/ApiKeyContext";
import { AgentDetailPage } from "@/pages/AgentDetailPage";
import { AgentsPage } from "@/pages/AgentsPage";
import { DashboardPage } from "@/pages/DashboardPage";
import { EnvPage } from "@/pages/EnvPage";
import { EscalationDetailPage } from "@/pages/EscalationDetailPage";
import { EscalationsPage } from "@/pages/EscalationsPage";
import { FilesPage } from "@/pages/FilesPage";
import { LoginPage } from "@/pages/LoginPage";
import { PlaceholderPage } from "@/pages/PlaceholderPage";
import { ProjectsPage } from "@/pages/ProjectsPage";
import { RunDetailPage } from "@/pages/RunDetailPage";
import { RunsPage } from "@/pages/RunsPage";
import { SettingsPage } from "@/pages/SettingsPage";

export default function App() {
  return (
    <ErrorBoundary>
      <ApiKeyProvider>
        <Routes>
          <Route path="/login" element={<LoginPage />} />
          <Route element={<AuthGate />}>
            <Route element={<ShellLayout />}>
              <Route path="/" element={<Navigate to="/projects" replace />} />
              <Route path="/projects" element={<ProjectsPage />} />
              <Route path="/project/:projectId">
                <Route index element={<DashboardPage />} />
                <Route path="runs" element={<RunsPage />} />
                <Route path="runs/:runId" element={<RunDetailPage />} />
                <Route path="agents" element={<AgentsPage />} />
                <Route path="agents/:qualifiedName" element={<AgentDetailPage />} />
                <Route path="escalations" element={<EscalationsPage />} />
                <Route path="escalations/:escalationId" element={<EscalationDetailPage />} />
                <Route path="files" element={<FilesPage />} />
                <Route path="env" element={<EnvPage />} />
              </Route>
              <Route path="/settings" element={<SettingsPage />} />
              <Route path="*" element={<PlaceholderPage title="Not found" />} />
            </Route>
          </Route>
        </Routes>
      </ApiKeyProvider>
    </ErrorBoundary>
  );
}

function AuthGate() {
  const { apiKey } = useApiKey();
  const location = useLocation();
  if (apiKey === null) {
    const redirect = encodeURIComponent(location.pathname + location.search);
    return <Navigate to={`/login?redirect=${redirect}`} replace />;
  }
  return <Outlet />;
}

function ShellLayout() {
  return (
    <AppShell>
      <Outlet />
    </AppShell>
  );
}
