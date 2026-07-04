import { useNavigate } from "react-router-dom";
import { useProjects } from "../../api/queries";
import { Select } from "../ui/Field";

export function ProjectSwitcher({ currentProjectId }: { currentProjectId: string }) {
  const projects = useProjects();
  const navigate = useNavigate();
  return (
    <Select
      aria-label="Switch project"
      className="w-48"
      value={currentProjectId}
      onChange={(event) => navigate(`/projects/${event.target.value}`)}
    >
      {(projects.data ?? []).map((project) => (
        <option key={project.id} value={project.id}>
          {project.name}
        </option>
      ))}
    </Select>
  );
}
