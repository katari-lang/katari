CREATE TABLE "oauth_clients" (
	"project_id" uuid NOT NULL,
	"name" text NOT NULL,
	"issuer" text NOT NULL,
	"authorize_endpoint" text NOT NULL,
	"token_endpoint" text NOT NULL,
	"client_id" text NOT NULL,
	"client_secret" text,
	"scopes" jsonb NOT NULL,
	CONSTRAINT "oauth_clients_project_id_name_pk" PRIMARY KEY("project_id","name")
);
--> statement-breakpoint
ALTER TABLE "instances" DROP CONSTRAINT "instances_kind_check";--> statement-breakpoint
ALTER TABLE "oauth_clients" ADD CONSTRAINT "oauth_clients_project_id_projects_id_fk" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "instances" ADD CONSTRAINT "instances_kind_check" CHECK ("instances"."kind" in ('core', 'api', 'ffi', 'http', 'webhook', 'mcp', 'time', 'oauth'));