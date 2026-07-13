CREATE TABLE "mcp_parked_instances" (
	"instance_id" uuid PRIMARY KEY NOT NULL,
	"call" jsonb NOT NULL
);
--> statement-breakpoint
ALTER TABLE "mcp_parked_instances" ADD CONSTRAINT "mcp_parked_instances_instance_id_mcp_instances_instance_id_fk" FOREIGN KEY ("instance_id") REFERENCES "public"."mcp_instances"("instance_id") ON DELETE cascade ON UPDATE no action;