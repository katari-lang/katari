import { FolderGit2, Plus } from "lucide-react";
import { useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { ApiError, api } from "../api/client";
import { useProjects } from "../api/queries";
import { Button } from "../components/ui/Button";
import { Card, CardBody } from "../components/ui/Card";
import { Dialog } from "../components/ui/Dialog";
import { EmptyState } from "../components/ui/EmptyState";
import { Input, Label, TextArea } from "../components/ui/Field";
import { PageHeader } from "../components/ui/PageHeader";
import { LoadingBlock } from "../components/ui/Spinner";
import { formatDateTime, relativeTime } from "../lib/format";
import { useToast } from "../lib/toast";

export function ProjectsPage() {
  const projects = useProjects();
  const [creating, setCreating] = useState(false);

  return (
    <>
      <PageHeader
        title="Projects"
        description="Every project this runtime hosts."
        actions={
          <Button variant="primary" onClick={() => setCreating(true)}>
            <Plus className="size-4" /> New project
          </Button>
        }
      />
      {projects.isPending ? (
        <LoadingBlock />
      ) : (projects.data ?? []).length === 0 ? (
        <EmptyState
          icon={FolderGit2}
          title="No projects yet"
          description="Create one here, or run `katari apply` from a project directory to deploy it."
          action={<Button onClick={() => setCreating(true)}>New project</Button>}
        />
      ) : (
        <div className="grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-3">
          {(projects.data ?? []).map((project) => (
            <Link key={project.id} to={`/projects/${project.id}`}>
              <Card className="h-full transition-colors hover:border-edge-strong">
                <CardBody className="flex h-full flex-col gap-1">
                  <p className="font-semibold text-fg">{project.name}</p>
                  {project.description !== null && (
                    <p className="line-clamp-2 text-sm text-fg-muted">{project.description}</p>
                  )}
                  <p
                    className="pt-1 text-xs text-fg-faint"
                    title={formatDateTime(project.createdAt)}
                  >
                    created {relativeTime(project.createdAt)}
                  </p>
                </CardBody>
              </Card>
            </Link>
          ))}
        </div>
      )}
      <CreateProjectDialog open={creating} onClose={() => setCreating(false)} />
    </>
  );
}

function CreateProjectDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const toast = useToast();
  const navigate = useNavigate();
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [busy, setBusy] = useState(false);

  const create = async () => {
    setBusy(true);
    try {
      const project = await api.createProject({
        name,
        ...(description === "" ? {} : { description }),
      });
      navigate(`/projects/${project.id}`);
    } catch (error) {
      toast(error instanceof ApiError ? error.message : "Create failed.", "error");
    } finally {
      setBusy(false);
    }
  };

  return (
    <Dialog open={open} onClose={onClose} title="New project">
      <div className="flex flex-col gap-3">
        <Label text="Name">
          <Input
            value={name}
            onChange={(event) => setName(event.target.value)}
            placeholder="my-project"
          />
        </Label>
        <Label text="Description" hint="optional">
          <TextArea
            value={description}
            onChange={(event) => setDescription(event.target.value)}
            className="min-h-14 font-sans"
          />
        </Label>
        <div className="flex justify-end gap-2 pt-1">
          <Button onClick={onClose}>Cancel</Button>
          <Button
            variant="primary"
            disabled={name === ""}
            loading={busy}
            onClick={() => void create()}
          >
            Create
          </Button>
        </div>
      </div>
    </Dialog>
  );
}
