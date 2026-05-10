#!/usr/bin/env node
// `katari` CLI entry point.
//
// 引数ゼロ → command picker (interactive)
// `katari <subcommand> ...` → 直接 dispatch (引数不足時は対話 fallback)

import { Command } from "commander";
import { applyCmd } from "./commands/apply.js";
import { runCmd } from "./commands/run.js";
import { cancelCmd } from "./commands/cancel.js";
import { lsCmd, type LsTarget } from "./commands/ls.js";
import {
  escalationListCmd,
  escalationAnswerCmd,
} from "./commands/escalation.js";
import { typecheckCmd } from "./commands/typecheck.js";
import { initCmd } from "./commands/init.js";
import { runCommandPicker } from "./prompt/command-picker.js";

const program = new Command();

program
  .name("katari")
  .description("Katari CLI: compile, deploy, and orchestrate agents.")
  .version("0.1.0");

program
  .command("apply")
  .description("Compile sources and upload as a new snapshot")
  .option("-p, --project <name>", "project name (overrides katari.toml)")
  .option("-s, --src <dir>", "source directory")
  .option("--sidecar <entry>", "sidecar entry path")
  .action((opts) => applyCmd(opts));

program
  .command("run [qualifiedName]")
  .description("Start an agent (interactive if args missing)")
  .option("-p, --project <name>", "project name")
  .option("--snapshot <id>", "snapshot id (defaults to latest)")
  .option("--args <json>", "agent args as JSON")
  .option("--wait", "poll until the agent finishes")
  .action((qualifiedName: string | undefined, opts) =>
    runCmd({ ...opts, qualifiedName }),
  );

program
  .command("cancel [agentId]")
  .description("Cancel a running agent")
  .option("-p, --project <name>", "project name")
  .action((agentId: string | undefined, opts) => cancelCmd({ ...opts, agentId }));

program
  .command("ls [target]")
  .description(
    "List projects / snapshots / agents / agent-defs (interactive if target missing)",
  )
  .option("-p, --project <name>", "project name")
  .option("--snapshot <id>", "snapshot id (for agent-defs)")
  .action((target: string | undefined, opts) => {
    const valid: LsTarget[] = ["agents", "agent-defs", "snapshots", "projects"];
    if (target !== undefined && !valid.includes(target as LsTarget)) {
      console.error(
        `Unknown ls target '${target}'. Choose one of: ${valid.join(", ")}`,
      );
      process.exit(1);
    }
    return lsCmd({ ...opts, target: target as LsTarget | undefined });
  });

const escalation = program
  .command("escalation")
  .description("Manage user-facing escalations");

escalation
  .command("list")
  .description("List pending escalations")
  .option("-p, --project <name>", "project name")
  .option("-s, --state <state>", "open | answered | cancelled")
  .action((opts) => escalationListCmd(opts));

escalation
  .command("answer [escalationId]")
  .description("Answer a pending escalation")
  .option("-p, --project <name>", "project name")
  .option("--value <json>", "answer value as JSON")
  .action((escalationId: string | undefined, opts) =>
    escalationAnswerCmd({ ...opts, escalationId }),
  );

program
  .command("typecheck")
  .description("Type-check sources without uploading")
  .option("-s, --src <dir>", "source directory")
  .action((opts) => typecheckCmd(opts));

program
  .command("init")
  .description("Scaffold a new project (katari.toml + src/main.ktr)")
  .action(() => initCmd());

// 引数ゼロ (= argv が node + script のみ) → 対話 picker
if (process.argv.length <= 2) {
  runCommandPicker().catch((err) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  });
} else {
  program.parseAsync(process.argv).catch((err) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  });
}
