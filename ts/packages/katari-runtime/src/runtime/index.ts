import { v4 as uuidv4 } from "uuid";
import type {
  KatariProtocol,
  OutgoingMessage,
  RequestInfo,
  AgentDefInfo,
  AgentSummary,
  AgentDetail,
  SpawnAgentRequest,
  SpawnAgentResponse,
  AgentRequestBody,
  AgentReplyBody,
  AgentReturnBody,
  TerminateBody,
  TerminateAckBody,
  ChildAgentRef,
  JsonValue,
} from "katari-protocol";
import type { IRModule } from "../ir.js";
import type { Value } from "../value.js";
import type {
  AgentState,
  Event,
  PendingRequest,
  Signal,
} from "./types.js";
import {
  setVar,
  isRunning,
  findThread,
  findRequestThread,
  isHeldByHandler,
  resumeThread,
  routeRequestToHandle,
} from "./types.js";
import type { ExecuteCallbacks } from "./execute.js";
import { executeThread } from "./execute.js";
import { setupHandle, dispatchRequest, processHandlerSignal, processHandleBodySignal, processHandleThenSignal } from "./handle.js";
import { setupFor, processForBodySignal, processForThenSignal } from "./for-loop.js";
import { setupPar, processParBranchSignal } from "./par.js";
import type { RequestConfig } from "./request.js";
import { handleICall, handleIRequest } from "./request.js";

// ===========================================================================
// Runtime
// ===========================================================================

export class Runtime implements KatariProtocol {
  module: IRModule | null = null;
  agents = new Map<string, AgentState>();
  agentNameMap = new Map<string, number>();
  schemas = new Map<string, JsonValue>();
  selfBaseUrl: string;
  eventQueue: Event[] = [];
  outgoingMessages: OutgoingMessage[] = [];

  // External routing
  servers = new Map<string, string>();
  externalAgents = new Map<number, string>();

  // Toplevel agent tracking
  toplevelAgents = new Set<string>();
  toplevelResults = new Map<string, { status: string; result?: Value }>();
  onAgentCompleted?: (agentId: string, result: Value) => void;
  onAgentError?: (agentId: string) => void;

  private execCb: ExecuteCallbacks;

  constructor(baseUrl: string) {
    this.selfBaseUrl = baseUrl;
    this.execCb = {
      setupHandle,
      setupFor,
      setupPar,
      handleICall: (agent, tid, dst, adid, args, events, msgs) =>
        handleICall(agent, tid, dst, adid, args, events, msgs, this.requestConfig),
      handleIRequest: (agent, tid, dst, rdid, args, events, msgs) =>
        handleIRequest(agent, tid, dst, rdid, args, events, msgs, this.requestConfig),
    };
  }

  private get requestConfig(): RequestConfig {
    return {
      selfBaseUrl: this.selfBaseUrl,
      servers: this.servers,
      externalAgents: this.externalAgents,
    };
  }

  applyModule(
    module: IRModule,
    nameMap: Map<string, number>,
    schemas: Map<string, JsonValue>,
    servers?: Map<string, string>,
    externalAgents?: Map<number, string>
  ): void {
    this.module = module;
    this.agentNameMap = nameMap;
    this.schemas = schemas;
    if (servers) this.servers = servers;
    if (externalAgents) this.externalAgents = externalAgents;
  }

  // =========================================================================
  // POST /run entry point
  // =========================================================================

  runAgent(agentName: string, args: Value[]): string {
    const module = this.module;
    if (!module) throw new Error("no module loaded");

    const agentDefId = this.agentNameMap.get(agentName);
    if (agentDefId === undefined)
      throw new Error(`agent '${agentName}' not found`);

    const agentDef = module.agents.find((a) => a.id === agentDefId);
    if (!agentDef) throw new Error(`agent def ${agentDefId} not found`);

    const entryTid = agentDef.entry;
    const agentId = `agent-${uuidv4()}`;
    const rootAgentId = `root-${uuidv4()}`;

    const agent = this.createAgent(
      agentId, agentDefId, entryTid, rootAgentId, "", new Set(), module
    );

    const irThread = findThread(module, entryTid);
    if (irThread) {
      for (let i = 0; i < irThread.params.length && i < args.length; i++) {
        setVar(agent, irThread.params[i]!, args[i]!);
      }
    }

    this.agents.set(agentId, agent);
    this.toplevelAgents.add(agentId);
    this.eventQueue.push({ agentId, kind: { tag: "Execute", threadId: entryTid } });
    this.runEventLoop();
    return agentId;
  }

