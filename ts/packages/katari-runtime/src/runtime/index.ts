import type {
  JsonValue,
  OutgoingMessage,
  KatariServerHooks,
  KatariServer,
  Agent,
  Delegation,
  Escalation,
  Capability,
  DelegateRequest,
} from "katari-protocol";
import type { IRModule } from "../ir.js";
import type { Value } from "../value.js";
import type {
  AgentState,
  OutgoingAction,
  ProtocolAction,
  DispatchContext,
  RuntimeEvent,
  ExternalAgentRef,
} from "./types.js";
import { setVar, findThread, createThread } from "./types.js";
import { fireEvent, deliverEvent, executeFromThread } from "./dispatch.js";
import { callPrimitive } from "../primitive.js";
import { serializeAgentState, deserializeAgentState } from "./serialize.js";
import type { Db } from "../db.js";
import type { RuntimeLogger } from "../logger.js";
import { NullRuntimeLogger } from "../logger.js";

// ===========================================================================
// Runtime — orchestrates agent execution via KatariServerHooks
// ===========================================================================

export class Runtime {
  private module: IRModule | null = null;
  private agents = new Map<string, AgentState>();
  private selfEndpoint: string;
  private db: Db | null;

  // Agent name/routing config (set via applyModule)
  private agentNameMap = new Map<string, number>();
  private defIdToName = new Map<number, string>();
  private externalAgents = new Map<number, ExternalAgentRef>();
  private servers = new Map<string, string>();
  private schemas = new Map<string, JsonValue>();

  // Parent tracking: childAgentId → { parentAgentId, parentThreadId }
  private parentMap = new Map<
    string,
    { parentAgentId: string; parentThreadId: number }
  >();

  // Delegation tracking: delegationId → { agentId, threadId }
  private delegationMap = new Map<
    string,
    { agentId: string; threadId: number }
  >();

  // Escalation tracking: escalationId → { agentId, threadId }
  private escalationMap = new Map<
    string,
    { agentId: string; threadId: number }
  >();

  // Toplevel agent tracking
  private toplevelAgents = new Set<string>();
  private toplevelResults = new Map<
    string,
    { status: string; result?: Value }
  >();
  onAgentCompleted?: (agentId: string, result: Value) => void;
  onAgentError?: (agentId: string) => void;

  // Dispatch context — shared by all agents
  private ctx: DispatchContext;

  // Protocol server — handles outbound protocol operations (store + message construction)
  private protocolServer: KatariServer | null = null;

  // Outgoing messages from last operation
  private pendingMessages: OutgoingMessage[] = [];

  // Protocol actions collected during synchronous dispatch, flushed in persistState
  private pendingProtocolActions: ProtocolAction[] = [];

  // Track which agents were modified during current operation
  private dirtyAgents = new Set<string>();
  private deletedAgents = new Set<string>();

  private logger: RuntimeLogger;

  constructor(endpoint: string, db?: Db, logger?: RuntimeLogger) {
    this.selfEndpoint = endpoint;
    this.db = db ?? null;
    this.logger = logger ?? new NullRuntimeLogger();

    this.ctx = {
      callHandler: (agent, threadId, dst, agentDefId, args, actions) =>
        this.handleCall(agent, threadId, dst, agentDefId, args, actions),
      rootRequestHandler: (agent, threadId, event, actions) =>
        this.handleRootRequest(agent, threadId, event, actions),
      logger: this.logger,
    };
  }

  getLogger(): RuntimeLogger {
    return this.logger;
  }

  setProtocolServer(server: KatariServer): void {
    this.protocolServer = server;
  }

  // =========================================================================
  // Module management
  // =========================================================================

  applyModule(
    module: IRModule,
    nameMap: Map<string, number>,
    schemas: Map<string, JsonValue>,
    externalAgents?: Map<number, ExternalAgentRef>,
    servers?: Map<string, string>,
  ): void {
    this.module = module;
    this.agentNameMap = nameMap;
    this.schemas = schemas;
    if (externalAgents) this.externalAgents = externalAgents;
    if (servers) this.servers = servers;

    // Build reverse name map
    this.defIdToName.clear();
    for (const [name, id] of nameMap) {
      this.defIdToName.set(id, name);
    }
  }

