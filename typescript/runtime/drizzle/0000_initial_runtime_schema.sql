CREATE TABLE "blobs" (
	"project_id" uuid NOT NULL,
	"blob_id" uuid NOT NULL,
	"owner_instance_id" uuid,
	"hash" text NOT NULL,
	"size" bigint NOT NULL,
	"content_type" text,
	"semantic_kind" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "blobs_project_id_blob_id_pk" PRIMARY KEY("project_id","blob_id")
);
--> statement-breakpoint
CREATE TABLE "scopes" (
	"project_id" uuid NOT NULL,
	"scope_id" integer NOT NULL,
	"parent_scope_id" integer,
	"owner_instance_id" uuid,
	"values" jsonb NOT NULL,
	CONSTRAINT "scopes_project_id_scope_id_pk" PRIMARY KEY("project_id","scope_id")
);
--> statement-breakpoint
CREATE TABLE "threads" (
	"project_id" uuid NOT NULL,
	"instance_id" uuid NOT NULL,
	"thread_id" integer NOT NULL,
	"kind" text NOT NULL,
	"parent_thread_id" integer,
	"parent_call_id" integer,
	"scope_id" integer NOT NULL,
	"block_id" integer NOT NULL,
	"status" text NOT NULL,
	"payload" jsonb NOT NULL,
	CONSTRAINT "threads_project_id_instance_id_thread_id_pk" PRIMARY KEY("project_id","instance_id","thread_id"),
	CONSTRAINT "threads_status_check" CHECK ("threads"."status" in ('running', 'cancelling')),
	CONSTRAINT "threads_kind_check" CHECK ("threads"."kind" in ('agent', 'sequence', 'primitive', 'construct', 'request', 'match', 'for', 'handle', 'parallel', 'delegate', 'external'))
);
--> statement-breakpoint
CREATE TABLE "core_instances" (
	"instance_id" uuid PRIMARY KEY NOT NULL,
	"target" jsonb NOT NULL,
	"snapshot_id" uuid NOT NULL,
	"ambient_generics" jsonb,
	"engine_state" jsonb NOT NULL
);
--> statement-breakpoint
CREATE TABLE "delegations" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"project_id" uuid NOT NULL,
	"caller_instance_id" uuid,
	"from_reactor" text NOT NULL,
	"to_reactor" text NOT NULL,
	"state" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "delegations_state_check" CHECK ("delegations"."state" in ('running', 'cancelling'))
);
--> statement-breakpoint
CREATE TABLE "escalations" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"project_id" uuid NOT NULL,
	"raiser_instance_id" uuid NOT NULL,
	"delegation_id" uuid NOT NULL,
	"from_reactor" text NOT NULL,
	"to_reactor" text NOT NULL,
	"request" text NOT NULL,
	"argument" jsonb,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "ffi_instances" (
	"instance_id" uuid PRIMARY KEY NOT NULL,
	"snapshot_id" uuid NOT NULL,
	"key" text NOT NULL,
	"argument" jsonb,
	"status" text NOT NULL
);
--> statement-breakpoint
CREATE TABLE "http_instances" (
	"instance_id" uuid PRIMARY KEY NOT NULL,
	"status" text NOT NULL
);
--> statement-breakpoint
CREATE TABLE "instances" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"project_id" uuid NOT NULL,
	"delegation_id" uuid,
	"kind" text NOT NULL,
	"caller_reactor" text,
	"status" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "instances_status_check" CHECK ("instances"."status" in ('running', 'cancelling')),
	CONSTRAINT "instances_kind_check" CHECK ("instances"."kind" in ('core', 'api', 'ffi', 'http'))
);
--> statement-breakpoint
CREATE TABLE "outbox" (
	"seq" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"project_id" uuid NOT NULL,
	"event" jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "run_escalations_audit" (
	"run_id" uuid NOT NULL,
	"escalation_id" uuid NOT NULL,
	"question" jsonb,
	"answer" jsonb,
	"answered_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "run_escalations_audit_run_id_escalation_id_pk" PRIMARY KEY("run_id","escalation_id")
);
--> statement-breakpoint
CREATE TABLE "runs" (
	"id" uuid PRIMARY KEY NOT NULL,
	"project_id" uuid NOT NULL,
	"snapshot_id" uuid,
	"name" text NOT NULL,
	"qualified_name" text NOT NULL,
	"argument" jsonb,
	"state" text DEFAULT 'running' NOT NULL,
	"result" jsonb,
	"error_message" text,
	"cancel_reason" text,
	"completed_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "runs_state_check" CHECK ("runs"."state" in ('running', 'cancelling', 'done', 'error', 'cancelled'))
);
--> statement-breakpoint
CREATE TABLE "env_entries" (
	"project_id" uuid NOT NULL,
	"key" text NOT NULL,
	"value" text NOT NULL,
	"is_secret" boolean DEFAULT false NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "env_entries_project_id_key_pk" PRIMARY KEY("project_id","key")
);
--> statement-breakpoint
CREATE TABLE "modules" (
	"project_id" uuid NOT NULL,
	"hash" text NOT NULL,
	"ir" jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "modules_project_id_hash_pk" PRIMARY KEY("project_id","hash")
);
--> statement-breakpoint
CREATE TABLE "projects" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"name" text NOT NULL,
	"description" text,
	"readme" text,
	"head_snapshot_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "projects_name_unique" UNIQUE("name")
);
--> statement-breakpoint
CREATE TABLE "snapshots" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"project_id" uuid NOT NULL,
	"modules" jsonb NOT NULL,
	"sidecar_bundle" jsonb,
	"message" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "blobs" ADD CONSTRAINT "blobs_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "blobs" ADD CONSTRAINT "blobs_owner_instance_id_instances_id_fk" FOREIGN KEY ("owner_instance_id") REFERENCES "public"."instances"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "scopes" ADD CONSTRAINT "scopes_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "scopes" ADD CONSTRAINT "scopes_owner_instance_id_instances_id_fk" FOREIGN KEY ("owner_instance_id") REFERENCES "public"."instances"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "threads" ADD CONSTRAINT "threads_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "threads" ADD CONSTRAINT "threads_instance_id_instances_id_fk" FOREIGN KEY ("instance_id") REFERENCES "public"."instances"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "core_instances" ADD CONSTRAINT "core_instances_instance_id_instances_id_fk" FOREIGN KEY ("instance_id") REFERENCES "public"."instances"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "core_instances" ADD CONSTRAINT "core_instances_snapshot_id_snapshots_id_fk" FOREIGN KEY ("snapshot_id") REFERENCES "public"."snapshots"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "delegations" ADD CONSTRAINT "delegations_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "delegations" ADD CONSTRAINT "delegations_caller_instance_id_instances_id_fk" FOREIGN KEY ("caller_instance_id") REFERENCES "public"."instances"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "escalations" ADD CONSTRAINT "escalations_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "escalations" ADD CONSTRAINT "escalations_raiser_instance_id_instances_id_fk" FOREIGN KEY ("raiser_instance_id") REFERENCES "public"."instances"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ffi_instances" ADD CONSTRAINT "ffi_instances_instance_id_instances_id_fk" FOREIGN KEY ("instance_id") REFERENCES "public"."instances"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ffi_instances" ADD CONSTRAINT "ffi_instances_snapshot_id_snapshots_id_fk" FOREIGN KEY ("snapshot_id") REFERENCES "public"."snapshots"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "http_instances" ADD CONSTRAINT "http_instances_instance_id_instances_id_fk" FOREIGN KEY ("instance_id") REFERENCES "public"."instances"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "instances" ADD CONSTRAINT "instances_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "instances" ADD CONSTRAINT "instances_delegation_id_delegations_id_fk" FOREIGN KEY ("delegation_id") REFERENCES "public"."delegations"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "outbox" ADD CONSTRAINT "outbox_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "run_escalations_audit" ADD CONSTRAINT "run_escalations_audit_run_id_runs_id_fk" FOREIGN KEY ("run_id") REFERENCES "public"."runs"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "runs" ADD CONSTRAINT "runs_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "runs" ADD CONSTRAINT "runs_snapshot_id_snapshots_id_fk" FOREIGN KEY ("snapshot_id") REFERENCES "public"."snapshots"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "env_entries" ADD CONSTRAINT "env_entries_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "modules" ADD CONSTRAINT "modules_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "projects" ADD CONSTRAINT "projects_head_snapshot_id_snapshots_id_fk" FOREIGN KEY ("head_snapshot_id") REFERENCES "public"."snapshots"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "snapshots" ADD CONSTRAINT "snapshots_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "blobs_owner_instance_id_idx" ON "blobs" USING btree ("owner_instance_id");--> statement-breakpoint
CREATE INDEX "scopes_owner_instance_id_idx" ON "scopes" USING btree ("owner_instance_id");--> statement-breakpoint
CREATE INDEX "delegations_caller_instance_id_idx" ON "delegations" USING btree ("caller_instance_id");--> statement-breakpoint
CREATE INDEX "escalations_project_id_idx" ON "escalations" USING btree ("project_id");--> statement-breakpoint
CREATE INDEX "escalations_raiser_instance_id_idx" ON "escalations" USING btree ("raiser_instance_id");--> statement-breakpoint
CREATE INDEX "instances_project_id_idx" ON "instances" USING btree ("project_id");--> statement-breakpoint
CREATE INDEX "instances_delegation_id_idx" ON "instances" USING btree ("delegation_id");--> statement-breakpoint
CREATE INDEX "outbox_project_id_idx" ON "outbox" USING btree ("project_id");--> statement-breakpoint
CREATE INDEX "runs_project_id_idx" ON "runs" USING btree ("project_id");--> statement-breakpoint
CREATE INDEX "snapshots_project_id_idx" ON "snapshots" USING btree ("project_id");