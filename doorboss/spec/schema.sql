-- DoorBoss backend schema (Postgres dialect; AI Studio's managed DB maps 1:1)
-- Every table carries created_at/updated_at. Soft-delete via deleted_at where it matters.

CREATE TABLE teams (
  id            text PRIMARY KEY,
  name          text NOT NULL,
  manager_id    text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE users (
  id            text PRIMARY KEY,                      -- matches the portal login user id
  name          text NOT NULL,
  email         text UNIQUE,
  phone         text,
  role          text NOT NULL CHECK (role IN ('rep','manager','admin')),
  team_id       text REFERENCES teams(id),
  color         text NOT NULL DEFAULT '#2b7fff',       -- pin/avatar color
  ghl_user_id   text,                                  -- GHL user to own contacts/appointments
  active        boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE territories (
  id                text PRIMARY KEY,
  team_id           text REFERENCES teams(id),
  name              text NOT NULL,
  color             text NOT NULL DEFAULT '#2b7fff',
  polygon           jsonb NOT NULL,                    -- [[lat,lng],...] closed ring, >=3 points
  assigned_user_ids jsonb NOT NULL DEFAULT '[]',       -- ["u2","u3"]
  reknock_days      int NOT NULL DEFAULT 3,            -- not_home becomes knockable again after N days
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE properties (
  id                 text PRIMARY KEY,
  lat                double precision NOT NULL,
  lng                double precision NOT NULL,
  address            text NOT NULL,
  city               text,
  state              text DEFAULT 'CO',
  zip                text,
  owner_name         text,
  owner_phone        text,
  owner_email        text,
  installer          text,                              -- installer of record on the permit
  installer_status   text DEFAULT 'unknown'             -- bankrupt | closed | active | unknown
                     CHECK (installer_status IN ('bankrupt','closed','active','unknown')),
  installer_closed   text,                              -- year the installer shut down, if known
  tier               text NOT NULL DEFAULT 'none'       -- Scout tiers
                     CHECK (tier IN ('verified_installed','verified_uninstalled','permit_only','none')),
  permit_year        text,
  system_kw          text,
  finance_co         text,
  source             text,                              -- 'Scout Data · Freedom Forever ledger', 'Rep added', import filename
  territory_id       text REFERENCES territories(id) ON DELETE SET NULL,
  status             text NOT NULL DEFAULT 'unknocked'  -- denormalized: latest knock status
                     CHECK (status IN ('unknocked','not_home','callback','interested','appointment','signed','not_interested','do_not_knock')),
  last_knock_at      timestamptz,
  last_knock_by      text REFERENCES users(id),
  callback_at        timestamptz,                       -- open callback, cleared when outcome changes
  appointment_at     timestamptz,                       -- open appointment
  ghl_contact_id     text,                              -- set after first upsert
  ghl_opportunity_id text,
  dnc                boolean NOT NULL DEFAULT false,    -- from the data vendor's DNC flag
  deleted_at         timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX properties_territory_idx ON properties (territory_id);
CREATE INDEX properties_status_idx    ON properties (status);
CREATE INDEX properties_geo_idx       ON properties (lat, lng);
CREATE UNIQUE INDEX properties_addr_idx ON properties (lower(address), zip) WHERE deleted_at IS NULL;

CREATE TABLE knocks (
  id             text PRIMARY KEY,
  client_id      text UNIQUE NOT NULL,                  -- generated on the phone; makes offline replays idempotent
  property_id    text NOT NULL REFERENCES properties(id),
  user_id        text NOT NULL REFERENCES users(id),
  status         text NOT NULL
                 CHECK (status IN ('not_home','callback','interested','appointment','signed','not_interested','do_not_knock')),
  note           text,
  callback_at    timestamptz,
  appointment_at timestamptz,
  lat            double precision,                      -- where the rep was standing
  lng            double precision,
  accuracy_m     int,
  photo_url      text,
  source         text NOT NULL DEFAULT 'door',          -- door | phone | text | portal
  created_at     timestamptz NOT NULL,                  -- phone time of the knock (not server time)
  received_at    timestamptz NOT NULL DEFAULT now(),
  synced_at      timestamptz,                           -- when GHL accepted it (null = not yet)
  sync_error     text
);
CREATE INDEX knocks_property_idx ON knocks (property_id, created_at);
CREATE INDEX knocks_user_day_idx ON knocks (user_id, created_at);

CREATE TABLE appointments (                             -- one row per appointment set at the door; outcome synced with GHL calendar
  id              text PRIMARY KEY,
  property_id     text NOT NULL REFERENCES properties(id),
  knock_id        text REFERENCES knocks(id),
  user_id         text NOT NULL REFERENCES users(id),   -- rep who set it (gets credit)
  closer_id       text REFERENCES users(id),            -- who ran it, if different
  at              timestamptz NOT NULL,
  status          text NOT NULL DEFAULT 'scheduled'
                  CHECK (status IN ('scheduled','confirmed','held','no_show','cancelled')),
  result          text CHECK (result IN ('signed','lost','follow_up')),   -- only when status = held
  note            text,
  ghl_event_id    text,                                  -- GHL calendar event; status changes flow both ways
  reschedule_of   text REFERENCES appointments(id),      -- set when this row replaced an earlier time
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX appointments_at_idx   ON appointments (at);
CREATE INDEX appointments_user_idx ON appointments (user_id, at);
-- properties.appointment_id → the most recent appointment on that door (open or settled); add the column:
ALTER TABLE properties ADD COLUMN appointment_id text REFERENCES appointments(id);

CREATE TABLE api_keys (                                 -- external access (CallBoss, Aira, n8n, partner portals)
  id          text PRIMARY KEY,
  user_id     text NOT NULL REFERENCES users(id),       -- key carries this user's role and team
  label       text NOT NULL,
  key_hash    text NOT NULL,                            -- sha256 of the key; the key itself is shown once
  prefix      text NOT NULL,                            -- first 12 chars for display
  last_used_at timestamptz,
  revoked_at  timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE outbound_webhooks (                        -- DoorBoss → other systems
  id          text PRIMARY KEY,
  team_id     text REFERENCES teams(id),
  url         text NOT NULL,                            -- https only
  secret      text NOT NULL,                            -- HMAC-SHA256 of the body in X-DoorBoss-Signature
  events      jsonb NOT NULL,                           -- ["knock.created","appointment.updated","territory.updated","property.updated"]
  active      boolean NOT NULL DEFAULT true,
  failures    int NOT NULL DEFAULT 0,                   -- auto-disable at 20 consecutive
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE user_ai (                                  -- bring-your-own model per rep
  user_id     text PRIMARY KEY REFERENCES users(id),
  provider    text NOT NULL CHECK (provider IN ('company','openai','anthropic','google')),
  key_enc     text,                                     -- encrypted at rest with the backend secret; never returned to the client
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE push_subscriptions (                       -- web push, one or more per user (phone + desktop)
  id          text PRIMARY KEY,
  user_id     text NOT NULL REFERENCES users(id),
  endpoint    text NOT NULL UNIQUE,
  keys        jsonb NOT NULL,                           -- { p256dh, auth }
  user_agent  text,
  failures    int NOT NULL DEFAULT 0,                   -- drop after 5 consecutive 404/410
  created_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE knocks ADD COLUMN photo_urls jsonb NOT NULL DEFAULT '[]';   -- uploaded door photos (max 3)
ALTER TABLE properties ADD COLUMN geocode_status text DEFAULT 'ok' CHECK (geocode_status IN ('ok','queued','failed'));

CREATE TABLE positions (                                -- one row per user, overwritten by heartbeat
  user_id     text PRIMARY KEY REFERENCES users(id),
  lat         double precision NOT NULL,
  lng         double precision NOT NULL,
  accuracy_m  int,
  heading     real,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE position_history (                         -- breadcrumbs from heartbeats (trail[]), drives the manager's day replay; prune after 30 days
  id          bigserial PRIMARY KEY,
  user_id     text NOT NULL REFERENCES users(id),
  lat         double precision NOT NULL,
  lng         double precision NOT NULL,
  at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX position_history_idx ON position_history (user_id, at);

CREATE TABLE messages (                                 -- texts/emails sent through GHL from the app
  id              text PRIMARY KEY,
  property_id     text NOT NULL REFERENCES properties(id),
  user_id         text NOT NULL REFERENCES users(id),
  channel         text NOT NULL CHECK (channel IN ('sms','email','call')),
  direction       text NOT NULL CHECK (direction IN ('out','in')),
  to_addr         text,
  body            text,
  ghl_message_id  text,
  status          text NOT NULL DEFAULT 'queued',       -- queued | sent | delivered | failed
  error           text,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE goals (
  user_id         text PRIMARY KEY REFERENCES users(id),
  daily_knocks    int NOT NULL DEFAULT 60,
  daily_contacts  int NOT NULL DEFAULT 20,
  daily_appts     int NOT NULL DEFAULT 2
);

CREATE TABLE sync_log (                                 -- every outbound GHL call and inbound webhook
  id          bigserial PRIMARY KEY,
  direction   text NOT NULL CHECK (direction IN ('out','in')),
  entity      text NOT NULL,                            -- knock | message | property | webhook
  entity_id   text,
  action      text NOT NULL,                            -- contact.upsert | opportunity.upsert | appointment.create | sms.send | webhook.<event>
  status      text NOT NULL,                            -- ok | error
  http_status int,
  error       text,
  payload     jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE training_items (                           -- portal: training library
  id          text PRIMARY KEY,
  title       text NOT NULL,
  category    text,                                     -- Pitch | Objections | Intake | Compliance
  video_url   text,
  body        text,
  sort        int NOT NULL DEFAULT 0,
  published   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE settings (                                 -- single row, id='default'
  id                     text PRIMARY KEY,
  ghl_location_id        text,                          -- Solar Freedom sub-account
  ghl_pipeline_id        text,
  ghl_stage_map          jsonb,                         -- {"interested":"<stageId>","callback":"<stageId>","appointment":"<stageId>","signed":"<stageId>","not_interested":"<stageId>"}
  ghl_calendar_id        text,                          -- closer calendar for appointments
  ghl_sms_from           text,                          -- Solar Freedom phone number
  reknock_days           int NOT NULL DEFAULT 3,
  heartbeat_seconds      int NOT NULL DEFAULT 20,
  ai_provider            text,                          -- assistable | ghl_agent | anthropic | none
  updated_at             timestamptz NOT NULL DEFAULT now()
);
-- Secrets (GHL private integration token, AI keys) live in the backend's secret store, never in this table.

-- Metric definitions (used by /api/stats, the rep day grid, and the gap engine):
--   door        = knocks row with source = 'door' (portal-sourced rows from GHL outcomes are NOT doors)
--   contact     = door with status IN ('callback','interested','appointment','signed','not_interested')  -- someone answered
--   follow-up   = door whose property's previous knock status was IN ('callback','interested','appointment')  -- a return visit to a real conversation
--   appointment = door with status = 'appointment'
--   close       = any knock with status = 'signed' (door or portal), counted on the day it happened
--   doors per contact = doors / contacts ; appt rate = appointments / contacts ; close rate = signed / appointments
--   show rate   = appointments.status = held / (held + no_show), by appointment date
--   per day     = first knock time, last knock time, hours = last - first + 0.25, early = doors before 10:30, evening = doors at/after 16:00
-- Gap engine (app: explainGap): drivers compared rep vs top rep → days worked, hours/day, doors/hour, evening share,
--   answer rate, appointment rate, follow-ups/day; impact = expected appointments over the period using the rep's own rates.