  // =========================================================================
  // DB persistence — save/load state
  // =========================================================================

  /** Flush pending protocol actions via KatariServer → OutgoingMessages */
  private async flushProtocolActions(): Promise<void> {
    const actions = this.pendingProtocolActions;
    this.pendingProtocolActions = [];
    if (actions.length === 0) return;

    const server = this.protocolServer;

    for (const action of actions) {
      switch (action.tag) {
        case "ProtocolDelegate": {
          if (server) {
            const { message } = await server.delegate(
              action.targetEndpoint,
              action.agentDefId,
              action.input,
              action.capabilityRefs,
              action.delegationId,
            );
            this.pendingMessages.push(message);
          }
          break;
        }
        case "ProtocolEscalate": {
          if (server) {
            const { message } = await server.sendEscalate(
              action.capabilityRef,
              action.input,
              action.escalationId,
            );
            this.pendingMessages.push(message);
          }
          break;
        }
        case "ProtocolDelegateAck": {
          if (server) {
            const msg = await server.sendDelegateAck(
              { id: action.agentId, endpoint: this.selfEndpoint },
              action.output,
            );
            if (msg) this.pendingMessages.push(msg);
          }
          break;
        }
        case "ProtocolEscalateAck": {
          if (server) {
            const msg = await server.sendEscalateAck(
              action.escalationEndpoint,
              action.escalationRef.id,
              action.output,
            );
            this.pendingMessages.push(msg);
          }
          break;
        }
        case "ProtocolThrow": {
          // Throw doesn't have a KatariServer convenience method yet — construct directly
          this.pendingMessages.push({
            toEndpoint: action.delegationEndpoint,
            kind: {
              type: "Throw",
              body: {
                delegation_ref: {
                  id: action.delegationId,
                  endpoint: action.delegationEndpoint,
                },
                message: action.message,
              },
            },
          });
          break;
        }
      }
    }
  }

  /** Save all modified agent states and ref maps to DB */
  async persistState(): Promise<void> {
    await this.flushProtocolActions();

    if (!this.db) return;

    const promises: Promise<void>[] = [];

    for (const agentId of this.deletedAgents) {
      promises.push(this.db.deleteAgent(agentId));
    }
    this.deletedAgents.clear();

    for (const agentId of this.dirtyAgents) {
      const agent = this.agents.get(agentId);
      if (!agent) continue;

      const parentInfo = this.parentMap.get(agentId);
      const isToplevel = this.toplevelAgents.has(agentId);
      const name = this.defIdToName.get(agent.agentDefId) ?? null;

      promises.push(
        this.db.saveAgent(
          agentId,
          agent.agentDefId,
          serializeAgentState(agent),
          parentInfo?.parentAgentId ?? null,
          parentInfo?.parentThreadId ?? null,
          isToplevel,
          name,
          null,
        ),
      );
    }
    this.dirtyAgents.clear();

    await Promise.all(promises);
  }

  /** Restore all running agents from DB (used on startup for non-serverless) */
  async restoreAgentsFromDb(): Promise<void> {
    if (!this.db || !this.module) return;

    const rows = await this.db.loadRunningAgents();
    for (const row of rows) {
      const agent = deserializeAgentState(row.state, this.module);
      this.agents.set(row.id, agent);
      if (row.parentAgentId && row.parentThreadId !== null) {
        this.parentMap.set(row.id, {
          parentAgentId: row.parentAgentId,
          parentThreadId: row.parentThreadId,
        });
      }
      if (row.isToplevel) {
        this.toplevelAgents.add(row.id);
      }

      // Restore ref maps
      const refs = await this.db.loadRefsByAgent(row.id);
      for (const ref of refs) {
        if (ref.kind === "delegation") {
          this.delegationMap.set(ref.id, {
            agentId: ref.agentId,
            threadId: ref.threadId,
          });
        } else {
          this.escalationMap.set(ref.id, {
            agentId: ref.agentId,
            threadId: ref.threadId,
          });
        }
      }
    }
  }

