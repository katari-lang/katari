// 引数ゼロで `katari` を呼んだときに出る top-level command picker。

import * as p from "@clack/prompts";
import pc from "picocolors";
import { applyCmd } from "../commands/apply.js";
import { runCmd } from "../commands/run.js";
import { cancelCmd } from "../commands/cancel.js";
import { lsCmd } from "../commands/ls.js";
import {
  escalationListCmd,
  escalationAnswerCmd,
} from "../commands/escalation.js";
import { typecheckCmd } from "../commands/typecheck.js";
import { initCmd } from "../commands/init.js";

type Cmd =
  | "apply"
  | "run"
  | "cancel"
  | "ls"
  | "escalation:list"
  | "escalation:answer"
  | "typecheck"
  | "init";

export async function runCommandPicker(): Promise<void> {
  p.intro(pc.bgMagenta(pc.black(" Katari CLI ")));
  const choice = await p.select({
    message: "What would you like to do?",
    options: [
      {
        value: "apply" as const,
        label: "apply",
        hint: "compile and upload a snapshot",
      },
      { value: "run" as const, label: "run", hint: "start an agent" },
      {
        value: "cancel" as const,
        label: "cancel",
        hint: "cancel a running agent",
      },
      {
        value: "ls" as const,
        label: "ls",
        hint: "list projects / snapshots / agents / agent-defs",
      },
      {
        value: "escalation:list" as const,
        label: "escalation list",
        hint: "show pending user-facing escalations",
      },
      {
        value: "escalation:answer" as const,
        label: "escalation answer",
        hint: "answer a pending escalation",
      },
      {
        value: "typecheck" as const,
        label: "typecheck",
        hint: "type-check sources without uploading",
      },
      {
        value: "init" as const,
        label: "init",
        hint: "scaffold a new project (katari.toml)",
      },
    ],
  }) as Cmd | symbol;
  if (p.isCancel(choice)) {
    p.cancel("cancelled");
    process.exit(130);
  }
  switch (choice) {
    case "apply":
      await applyCmd({});
      return;
    case "run":
      await runCmd({});
      return;
    case "cancel":
      await cancelCmd({});
      return;
    case "ls":
      await lsCmd({});
      return;
    case "escalation:list":
      await escalationListCmd({});
      return;
    case "escalation:answer":
      await escalationAnswerCmd({});
      return;
    case "typecheck":
      await typecheckCmd({});
      return;
    case "init":
      await initCmd();
      return;
  }
}
