CREATE TABLE "repository" (
	"id" TEXT PRIMARY KEY,
	"owner" TEXT NOT NULL,
	"name" TEXT NOT NULL,
	UNIQUE ("owner", "name")
) STRICT, WITHOUT ROWID;

CREATE TABLE "pull_request" (
	"id" TEXT PRIMARY KEY,
	"repository" TEXT NOT NULL REFERENCES "repository",
	"number" INTEGER NOT NULL,
	UNIQUE ("repository", "number")
) STRICT, WITHOUT ROWID;

CREATE TABLE "commit" (
	"id" TEXT PRIMARY KEY,
	"oid" TEXT NOT NULL UNIQUE -- git hash
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
	)),
	"status" TEXT NOT NULL CHECK ("status" IN (
		'COMPLETED',
		'IN_PROGRESS',
		'PENDING',
		'QUEUED',
		'REQUESTED',
		'WAITING'
	))
) STRICT, WITHOUT ROWID;

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
	))
) STRICT, WITHOUT ROWID;