  /** Load a single agent from DB on demand (for serverless) */
  private async loadAgentFromDb(agentId: string): Promise<AgentState | null> {
    if (!this.db || !this.module) return null;

    const row = await this.db.loadAgent(agentId);
    if (!row || row.status !== "running") return null;

    const agent = deserializeAgentState(row.state, this.module);
    this.agents.set(agentId, agent);

    if (row.parentAgentId && row.parentThreadId !== null) {
      this.parentMap.set(agentId, {
        parentAgentId: row.parentAgentId,
        parentThreadId: row.parentThreadId,
      });
    }
    if (row.isToplevel) {
      this.toplevelAgents.add(agentId);
    }
    return agent;
  }

  // =========================================================================
  // KatariServerHooks — provided to KatariServer
  // =========================================================================

  createHooks(): KatariServerHooks {
    return {
      onDelegate: (agent, req) => this.onDelegate(agent, req),
      onDelegateAck: (delegation, output) =>
        this.onDelegateAck(delegation, output),
      onEscalate: (escalation, capability) =>
        this.onEscalate(escalation, capability),
      onEscalateAck: (escalation, output) =>
        this.onEscalateAck(escalation, output),
      onTerminate: (delegation) => this.onTerminate(delegation),
      onTerminateAck: (delegation) => this.onTerminateAck(delegation),
      onThrow: (delegation, message) => this.onThrow(delegation, message),
    };
  }

  // =========================================================================
  // Hook: onDelegate — create agent, start execution
  // =========================================================================

  private async onDelegate(
    protocolAgent: Agent,
    req: DelegateRequest,
  ): Promise<void> {
    if (!this.module) return;

    const agentDefId = parseInt(protocolAgent.definition_ref.id, 10);
    if (isNaN(agentDefId)) return;

    const agentDef = this.module.agents.find((a) => a.id === agentDefId);
    if (!agentDef) return;

    const agentId = protocolAgent.id;
    const entryTid = agentDef.entry;

    const agent = this.createAgentState(agentId, agentDefId, entryTid);
    agent.delegationEndpoint = req.delegation_ref?.endpoint ?? null;
    agent.delegationId = req.delegation_ref?.id ?? null;
    agent.capabilityRefs = req.capability_refs;

    // Set named args
    this.setNamedArgs(
      agent,
      entryTid,
      agentDef.paramNames,
      req.input as Record<string, Value>,
    );

    this.agents.set(agentId, agent);
    this.markDirty(agentId);

    // Execute from entry thread
    const actions: OutgoingAction[] = [];
    executeFromThread(this.ctx, agent, entryTid, actions);
    this.processActions(actions);

    await this.persistState();
  }

  // =========================================================================
  // Hook: onDelegateAck — child agent completed
  // =========================================================================

  private async onDelegateAck(
    delegation: Delegation,
    output: JsonValue,
  ): Promise<void> {
    const entry = await this.resolveRef("delegation", delegation.id);
    if (!entry) return;

    this.delegationMap.delete(delegation.id);
    if (this.db) await this.db.deleteRef(delegation.id);

    const agent =
      this.agents.get(entry.agentId) ??
      (await this.loadAgentFromDb(entry.agentId));
    if (!agent) return;

    const actions: OutgoingAction[] = [];
    deliverEvent(
      this.ctx,
      agent,
      entry.threadId,
      { tag: "completed", value: output as Value },
      actions,
    );
    this.markDirty(entry.agentId);
    this.processActions(actions);

    await this.persistState();
  }

  // =========================================================================
  // Hook: onEscalate — child's request routed to our capability
  // =========================================================================

