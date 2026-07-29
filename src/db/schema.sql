-- GitHub API types

CREATE TABLE "repository" (
	"id" TEXT PRIMARY KEY,
	"owner" TEXT NOT NULL,
	"name" TEXT NOT NULL,
	UNIQUE ("owner", "name")
) STRICT, WITHOUT ROWID;

CREATE TABLE "pull_request" (
	"id" TEXT PRIMARY KEY,
	"repository" TEXT NOT NULL REFERENCES "repository",
	"number" INTEGER NOT NULL CHECK ("number" > 0),
	"state" TEXT NOT NULL CHECK ("state" IN (
		'CLOSED',
		'MERGED',
		'OPEN'
	)),
	"head_ref_oid" TEXT NOT NULL,
	"merge_base_oid" TEXT, -- null if the PR has no commits
	UNIQUE ("repository", "number")
) STRICT, WITHOUT ROWID;

CREATE TABLE "commit" (
	"id" TEXT PRIMARY KEY,
	"repository" TEXT NOT NULL REFERENCES "repository",
	"oid" TEXT NOT NULL,
	"parent" TEXT REFERENCES "commit",
	UNIQUE ("repository", "oid")
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
	"name" TEXT NOT NULL
) STRICT, WITHOUT ROWID;

CREATE TABLE "check_suite" (
	"id" TEXT PRIMARY KEY,
	"repository" TEXT NOT NULL REFERENCES "repository",
	"commit" TEXT NOT NULL REFERENCES "commit",
	"app" TEXT NOT NULL REFERENCES "app",
	"created_at" TEXT NOT NULL, -- ISO8601
	"updated_at" TEXT NOT NULL, -- ISO8601
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

CREATE TABLE "check_run" (
	"id" TEXT PRIMARY KEY,
	"suite" TEXT NOT NULL REFERENCES "check_suite",
	"name" TEXT NOT NULL,
	"started_at" TEXT NOT NULL, -- ISO8601
	"completed_at" TEXT, -- ISO8601
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
