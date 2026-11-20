ALTER TABLE "user" ADD COLUMN "username" text;
--> statement-breakpoint
ALTER TABLE "user" ADD COLUMN "password_hash" text;
--> statement-breakpoint
ALTER TABLE "user" ADD COLUMN "is_admin" boolean DEFAULT false NOT NULL;
--> statement-breakpoint
CREATE UNIQUE INDEX "user_username_unique" ON "user" ("username");