  private async onEscalate(
    escalation: Escalation,
    capability: Capability,
  ): Promise<void> {
    // Find the agent that owns this capability
    const agentId = capability.agent_ref.id;
    const agent =
      this.agents.get(agentId) ?? (await this.loadAgentFromDb(agentId));
    if (!agent) {
      this.logger.log("warn", `onEscalate: agent ${agentId} not found`);
      return;
    }

    // The escalation carries input that maps to a request event
    // Route it to the delegating thread for this child
    // Find the thread that's in DELEGATING state for this child
    for (const [_tid, thread] of agent.threads) {
      if (
        thread.status.tag === "CALLING" &&
        thread.status.kind.tag === "DELEGATING"
      ) {
        const actions: OutgoingAction[] = [];
        const reqDefId = this.findRequestDefByCapability(capability);

        deliverEvent(
          this.ctx,
          agent,
          thread.threadId,
          {
            tag: "requested",
            reqDefId: reqDefId ?? 0,
            args: escalation.input as Record<string, Value>,
            requestId: escalation.id,
            fromThreadId: null,
            escalationRef: { id: escalation.id, endpoint: escalation.endpoint },
            escalationEndpoint: escalation.endpoint,
          },
          actions,
        );
        this.markDirty(agentId);
        this.processActions(actions);

        await this.persistState();
        return;
      }
    }

    this.logger.log(
      "warn",
      `onEscalate: no DELEGATING thread found for capability ${capability.id}`,
    );
  }

  // =========================================================================
  // Hook: onEscalateAck — request response from capability holder
  // =========================================================================

  private async onEscalateAck(
    escalation: Escalation,
    output: JsonValue,
  ): Promise<void> {
    const entry = await this.resolveRef("escalation", escalation.id);
    if (!entry) return;

    this.escalationMap.delete(escalation.id);
    if (this.db) await this.db.deleteRef(escalation.id);

    const agent =
      this.agents.get(entry.agentId) ??
      (await this.loadAgentFromDb(entry.agentId));
    if (!agent) return;

    const actions: OutgoingAction[] = [];
    fireEvent(
      this.ctx,
      agent,
      entry.threadId,
      { tag: "continue", value: output as Value },
      actions,
    );
    this.markDirty(entry.agentId);
    this.processActions(actions);

    await this.persistState();
  }

  // =========================================================================
  // Hook: onTerminate — parent tells us to stop
  // =========================================================================

  private async onTerminate(delegation: Delegation): Promise<void> {
    for (const [agentId, agent] of this.agents) {
      if (agent.delegationId === delegation.id) {
        const actions: OutgoingAction[] = [];
        fireEvent(
          this.ctx,
          agent,
          agent.rootThreadId,
          { tag: "cancel" },
          actions,
        );
        this.markDirty(agentId);
        this.processActions(actions);

        await this.persistState();
        break;
      }
    }

    // If not found in memory, try DB
    if (this.db) {
      const rows = await this.db.loadRunningAgents();
      for (const row of rows) {
        if (row.state.delegationId === delegation.id) {
          const agent = await this.loadAgentFromDb(row.id);
          if (!agent) continue;

          const actions: OutgoingAction[] = [];
          fireEvent(
            this.ctx,
            agent,
            agent.rootThreadId,
            { tag: "cancel" },
            actions,
          );
          this.markDirty(row.id);
          this.processActions(actions);

          await this.persistState();
          break;
        }
      }
    }
  }

  // =========================================================================
  // Hook: onTerminateAck — child confirmed termination
  // =========================================================================

  private async onTerminateAck(delegation: Delegation): Promise<void> {
    const entry = await this.resolveRef("delegation", delegation.id);
    if (!entry) return;

    this.delegationMap.delete(delegation.id);
    if (this.db) await this.db.deleteRef(delegation.id);

    const agent =
      this.agents.get(entry.agentId) ??
      (await this.loadAgentFromDb(entry.agentId));
    if (!agent) return;

    const actions: OutgoingAction[] = [];
    deliverEvent(this.ctx, agent, entry.threadId, { tag: "canceled" }, actions);
    this.markDirty(entry.agentId);
    this.processActions(actions);

    await this.persistState();
  }

  // =========================================================================
  // Hook: onThrow — child reports an error
  // =========================================================================

