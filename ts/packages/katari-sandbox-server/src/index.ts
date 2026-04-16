import { startServer } from "katari-protocol";
import type { AgentHandlerFn, JsonValue } from "katari-protocol";
import { Sandbox } from "@e2b/code-interpreter";

// ===========================================================================
// Sandbox management
// ===========================================================================

const sandboxes = new Map<string, Sandbox>();

const E2B_TEMPLATE = process.env.E2B_TEMPLATE ?? undefined;

// ===========================================================================
// Handlers
// ===========================================================================

const create: AgentHandlerFn = async () => {
  const sandbox = await Sandbox.create(E2B_TEMPLATE ?? "base", {
    allowInternetAccess: false,
    timeoutMs: 5 * 60 * 1000, // 5 minutes
  });
  const sandboxId = sandbox.sandboxId;
  sandboxes.set(sandboxId, sandbox);
  console.log(`Sandbox created: ${sandboxId}`);
  return sandboxId as JsonValue;
};

const exec: AgentHandlerFn = async (args) => {
  const a = args as Record<string, JsonValue>;
  const sandboxId = a.sandbox_id as string;
  const command = a.command as string;

  const sandbox = sandboxes.get(sandboxId);
  if (!sandbox) throw new Error(`Sandbox ${sandboxId} not found`);

  const result = await sandbox.commands.run(command);
  return {
    stdout: result.stdout,
    stderr: result.stderr,
    exitCode: result.exitCode,
  } as unknown as JsonValue;
};

const writeFile: AgentHandlerFn = async (args) => {
  const a = args as Record<string, JsonValue>;
  const sandboxId = a.sandbox_id as string;
  const filePath = a.path as string;
  const content = a.content as string;

  const sandbox = sandboxes.get(sandboxId);
  if (!sandbox) throw new Error(`Sandbox ${sandboxId} not found`);

  await sandbox.files.write(filePath, content);
  return null;
};

const readFile: AgentHandlerFn = async (args) => {
  const a = args as Record<string, JsonValue>;
  const sandboxId = a.sandbox_id as string;
  const filePath = a.path as string;

  const sandbox = sandboxes.get(sandboxId);
  if (!sandbox) throw new Error(`Sandbox ${sandboxId} not found`);

  const content = await sandbox.files.read(filePath);
  return content as JsonValue;
};

const destroy: AgentHandlerFn = async (args) => {
  const a = args as Record<string, JsonValue>;
  const sandboxId = a.sandbox_id as string;

  const sandbox = sandboxes.get(sandboxId);
  if (!sandbox) throw new Error(`Sandbox ${sandboxId} not found`);

  await sandbox.kill();
  sandboxes.delete(sandboxId);
  console.log(`Sandbox destroyed: ${sandboxId}`);
  return null;
};

// ===========================================================================
// Start
// ===========================================================================

const port = parseInt(process.env.PORT ?? "8005", 10);
const endpoint = process.env.KATARI_BASE_URL ?? `http://localhost:${port}`;
const databaseUrl = process.env.DATABASE_URL;

startServer({
  port,
  endpoint,
  databaseUrl,
  agentDefs: {
    create: { handler: create, description: "Create a cloud sandbox" },
    exec: { handler: exec, description: "Execute a command in a sandbox" },
    write_file: {
      handler: writeFile,
      description: "Write a file in a sandbox",
    },
    read_file: { handler: readFile, description: "Read a file from a sandbox" },
    destroy: { handler: destroy, description: "Destroy a sandbox" },
  },
});
