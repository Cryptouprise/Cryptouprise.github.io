# DoorBoss API contract

The app (`app/index.html`) talks to one data layer with the method names below. In the demo that layer is `localStorage`. In production it is `app/data-layer.backend.js`, which calls these endpoints. Build the backend to this contract and the app works unchanged.

**Base path:** `/api` on the same origin as the portal.
**Auth:** the portal's session cookie or a `Bearer` token. Every request resolves to a `user` with `id`, `role`, `team_id`. Reps only see their team. Managers/admins see everything in their team.
**Times:** ISO-8601 UTC strings in JSON. The app converts.
**Errors:** `{ "error": "message" }` with 4xx/5xx.

---

## Session

| Method | Path | Returns |
|---|---|---|
| GET | `/api/me` | `{ id, name, email, phone, role, team_id, color, ghl_user_id }` |
| GET | `/api/users` | `[user]` — team members (reps + managers), `active=true` only |
| GET | `/api/settings` | `{ reknock_days, heartbeat_seconds, ai_provider, ghl_configured: true|false }` (no secrets, no ids) |
| GET/PUT | `/api/goals` | `{ daily_knocks, daily_contacts, daily_appts }` for the current user |

## Properties (doors)

| Method | Path | Notes |
|---|---|---|
| GET | `/api/properties?bbox=s,w,n,e&territory=<id>&status=a,b&since=<iso>` | All params optional. Default: every property in the user's team territories (reps) or team (managers). `since` returns only rows updated after that time, for incremental refresh. Cap 5,000 rows; paginate with `?cursor=`. |
| GET | `/api/properties/:id` | One property + `knocks[]` (newest first, max 50) + `messages[]` |
| POST | `/api/properties` | Body: `[property]` (array, max 2,000). Upsert by `id`, else by `(lower(address), zip)`. Assigns `territory_id` by point-in-polygon when null. Returns `{ added, updated, skipped: [{row, reason}] }`. Manager/admin only, except a rep may post a single property with `source:"Rep added"`. |
| POST | `/api/properties/import` | `multipart/form-data` with a CSV. Same column rules as the app's importer (see `sample-data/`). Rows without lat/lng go to a `geocode` job and return as `queued`. |

Property shape: see `schema.sql`. The API returns `status`, `last_knock_at`, `callback_at`, `appointment_at` denormalized so the map does not need the knocks table.

## Knocks

| Method | Path | Notes |
|---|---|---|
| POST | `/api/knocks` | Body: `[knock]`, each with a phone-generated `client_id`. **Idempotent:** a `client_id` already stored returns the stored row with `200`, never a duplicate. Updates the property's denormalized fields. Enqueues GHL sync (see `ghl-sync.md`). Returns `[{ id, client_id, synced_at }]`. |
| GET | `/api/knocks?from=<iso>&to=<iso>&user=<id>&property=<id>` | Managers: team. Reps: own knocks + knocks on properties in their territories (for history). Cap 10,000; paginate. |

Validation: `status` in the allowed set; `callback_at` required when `status=callback`; `appointment_at` required when `status=appointment`; `property_id` must exist; `created_at` required (phone time), rejected if more than 7 days in the past or 10 minutes in the future.

## Appointments

| Method | Path | Notes |
|---|---|---|
| GET | `/api/appointments?from=<iso>&to=<iso>&user=<id>&status=a,b` | Reps: own + their territories. Managers: team. Includes `property` summary (address, owner_name) in each row. |
| POST | `/api/appointments/:id` | Patch `{ status, result?, at?, note?, closer_id? }`. Rules: `held` requires `result`; `rescheduled` is a status transition that writes a new row with `reschedule_of` and sets the old row to `cancelled`, so the API accepts `{ status:"rescheduled", at }` and returns the new row. `no_show` sets the property to `callback` next day 5 pm and inserts a knock `{ status:"callback", source:"portal" }`. `held/signed` inserts `{ status:"signed", source:"portal" }`. Every change pushes the GHL calendar event (see ghl-sync.md §2c, §4). |

Appointments are created by `POST /api/knocks` with `status:"appointment"` — never directly — so the door, the knock, and the calendar stay one record.

## Rep stats and the gap engine

| Method | Path | Returns |
|---|---|---|
| GET | `/api/reps/:id/days?period=week|month` | `[{ day, doors, contacts, callbacks, appts, signed, followups, early, mid, evening, first, last, hours }]` — the day grid, newest first. Visible to every user on the team (transparency is the point). |
| GET | `/api/reps/:id/summary?period=` | The `repSummary` object: totals, `doorsPerDay, hoursPerDay, doorsPerHour, avgStart, earlyShare, eveningShare, contactRate, apptRate, closeRate, eveningContactRate, dayContactRate, followupsPerDay, fuApptRate, overdue, held, noShow, showRate`. |
| GET | `/api/reps/:id/gap?vs=<id>&period=` | `explainGap(a, b)`: `{ gap, reasons:[{ k, label, fa, fb, impact, fix }], same:[], better:[] }`. Default `vs` = top rep by appointments. |
| GET | `/api/nudges?period=` | Manager cards: the pattern to spread (top rep vs team average), one card per rep with the biggest fixable driver, no-show rate, appointments missing an outcome. Same output shape as the app's `nudges()`. |

