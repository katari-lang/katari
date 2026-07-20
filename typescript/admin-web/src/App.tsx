import { Navigate, Route, Routes } from "react-router-dom";
import { AppShell } from "./components/shell/AppShell";
import { AgentDetailPage } from "./pages/AgentDetailPage";
import { AgentsPage } from "./pages/AgentsPage";
import { CredentialsPage } from "./pages/CredentialsPage";
import { DashboardPage } from "./pages/DashboardPage";
import { EnvPage } from "./pages/EnvPage";
import { EscalationsPage } from "./pages/EscalationsPage";
import { FilesPage } from "./pages/FilesPage";
import { ProjectsPage } from "./pages/ProjectsPage";
import { RunDetailPage } from "./pages/RunDetailPage";
import { RunsPage } from "./pages/RunsPage";
import { SnapshotsPage } from "./pages/SnapshotsPage";
import { StorePage } from "./pages/StorePage";

export function App() {
  return (
    <Routes>
      <Route element={<AppShell />}>
        <Route path="/" element={<Navigate to="/projects" replace />} />
        <Route path="/projects" element={<ProjectsPage />} />
        <Route path="/projects/:projectId" element={<DashboardPage />} />
        <Route path="/projects/:projectId/runs" element={<RunsPage />} />
        <Route path="/projects/:projectId/runs/:runId" element={<RunDetailPage />} />
        <Route path="/projects/:projectId/agents" element={<AgentsPage />} />
        <Route path="/projects/:projectId/agents/:qualifiedName" element={<AgentDetailPage />} />
        <Route path="/projects/:projectId/escalations" element={<EscalationsPage />} />
        <Route path="/projects/:projectId/snapshots" element={<SnapshotsPage />} />
        <Route path="/projects/:projectId/files" element={<FilesPage />} />
        <Route path="/projects/:projectId/env" element={<EnvPage />} />
        <Route path="/projects/:projectId/store" element={<StorePage />} />
        <Route path="/projects/:projectId/credentials" element={<CredentialsPage />} />
      </Route>
    </Routes>
  );
}
