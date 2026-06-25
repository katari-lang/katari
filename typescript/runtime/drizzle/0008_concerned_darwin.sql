CREATE TABLE "ffi_calls" (
	"delegation" uuid PRIMARY KEY NOT NULL,
	"project_id" uuid NOT NULL,
	"instance_id" uuid NOT NULL,
	"snapshot_id" uuid NOT NULL,
	"key" text NOT NULL,
	"argument" jsonb,
	"caller_reactor" text NOT NULL,
	"status" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "delegations" ADD COLUMN "from_reactor" text NOT NULL;--> statement-breakpoint
ALTER TABLE "delegations" ADD COLUMN "to_reactor" text NOT NULL;--> statement-breakpoint
ALTER TABLE "escalations" ADD COLUMN "delegation_id" uuid NOT NULL;--> statement-breakpoint
ALTER TABLE "escalations" ADD COLUMN "from_reactor" text NOT NULL;--> statement-breakpoint
ALTER TABLE "escalations" ADD COLUMN "to_reactor" text NOT NULL;--> statement-breakpoint
ALTER TABLE "ffi_calls" ADD CONSTRAINT "ffi_calls_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ffi_calls" ADD CONSTRAINT "ffi_calls_snapshot_id_snapshots_id_fk" FOREIGN KEY ("snapshot_id") REFERENCES "public"."snapshots"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "ffi_calls_project_id_idx" ON "ffi_calls" USING btree ("project_id");