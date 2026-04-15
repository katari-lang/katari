import { Hono } from "hono";
import { cors } from "hono/cors";
import { serve } from "@hono/node-server";
import { randomUUID } from "node:crypto";
import type { JsonValue } from "./json.js";
import type {
  Agent,
  AgentDefinition,
  Capability,
  Delegation,
  Escalation,
  Template,
  DelegateRequest,
  DelegateResponse,
  DelegateAckRequest,
  EscalateRequest,
  EscalateAckRequest,
  TerminateRequest,
  TerminateAckRequest,
  ThrowRequest,
  OutgoingMessage,
  AgentRef,
  CapabilityRef,
} from "./types.js";
import type { KatariStore } from "./store.js";
import { PostgresKatariStore, createPostgresAdapter } from "./store.js";
import { buildKatariRouter } from "./router.js";
import { sendOutgoingMessages } from "./client.js";
import type { KatariLogger } from "./logger.js";
import { ConsoleKatariLogger } from "./logger.js";

// ===========================================================================
// Server hooks — server-specific behavior on protocol events
// ===========================================================================

export interface KatariServerHooks {
  onDelegate?(agent: Agent, delegationRef: DelegateRequest): Promise<void>;
  onDelegateAck?(delegation: Delegation, output: JsonValue): Promise<void>;
  onEscalate?(escalation: Escalation, capability: Capability): Promise<void>;
  onEscalateAck?(escalation: Escalation, output: JsonValue): Promise<void>;
  onTerminate?(delegation: Delegation): Promise<void>;
  onTerminateAck?(delegation: Delegation): Promise<void>;
  onThrow?(delegation: Delegation, message: string): Promise<void>;
}

// ===========================================================================
// Result type for handlers
// ===========================================================================

type HandlerResult<T = void> =
  | { response: T; messages: OutgoingMessage[] }
  | string;

// ===========================================================================
// KatariServer — protocol resource lifecycle + hooks
// ===========================================================================

export class KatariServer {
  private store: KatariStore;
  private hooks: KatariServerHooks;
  private endpoint: string;
  private pendingMessages: OutgoingMessage[] = [];

  constructor(
    endpoint: string,
    store: KatariStore,
    hooks: KatariServerHooks = {},
  ) {
    this.endpoint = endpoint;
    this.store = store;
    this.hooks = hooks;
  }

  // =========================================================================
  // POST /delegate — create Agent from AgentDefinition
  // =========================================================================

  async handleDelegate(
    req: DelegateRequest,
  ): Promise<HandlerResult<DelegateResponse>> {
    const agentDef = await this.store.getAgentDefinition(req.agent_def_ref.id);
    if (!agentDef) return `agent definition ${req.agent_def_ref.id} not found`;

    const agentId = randomUUID();
    const agent: Agent = {
      id: agentId,
      endpoint: this.endpoint,
      input: req.input,
      definition_ref: req.agent_def_ref,
      delegation_ref: req.delegation_ref,
      status: "RUNNING",
    };

    await this.store.createAgent(agent);

    this.pendingMessages = [];
    await this.hooks.onDelegate?.(agent, req);
    const messages = this.drainPendingMessages();

    return {
      response: { agent_ref: { id: agentId, endpoint: this.endpoint } },
      messages,
    };
  }

  // =========================================================================
  // POST /delegate_ack — child completed, parent receives result
  // =========================================================================

  async handleDelegateAck(req: DelegateAckRequest): Promise<HandlerResult> {
    const delegation = await this.store.getDelegation(req.delegation_ref.id);
    if (!delegation) return `delegation ${req.delegation_ref.id} not found`;

    // Delete the delegation (child agent + capabilities already cleaned up by sender)
    await this.store.deleteDelegation(delegation.id);

    this.pendingMessages = [];
    await this.hooks.onDelegateAck?.(delegation, req.output);
    const messages = this.drainPendingMessages();

    return { response: undefined, messages };
  }

  // =========================================================================
  // POST /escalate — child escalates to a capability on THIS server
  // =========================================================================

