# DoorBoss ↔ GoHighLevel sync (Solar Freedom sub-account)

Two-way. The app never talks to GHL directly; the backend does, from a queue, with retries, and logs every call to `sync_log`.

**GHL API v2.** Base `https://services.leadconnectorhq.com`. Headers on every call:
```
Authorization: Bearer <PRIVATE_INTEGRATION_TOKEN>   (sub-account Private Integration, scopes below)
Version: 2021-07-28
Content-Type: application/json
```
Scopes the Private Integration needs: `contacts.readonly contacts.write opportunities.readonly opportunities.write calendars.readonly calendars/events.write conversations.readonly conversations/message.write locations/customFields.readonly locations/customFields.write users.readonly`.

Settings row (`settings` table): `ghl_location_id`, `ghl_pipeline_id`, `ghl_stage_map`, `ghl_calendar_id`, `ghl_sms_from`. The token goes in the backend secret store, never in the DB or the app.

---

## 1. One-time setup (backend does this on first run, idempotent)

Create custom fields on the location if missing (`GET /locations/{locationId}/customFields`, then `POST` the missing ones). Field keys the app relies on:

| Key | Type | Source |
|---|---|---|
| `db_installer` | text | `properties.installer` |
| `db_installer_status` | text | bankrupt / closed / active / unknown |
| `db_tier` | text | verified_installed / verified_uninstalled / permit_only |
| `db_permit_year` | text | |
| `db_system_kw` | text | |
| `db_finance_co` | text | |
| `db_territory` | text | territory name |
| `db_rep` | text | rep name who logged the last knock |
| `db_door_status` | text | latest knock status |
| `db_last_knock_at` | date | |
| `db_property_id` | text | DoorBoss property id (for reverse lookup) |
| `db_source` | text | "door" — attribution, set once, never overwritten |

Store the returned field ids in `settings.ghl_field_map` so later upserts can pass `customFields: [{ id, field_value }]`.

Pipeline stages: read `GET /opportunities/pipelines?locationId=` once and fill `settings.ghl_stage_map` by stage name. Expected stage names in Solar Freedom (rename here if the pipeline differs):

| Knock status | Pipeline stage | Opportunity status |
|---|---|---|
| interested | Door – Interested | open |
| callback | Door – Callback | open |
| appointment | Appointment Set | open |
| signed | Signed / Intake | won |
| not_interested | (no opportunity; tag only) | — |
| not_home / do_not_knock | (nothing to GHL) | — |

---

## 2. Outbound: knock → GHL

Trigger: `POST /api/knocks` stores the row and enqueues `sync.knock(knock_id)` **only** for statuses `interested`, `callback`, `appointment`, `signed`, `not_interested`. `not_home` and `do_not_knock` never leave DoorBoss (DNK is still written to the property; the property gets tag `dnk` on the next sync if a contact exists).

Worker, per knock, in this order (each step idempotent):

**a. Upsert the contact** — `POST /contacts/upsert`
```json
{
  "locationId": "<ghl_location_id>",
  "firstName": "Maria", "lastName": "Garcia",
  "phone": "+17205551234", "email": "maria.garcia@example.com",
  "address1": "15420 E Jewell Ave", "city": "Aurora", "state": "CO", "postalCode": "80014",
  "source": "door",
  "tags": ["doorboss", "door-knock", "status:appointment", "territory:jewell-iliff", "rep:marcus-r", "tier:verified_uninstalled", "installer:titan-solar-power"],
  "customFields": [ { "id": "<db_installer>", "field_value": "Titan Solar Power" }, ... ]
}
```
Upsert matches on phone, then email. Save `contact.id` to `properties.ghl_contact_id`. If the property has neither phone nor email, create by name + address and still save the id (GHL allows it). Remove the previous `status:*` tag with `DELETE /contacts/{id}/tags` so only one status tag is live.

