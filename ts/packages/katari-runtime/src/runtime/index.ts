import type {
  JsonValue,
  OutgoingMessage,
  KatariServerHooks,
  KatariServer,
  Agent,
  Delegation,
  Escalation,
  Capability,
  CapabilityRef,
  DelegateRequest,
} from "katari-protocol";
import type { IRModule } from "../ir.js";
import type { Value } from "../value.js";
import type {
  AgentState,
  OutgoingAction,
  ProtocolAction,
  CapabilityToCreate,
  DispatchContext,
  RuntimeEvent,
  ExternalAgentRef,
} from "./types.js";
import { setVar, findThread, findHandle, createThread } from "./types.js";
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

  // Agent routing config (set via applyModule)
  private protocolDefIdToBlockId = new Map<string, number>(); // agent_def_id (UUID) → block_id
  private protocolTemplateIdToRequestId = new Map<string, number>(); // template_id → request_id
  private requestIdToTemplateRef = new Map<number, { id: string; endpoint: string }>(); // request_id → TemplateRef
  private primBlockIds = new Map<number, string>(); // block_id → prim function name
  private externalAgents = new Map<number, ExternalAgentRef>();
  private servers = new Map<string, string>();
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

  // Capabilities created per delegation — for cleanup
  private delegationCapabilityIds = new Map<string, string[]>();

  // External delegation endpoint tracking: delegationId → target endpoint
  private delegationEndpointMap = new Map<string, string>();

  // Name → AgentRef (for ref_agent primitive, covers both internal and external)
  private nameToAgentRef = new Map<string, { url: string; agent_def_id: string; name: string; arg_type: JsonValue }>();

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

  setProtocolTemplateMap(
    map: Map<string, number>,
    templateEndpoints: Map<string, string>,
  ): void {
    this.protocolTemplateIdToRequestId = map;
    this.requestIdToTemplateRef.clear();
    for (const [templateId, requestId] of map) {
      const endpoint = templateEndpoints.get(templateId) ?? this.selfEndpoint;
      this.requestIdToTemplateRef.set(requestId, { id: templateId, endpoint });
    }
  }

  // =========================================================================
  // Module management
  // =========================================================================

  applyModule(
    module: IRModule,
    protocolDefIdToBlockId: Map<string, number>,
    externalAgents?: Map<number, ExternalAgentRef>,
    servers?: Map<string, string>,
    primBlockIds?: Map<number, string>,
    nameToAgentRef?: Map<string, { url: string; agent_def_id: string; name: string; arg_type: JsonValue }>,
  ): void {
    this.module = module;
    this.protocolDefIdToBlockId = protocolDefIdToBlockId;
    if (externalAgents) this.externalAgents = externalAgents;
    if (servers) this.servers = servers;
    if (nameToAgentRef) this.nameToAgentRef = nameToAgentRef;

    // Set prim block_id → name map (provided by /apply from CLI metadata)
    this.primBlockIds = primBlockIds ?? new Map();
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
            // Create capabilities in protocol store before sending delegate
            const store = server.getStore();
            for (const cap of action.capabilitiesToCreate) {
              await store.createCapability({
                id: cap.id,
                endpoint: this.selfEndpoint,
                template_ref: cap.templateRef,
                agent_ref: cap.agentRef,
              });
            }

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
        case "ProtocolTerminate": {
          this.pendingMessages.push({
            toEndpoint: action.targetEndpoint,
            kind: {
              type: "Terminate",
              body: {
                delegation_ref: {
                  id: action.delegationId,
                  endpoint: action.parentEndpoint,
                },
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

      const isToplevel = this.toplevelAgents.has(agentId);
      const name = this.module?.agents.find(a => a.id === agent.agentDefId)?.name ?? null;

      promises.push(
        this.db.saveAgent(
          agentId,
          agent.agentDefId,
          serializeAgentState(agent),
          null,
          null,
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

    // Resolve protocol agent_def_id (UUID) → compiler block_id
    const blockId = this.protocolDefIdToBlockId.get(
      protocolAgent.definition_ref.id,
    );
    if (blockId === undefined) {
      this.logger.log(
        "warn",
        `onDelegate: unknown agent_def_id=${protocolAgent.definition_ref.id}`,
      );
      return;
    }

    const agentDef = this.module.agents.find((a) => a.id === blockId);
    if (!agentDef) return;
    const agentDefId = blockId;

    const agentId = protocolAgent.id;
    const entryTid = agentDef.entry;

    const agent = this.createAgentState(agentId, agentDefId, entryTid);
    agent.delegationEndpoint = req.delegation_ref?.endpoint ?? null;
    agent.delegationId = req.delegation_ref?.id ?? null;
    agent.capabilityRefs = req.capability_refs;

    // Set named args (root thread uses scope 0)
    this.setNamedArgs(
      agent,
      0,
      entryTid,
      agentDef.paramNames,
      req.input as Record<string, Value>,
    );

    this.agents.set(agentId, agent);
    this.markDirty(agentId);

    // Execute from entry thread
    const actions: OutgoingAction[] = [];
    executeFromThread(this.ctx, agent, agent.rootThreadId, actions);
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
    this.delegationEndpointMap.delete(delegation.id);
    if (this.db) await this.db.deleteRef(delegation.id);

    // Clean up capabilities created for this delegation
    await this.cleanupDelegationCapabilities(delegation.id);

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

    // Route escalation to the thread that's delegating to this child.
    // The thread may be CALLING(DELEGATING) or REQUESTING(previousState=DELEGATING)
    // if a prior escalation already transitioned it.
    const reqDefId = this.findRequestDefByCapability(capability);
    const event: RuntimeEvent = {
      tag: "requested",
      reqDefId: reqDefId ?? 0,
      args: escalation.input as Record<string, Value>,
      requestId: escalation.id,
      fromThreadId: null,
      escalationRef: { id: escalation.id, endpoint: escalation.endpoint },
      escalationEndpoint: escalation.endpoint,
    };

    for (const [_tid, thread] of agent.threads) {
      const isDelegating =
        (thread.status.tag === "CALLING" &&
          thread.status.kind.tag === "DELEGATING") ||
        (thread.status.tag === "REQUESTING" &&
          thread.status.previousState.tag === "DELEGATING");
      if (isDelegating) {
        const actions: OutgoingAction[] = [];
        deliverEvent(this.ctx, agent, thread.threadId, event, actions);
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
    this.delegationEndpointMap.delete(delegation.id);
    if (this.db) await this.db.deleteRef(delegation.id);

    // Clean up capabilities created for this delegation
    await this.cleanupDelegationCapabilities(delegation.id);

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
    this.delegationEndpointMap.delete(delegation.id);
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

    const agentDef = module.agents.find((a) => a.name === agentName);
    if (!agentDef) throw new Error(`agent '${agentName}' not found`);
    const agentDefId = agentDef.id;

    const agentId = `agent-${crypto.randomUUID()}`;
    const entryTid = agentDef.entry;

    const agent = this.createAgentState(agentId, agentDefId, entryTid);
    this.setNamedArgs(agent, 0, entryTid, agentDef.paramNames, namedArgs);
    this.agents.set(agentId, agent);
    this.toplevelAgents.add(agentId);
    this.markDirty(agentId);

    // Execute from entry thread
    const actions: OutgoingAction[] = [];
    executeFromThread(this.ctx, agent, agent.rootThreadId, actions);
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
    const callerThread = agent.threads.get(threadId);
    const callerScope = callerThread?.scopeId ?? 0;

    // --- Primitive agents ---
    const primName = this.primBlockIds.get(agentDefId);
    if (primName) {
      if (primName === "prim.ref_agent") {
        const agentName = Object.values(args)[0] as string;
        setVar(agent, callerScope, dst, this.resolveAgentRef(agentName));
        return true;
      }

      const argValues = Object.values(args);
      const result = callPrimitive(primName, argValues);

      if (result.tag === "Ok") {
        setVar(agent, callerScope, dst, result.value);
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

      setVar(agent, callerScope, dst, null);
      return true;
    }

    // --- Internal agent (same agent, new scope + thread) ---
    const agentDef = this.module?.agents.find((a) => a.id === agentDefId);
    if (agentDef) {
      const entryTid = agentDef.entry;

      // Create a new variable scope for the ICall boundary
      const childScopeId = agent.nextScopeId++;
      agent.scopes.set(childScopeId, new Map());

      // Create child thread in the same agent
      const childThread = createThread(agent, entryTid, threadId);
      childThread.scopeId = childScopeId;
      this.logger.runtimeEvent(agent.agentId, childThread.threadId, "thread:created",
        { parent: threadId, blockId: entryTid, reason: "icall", agentDefId });

      // Set named args into child scope
      this.setNamedArgs(agent, childScopeId, entryTid, agentDef.paramNames, args);

      // Set parent thread to AGENT calling kind
      const thread = agent.threads.get(threadId);
      if (thread) {
        thread.status = {
          tag: "CALLING",
          kind: { tag: "AGENT", childThreadId: childThread.threadId, childScopeId, dst },
        };
      }

      this.markDirty(agent.agentId);

      // Execute child thread in the same agent
      executeFromThread(this.ctx, agent, childThread.threadId, actions);

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
      this.delegationEndpointMap.set(delegationId, extRef.agent_def_where);
      this.markDirty(agent.agentId);

      // Save ref to DB
      if (this.db) {
        this.db
          .saveRef(delegationId, "delegation", agent.agentId, threadId)
          .catch(() => {});
      }

      // Collect capabilities from ancestor handle blocks + parent's protocol caps
      const { capabilitiesToCreate, capabilityRefs } =
        this.collectCapabilitiesForDelegation(agent, threadId);

      // Track for cleanup when delegation resolves
      if (capabilitiesToCreate.length > 0) {
        this.delegationCapabilityIds.set(
          delegationId,
          capabilitiesToCreate.map((c) => c.id),
        );
      }

      actions.push({
        tag: "ProtocolDelegate",
        targetEndpoint: extRef.agent_def_where,
        agentDefId: extRef.agent_def_id,
        input: args as JsonValue,
        capabilityRefs,
        delegationId,
        capabilitiesToCreate,
      });

      return false;
    }

    // Unknown agent — return null
    this.logger.log("warn", `Unknown agent def block_id=${agentDefId}`);
    setVar(agent, callerScope, dst, null);
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
      // Unblock the REQUESTING chain with null
      fireEvent(this.ctx, agent, _threadId, { tag: "continue", value: null }, actions);
    } else {
      this.logger.log(
        "warn",
        `Unhandled request ${reqDef.name} at root — no parent to escalate to`,
      );
      // Unblock the REQUESTING chain with null
      fireEvent(this.ctx, agent, _threadId, { tag: "continue", value: null }, actions);
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
    this.agents.delete(agentId);
    this.deletedAgents.add(agentId);

    if (this.db) {
      this.db.updateAgentStatus(agentId, "error", null).catch(() => {});
    }
  }

  private terminateChild(childAgentId: string): void {
    // External delegation — send /terminate to remote server
    const delegationEndpoint = this.delegationEndpointMap.get(childAgentId);
    if (delegationEndpoint) {
      this.pendingProtocolActions.push({
        tag: "ProtocolTerminate",
        targetEndpoint: delegationEndpoint,
        delegationId: childAgentId,
        parentEndpoint: this.selfEndpoint,
      });
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
      scopes: new Map([[0, new Map()]]),
      nextScopeId: 1,
      threads: new Map(),
      rootThreadId: 0, // will be set after createThread
      nextThreadId: 0,
      delegationEndpoint: null,
      delegationId: null,
      selfEndpoint: this.selfEndpoint,
      capabilityRefs: [],
    };

    const rootThread = createThread(agent, entryTid, null);
    agent.rootThreadId = rootThread.threadId;
    this.logger.runtimeEvent(agent.agentId, rootThread.threadId, "thread:created",
      { parent: null, blockId: entryTid, reason: "root" });
    return agent;
  }

  private setNamedArgs(
    agent: AgentState,
    scopeId: number,
    entryTid: number,
    paramNames: string[],
    namedArgs: Record<string, Value>,
  ): void {
    const irThread = findThread(agent.module, entryTid);
    if (!irThread) return;
    for (let i = 0; i < irThread.params.length && i < paramNames.length; i++) {
      const val = namedArgs[paramNames[i]!];
      if (val !== undefined) setVar(agent, scopeId, irThread.params[i]!, val);
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

    // Flush protocol actions (e.g. ProtocolTerminate for external delegations)
    await this.persistState();

    // Clean up
    this.toplevelAgents.delete(agentId);
    this.agents.delete(agentId);
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
    return this.module?.agents.find((a) => a.name === name)?.id;
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

  /** Delete capabilities that were created for a specific delegation */
  private async cleanupDelegationCapabilities(
    delegationId: string,
  ): Promise<void> {
    const capIds = this.delegationCapabilityIds.get(delegationId);
    if (!capIds || capIds.length === 0) return;

    this.delegationCapabilityIds.delete(delegationId);

    if (this.protocolServer) {
      const store = this.protocolServer.getStore();
      for (const capId of capIds) {
        await store.deleteCapability(capId);
      }
    }
  }

  private findRequestDefByCapability(capability: Capability): number | null {
    const requestId = this.protocolTemplateIdToRequestId.get(
      capability.template_ref.id,
    );
    if (requestId !== undefined) return requestId;
    return null;
  }

  /**
   * Walk up the thread ancestor chain from `threadId`, collecting handle
   * request cases that would intercept a `requested` event. Produces
   * CapabilityToCreate entries (with pre-generated UUIDs) and the final
   * merged CapabilityRef list (local caps + parent's protocol caps, deduped
   * by template — leaf wins).
   */
  private collectCapabilitiesForDelegation(
    agent: AgentState,
    threadId: number,
  ): { capabilitiesToCreate: CapabilityToCreate[]; capabilityRefs: CapabilityRef[] } {
    // Collect template_id → CapabilityToCreate, leaf-first (first encountered wins)
    const seenTemplateIds = new Set<string>();
    const capsToCreate: CapabilityToCreate[] = [];

    let currentId: number | null = threadId;
    while (currentId !== null) {
      const thread = agent.threads.get(currentId);
      if (!thread || thread.parent === null) break;

      const parent = agent.threads.get(thread.parent);
      if (!parent || parent.status.tag !== "CALLING") {
        currentId = thread.parent;
        continue;
      }

      const kind = parent.status.kind;
      // HANDLE_TARGET and HANDLE_BODY both belong to a handle scope whose
      // request cases can intercept escalations.
      if (kind.tag === "HANDLE_TARGET" || kind.tag === "HANDLE_BODY") {
        const hdef = findHandle(agent.module, kind.handleDefId);
        if (hdef) {
          for (const [reqId] of hdef.reqCases) {
            const templateRef = this.requestIdToTemplateRef.get(reqId);
            if (templateRef && !seenTemplateIds.has(templateRef.id)) {
              seenTemplateIds.add(templateRef.id);
              capsToCreate.push({
                id: crypto.randomUUID(),
                templateRef,
                agentRef: { id: agent.agentId, endpoint: this.selfEndpoint },
              });
            }
          }
        }
      }

      currentId = thread.parent;
    }

    // Merge: local capabilities first (already in capsToCreate), then
    // parent's protocol capabilities for templates not already covered.
    const capabilityRefs: CapabilityRef[] = capsToCreate.map((c) => ({
      id: c.id,
      endpoint: this.selfEndpoint,
    }));

    for (const parentCap of agent.capabilityRefs) {
      // Parent caps only included if their template isn't shadowed by a
      // local handle.  We can't easily inspect the template of a foreign
      // CapabilityRef without a store lookup, so we include all of them —
      // the protocol routing will naturally pick the first matching
      // capability the child tries.  For same-endpoint caps we can dedup.
      capabilityRefs.push(parentCap);
    }

    return { capabilitiesToCreate: capsToCreate, capabilityRefs };
  }

  private resolveAgentRef(agentName: string): Value {
    const ref = this.nameToAgentRef.get(agentName);
    if (!ref) return null;
    return ref;
  }
}
