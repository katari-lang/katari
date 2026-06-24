CREATE TABLE "outbox" (
	"seq" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"project_id" uuid NOT NULL,
	"instance_id" uuid,
	"event" jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "delegations" DROP CONSTRAINT "delegations_state_check";--> statement-breakpoint
ALTER TABLE "escalations" DROP CONSTRAINT "escalations_state_check";--> statement-breakpoint
ALTER TABLE "delegations" ADD COLUMN "result" jsonb;--> statement-breakpoint
ALTER TABLE "escalations" ADD COLUMN "answer" jsonb;--> statement-breakpoint
ALTER TABLE "escalations" ADD COLUMN "updated_at" timestamp with time zone DEFAULT now() NOT NULL;--> statement-breakpoint
ALTER TABLE "outbox" ADD CONSTRAINT "outbox_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "outbox" ADD CONSTRAINT "outbox_instance_id_instances_id_fk" FOREIGN KEY ("instance_id") REFERENCES "public"."instances"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "outbox_project_id_idx" ON "outbox" USING btree ("project_id");--> statement-breakpoint
ALTER TABLE "delegations" ADD CONSTRAINT "delegations_state_check" CHECK ("delegations"."state" in ('running', 'cancelling', 'done', 'gone'));--> statement-breakpoint
ALTER TABLE "escalations" ADD CONSTRAINT "escalations_state_check" CHECK ("escalations"."state" in ('open', 'answered'));