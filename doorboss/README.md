# DoorBoss — door-to-door canvassing for Elite Solar Recovery

One portal for the rep team: a territory map with the orphaned-solar list pre-loaded, door outcomes that land in Solar Freedom (GHL) the second they're logged, follow-ups, live rep positions, leaderboards, and the manager numbers Chase's partner asked for — doors knocked, doors per contact, follow-ups per day, appointments per day, closes per day.

Built for GoHighLevel **AI Studio** (full-stack as of Oct 2026). Built so Claude Code can drive the build in the browser from `AI-STUDIO-BUILD.md`.

## Files

| Path | What it is |
|---|---|
| `app/src/` | The app, one module per concern (config, seed, data layer, map, route, sheet, follow-ups, metrics + gap engine, team, rep profile, me, sync/GPS, notifications, boot). **Edit here.** |
| `app/build.js` | `node build.js` → `dist/index.html` (demo, sample data). `node build.js --prod` → `dist/index.prod.html` with the production data layer. Both are single files to paste into AI Studio. `app/index.html` is just a copy of the latest demo build. |
| `app/test/smoke.js` | `node test/smoke.js dist/index.html` — runs the logic in Node and checks the numbers. Must say ALL PASS before anything ships. |
| `app/data-layer.backend.js` | Production data layer; swapped in by `--prod`. Talks to `/api/*`; offline queue with idempotent replay; photo upload at flush. |
| `app/sw.js` | Service worker for notifications. Served at `/sw.js` by the portal. |
| `backend/schema.sql` | Tables. Metric definitions at the bottom. |
| `backend/api-contract.md` | Every endpoint the app expects. Build the backend to this and the app works unchanged. |
| `backend/ghl-sync.md` | Two-way GHL spec: contact upsert, custom fields, tags, opportunity stages, calendar appointments, SMS through Conversations, inbound webhooks, attribution rule, AI agent hooks. |
| `MASTER-PROMPT.md` | **Start here.** The whole build as one paste for AI Studio: all phases, decisions pre-made, self-test, final report. Hosted at `https://cryptouprise.github.io/doorboss/prompt.txt`. |
| `AI-STUDIO-BUILD.md` | The same build as staged prompts with a PASS test per stage. Claude Code's path, and how to repair anything the one-paste run skipped. |
| `sample-data/aurora-orphaned-permits.csv` | 48-row import sample in the column format the app and the launcher read. Fake owners, real street names, real bankrupt installers. |
| `tools/territory-launcher.html` | Open locally in a browser. Drop one territory's Scout list → download the GHL import, Meta + Google hashed audiences, CallBoss dialer file, and DoorBoss pins. Nothing uploads anywhere. |

## What the app does

**Rep**
- Map of their territory with pins colored by outcome. "Knock next" filter shows only doors worth knocking (never knocked, callback due, interested, or not-home older than 3 days).
- "Next door" card: nearest due callback first, then nearest knockable door, with distance.
- Tap a pin → dossier (owner, phone, email, installer + bankrupt tag + year closed, tier, permit year, kW, finance co), navigate, text through GHL with templates, AI door brief, 7 outcome buttons, callback/appointment time with one-tap presets, note, full knock history.
- Long-press anywhere → add a house (for doors not on the list).
- Follow-ups tab: overdue callbacks on top, today's appointments, today's callbacks, "interested going cold," next 7 days. Badge on the tab.
- Me: today's doors/contacts/appts against goals, doors-per-contact, streak, sync state.
- Works offline. Knocks queue on the phone and replay in order when signal returns; `client_id` makes replays idempotent.