  private async onThrow(
    delegation: Delegation,
    message: string,
  ): Promise<void> {
    // Find the agent whose delegation matches
    const entry = await this.resolveRef("delegation", delegation.id);
    if (!entry) {
      this.logger.log("warn", `onThrow: delegation ${delegation.id} not found`);
      return;
    }

    const agent =
      this.agents.get(entry.agentId) ??
      (await this.loadAgentFromDb(entry.agentId));
    if (!agent) return;

    // Clean up the delegation ref
    this.delegationMap.delete(delegation.id);
    if (this.db) await this.db.deleteRef(delegation.id);

    // For now, treat throw as an error that propagates up.
    // If this agent has a parent (delegation), forward the throw.
    if (agent.delegationEndpoint && agent.delegationId) {
      // First cancel the delegating thread
      const actions: OutgoingAction[] = [];
      deliverEvent(
        this.ctx,
        agent,
        entry.threadId,
        { tag: "canceled" },
        actions,
      );
      this.markDirty(entry.agentId);

      // Forward throw to parent
      actions.push({
        tag: "ProtocolThrow",
        delegationEndpoint: agent.delegationEndpoint,
        delegationId: agent.delegationId,
        message,
      });

      this.processActions(actions);
    } else {
      // Toplevel agent — mark as error
      const actions: OutgoingAction[] = [];
      deliverEvent(
        this.ctx,
        agent,
        entry.threadId,
        { tag: "canceled" },
        actions,
      );
      this.markDirty(entry.agentId);
      actions.push({ tag: "AgentError", agentId: agent.agentId });
      this.processActions(actions);
      this.logger.log(
        "error",
        `Agent ${agent.agentId}: unhandled throw — ${message}`,
      );
    }

    await this.persistState();
  }

  // =========================================================================
  // Local agent execution (for /agents endpoint)
  // =========================================================================

  async runAgent(
    agentName: string,
    namedArgs: Record<string, Value>,
  ): Promise<string> {
    const module = this.module;
    if (!module) throw new Error("no module loaded");

    const agentDefId = this.agentNameMap.get(agentName);
    if (agentDefId === undefined)
      throw new Error(`agent '${agentName}' not found`);

    const agentDef = module.agents.find((a) => a.id === agentDefId);
    if (!agentDef) throw new Error(`agent def ${agentDefId} not found`);

    const agentId = `agent-${crypto.randomUUID()}`;
    const entryTid = agentDef.entry;

    const agent = this.createAgentState(agentId, agentDefId, entryTid);
    this.setNamedArgs(agent, entryTid, agentDef.paramNames, namedArgs);
    this.agents.set(agentId, agent);
    this.toplevelAgents.add(agentId);
    this.markDirty(agentId);

    // Execute from entry thread
    const actions: OutgoingAction[] = [];
    executeFromThread(this.ctx, agent, entryTid, actions);
    this.processActions(actions);

    await this.persistState();
    return agentId;
  }

  // =========================================================================
  // Call handler — resolves ICall to primitive/internal/external
  // =========================================================================

