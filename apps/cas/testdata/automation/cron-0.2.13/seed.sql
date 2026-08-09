-- Frozen from tag cron-v0.2.13, commit 90fd7ee4e5f94e95218ca13a4ae0984b1de9bd8a.
-- Source apps/cron/scripts/cron.zig SHA-256:
-- 1198f4cb246799fc9b68142ab4f34c0626580223cffffa7ffeaaddc4c4bb2d21
PRAGMA foreign_keys = OFF;

CREATE TABLE automations (
  id text primary key,
  name text not null,
  prompt text not null,
  status text not null,
  next_run_at integer,
  last_run_at integer,
  cwds text not null,
  rrule text not null,
  created_at integer not null,
  updated_at integer not null
);

CREATE TABLE automation_runs (
  thread_id text primary key,
  automation_id text not null,
  status text not null,
  read_at integer,
  thread_title text,
  source_cwd text,
  inbox_title text,
  inbox_summary text,
  created_at integer not null,
  updated_at integer not null,
  archived_user_message text,
  archived_assistant_message text,
  archived_reason text
);

CREATE TABLE inbox_items (
  id text primary key,
  title text,
  description text,
  thread_id text,
  read_at integer,
  created_at integer
);

INSERT INTO automations (
  id, name, prompt, status, next_run_at, last_run_at, cwds, rrule,
  created_at, updated_at
) VALUES (
  'cron-0.2.13-oracle',
  'Cron 0.2.13 Oracle',
  'initial prompt',
  'ACTIVE',
  NULL,
  NULL,
  '["/tmp/cron fixture","/var/empty"]',
  'FREQ=DAILY;BYHOUR=9;BYMINUTE=15',
  4102358400000,
  4102358400000
);

INSERT INTO automation_runs (
  thread_id, automation_id, status, read_at, thread_title, source_cwd,
  inbox_title, inbox_summary, created_at, updated_at,
  archived_user_message, archived_assistant_message, archived_reason
) VALUES (
  'thread-existing',
  'cron-0.2.13-oracle',
  'COMPLETED',
  NULL,
  'Existing run',
  '/tmp/cron fixture',
  'Existing inbox title',
  'Existing inbox summary',
  4102358400000,
  4102358400000,
  'existing user message',
  'existing assistant message',
  'existing reason'
);

INSERT INTO inbox_items (
  id, title, description, thread_id, read_at, created_at
) VALUES (
  'inbox-existing',
  'Existing inbox title',
  'Existing inbox description',
  'thread-existing',
  NULL,
  4102358400000
);

CREATE TRIGGER freeze_oracle_updated_at
AFTER UPDATE ON automations
WHEN NEW.id = 'cron-0.2.13-oracle' AND NEW.updated_at <> 4102444800000
BEGIN
  UPDATE automations
  SET updated_at = 4102444800000
  WHERE id = NEW.id;
END;