  private createAgent(
    agentId: string,
    agentDefId: number,
    entryTid: number,
    parentAgentId: string,
    parentAgentWhere: string,
    parentAvailableRequests: Set<number>,
    module: IRModule
  ): AgentState {
    const agent: AgentState = {
      agentId,
      agentDefId,
      module,
      vars: new Map(),
      threads: new Map(),
      rootThread: entryTid,
      parentAgentId,
      parentAgentWhere,
      children: new Map(),
      parentAvailableRequests,
      selfWhere: this.selfBaseUrl,
      status: { tag: "Running" },
    };
    agent.threads.set(entryTid, {
      threadId: entryTid,
      kind: "FnBody",
      pc: 0,
      status: { tag: "Running" },
      parent: null,
    });
    return agent;
  }

  // =========================================================================
  // Event loop
  // =========================================================================

  runEventLoop(): void {
    for (let i = 0; i < 100_000; i++) {
      const idx = this.eventQueue.findIndex((e) => this.isApplicable(e));
      if (idx === -1) break;
      const event = this.eventQueue.splice(idx, 1)[0]!;
      this.applyEvent(event);
    }
    this.eventQueue = this.eventQueue.filter((e) => this.agents.has(e.agentId));
  }

  private isApplicable(event: Event): boolean {
    const agent = this.agents.get(event.agentId);
    if (!agent) return false;

    const kind = event.kind;
    switch (kind.tag) {
      case "Execute": {
        const t = agent.threads.get(kind.threadId);
        return !!t && isRunning(t) && !isHeldByHandler(agent, kind.threadId);
      }
      case "ThreadCompleted": {
        const t = agent.threads.get(kind.parentId);
        if (!t) return false;
        if (
          t.status.tag === "Suspended" &&
          t.status.reason.tag === "Handle" &&
          t.status.reason.phase.tag === "RunningHandler"
        ) {
          return kind.childId === t.status.reason.phase.handlerThread;
        }
        return !isHeldByHandler(agent, kind.parentId);
      }
      case "Terminate":
        return agent.threads.has(kind.threadId);
      case "IncomingRequest": {
        const t = agent.threads.get(kind.ownerThreadId);
        if (!t) return false;
        if (
          t.status.tag === "Suspended" &&
          t.status.reason.tag === "Handle" &&
          t.status.reason.phase.tag === "RunningBody"
        ) {
          return !isHeldByHandler(agent, kind.ownerThreadId);
        }
        return false;
      }
      case "Reply":
      case "ChildAgentCompleted":
        return (
          agent.threads.has(kind.threadId) &&
          !isHeldByHandler(agent, kind.threadId)
        );
      case "SpawnChildAgent":
      case "AgentCompleted":
      case "TerminateAgent":
        return true;
    }
  }

  // =========================================================================
  // Event dispatch
  // =========================================================================