  private handleCall(
    agent: AgentState,
    threadId: number,
    dst: number,
    agentDefId: number,
    args: Record<string, Value>,
    actions: OutgoingAction[],
  ): boolean {
    const name = this.defIdToName.get(agentDefId);

    // --- Primitive agents ---
    if (name?.startsWith("prim.")) {
      if (name === "prim.ref_agent") {
        const agentName = Object.values(args)[0] as string;
        setVar(agent, dst, this.resolveAgentRef(agentName));
        return true;
      }

      const argValues = Object.values(args);
      const result = callPrimitive(name, argValues);

      if (result.tag === "Ok") {
        setVar(agent, dst, result.value);
        return true;
      }

      if (result.tag === "RaiseRequest") {
        const rid = this.module?.requests.find(
          (r) => r.name === result.reqName,
        )?.id;
        if (rid !== undefined) {
          const requestId = crypto.randomUUID();
          const thread = agent.threads.get(threadId);
          if (!thread) return true;

          const currentKind =
            thread.status.tag === "CALLING"
              ? thread.status.kind
              : { tag: "BLOCK" as const, childThreadId: -1, dst: -1 };

          thread.status = {
            tag: "REQUESTING",
            fromThread: null,
            previousState: currentKind,
            eventQueue: [],
            escalationRef: null,
          };

          fireEvent(
            this.ctx,
            agent,
            threadId,
            {
              tag: "requested",
              reqDefId: rid,
              args: result.args,
              requestId,
              fromThreadId: null,
              escalationRef: null,
              escalationEndpoint: null,
            },
            actions,
          );
        }
        return false;
      }

      setVar(agent, dst, null);
      return true;
    }

    // --- Internal agent ---
    const agentDef = this.module?.agents.find((a) => a.id === agentDefId);
    if (agentDef) {
      const childAgentId = `agent-${crypto.randomUUID()}`;
      const entryTid = agentDef.entry;

      const childAgent = this.createAgentState(
        childAgentId,
        agentDefId,
        entryTid,
      );
      this.setNamedArgs(childAgent, entryTid, agentDef.paramNames, args);
      this.agents.set(childAgentId, childAgent);

      // Track parent-child relationship
      this.parentMap.set(childAgentId, {
        parentAgentId: agent.agentId,
        parentThreadId: threadId,
      });

      // Set parent thread to AGENT calling kind
      const thread = agent.threads.get(threadId);
      if (thread) {
        thread.status = {
          tag: "CALLING",
          kind: { tag: "AGENT", childAgentId, dst },
        };
      }

      this.markDirty(childAgentId);
      this.markDirty(agent.agentId);

      // Execute child agent synchronously
      const childActions: OutgoingAction[] = [];
      executeFromThread(this.ctx, childAgent, entryTid, childActions);

      // Process child actions inline
      this.processActions(childActions);

      return false;
    }

    // --- External agent (delegation) ---
    const extRef = this.externalAgents.get(agentDefId);
    if (extRef) {
      const delegationId = crypto.randomUUID();

      const thread = agent.threads.get(threadId);
      if (thread) {
        thread.status = {
          tag: "CALLING",
          kind: { tag: "DELEGATING", delegationId, dst },
        };
      }

      this.delegationMap.set(delegationId, {
        agentId: agent.agentId,
        threadId,
      });
      this.markDirty(agent.agentId);

      // Save ref to DB
      if (this.db) {
        this.db
          .saveRef(delegationId, "delegation", agent.agentId, threadId)
          .catch(() => {});
      }

      actions.push({
        tag: "ProtocolDelegate",
        targetEndpoint: extRef.agent_def_where,
        agentDefId: extRef.agent_def_id,
        input: args as JsonValue,
        capabilityRefs: agent.capabilityRefs,
        delegationId,
      });

      return false;
    }

    // Unknown agent — return null
    this.logger.log("warn", `Unknown agent def ${agentDefId} (${name ?? "?"})`);
    setVar(agent, dst, null);
    return true;
  }

  // =========================================================================
  // Root request handler — escalates unhandled requests
  // =========================================================================

  private handleRootRequest(
    agent: AgentState,
    _threadId: number,
    event: RuntimeEvent & { tag: "requested" },
    actions: OutgoingAction[],
  ): void {
    const reqDef = agent.module.requests.find((r) => r.id === event.reqDefId);
    if (!reqDef) return;

    // Look for a matching capability in the agent's capability refs
    if (agent.capabilityRefs.length > 0) {
      const capRef = agent.capabilityRefs[0]!;
      const escalationId = crypto.randomUUID();

      this.escalationMap.set(escalationId, {
        agentId: agent.agentId,
        threadId: _threadId,
      });

      // Save ref to DB
      if (this.db) {
        this.db
          .saveRef(escalationId, "escalation", agent.agentId, _threadId)
          .catch(() => {});
      }

      actions.push({
        tag: "ProtocolEscalate",
        capabilityRef: capRef,
        input: event.args as JsonValue,
        escalationId,
      });
    } else if (agent.delegationEndpoint) {
      this.logger.log(
        "warn",
        `Request ${reqDef.name}: no capabilities available, cannot escalate`,
      );
    } else {
      this.logger.log(
        "warn",
        `Unhandled request ${reqDef.name} at root — no parent to escalate to`,
      );
    }
  }

