-- GitHub API types

CREATE TABLE "repository" (
	"id" TEXT PRIMARY KEY,
	"owner" TEXT NOT NULL,
	"name" TEXT NOT NULL,
	"created_at" TEXT NOT NULL CHECK ("created_at" IS strftime('%Y-%m-%dT%H:%M:%fZ', "created_at")),
	"updated_at" TEXT NOT NULL CHECK ("updated_at" IS strftime('%Y-%m-%dT%H:%M:%fZ', "updated_at")),
	"archived_at" TEXT CHECK ("archived_at" IS strftime('%Y-%m-%dT%H:%M:%fZ', "archived_at")),
	"pushed_at" TEXT CHECK ("pushed_at" IS strftime('%Y-%m-%dT%H:%M:%fZ', "pushed_at")),
	UNIQUE ("owner", "name")
) STRICT, WITHOUT ROWID;

CREATE INDEX "idx_repository_created_at" ON "repository" ("created_at");
CREATE INDEX "idx_repository_updated_at" ON "repository" ("updated_at");

CREATE TABLE "pull_request" (
	"id" TEXT PRIMARY KEY,
	"repository" TEXT NOT NULL REFERENCES "repository",
	"number" INT NOT NULL CHECK ("number" > 0),
	"state" TEXT NOT NULL CHECK ("state" IN (
		'CLOSED',
		'MERGED',
		'OPEN'
	)),
	"created_at" TEXT NOT NULL CHECK ("created_at" IS strftime('%Y-%m-%dT%H:%M:%fZ', "created_at")),
	"updated_at" TEXT NOT NULL CHECK ("updated_at" IS strftime('%Y-%m-%dT%H:%M:%fZ', "updated_at")),
	"published_at" TEXT CHECK ("published_at" IS strftime('%Y-%m-%dT%H:%M:%fZ', "published_at")),
	"merged_at" TEXT CHECK ("merged_at" IS strftime('%Y-%m-%dT%H:%M:%fZ', "merged_at")),
	"closed_at" TEXT CHECK ("closed_at" IS strftime('%Y-%m-%dT%H:%M:%fZ', "closed_at")),
	"head_ref_oid" TEXT NOT NULL,
	"merge_base_oid" TEXT, -- null if the PR has no commits
	UNIQUE ("repository", "number")
) STRICT, WITHOUT ROWID;

CREATE INDEX "idx_pull_request_created_at" ON "pull_request" ("created_at");
CREATE INDEX "idx_pull_request_updated_at" ON "pull_request" ("updated_at");

CREATE TABLE "commit" (
	"id" TEXT PRIMARY KEY,
	"repository" TEXT NOT NULL REFERENCES "repository",
	"oid" TEXT NOT NULL,
	"authored_at" TEXT NOT NULL CHECK ("authored_at" IS strftime('%Y-%m-%dT%H:%M:%fZ', "authored_at")),
	"committed_at" TEXT NOT NULL CHECK ("committed_at" IS strftime('%Y-%m-%dT%H:%M:%fZ', "committed_at")),
	UNIQUE ("repository", "oid")
) STRICT, WITHOUT ROWID;

CREATE INDEX "idx_commit_authored_at" ON "commit" ("authored_at");
CREATE INDEX "idx_commit_committed_at" ON "commit" ("committed_at");

CREATE TABLE "commit_parent" (
	"commit" TEXT NOT NULL REFERENCES "commit",
	"index" INT NOT NULL CHECK ("index" >= 0),
	"parent" TEXT NOT NULL REFERENCES "commit",
	PRIMARY KEY ("commit", "index"),
	UNIQUE ("commit", "parent")
) STRICT, WITHOUT ROWID;

CREATE TABLE "ref" (
	"id" TEXT PRIMARY KEY,
	"repository" TEXT NOT NULL REFERENCES "repository",
	"prefix" TEXT NOT NULL,
	"name" TEXT NOT NULL,
	"target_oid" TEXT NOT NULL,
	UNIQUE ("repository", "prefix", "name")
) STRICT, WITHOUT ROWID;