  private applyEvent(event: Event): void {
    const newEvents: Event[] = [];
    const newMessages: OutgoingMessage[] = [];
    const agentId = event.agentId;

    switch (event.kind.tag) {
      case "Execute": {
        const agent = this.agents.get(agentId);
        if (agent)
          executeThread(agent, event.kind.threadId, newEvents, newMessages, this.execCb);
        break;
      }

      case "ThreadCompleted": {
        const { parentId, childId, childKind, signal } = event.kind;
        const agent = this.agents.get(agentId);
        if (agent)
          this.dispatchSignal(agent, parentId, childId, childKind, signal, newEvents, newMessages);
        break;
      }

      case "Terminate": {
        const agent = this.agents.get(agentId);
        if (agent) {
          const tid = event.kind.threadId;
          for (const [id, t] of agent.threads) {
            if (t.parent === tid) {
              newEvents.push({ agentId, kind: { tag: "Terminate", threadId: id } });
            }
          }
          const t = agent.threads.get(tid);
          if (t?.status.tag === "Suspended" && t.status.reason.tag === "Call") {
            agent.children.delete(t.status.reason.childAgentId);
          }
          agent.threads.delete(tid);
        }
        break;
      }

      case "IncomingRequest": {
        const { ownerThreadId, request, handlerDefTid } = event.kind;
        const agent = this.agents.get(agentId);
        if (agent)
          dispatchRequest(agent, ownerThreadId, handlerDefTid, request, newEvents);
        break;
      }

      case "Reply": {
        const agent = this.agents.get(agentId);
        if (agent) {
          const t = agent.threads.get(event.kind.threadId);
          if (t?.status.tag === "Suspended" && t.status.reason.tag === "Request") {
            setVar(agent, t.status.reason.dst, event.kind.value);
            resumeThread(agent, event.kind.threadId, newEvents);
          }
        }
        break;
      }

      case "SpawnChildAgent": {
        const { childAgentId, agentDefId, args } = event.kind;
        const parentAgent = this.agents.get(agentId);
        if (!parentAgent) break;

        const module = parentAgent.module;
        const agentDef = module.agents.find((a) => a.id === agentDefId);
        if (!agentDef) break;

        const entryTid = agentDef.entry;
        const child = this.createAgent(
          childAgentId, agentDefId, entryTid, agentId, this.selfBaseUrl,
          new Set(parentAgent.parentAvailableRequests), module
        );

        const irThread = findThread(module, entryTid);
        if (irThread) {
          for (let i = 0; i < irThread.params.length && i < args.length; i++) {
            setVar(child, irThread.params[i]!, args[i]!);
          }
        }

        this.agents.set(childAgentId, child);
        newEvents.push({
          agentId: childAgentId,
          kind: { tag: "Execute", threadId: entryTid },
        });
        break;
      }

      case "AgentCompleted": {
        const agent = this.agents.get(agentId);
        if (!agent) break;

        const result = agent.status.tag === "Completed" ? agent.status.value : null;

        // Toplevel agent completed — cache result, fire callback, remove from memory
        if (this.toplevelAgents.has(agentId)) {
          if (agent.status.tag === "Completed") {
            this.toplevelResults.set(agentId, { status: "completed", result });
            this.onAgentCompleted?.(agentId, result);
          } else {
            this.toplevelResults.set(agentId, { status: "error" });
            this.onAgentError?.(agentId);
          }
          this.toplevelAgents.delete(agentId);
          this.agents.delete(agentId);
          break;
        }

        const parentAgent = this.agents.get(agent.parentAgentId);

        if (parentAgent && parentAgent.children.has(agentId)) {
          const spawningTid = parentAgent.children.get(agentId)!;
          newEvents.push({
            agentId: agent.parentAgentId,
            kind: {
              tag: "ChildAgentCompleted",
              threadId: spawningTid,
              childAgentId: agentId,
              result,
            },
          });
          this.agents.delete(agentId);
        } else if (parentAgent && !parentAgent.children.has(agentId)) {
          newMessages.push({
            toUrl: agent.parentAgentWhere,
            kind: {
              type: "Return",
              body: {
                result: result as JsonValue,
                from_agent_id: agentId,
                from_agent_where: this.selfBaseUrl,
                agent_id: agent.parentAgentId,
              },
            },
          });
          this.agents.delete(agentId);
        }
        break;
      }

      case "ChildAgentCompleted": {
        const agent = this.agents.get(agentId);
        if (!agent) break;
        const t = agent.threads.get(event.kind.threadId);
        if (t?.status.tag === "Suspended" && t.status.reason.tag === "Call") {
          setVar(agent, t.status.reason.dst, event.kind.result);
          agent.children.delete(event.kind.childAgentId);
          resumeThread(agent, event.kind.threadId, newEvents);
        }
        break;
      }

      case "TerminateAgent": {
        const { agentId: targetAgentId, fromAgentId, fromAgentWhere } = event.kind;
        const agent = this.agents.get(targetAgentId);
        if (!agent) break;

        for (const [childId] of agent.children) {
          const child = this.agents.get(childId);
          if (child) {
            newEvents.push({
              agentId: childId,
              kind: {
                tag: "TerminateAgent",
                agentId: childId,
                fromAgentId: targetAgentId,
                fromAgentWhere: this.selfBaseUrl,
              },
            });
          }
        }

        agent.status = { tag: "Error" };
        agent.threads.clear();

        // Toplevel agent terminated — cache result, fire callback
        if (this.toplevelAgents.has(targetAgentId)) {
          this.toplevelResults.set(targetAgentId, { status: "stopped" });
          this.onAgentError?.(targetAgentId);
          this.toplevelAgents.delete(targetAgentId);
        }

        if (fromAgentWhere) {
          newMessages.push({
            toUrl: fromAgentWhere,
            kind: {
              type: "TerminateAck",
              body: {
                from_agent_id: targetAgentId,
                from_agent_where: this.selfBaseUrl,
                agent_id: fromAgentId,
              },
            },
          });
        }

        this.agents.delete(targetAgentId);
        break;
      }
    }

    for (const e of newEvents) this.eventQueue.push(e);
    this.outgoingMessages.push(...newMessages);
  }

  // =========================================================================
  // Signal dispatch
  // =========================================================================

