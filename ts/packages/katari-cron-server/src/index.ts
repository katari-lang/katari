import { startServer } from "katari-protocol";
import type { AgentHandlerFn } from "katari-protocol";
import cron from "node-cron";

const schedule: AgentHandlerFn = async (args, ctx) => {
  const cronExpr = args.cron_expr as string;

  if (!cron.validate(cronExpr)) {
    throw new Error(`Invalid cron expression: ${cronExpr}`);
  }

  return new Promise(() => {
    // Long-running: never resolves (agent stays alive)
    cron.schedule(cronExpr, () => {
      const now = new Date().toISOString();
      ctx.sendRequest("notify", { time: now });
    });
  });
};

const port = parseInt(process.env.PORT ?? "8003", 10);
const selfBaseUrl = process.env.KATARI_BASE_URL ?? `http://localhost:${port}/katari`;

startServer({
  port,
  selfBaseUrl,
  handlers: { schedule },
});