The app computes all of this on the phone from the knock list today. Move it server-side at ~5k knocks; the shapes above match the app's functions one-for-one so nothing in the UI changes.

## Territories

| Method | Path | Notes |
|---|---|---|
| GET | `/api/territories` | Team's territories with `counts: { total, touched, knockable, last_knock_at }` computed server-side |
| POST | `/api/territories` | Create or update (`id` present = update). Re-assigns `properties.territory_id` for every property inside the polygon. **Reps may create** (the server forces `assigned_user_ids = [self]`) and may update only name/polygon of territories they are assigned to. Managers/admins may do anything, including reassign. |
| POST | `/api/territories/:id/claim` | Rep adds themselves to an **unassigned** territory. 409 if already assigned. |
| DELETE | `/api/territories/:id` | Properties keep rows, `territory_id` → null. Manager/admin. |

## Positions (live map)

| Method | Path | Notes |
|---|---|---|
| POST | `/api/heartbeat` | Body `{ lat, lng, accuracy_m, heading }`. Upserts `positions`, appends `position_history`. Called every 20s while the app is visible. |
| GET | `/api/positions` | Manager/admin: `[ { user_id, lat, lng, accuracy_m, updated_at } ]` for the team. Reps get `403`. |

## Uploads (door photos)

| Method | Path | Notes |
|---|---|---|
| POST | `/api/uploads` | `multipart/form-data`: `file` (JPEG, already shrunk to ≤1280 px by the phone), `knock_client_id`. Stores in the backend's file storage under `knocks/<client_id>/<n>.jpg`, returns `{ url }`. Max 2 MB, 3 per knock. Appends the url to `knocks.photo_urls` when the knock exists, otherwise the knock POST that follows carries `photo_urls`. |

## Positions — history and replay

`POST /api/heartbeat` body now also carries `trail: [{ lat, lng, at, acc }]` (up to 10 points since the last beat) and `fix_at`. Insert the trail into `position_history`; keep `positions` as the latest fix.

| Method | Path | Notes |
|---|---|---|
| GET | `/api/positions/:user/history?day=YYYY-MM-DD` | Manager/admin: `[{ lat, lng, at, acc }]` ordered by time, thinned to ≤2,000 points. The manager's "Trail" button. |

Prune `position_history` older than 30 days nightly. Reps consent in-app before any position is sent; store `users.gps_consent_at` when the first heartbeat arrives.

## Push notifications

| Method | Path | Notes |
|---|---|---|
| POST | `/api/push/subscribe` | `{ subscription }` from `pushManager.subscribe`. Upsert on `endpoint`. |
| DELETE | `/api/push/subscribe` | `{ endpoint }` |
| GET | `/api/push/vapid` | `{ publicKey }` — the app reads this into `CONFIG.vapidPublicKey` at boot if the config is empty. |

Server sends (via the `web-push` library, VAPID keys as backend secrets) on: callback due in 15 min, appointment in 60 min, no-show logged by the closer, appointment set for a closer, "log the outcome" 45 min after an appointment. Payload `{ title, body, tag, url:"/doors#p=<id>", propertyId }`. If a push is not acknowledged (the app does not open) within 10 minutes for a callback or appointment, fall through to the GHL SMS reminder (ghl-sync.md §5). iOS delivers web push only when the portal is installed to the home screen.

## Users (admin)

| Method | Path | Notes |
|---|---|---|
| POST | `/api/users` | `{ name, email, phone, role, team_id, color, ghl_user_id, active }` — creates the portal login too (sends an invite). Admin, or manager for their own team (role ≤ manager). |
| PUT | `/api/users/:id` | Same fields. Deactivating keeps history. |

## Geocoding

`POST /api/properties` rows without `lat/lng` are stored with `geocode_status = queued` and no pin. A backend job geocodes them (any provider; Mapbox or Google, keyed in secrets) and sets `lat, lng, geocode_status = ok`, then assigns a territory. `GET /api/properties?geocode=queued` lists the backlog for the Data tab.

## Messages (texts through GHL)