  private dispatchSignal(
    agent: AgentState,
    parentId: number,
    childId: number,
    childKind: string,
    signal: Signal,
    events: Event[],
    messages: OutgoingMessage[]
  ): void {
    switch (childKind) {
      case "Block":
        processParBranchSignal(agent, parentId, childId, signal, events);
        break;
      case "HandlerTarget":
        processHandleBodySignal(agent, parentId, signal, events);
        break;
      case "RequestHandler":
        processHandlerSignal(agent, parentId, signal, events, messages);
        break;
      case "HandleThen":
        processHandleThenSignal(agent, parentId, signal, events);
        break;
      case "ForBody":
        processForBodySignal(agent, parentId, signal, events);
        break;
      case "ForThen":
        processForThenSignal(agent, parentId, signal, events);
        break;
      case "FnBody":
        break;
    }
  }

  // =========================================================================
  // Agent status
  // =========================================================================

  getAgentStatus(agentId: string): { status: string; result?: Value } | null {
    const agent = this.agents.get(agentId);
    if (agent) {
      switch (agent.status.tag) {
        case "Running": return { status: "running" };
        case "Completed": return { status: "completed", result: agent.status.value };
        case "Error": return { status: "error" };
      }
    }
    // Fallback to cached toplevel results
    return this.toplevelResults.get(agentId) ?? null;
  }

  // =========================================================================
  // Remote child registration
  // =========================================================================

  registerRemoteChild(
    parentAgentId: string,
    provisionalId: string,
    actualId: string,
    _actualWhere: string
  ): void {
    const agent = this.agents.get(parentAgentId);
    if (!agent) return;

    const spawningTid = agent.children.get(provisionalId);
    if (spawningTid === undefined) return;

    agent.children.delete(provisionalId);
    agent.children.set(actualId, spawningTid);

    const t = agent.threads.get(spawningTid);
    if (t?.status.tag === "Suspended" && t.status.reason.tag === "Call") {
      t.status.reason.childAgentId = actualId;
    }
  }

  // =========================================================================
  // Drain outgoing messages
  // =========================================================================

  drainMessages(): OutgoingMessage[] {
    const msgs = [...this.outgoingMessages];
    this.outgoingMessages = [];
    return msgs;
  }

  // =========================================================================
  // KatariProtocol implementation
  // =========================================================================

  listRequests(_moduleName?: string): RequestInfo[] {
    if (!this.module) return [];
    return this.module.requests
      .filter((r) => !r.from)
      .map((r) => ({
        request_id: String(r.id),
        request_where: this.selfBaseUrl,
        name: r.name,
        description: "",
        arg_types: [],
        return_type: null,
      }));
  }

  listAgentDefs(_moduleName?: string): AgentDefInfo[] {
    if (!this.module) return [];
    return this.module.agents.map((a) => ({
      agent_def_id: String(a.id),
      agent_def_where: this.selfBaseUrl,
      name: a.name,
      description: "",
      arg_types: [],
      return_type: null,
      with_effects: [],
    }));
  }

  listAgents(): AgentSummary[] {
    return Array.from(this.agents.entries()).map(([id, a]) => ({
      agent_id: id,
      agent_where: a.selfWhere,
      agent_def_id: String(a.agentDefId),
      args: [],
    }));
  }

  getAgent(agentId: string): AgentDetail | null {
    const agent = this.agents.get(agentId);
    if (!agent) return null;

    const childAgents: ChildAgentRef[] = Array.from(agent.children.keys()).map(
      (cid) => ({
        agent_id: cid,
        agent_where: this.agents.get(cid)?.selfWhere ?? "",
      })
    );

    return {
      agent_id: agentId,
      agent_where: agent.selfWhere,
      agent_def_id: String(agent.agentDefId),
      args: [],
      parent_agent_id: agent.parentAgentId,
      parent_agent_where: agent.parentAgentWhere,
      with_effects: [],
      child_agents: childAgents,
    };
  }

