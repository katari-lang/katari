import { Navigate, Outlet, Route, Routes, useLocation } from "react-router-dom";
import { ApiKeyProvider, useApiKey } from "@/contexts/ApiKeyContext";
import { AppShell } from "@/components/shell/AppShell";
import { LoginPage } from "@/pages/LoginPage";
import { ProjectsPage } from "@/pages/ProjectsPage";
import { DashboardPage } from "@/pages/DashboardPage";
import { RunsPage } from "@/pages/RunsPage";
import { RunDetailPage } from "@/pages/RunDetailPage";
import { RunTreePage } from "@/pages/RunTreePage";
import { DefinitionsPage } from "@/pages/DefinitionsPage";
import { DefinitionDetailPage } from "@/pages/DefinitionDetailPage";
import { EscalationsPage } from "@/pages/EscalationsPage";
import { EscalationDetailPage } from "@/pages/EscalationDetailPage";
import { EnvPage } from "@/pages/EnvPage";
import { SettingsPage } from "@/pages/SettingsPage";
import { PlaceholderPage } from "@/pages/PlaceholderPage";

export default function App() {
  return (
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
              <Route path="runs/:runId/tree" element={<RunTreePage />} />
              <Route path="definitions" element={<DefinitionsPage />} />
              <Route path="definitions/:qualifiedName" element={<DefinitionDetailPage />} />
              <Route path="escalations" element={<EscalationsPage />} />
              <Route path="escalations/:escalationId" element={<EscalationDetailPage />} />
            </Route>
            <Route path="/env" element={<EnvPage />} />
            <Route path="/settings" element={<SettingsPage />} />
            <Route path="*" element={<PlaceholderPage title="Not found" />} />
          </Route>
        </Route>
      </Routes>
    </ApiKeyProvider>
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