**b. Opportunity** — if `properties.ghl_opportunity_id` is null: `POST /opportunities/`
```json
{ "pipelineId": "<ghl_pipeline_id>", "locationId": "<ghl_location_id>", "name": "15420 E Jewell Ave · Garcia",
  "pipelineStageId": "<stage for status>", "status": "open", "contactId": "<contact.id>",
  "monetaryValue": 3200, "assignedTo": "<users.ghl_user_id of the rep>", "source": "door" }
```
Else `PUT /opportunities/{id}` with the new `pipelineStageId` (and `status: "won"` for `signed`). Never move an opportunity backwards from `won`.

**c. Appointment** — when `status = appointment`: `POST /calendars/events/appointments`
```json
{ "calendarId": "<ghl_calendar_id>", "locationId": "<ghl_location_id>", "contactId": "<contact.id>",
  "startTime": "<appointment_at ISO>", "endTime": "<+45 min>", "title": "Solar contract review · 15420 E Jewell Ave",
  "appointmentStatus": "confirmed", "assignedUserId": "<closer or rep ghl_user_id>", "notes": "<knock.note> · set at the door by Marcus R." }
```
Store the event id on the knock (`knocks.photo_url` is not for this; add `ghl_appointment_id text` to `knocks` if you want it, otherwise keep it in `sync_log.payload`). Callback outcomes do **not** create calendar events; they create a GHL task instead (`POST /contacts/{id}/tasks` with `dueDate = callback_at`, assigned to the rep) so the follow-up shows in the rep's GHL mobile app too.

**d. Mark synced** — `knocks.synced_at = now()`. On any 4xx that is not 429, store `sync_error` and stop retrying that knock (surface it on Team → Data). On 429 or 5xx, back off 2s, 8s, 30s, 2m, 10m, then park it for the retry endpoint.

Rate limit: GHL allows roughly 100 requests per 10 seconds per location. The worker runs single-threaded per location and sleeps when it sees 429.

**Attribution rule (decides who gets the appointment money):** `db_source` and the contact `source` are written **once**, on first upsert, and never overwritten. If a contact already exists with `source = "ads"` or `"call-center"` when the rep knocks, the knock adds `door-knock` as a tag but the source stays. The manager report "appointments by original source" is what settles the split with the partner. Agree on this in writing before launch.

---

## 3. Outbound: texts from the app

`POST /api/messages` → worker:
1. Ensure contact (step 2a).
2. `POST /conversations/messages`
```json
{ "type": "SMS", "contactId": "<contact.id>", "message": "<body>", "fromNumber": "<ghl_sms_from>" }
```
3. Save `ghl_message_id`, `status = sent`. Replies come back through the webhook and land in `messages` with `direction = in`, so the rep sees the thread in the property sheet.

Compliance gate in the worker: refuse to send if `properties.dnc = true` or if the contact carries tag `dnc` or `stop`, and return `{ status:"blocked", reason }` to the app. The intro template is only sendable after a knock with a contact outcome on that property (the homeowner has met the rep); the server enforces this by checking the latest knock.

---

## 4. Inbound: GHL → DoorBoss

Use a GHL **Workflow** with a *Custom Webhook* action pointed at `POST https://<portal>/api/webhooks/ghl?key=<shared secret>` (no marketplace app needed). Create one workflow per trigger:

| GHL trigger | Backend action |
|---|---|
| Opportunity stage changed | Map stage → status with `ghl_stage_map` reversed. If the new stage maps to `signed`, insert a knock `{ status:"signed", source:"portal", user_id: <closer or system> }` so the door turns green on every rep's map and the rep gets credit on the leaderboard (configurable: `settings.credit_signed_to = "rep" | "closer"`). |
| Opportunity status → lost | Insert knock `{ status:"not_interested", source:"portal", note:"Lost in GHL: <reason>" }`. |
| Appointment status changed (confirmed / showed / no-show / cancelled / rescheduled) | Resolve the `appointments` row by `ghl_event_id`. Map GHL `appointmentStatus` → `confirmed` / `held` / `no_show` / `cancelled`; a moved start time → `rescheduled` with the new `at`. Apply the same transitions as `POST /api/appointments/:id` (no-show → callback next day 5 pm; held needs a `result`, which the closer sets in the app or the opportunity stage supplies: Signed stage → `held/signed`, Lost → `held/lost`). The door updates on every rep's map and the show rate stays honest. |
| Customer replied (SMS) | Insert `messages { direction:"in", body, ghl_message_id }`. If body matches `STOP|UNSUBSCRIBE`, set `properties.dnc = true` and tag. |
| Contact tag added `dnk` | `properties.status = do_not_knock` (via a knock row). |