  spawnAgent(
    req: SpawnAgentRequest
  ): { response: SpawnAgentResponse; messages: OutgoingMessage[] } | string {
    if (!this.module) return "no module loaded";

    const agentDefId = parseInt(req.agent_def_id, 10);
    if (isNaN(agentDefId)) return `invalid agent_def_id: ${req.agent_def_id}`;

    const agentDef = this.module.agents.find((a) => a.id === agentDefId);
    if (!agentDef) return `agent def ${req.agent_def_id} not found`;

    const entryTid = agentDef.entry;
    const agentId = `agent-${uuidv4()}`;

    const withEffects = new Set(
      (req.with_effects ?? [])
        .map((name) => this.module!.requests.find((r) => r.name === name)?.id)
        .filter((id): id is number => id !== undefined)
    );

    const agent = this.createAgent(
      agentId, agentDefId, entryTid, req.parent_agent_id,
      req.parent_agent_where, withEffects, this.module
    );

    const irThread = findThread(this.module, entryTid);
    if (irThread) {
      for (let i = 0; i < irThread.params.length && i < req.args.length; i++) {
        setVar(agent, irThread.params[i]!, req.args[i] as Value);
      }
    }

    this.agents.set(agentId, agent);
    this.eventQueue.push({ agentId, kind: { tag: "Execute", threadId: entryTid } });
    this.runEventLoop();

    return {
      response: { agent_id: agentId, agent_where: this.selfBaseUrl },
      messages: this.drainMessages(),
    };
  }

  deliverRequest(req: AgentRequestBody): OutgoingMessage[] | string {
    let agentId: string | null = null;
    let sourceThreadId: number | null = null;

    for (const [aid, a] of this.agents) {
      const tid = a.children.get(req.from_agent_id);
      if (tid !== undefined) {
        agentId = aid;
        sourceThreadId = tid;
        break;
      }
    }

    if (!agentId || sourceThreadId === null) {
      return `child agent ${req.from_agent_id} not found`;
    }

    const agent = this.agents.get(agentId)!;

    let reqDefId: number;
    const parsed = parseInt(req.request_def_id, 10);
    if (!isNaN(parsed)) {
      reqDefId = parsed;
    } else {
      const found = agent.module.requests.find((r) => r.name === req.request_def_id)?.id;
      if (found === undefined) return `request ${req.request_def_id} not found`;
      reqDefId = found;
    }

    const args = req.args as Value[];
    const pending: PendingRequest = {
      requestId: req.request_id,
      reqDefId,
      args,
      fromAgentId: req.from_agent_id,
      fromAgentWhere: req.from_agent_where,
    };

    const route = routeRequestToHandle(agent, sourceThreadId, reqDefId);
    if (route) {
      this.eventQueue.push({
        agentId,
        kind: {
          tag: "IncomingRequest",
          ownerThreadId: route[0],
          request: pending,
          handlerDefTid: route[1],
        },
      });
    } else {
      console.warn(`no handle scope for external request ${req.request_def_id}`);
    }

    this.runEventLoop();
    return this.drainMessages();
  }

  deliverReply(req: AgentReplyBody): OutgoingMessage[] | string {
    const agent = this.agents.get(req.agent_id);
    if (!agent) return `agent ${req.agent_id} not found`;

    const threadId = findRequestThread(agent, req.request_id);
    if (threadId === null) return `request ${req.request_id} not found`;

    this.eventQueue.push({
      agentId: req.agent_id,
      kind: {
        tag: "Reply",
        threadId,
        requestId: req.request_id,
        value: req.result as Value,
      },
    });

    this.runEventLoop();
    return this.drainMessages();
  }

  deliverReturn(req: AgentReturnBody): OutgoingMessage[] | string {
    const agent = this.agents.get(req.agent_id);
    if (!agent) return `agent ${req.agent_id} not found`;

    const spawningTid = agent.children.get(req.from_agent_id);
    if (spawningTid === undefined) return `child ${req.from_agent_id} not found`;

    this.eventQueue.push({
      agentId: req.agent_id,
      kind: {
        tag: "ChildAgentCompleted",
        threadId: spawningTid,
        childAgentId: req.from_agent_id,
        result: req.result as Value,
      },
    });

    agent.children.delete(req.from_agent_id);
    this.runEventLoop();
    return this.drainMessages();
  }

  terminateAgent(req: TerminateBody): OutgoingMessage[] | string {
    const agent = this.agents.get(req.agent_id);
    if (!agent) return `agent ${req.agent_id} not found`;

    this.eventQueue.push({
      agentId: req.agent_id,
      kind: {
        tag: "TerminateAgent",
        agentId: req.agent_id,
        fromAgentId: req.from_agent_id,
        fromAgentWhere: req.from_agent_where,
      },
    });

    this.runEventLoop();
    return this.drainMessages();
  }

  deliverTerminateAck(req: TerminateAckBody): OutgoingMessage[] | string {
    const agent = this.agents.get(req.agent_id);
    if (!agent) return `agent ${req.agent_id} not found`;
    agent.children.delete(req.from_agent_id);
    return [];
  }
}
