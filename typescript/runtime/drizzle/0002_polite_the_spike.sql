CREATE TABLE "mcp_instances" (
	"instance_id" uuid PRIMARY KEY NOT NULL,
	"status" text NOT NULL
);
--> statement-breakpoint
ALTER TABLE "instances" DROP CONSTRAINT "instances_kind_check";--> statement-breakpoint
ALTER TABLE "mcp_instances" ADD CONSTRAINT "mcp_instances_instance_id_instances_id_fk" FOREIGN KEY ("instance_id") REFERENCES "public"."instances"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "instances" ADD CONSTRAINT "instances_kind_check" CHECK ("instances"."kind" in ('core', 'api', 'ffi', 'http', 'webhook', 'mcp'));