  // =========================================================================
  // Process outgoing actions
  // =========================================================================

  private processActions(actions: OutgoingAction[]): void {
    for (const action of actions) {
      switch (action.tag) {
        case "ProtocolDelegate":
        case "ProtocolEscalate":
        case "ProtocolDelegateAck":
        case "ProtocolEscalateAck":
        case "ProtocolThrow":
          this.pendingProtocolActions.push(action);
          break;
        case "AgentCompleted":
          this.onAgentComplete(action.agentId, action.value);
          break;
        case "AgentError":
          this.onAgentFail(action.agentId);
          break;
        case "TerminateAgent":
          this.terminateChild(action.childAgentId);
          break;
      }
    }
  }

  private onAgentComplete(agentId: string, value: Value): void {
    // Check if this is a child of another agent
    const parentInfo = this.parentMap.get(agentId);
    if (parentInfo) {
      this.parentMap.delete(agentId);
      this.agents.delete(agentId);
      this.deletedAgents.add(agentId);

      const parentAgent = this.agents.get(
        agentId === parentInfo.parentAgentId
          ? agentId
          : parentInfo.parentAgentId,
      );
      if (parentAgent) {
        const actions: OutgoingAction[] = [];
        deliverEvent(
          this.ctx,
          parentAgent,
          parentInfo.parentThreadId,
          { tag: "completed", value },
          actions,
        );
        this.markDirty(parentInfo.parentAgentId);
        this.processActions(actions);
      }
      return;
    }

    // Toplevel agent
    if (this.toplevelAgents.has(agentId)) {
      this.toplevelResults.set(agentId, { status: "completed", result: value });
      this.onAgentCompleted?.(agentId, value);
      this.toplevelAgents.delete(agentId);
      this.agents.delete(agentId);

      // Update DB status
      if (this.db) {
        this.db
          .updateAgentStatus(agentId, "completed", value as JsonValue)
          .catch(() => {});
      }
      return;
    }

    // Protocol agent — send delegate_ack
    const agent = this.agents.get(agentId);
    if (agent?.delegationEndpoint && agent.delegationId) {
      this.pendingProtocolActions.push({
        tag: "ProtocolDelegateAck",
        agentId,
        output: value as JsonValue,
      });
      this.agents.delete(agentId);
      this.deletedAgents.add(agentId);

      if (this.db) {
        this.db
          .updateAgentStatus(agentId, "completed", value as JsonValue)
          .catch(() => {});
      }
    }
  }

  private onAgentFail(agentId: string): void {
    if (this.toplevelAgents.has(agentId)) {
      this.toplevelResults.set(agentId, { status: "error" });
      this.onAgentError?.(agentId);
      this.toplevelAgents.delete(agentId);
    }
    this.parentMap.delete(agentId);
    this.agents.delete(agentId);
    this.deletedAgents.add(agentId);

    if (this.db) {
      this.db.updateAgentStatus(agentId, "error", null).catch(() => {});
    }
  }

  private terminateChild(childAgentId: string): void {
    const childAgent = this.agents.get(childAgentId);
    if (childAgent) {
      const actions: OutgoingAction[] = [];
      fireEvent(
        this.ctx,
        childAgent,
        childAgent.rootThreadId,
        { tag: "cancel" },
        actions,
      );
      this.markDirty(childAgentId);
      this.processActions(actions);
    }
  }

  // =========================================================================
  // Agent lifecycle
  // =========================================================================

  private createAgentState(
    agentId: string,
    agentDefId: number,
    entryTid: number,
  ): AgentState {
    if (!this.module) throw new Error("no module loaded");

    const agent: AgentState = {
      agentId,
      agentDefId,
      module: this.module,
      vars: new Map(),
      threads: new Map(),
      rootThreadId: entryTid,
      delegationEndpoint: null,
      delegationId: null,
      selfEndpoint: this.selfEndpoint,
      capabilityRefs: [],
    };

    createThread(agent, entryTid, null);
    return agent;
  }

