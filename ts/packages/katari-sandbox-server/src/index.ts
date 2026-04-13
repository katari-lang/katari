import { startServer } from "katari-protocol";
import type { AgentHandlerFn, JsonValue } from "katari-protocol";
import Docker from "dockerode";
import { Readable } from "node:stream";

const docker = new Docker();
const sandboxes = new Map<string, { containerId: string }>();

const SANDBOX_IMAGE = process.env.SANDBOX_IMAGE ?? "node:22-alpine";

async function ensureImage(): Promise<void> {
  try {
    await docker.getImage(SANDBOX_IMAGE).inspect();
  } catch {
    console.log(`Pulling image ${SANDBOX_IMAGE}...`);
    const stream = await docker.pull(SANDBOX_IMAGE);
    await new Promise<void>((resolve, reject) => {
      docker.modem.followProgress(stream, (err: Error | null) =>
        err ? reject(err) : resolve()
      );
    });
  }
}

const create: AgentHandlerFn = async () => {
  await ensureImage();
  const container = await docker.createContainer({
    Image: SANDBOX_IMAGE,
    Cmd: ["sleep", "infinity"],
    NetworkDisabled: true,
    HostConfig: {
      Memory: 256 * 1024 * 1024,
      CpuPeriod: 100000,
      CpuQuota: 50000,
    },
  });
  await container.start();
  const sandboxId = container.id.slice(0, 12);
  sandboxes.set(sandboxId, { containerId: container.id });
  console.log(`Sandbox created: ${sandboxId}`);
  return sandboxId as JsonValue;
};

const exec: AgentHandlerFn = async (args) => {
  const sandboxId = args[0] as string;
  const command = args[1] as string;

  const sandbox = sandboxes.get(sandboxId);
  if (!sandbox) throw new Error(`Sandbox ${sandboxId} not found`);

  const container = docker.getContainer(sandbox.containerId);
  const execution = await container.exec({
    Cmd: ["sh", "-c", command],
    AttachStdout: true,
    AttachStderr: true,
  });
  const stream = await execution.start({ Detach: false, Tty: false });

  const output = await streamToString(stream);
  return output as JsonValue;
};

const writeFile: AgentHandlerFn = async (args) => {
  const sandboxId = args[0] as string;
  const filePath = args[1] as string;
  const content = args[2] as string;

  const sandbox = sandboxes.get(sandboxId);
  if (!sandbox) throw new Error(`Sandbox ${sandboxId} not found`);

  const container = docker.getContainer(sandbox.containerId);

  // Use exec to write file via sh
  const execution = await container.exec({
    Cmd: ["sh", "-c", `mkdir -p "$(dirname '${filePath}')" && cat > '${filePath}'`],
    AttachStdin: true,
    AttachStdout: true,
    AttachStderr: true,
  });
  const stream = await execution.start({ hijack: true, stdin: true });
  stream.write(content);
  stream.end();
  await new Promise<void>((resolve) => stream.on("end", resolve));

  return null;
};

const readFile: AgentHandlerFn = async (args) => {
  const sandboxId = args[0] as string;
  const filePath = args[1] as string;

  const sandbox = sandboxes.get(sandboxId);
  if (!sandbox) throw new Error(`Sandbox ${sandboxId} not found`);

  const container = docker.getContainer(sandbox.containerId);
  const execution = await container.exec({
    Cmd: ["cat", filePath],
    AttachStdout: true,
    AttachStderr: true,
  });
  const stream = await execution.start({ Detach: false, Tty: false });
  const content = await streamToString(stream);
  return content as JsonValue;
};

const destroy: AgentHandlerFn = async (args) => {
  const sandboxId = args[0] as string;

  const sandbox = sandboxes.get(sandboxId);
  if (!sandbox) throw new Error(`Sandbox ${sandboxId} not found`);

  const container = docker.getContainer(sandbox.containerId);
  try {
    await container.stop({ t: 1 });
  } catch {
    // Already stopped
  }
  await container.remove({ force: true });
  sandboxes.delete(sandboxId);
  console.log(`Sandbox destroyed: ${sandboxId}`);
  return null;
};

function streamToString(stream: NodeJS.ReadableStream): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    stream.on("data", (chunk: Buffer) => chunks.push(chunk));
    stream.on("end", () => resolve(Buffer.concat(chunks).toString("utf-8")));
    stream.on("error", reject);
  });
}

const port = parseInt(process.env.PORT ?? "8005", 10);
const selfBaseUrl = process.env.KATARI_BASE_URL ?? `http://localhost:${port}/katari`;

startServer({
  port,
  selfBaseUrl,
  handlers: {
    create,
    exec,
    write_file: writeFile,
    read_file: readFile,
    destroy,
  },
});