  async handleEscalate(req: EscalateRequest): Promise<HandlerResult> {
    const capability = await this.store.getCapability(req.capability_ref.id);
    if (!capability) return `capability ${req.capability_ref.id} not found`;

    // Create escalation record (managed by the escalating server, but we
    // receive the ref; the actual Escalation object lives on the child's server)
    this.pendingMessages = [];
    await this.hooks.onEscalate?.(
      {
        id: req.escalation_ref.id,
        endpoint: req.escalation_ref.endpoint,
        capability_ref: req.capability_ref,
        input: req.input,
      },
      capability,
    );
    const messages = this.drainPendingMessages();

    return { response: undefined, messages };
  }

  // =========================================================================
  // POST /escalate_ack — capability handler completed, child receives result
  // =========================================================================

  async handleEscalateAck(req: EscalateAckRequest): Promise<HandlerResult> {
    const escalation = await this.store.getEscalation(req.escalation_ref.id);
    if (!escalation) return `escalation ${req.escalation_ref.id} not found`;

    // Delete the escalation
    await this.store.deleteEscalation(escalation.id);

    this.pendingMessages = [];
    await this.hooks.onEscalateAck?.(escalation, req.output);
    const messages = this.drainPendingMessages();

    return { response: undefined, messages };
  }

  // =========================================================================
  // POST /terminate — parent tells child to stop
  // =========================================================================

  async handleTerminate(req: TerminateRequest): Promise<HandlerResult> {
    const delegation = await this.store.getDelegation(req.delegation_ref.id);
    if (!delegation) return `delegation ${req.delegation_ref.id} not found`;

    // Find agent by delegation
    const agents = await this.store.listAgents();
    const agent = agents.find(
      (a) =>
        a.delegation_ref?.id === delegation.id &&
        a.delegation_ref?.endpoint === delegation.endpoint,
    );
    if (agent) {
      await this.store.updateAgentStatus(agent.id, "TERMINATING");
    }

    this.pendingMessages = [];
    await this.hooks.onTerminate?.(delegation);
    const messages = this.drainPendingMessages();

    return { response: undefined, messages };
  }

  // =========================================================================
  // POST /terminate_ack — child confirms termination complete
  // =========================================================================

  async handleTerminateAck(req: TerminateAckRequest): Promise<HandlerResult> {
    const delegation = await this.store.getDelegation(req.delegation_ref.id);
    if (!delegation) return `delegation ${req.delegation_ref.id} not found`;

    // Clean up delegation
    await this.store.deleteDelegation(delegation.id);

    this.pendingMessages = [];
    await this.hooks.onTerminateAck?.(delegation);
    const messages = this.drainPendingMessages();

    return { response: undefined, messages };
  }

  // =========================================================================
  // POST /throw — child reports error
  // =========================================================================

  async handleThrow(req: ThrowRequest): Promise<HandlerResult> {
    const delegation = await this.store.getDelegation(req.delegation_ref.id);
    if (!delegation) return `delegation ${req.delegation_ref.id} not found`;

    this.pendingMessages = [];
    await this.hooks.onThrow?.(delegation, req.message);
    const messages = this.drainPendingMessages();

    return { response: undefined, messages };
  }

  // =========================================================================
  // GET endpoints — resource queries
  // =========================================================================

  async listAgentDefinitions(): Promise<AgentDefinition[]> {
    return this.store.listAgentDefinitions();
  }

  async listAgents(): Promise<Agent[]> {
    return this.store.listAgents();
  }

  async listDelegations(): Promise<Delegation[]> {
    return this.store.listDelegations();
  }

  async listTemplates(): Promise<Template[]> {
    return this.store.listTemplates();
  }

  async listCapabilities(): Promise<Capability[]> {
    return this.store.listCapabilities();
  }

  async listEscalations(): Promise<Escalation[]> {
    return this.store.listEscalations();
  }

  // =========================================================================
  // Outgoing message helpers — used by hooks to enqueue messages
  // =========================================================================

  /** Enqueue an outgoing message (called from hooks) */
  enqueueMessage(msg: OutgoingMessage): void {
    this.pendingMessages.push(msg);
  }