CREATE TABLE "app" (
	"id" TEXT PRIMARY KEY,
	"slug" TEXT NOT NULL UNIQUE,
	"name" TEXT NOT NULL,
	"created_at" TEXT NOT NULL CHECK ("created_at" IS strftime('%Y-%m-%dT%H:%M:%fZ', "created_at")),
	"updated_at" TEXT NOT NULL CHECK ("updated_at" IS strftime('%Y-%m-%dT%H:%M:%fZ', "updated_at"))
) STRICT, WITHOUT ROWID;

CREATE INDEX "idx_app_created_at" ON "app" ("created_at");
CREATE INDEX "idx_app_updated_at" ON "app" ("updated_at");

CREATE TABLE "check_suite" (
	"id" TEXT PRIMARY KEY,
	"repository" TEXT NOT NULL REFERENCES "repository",
	"commit" TEXT NOT NULL REFERENCES "commit",
	"app" TEXT NOT NULL REFERENCES "app",
	"created_at" TEXT NOT NULL CHECK ("created_at" IS strftime('%Y-%m-%dT%H:%M:%fZ', "created_at")),
	"updated_at" TEXT NOT NULL CHECK ("updated_at" IS strftime('%Y-%m-%dT%H:%M:%fZ', "updated_at")),
	"status" TEXT NOT NULL CHECK ("status" IN (
		'COMPLETED',
		'IN_PROGRESS',
		'PENDING',
		'QUEUED',
		'REQUESTED',
		'WAITING'
	)),
	"conclusion" TEXT CHECK ("conclusion" IN (
		'ACTION_REQUIRED',
		'CANCELLED',
		'FAILURE',
		'NEUTRAL',
		'SKIPPED',
		'STALE',
		'STARTUP_FAILURE',
		'SUCCESS',
		'TIMED_OUT'
	))
) STRICT, WITHOUT ROWID;

CREATE INDEX "idx_check_suite_commit" ON "check_suite" ("commit");
CREATE INDEX "idx_check_suite_created_at" ON "check_suite" ("created_at");
CREATE INDEX "idx_check_suite_updated_at" ON "check_suite" ("updated_at");

CREATE TABLE "check_run" (
	"id" TEXT PRIMARY KEY,
	"suite" TEXT NOT NULL REFERENCES "check_suite",
	"name" TEXT NOT NULL,
	"started_at" TEXT NOT NULL CHECK ("started_at" IS strftime('%Y-%m-%dT%H:%M:%fZ', "started_at")),
	"completed_at" TEXT CHECK ("completed_at" IS strftime('%Y-%m-%dT%H:%M:%fZ', "completed_at")),
	"external_id" TEXT,
	"status" TEXT NOT NULL CHECK ("status" IN (
		'COMPLETED',
		'IN_PROGRESS',
		'PENDING',
		'QUEUED',
		'REQUESTED',
		'WAITING'
	)),
	"conclusion" TEXT CHECK ("conclusion" IN (
		'ACTION_REQUIRED',
		'CANCELLED',
		'FAILURE',
		'NEUTRAL',
		'SKIPPED',
		'STALE',
		'STARTUP_FAILURE',
		'SUCCESS',
		'TIMED_OUT'
	))
) STRICT, WITHOUT ROWID;

CREATE INDEX "idx_check_run_suite" ON "check_run" ("suite");
CREATE INDEX "idx_check_run_started_at" ON "check_run" ("started_at");
CREATE INDEX "idx_check_run_completed_at" ON "check_run" ("completed_at");

-- application state

CREATE TABLE "scan" (
	"targets" TEXT NOT NULL,
	"historical" INT NOT NULL CHECK ("historical" IN (TRUE, FALSE)),
	"targets_idx" INT NOT NULL CHECK ("targets_idx" >= 0),
	"prss_idx" INT NOT NULL CHECK ("prss_idx" >= 0),
	"pr" TEXT REFERENCES "pull_request",
	"commit" TEXT REFERENCES "commit",
	"check_suite" TEXT REFERENCES "check_suite",
	"updated_at" TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
	PRIMARY KEY ("targets", "historical")
) STRICT, WITHOUT ROWID;

CREATE TRIGGER "scan_updated_at"
AFTER UPDATE ON "scan"
FOR EACH ROW
BEGIN
	UPDATE "scan" SET "updated_at" = CURRENT_TIMESTAMP
	WHERE "targets" = NEW."targets" AND "historical" = NEW."historical";
END;