Webhook body from GHL carries `contact_id`; resolve the property by `properties.ghl_contact_id`, falling back to the `db_property_id` custom field. Log every event to `sync_log` with the raw payload. Return `200` fast; process async.

Verify the request with the shared secret in the query string **and** check that `locationId` in the payload equals `settings.ghl_location_id`.

---

## 5. Portal glue (AI Studio)

- **Reps already exist as GHL users.** On portal login, map the portal user to `users.ghl_user_id` by email (`GET /users/?locationId=`), so appointments and tasks are assigned to the right person in GHL.
- **Intake form.** When a rep taps "Start intake" in the property sheet (add this button in the portal build; the demo omits it), open the existing AI Studio intake form with the contact pre-filled: `/intake?contact=<ghl_contact_id>&property=<id>`. On submit, the form's own GHL workflow moves the opportunity to Signed, and the inbound webhook above turns the door green.
- **Training.** `training_items` is just a table; the portal renders it. No GHL involvement.

---

## 5b. Reminders to reps by SMS (the fallback that always lands)

Web push is unreliable on iPhones unless the portal is on the home screen. So the backend also texts the rep through GHL for anything that still matters 10 minutes after a push went unanswered: a callback due now, an appointment in an hour, a no-show logged on their door, an appointment missing an outcome.

Set it up once in Solar Freedom → Automation → Workflows:
1. Trigger: **Inbound Webhook** (copy the URL into backend secret `GHL_REP_SMS_WEBHOOK`).
2. Action: **Send Internal Notification** → SMS → "User" → map the user by the `rep_email` field in the payload (GHL users, not contacts).
3. Message body: `{{inboundWebhookRequest.message}}`.

Backend POSTs `{ rep_email, rep_phone, message, propertyId }`. Reps therefore need `users.email` to match their GHL user email (stage 9). Cap at 20 SMS per rep per day so a bad loop cannot spam anyone.

## 6. AI agents (optional, pluggable)

`settings.ai_provider` picks one. The backend owns prompts and keys; the app only sends ids.

| Provider | Brief / draft | Notes |
|---|---|---|
| `assistable` | POST to the Assistable agent endpoint with the dossier as context | Already in Chase's stack |
| `ghl_agent` | GHL Conversation AI / Agent Studio via the location's agent | Keeps everything inside GHL |
| `anthropic` | Claude Messages API with a short system prompt | Fastest to stand up; see `/api/ai/*` in `api-contract.md` |

Dossier passed to the model (never the whole DB): address, owner first name, installer + closed year, tier, permit year, kW, finance co, last 3 knock notes, territory, rep name. Output is capped at 4 lines for the brief, 320 chars for a text.

---

## 7. What to verify before reps go live

1. One test knock with `status: appointment` → contact exists in Solar Freedom with tags and custom fields, opportunity in "Appointment Set", event on the closer calendar. Check `sync_log` shows 3 `ok` rows.
2. Change the opportunity stage to Signed in GHL → the door turns green in the app within 60 seconds and shows a knock with `source: portal`.
3. Send a text from the sheet → arrives from the Solar Freedom number; reply from the phone → shows in the sheet history.
4. Turn airplane mode on, log 5 knocks, turn it off → exactly 5 rows in `knocks`, no duplicates, all `synced_at` set.
5. Two reps log the same door 10 seconds apart → property status equals the later `created_at`, both knocks kept.