| Method | Path | Notes |
|---|---|---|
| POST | `/api/messages` | `{ property_id, channel:"sms", body }`. Server resolves the GHL contact (upserting if needed), sends through GHL Conversations from the Solar Freedom number, stores the row with `ghl_message_id`. Returns `{ id, status }`. |
| GET | `/api/messages?property=<id>` | Outbound and inbound (inbound arrive via the GHL webhook). |

## Stats (server-side so managers don't pull 10k knocks to a phone)

| Method | Path | Returns |
|---|---|---|
| GET | `/api/stats?period=today|week|month&team=<id>` | `{ team: Metrics, per_rep: [{ user_id, ...Metrics }], by_hour: [24 x {knocks, contacts}], territories: [{ id, total, touched, knockable }] }` |

`Metrics = { knocks, contacts, followups, callbacks, appts, signed, days }` using the definitions at the bottom of `schema.sql`. The demo computes these on the phone from the full knock list; production should compute them here and the app will call this instead once the list grows past a few thousand knocks.

## AI hooks (optional; wire to Assistable, GHL's agent, or Claude)

| Method | Path | Notes |
|---|---|---|
| POST | `/api/ai/brief` | `{ property_id }` → `{ headline, lines: [string] }`. A 3–4 line door brief from the dossier (installer, tier, finance, history). |
| POST | `/api/ai/draft` | `{ property_id, intent: "intro"|"callback"|"confirm"|"custom", prompt? }` → `{ body }`. Text/email draft in ESR's voice. |
| POST | `/api/ai/coach` | `{ user_id, period }` → `{ cards: [{ kind, title, detail }] }`. Replaces the rule-based "What to do about it" cards with a model-written version. |

The backend holds the prompt and the provider key. The app only ever sends ids.

**Bring your own model.** `GET/PUT /api/me/ai` → `{ provider: company|openai|anthropic|google, has_key: bool }`. PUT accepts `{ provider, key }`; the key is encrypted at rest (`user_ai.key_enc`) and never returned. When a user has a key, every `/api/ai/*` call for that user runs on their provider with their key; otherwise the company default. Same prompts, same input shape, so a rep's ChatGPT key and the company Claude key produce the same kind of brief. Rate-limit per user (30 AI calls/hour) regardless of whose key it is.

`POST /api/ai/coach` input is the rep's `summary`, the `gap` vs the top rep, today's follow-ups, and the question. The deterministic answers in the app (`askCoach`) are the fallback when the provider errors, so the coach never goes silent in the field.

## API keys and outbound webhooks (manager/admin)

| Method | Path | Notes |
|---|---|---|
| GET | `/api/keys` | `[{ id, label, prefix, last_used_at, created_at }]` — never the key |
| POST | `/api/keys` | `{ label }` → `{ id, key }` shown once. Key = `db_live_` + 32 random chars; store `sha256(key)`. The key authenticates as its creator (same role, same team) via `Authorization: Bearer db_live_…`. |
| DELETE | `/api/keys/:id` | Revoke |
| GET/POST/DELETE | `/api/webhooks/outbound[/:id]` | `{ url, events[], active }`. Server generates `secret`. |

Webhook delivery: `POST url` with JSON `{ event, at, data }`, header `X-DoorBoss-Signature: sha256=<hmac of body>`, `X-DoorBoss-Event`. Retry 3 times with backoff; auto-disable after 20 consecutive failures and surface it on Me → API. Events:

| Event | `data` |
|---|---|
| `knock.created` | the knock + `property` summary + `user` summary |
| `appointment.updated` | the appointment row + `property` + previous `status` |
| `territory.updated` | the territory + `counts` |
| `property.updated` | the property (after import or status change) |

This is how CallBoss gets told "set a callback for 5 pm," how Aira/n8n can fire a confirmation text the morning of an appointment, and how a partner portal can watch its own reps' doors.

## Webhooks (inbound from GHL)

`POST /api/webhooks/ghl` — see `ghl-sync.md` for events and handling. Verify the signature; log every event to `sync_log`.

## Admin / portal glue

| Method | Path | Notes |
|---|---|---|
| GET | `/api/training` | Published `training_items` ordered by `sort` |
| POST/PUT/DELETE | `/api/training/:id` | Admin |
| GET | `/api/sync/status` | `{ queued, failed_24h, last_ok_at }` for the manager Data tab |
| POST | `/api/sync/retry` | Re-run failed GHL syncs |

---

## Offline behaviour the backend must tolerate

- Knocks arrive late (hours) with `created_at` in the past. Accept them; stats use `created_at`.
- The same knock may arrive twice. `client_id` is the dedupe key.
- Knocks may arrive out of order for one property. The property's denormalized `status` is set from the knock with the **latest `created_at`**, not the latest received.
- Heartbeats may stop for minutes. A position older than 3 minutes is "stale", older than 2 minutes is "offline" on the Live tab. Don't delete rows.
