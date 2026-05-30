-- Runs FIRST in /docker-entrypoint-initdb.d/ (alphabetical sort puts
-- "00_pre.sql" ahead of "001_initial.sql"). Sets up extensions + log
-- markers that every later migration depends on.
--
-- This file is staging-only — production uses different operator-run
-- bootstrap. See infra/wrangler/pg-platform/Dockerfile for context.

-- pgvector — mig 040+ does CREATE EXTENSION vector and assumes the
-- shared library is loadable. pgvector/pgvector:pg16 ships the .so;
-- this just registers it in the freshly-init'd database.
CREATE EXTENSION IF NOT EXISTS vector;

-- Standard extensions we use across migrations.
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Match prod timezone — every timestamp comparison in tests assumes UTC.
SET TIME ZONE 'UTC';

-- Log marker. Shows in `wrangler tail` so operators know this is a
-- cold-start init (vs an unexpected mid-life restart).
DO $$
BEGIN
  RAISE NOTICE 'pg-platform staging cold start — re-applying 63 migrations against fresh PGDATA';
END $$;