  private setNamedArgs(
    agent: AgentState,
    entryTid: number,
    paramNames: string[],
    namedArgs: Record<string, Value>,
  ): void {
    const irThread = findThread(agent.module, entryTid);
    if (!irThread) return;
    for (let i = 0; i < irThread.params.length && i < paramNames.length; i++) {
      const val = namedArgs[paramNames[i]!];
      if (val !== undefined) setVar(agent, irThread.params[i]!, val);
    }
  }

  // =========================================================================
  // Agent status & management
  // =========================================================================

  getAgentStatus(agentId: string): { status: string; result?: Value } | null {
    const agent = this.agents.get(agentId);
    if (agent) {
      if (agent.threads.size === 0) return { status: "completed" };
      return { status: "running" };
    }
    return this.toplevelResults.get(agentId) ?? null;
  }

  async stopAgent(agentId: string): Promise<void> {
    const agent =
      this.agents.get(agentId) ?? (await this.loadAgentFromDb(agentId));
    if (!agent) return;

    const actions: OutgoingAction[] = [];
    fireEvent(this.ctx, agent, agent.rootThreadId, { tag: "cancel" }, actions);
    this.processActions(actions);

    // Clean up
    this.toplevelAgents.delete(agentId);
    this.agents.delete(agentId);
    this.parentMap.delete(agentId);
    this.deletedAgents.add(agentId);

    if (this.db) {
      await this.db.updateAgentStatus(agentId, "stopped", null);
    }
  }

  hasAgent(agentId: string): boolean {
    return this.agents.has(agentId);
  }

  // =========================================================================
  // Module info (for HTTP API)
  // =========================================================================

  getModuleAgents(): { id: number; name: string }[] {
    return this.module?.agents.map((a) => ({ id: a.id, name: a.name })) ?? [];
  }

  getModuleRequests(): { id: number; name: string }[] {
    return this.module?.requests.map((r) => ({ id: r.id, name: r.name })) ?? [];
  }

  getAgentDefId(name: string): number | undefined {
    return this.agentNameMap.get(name);
  }

  getEndpoint(): string {
    return this.selfEndpoint;
  }

  // =========================================================================
  // Drain outgoing messages
  // =========================================================================

  drainMessages(): OutgoingMessage[] {
    const msgs = [...this.pendingMessages];
    this.pendingMessages = [];
    return msgs;
  }

  // =========================================================================
  // Helpers
  // =========================================================================

  private markDirty(agentId: string): void {
    this.dirtyAgents.add(agentId);
    this.deletedAgents.delete(agentId);
  }

  private async resolveRef(
    kind: "delegation" | "escalation",
    refId: string,
  ): Promise<{ agentId: string; threadId: number } | null> {
    const map = kind === "delegation" ? this.delegationMap : this.escalationMap;
    const entry = map.get(refId);
    if (entry) return entry;

    // Fallback to DB
    if (this.db) {
      const row = await this.db.loadRef(refId);
      if (row && row.kind === kind)
        return { agentId: row.agentId, threadId: row.threadId };
    }
    return null;
  }

  private findRequestDefByCapability(_capability: Capability): number | null {
    // TODO: proper template-to-requestDef mapping once compiler provides template info
    if (this.module?.requests.length) {
      return this.module.requests[0]!.id;
    }
    return null;
  }

  private resolveAgentRef(agentName: string): Value {
    const numId = this.agentNameMap.get(agentName);
    if (numId === undefined) return null;

    const extRef = this.externalAgents.get(numId);
    if (!extRef) return null;

    const schema = this.schemas.get(agentName) as
      | Record<string, JsonValue>
      | undefined;
    return {
      url: extRef.agent_def_where,
      agent_def_id: extRef.agent_def_id,
      name: agentName,
      description: (schema?.description as string) ?? "",
      arg_type: schema?.arg_type ?? null,
    };
  }
}
