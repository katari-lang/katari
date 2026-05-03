import { ThreadId } from "./id.js";

export type Waiter =
  | {
      kind: "external-call-arg";
      argLabel: string;
      threadId: ThreadId;
    }
  | {
      kind: "prim-call-arg";
      argLabel: string;
      threadId: ThreadId;
    }
  | {
      kind: "match-scrutinee";
      threadId: ThreadId;
    }
  | {
      kind: "bind-right-hand-side";
      statementIndex: number;
    };