  private drainPendingMessages(): OutgoingMessage[] {
    const msgs = this.pendingMessages;
    this.pendingMessages = [];
    return msgs;
  }

  // =========================================================================
  // Convenience: delegate to another server
  // =========================================================================

  /** Create a delegation and send /delegate to the target server */
  async delegate(
    targetEndpoint: string,
    agentDefId: string,
    input: JsonValue,
    capabilityRefs: CapabilityRef[],
    delegationId?: string,
  ): Promise<{ delegationId: string; message: OutgoingMessage }> {
    delegationId = delegationId ?? randomUUID();
    const delegation: Delegation = {
      id: delegationId,
      endpoint: this.endpoint,
      agent_def_ref: { id: agentDefId, endpoint: targetEndpoint },
      input,
      capability_refs: capabilityRefs,
    };
    await this.store.createDelegation(delegation);

    const message: OutgoingMessage = {
      toEndpoint: targetEndpoint,
      kind: {
        type: "Delegate",
        body: {
          agent_def_ref: { id: agentDefId, endpoint: targetEndpoint },
          input,
          delegation_ref: { id: delegationId, endpoint: this.endpoint },
          capability_refs: capabilityRefs,
        },
        delegationId,
      },
    };

    return { delegationId, message };
  }

  /** Send delegate_ack to parent (cleans up local agent + capabilities first) */
  async sendDelegateAck(
    agentRef: AgentRef,
    output: JsonValue,
  ): Promise<OutgoingMessage | null> {
    const agent = await this.store.getAgent(agentRef.id);
    if (!agent || !agent.delegation_ref) return null;

    // Cascade delete: capabilities belonging to this agent
    await this.store.deleteCapabilitiesByAgent(agentRef);
    // Delete the agent
    await this.store.deleteAgent(agent.id);

    return {
      toEndpoint: agent.delegation_ref.endpoint,
      kind: {
        type: "DelegateAck",
        body: {
          delegation_ref: agent.delegation_ref,
          output,
        },
      },
    };
  }

  /** Send escalation to a capability's endpoint */
  async sendEscalate(
    capabilityRef: CapabilityRef,
    input: JsonValue,
    escalationId?: string,
  ): Promise<{ escalationId: string; message: OutgoingMessage }> {
    escalationId = escalationId ?? randomUUID();
    const escalation: Escalation = {
      id: escalationId,
      endpoint: this.endpoint,
      capability_ref: capabilityRef,
      input,
    };
    await this.store.createEscalation(escalation);

    const message: OutgoingMessage = {
      toEndpoint: capabilityRef.endpoint,
      kind: {
        type: "Escalate",
        body: {
          escalation_ref: { id: escalationId, endpoint: this.endpoint },
          capability_ref: capabilityRef,
          input,
        },
      },
    };

    return { escalationId, message };
  }

  /** Send escalate_ack back to the escalating server */
  async sendEscalateAck(
    escalationEndpoint: string,
    escalationId: string,
    output: JsonValue,
  ): Promise<OutgoingMessage> {
    return {
      toEndpoint: escalationEndpoint,
      kind: {
        type: "EscalateAck",
        body: {
          escalation_ref: { id: escalationId, endpoint: escalationEndpoint },
          output,
        },
      },
    };
  }

  // =========================================================================
  // Store access (for hooks)
  // =========================================================================

  getStore(): KatariStore {
    return this.store;
  }

  getEndpoint(): string {
    return this.endpoint;
  }
}

// ===========================================================================
// AgentContext — passed to external server handler functions
// ===========================================================================

export interface AgentContext {
  agentId: string;
  endpoint: string;
  delegationRef: { id: string; endpoint: string } | null;
  capabilityRefs: CapabilityRef[];
  /** Signal that fires when the agent is terminated */
  signal: AbortSignal;

  /** Escalate to a capability */
  escalate(capabilityRef: CapabilityRef, input: JsonValue): void;

  /** Delegate to another server's agent and wait for result */
  delegateAndWait(
    targetEndpoint: string,
    agentDefId: string,
    input: JsonValue,
    capabilityRefs?: CapabilityRef[],
  ): Promise<JsonValue>;
}

