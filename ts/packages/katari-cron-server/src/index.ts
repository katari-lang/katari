import { startServer } from "katari-protocol";
import type { AgentHandlerFn, JsonValue } from "katari-protocol";
import cron from "node-cron";

const schedule: AgentHandlerFn = async (args, ctx) => {
  const a = args as Record<string, JsonValue>;
  const cronExpr = a.cron_expr as string;

  if (!cron.validate(cronExpr)) {
    throw new Error(`Invalid cron expression: ${cronExpr}`);
  }

  return new Promise(() => {
    // Long-running: never resolves (agent stays alive)
    cron.schedule(cronExpr, () => {
      const now = new Date().toISOString();
      // Escalate to first capability (notify handler in parent)
      if (ctx.capabilityRefs.length > 0) {
        ctx.escalate(ctx.capabilityRefs[0]!, { time: now });
      }
    });
  });
};

const port = parseInt(process.env.PORT ?? "8003", 10);
const endpoint = process.env.KATARI_BASE_URL ?? `http://localhost:${port}`;
const databaseUrl = process.env.DATABASE_URL;

startServer({
  port,
  endpoint,
  databaseUrl,
  agentDefs: {
    schedule: {
      handler: schedule,
      description: "Schedule a cron job that escalates on each tick",
    },
  },
});