**Everyone**
- Leaderboard (doors, talks, appts, signed, appt %, before 10:30, after 4 pm, earliest start) — tap any rep.
- Rep profile: Excel-style day grid with weekly totals, start time, hours, before-10:30 and after-4 columns; side-by-side with any other rep; **"Why X books more"** — the gap engine ranks days worked, hours/day, doors/hour, evening share, answer rate, appointment rate and follow-up discipline by estimated appointment impact, and says what to change. Visible to every rep on purpose.
- Appointments as first-class records: scheduled → confirmed → held / no-show / rescheduled / cancelled → signed / lost / follow-up. Outcome buttons on the door, "needs an outcome" list in Follow-ups, show rate in Stats. Synced both ways with the GHL calendar.
- Territories: reps draw their own (auto-assigned) or claim open ones; managers reassign.
- Ask the coach (deterministic answers from the rep's own numbers; a model phrases them in production) and bring-your-own AI key per rep.

**GPS, honestly**
- Tracking runs while the app is open: consent screen first, then a "Tracking ±8 m" pill, accuracy ring on the map, screen kept awake, fix age so "last seen 9 min ago" is truthful. Heartbeats carry the trail; the manager's Live tab has a **Trail** button per rep (start, path, last fix).
- Hours in the grid are time on the doors with gaps over 45 minutes removed, not first-to-last.
- A phone stops reporting when it's locked or the app is in the background. That is the platform, not the app. Stage 13 (Capacitor wrapper) is the path to true background tracking.

**Field extras**
- Route: the route FAB plans the day from where the rep stands — callbacks due first, then nearest-neighbour + 2-opt over up to 120 knockable doors. Logging a door advances the route.
- Clustering below zoom 15 so a 10k-door import stays smooth.
- Photos on a door, shrunk on the phone, uploaded when back online.
- Reminders: in-app toasts, web push through `sw.js`, and a GHL SMS to the rep as the fallback that always lands.
- Admin: add/edit reps under Me (role, team, color, GHL user link).

**Manager** (Team tab)
- Live: who's on the doors right now, last seen, today's counts; reps on the map.
- Leaderboard: today/week/30d × doors/contacts/appts/signed/appt-rate.
- Stats: the six numbers, per day; funnel; doors-by-hour with answer rate; per-rep table; "what to do about it" cards (overdue callbacks, low contact rate vs team, talking-but-not-booking, best hour, territory nearly covered, territory unassigned, rep offline).
- Territories: draw on the map, assign reps, coverage bar, knockable count.
- Data: import a Scout CSV, export knocks/properties, GHL sync status.
- Nudges (Stats): the pattern to spread from the top rep, one card per rep with their biggest fixable driver, no-show rate, appointments missing an outcome.
- API keys and outbound webhooks (Me tab): `/api/*` with a key that carries the manager's role; webhooks on knock.created, appointment.updated, territory.updated, property.updated for CallBoss, Aira, n8n.

**GHL** (production)
- Interested / callback / appointment / signed / not interested → contact upsert with tags + custom fields, opportunity stage, calendar appointment or task, from the Solar Freedom number for texts.
- GHL → app: opportunity moved to Signed turns the door green on every rep's map; no-shows re-queue a callback; STOP replies set DNC.
- Source is written once, at first contact, and never overwritten. That is the attribution rule that decides the appointment split with the partner.

## Demo vs production

The demo (`index.html` as published) fakes two things because the preview sandbox blocks them: street tiles (you get a schematic grid; production uses OpenStreetMap or Mapbox) and GPS (fixed demo position; production uses the phone). Everything else is real code. "Preview as" under Me switches between manager and rep.

## Order of operations

1. Open the demo on a phone. Decide what to cut before anyone builds anything. The spec is written to be cut, not added to.
2. Scout call: buy the Colorado bankrupt-installer list by tier with contacts. Do not rent seats.
3. Run `AI-STUDIO-BUILD.md` stages 0–4 (portal, DB, API, Doors). That alone replaces what Cancel Your Solar gives the partner.
4. Stage 6 (GHL sync) before the first real knock. Stage 7 (intake + training) the same week.
5. Launch one territory with `tools/territory-launcher.html`: audiences first, dialer second, doors third.

## Naming

"DoorBoss" matches CallBoss and Boss AI. Rename in one place: `CONFIG.appName` and the `<title>` in `index.html`.