// ===========================================================================
// ExternalAgentServer — convenience for building external servers
// ===========================================================================

export type AgentHandlerFn = (
  args: JsonValue,
  ctx: AgentContext,
) => Promise<JsonValue>;

export async function startServer(opts: {
  port: number;
  endpoint: string;
  agentDefs: Record<string, { handler: AgentHandlerFn; description?: string }>;
  templateDefs?: Record<string, { description?: string; input_schema?: JsonValue; output_schema?: JsonValue }>;
  databaseUrl?: string;
  logger?: KatariLogger;
}): Promise<void> {
  const log = opts.logger ?? new ConsoleKatariLogger();

  // Mount path is derived from opts.endpoint's pathname.
  // e.g. "http://ai:8002/katari" → mount at "/katari"
  const endpointUrl = new URL(opts.endpoint);
  const katariMountPath = endpointUrl.pathname.replace(/\/+$/, "") || "/";

  let store: KatariStore;
  if (opts.databaseUrl) {
    const adapter = await createPostgresAdapter(opts.databaseUrl);
    const pgStore = new PostgresKatariStore(adapter);
    await pgStore.initialize();
    store = pgStore;
    log.log("info", "Using PostgreSQL store for protocol resources");
  } else {
    throw new Error(
      "databaseUrl is required. Refusing to start without persistent protocol store.",
    );
  }
  const pendingDelegateAcks = new Map<
    string,
    { resolve: (v: JsonValue) => void }
  >();

  // Running handler tracking: agentId → AbortController
  const runningHandlers = new Map<string, AbortController>();

  // UUID → handler name mapping (for onDelegate lookup)
  const agentDefIdToName = new Map<string, string>();

  // Register agent definitions (find-or-create: reuse existing UUID on restart)
  for (const [name, def] of Object.entries(opts.agentDefs)) {
    const existing = await store.getAgentDefinitionByName(name);
    const id = existing?.id ?? randomUUID();
    agentDefIdToName.set(id, name);
    await store.createAgentDefinition({
      id,
      endpoint: opts.endpoint,
      name,
      description: def.description ?? "",
      input_schema: null,
      output_schema: null,
    });
  }

  // Register templates (find-or-create: reuse existing UUID on restart)
  for (const [name, def] of Object.entries(opts.templateDefs ?? {})) {
    const existing = await store.getTemplateByName(name);
    const id = existing?.id ?? randomUUID();
    await store.createTemplate({
      id,
      endpoint: opts.endpoint,
      name,
      description: def.description,
      input_schema: def.input_schema ?? null,
      output_schema: def.output_schema ?? null,
    });
  }

  // KatariServer is declared here so runAgentHandler can reference it;
  // assigned after hooks are defined.
  let katariServer: KatariServer;

  /** Shared logic: build AgentContext and run the handler for an agent */
  function runAgentHandler(
    agentId: string,
    defId: string,
    input: JsonValue,
    delegationRef: { id: string; endpoint: string } | null,
    capabilityRefs: CapabilityRef[],
  ): void {
    // defId is a UUID; resolve to handler name via the UUID→name map
    const handlerName = agentDefIdToName.get(defId) ?? defId;
    const handlerEntry = opts.agentDefs[handlerName];
    if (!handlerEntry) {
      log.log("warn", `No handler for definition '${defId}' (name: '${handlerName}')`);
      return;
    }

    const ac = new AbortController();
    runningHandlers.set(agentId, ac);

    const ctx: AgentContext = {
      agentId,
      endpoint: opts.endpoint,
      delegationRef,
      capabilityRefs,
      signal: ac.signal,

      escalate(capabilityRef, capInput) {
        if (ac.signal.aborted) return;
        katariServer
          .sendEscalate(capabilityRef, capInput)
          .then(({ message }) => {
            sendOutgoingMessages([message], log).catch((e) =>
              log.log("error", `escalate send failed: ${e}`),
            );
          });
      },

      async delegateAndWait(targetEndpoint, agentDefId, delegateInput, capRefs) {
        const { delegationId, message } = await katariServer.delegate(
          targetEndpoint,
          agentDefId,
          delegateInput,
          capRefs ?? [],
        );
        sendOutgoingMessages([message], log).catch((e) =>
          log.log("error", `delegate send failed: ${e}`),
        );
        return new Promise<JsonValue>((resolve) => {
          pendingDelegateAcks.set(delegationId, { resolve });
        });
      },
    };

    handlerEntry
      .handler(input, ctx)
      .then(async (result) => {
        runningHandlers.delete(agentId);
        if (ac.signal.aborted) return;
        const msg = await katariServer.sendDelegateAck(
          { id: agentId, endpoint: opts.endpoint },
          result,
        );
        if (msg) {
          sendOutgoingMessages([msg], log).catch((e) =>
            log.log("error", `delegate_ack send failed: ${e}`),
          );
        }
      })
      .catch(async (err) => {
        runningHandlers.delete(agentId);
        if (ac.signal.aborted) return;
        log.log("error", `Handler error for ${defId}: ${err}`);
        const msg = await katariServer.sendDelegateAck(
          { id: agentId, endpoint: opts.endpoint },
          null,
        );
        if (msg) {
          sendOutgoingMessages([msg], log).catch(() => {});
        }
      });
  }

  const hooks: KatariServerHooks = {
    async onDelegate(agent, req) {
      runAgentHandler(
        agent.id,
        agent.definition_ref.id,
        agent.input,
        agent.delegation_ref,
        req.capability_refs,
      );
    },

    async onDelegateAck(delegation, output) {
      const pending = pendingDelegateAcks.get(delegation.id);
      if (pending) {
        pending.resolve(output);
        pendingDelegateAcks.delete(delegation.id);
      }
    },

    async onTerminate(delegation) {
      // Find and abort the running handler
      const agents = await store.listAgents();
      const agent = agents.find((a) => a.delegation_ref?.id === delegation.id);
      if (agent) {
        const ac = runningHandlers.get(agent.id);
        if (ac) {
          ac.abort();
          runningHandlers.delete(agent.id);
        }
        await store.deleteCapabilitiesByAgent({
          id: agent.id,
          endpoint: opts.endpoint,
        });
        await store.deleteAgent(agent.id);
      }

      // Send terminate_ack back
      katariServer.enqueueMessage({
        toEndpoint: delegation.endpoint,
        kind: {
          type: "TerminateAck",
          body: {
            delegation_ref: {
              id: delegation.id,
              endpoint: delegation.endpoint,
            },
          },
        },
      });
    },
  };

  katariServer = new KatariServer(opts.endpoint, store, hooks);

  // =========================================================================
  // Restore running agents from protocol store
  // =========================================================================

  const existingAgents = await store.listAgents();
  const ownAgents = existingAgents.filter(
    (a) => a.endpoint === opts.endpoint && a.status === "RUNNING",
  );

  for (const agent of ownAgents) {
    // Get capability_refs from the delegation (stored on the runtime side
    // in the shared protocol DB).
    let capabilityRefs: CapabilityRef[] = [];
    if (agent.delegation_ref) {
      const delegation = await store.getDelegation(agent.delegation_ref.id);
      if (delegation) {
        capabilityRefs = delegation.capability_refs;
      }
    }

    runAgentHandler(
      agent.id,
      agent.definition_ref.id,
      agent.input,
      agent.delegation_ref,
      capabilityRefs,
    );
    log.log(
      "info",
      `Restored agent ${agent.id} (${agent.definition_ref.id})`,
    );
  }

  // =========================================================================
  // HTTP server
  // =========================================================================

  const app = new Hono();
  app.use("*", cors());

  const katariRouter = buildKatariRouter(
    () => katariServer,
    (msgs) => {
      if (msgs.length > 0) {
        sendOutgoingMessages(msgs, log).catch((e) =>
          log.log("error", `outgoing messages failed: ${e}`),
        );
      }
    },
    log,
  );
  app.route(katariMountPath, katariRouter);

  app.get("/health", (c) => c.json({ ok: true }));

  log.log("info", `External server starting on port ${opts.port}`);
  log.log("info", `Katari protocol at ${opts.endpoint}`);
  serve({ fetch: app.fetch, port: opts.port });
}
