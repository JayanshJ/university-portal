# University Portal — Implementation Plan (macOS app)

Oct 23, 2026 · @Jayansh

## Summary

University Portal is a native macOS app (SwiftUI) that pulls deadlines, announcements, materials and schedules from Moodle (moodle.uni-saarland.de) and CMS (cms.sic.saarland) into one place, with a Today view and a menu bar summary. Every data source it needs was tested against real accounts on 23 Oct 2026, and all of them work. There is no server: the app syncs, stores and renders everything on the Mac.

- **Moodle**: official mobile web service API with a long-lived token. Clean JSON, no scraping.
- **CMS**: no API. Public `.ics` feeds and news pages, plus HTML scraping of materials behind a username/password login.
- **Auth**: Moodle is reconnected in your normal browser: the app registers the `moodlemobile://` link type, so Moodle's redirect lands back in the app (an in-app sheet and a paste box are fallbacks); the SSO password is never stored. CMS re-logs in automatically with its password stored in the Keychain.
- **Stack**: SwiftUI app + a `UniversityKit` Swift package (all logic, testable with `swift test`), SQLite via GRDB, Keychain for secrets, PDFKit for PDFs.

Verified on 23 Oct in the app: the browser → `moodlemobile://` → app reconnect, the deadlines call with the token, and the site-hash formula. Still untested: the CMS login POST end to end, the Moodle token's lifetime, and the CMS personal status page (your own tutorial slot).

## What's verified

All rows below were run on 23 Oct 2026 against Jayansh's own accounts. "Token" means the call was made with only the Moodle mobile token and no browser cookies, exactly as the app will.

| Capability | Source and call | Result |
| --- | --- | --- |
| Moodle auth config | `tool_mobile_get_public_config` (no login) | Moodle 4.5.11. Web services and mobile service enabled. Login type 3 (embedded browser), SAML2 SSO, launch URL exposed. |
| Moodle token issuance | `launch.php?service=moodle_mobile_app&passport=…` while logged in | 302 with `Location: moodlemobile://token=<base64>`. Decodes to 3 parts: site hash, token, private token. |
| Custom URL scheme | `launch.php … &urlscheme=web%2Btest` | Rejected (invalid urlscheme). Only `moodlemobile` works. A native app can catch that scheme; a website could not. |
| Token validity | `core_webservice_get_site_info` (token) | OK. 445 functions allowed. |
| Moodle courses | `core_enrol_get_users_courses` (token) | 7 courses, including last semester's Deskriptive SoSe26. |
| Moodle deadlines | `core_calendar_get_action_events_by_timesort` (session) | 7 open assignments with due time, course and link. Names end in "ist fällig." Re-run with the token alone in the app on 23 Oct: works (10 open assignments within the 120-day window). |
| Moodle announcements | `mod_forum_get_forums_by_courses` + `mod_forum_get_forum_discussions` (token) | Works. Same calls via browser-session AJAX return `servicenotavailable`, so the token is required. |
| Moodle materials | `core_course_get_contents` (token) | 56 files across 7 courses, each with `timemodified`. |
| Moodle file download | `fileurl` + `token=` (no cookies) | 200, `application/pdf`. |
| CMS course list | `/system/courses` (public) | All courses by term, slug per course (e.g. `prog1_26`). |
| CMS enrolled courses | `/system/courses` (logged in) | 14 marked rows across terms. Current: `i2cl_2627`, `introalgdat2627`, `prog1_26`. Detection was heuristic. |
| CMS news | `/<slug>/` (public) | Title, date, author, body. Example: Prog 1 "Tutorial Assignment", 20 Oct. |
| CMS schedule | `/<slug>/termine/events/download` (public) | Valid iCalendar. Prog 1 includes lectures, tutorials, office hours, Midterm 11 Dec, Endterm 25 Feb, retakes. |
| CMS materials | `/<slug>/materials` (logged in) | 12, 6 and 13 links for the three current courses, plus "Download all". Public view says login required. |
| CMS file download | `/<slug>/dl/<id>/<file>` (session cookie) | 200, `application/pdf`. |
| CMS session scope | Same cookie across courses | One login covers every course instance. |
| CMS login form | `/<slug>/users/login` (inspected, not submitted) | CakePHP 2 form with SecurityComponent tokens and a remember-me option. |

Verified in the app on 23 Oct: the deadlines call with the token alone, the full browser → `moodlemobile://` reconnect, and the site hash `md5(wwwroot + passport)`. Not yet tested: the in-app `ASWebAuthenticationSession` sheet after its fixes (on 23 Oct it showed Moodle's login chooser but did not accept clicks), submitting the CMS login form from the app, how long a Moodle token lives, and parsing the CMS personal status page.

## Architecture

One app, two layers: the `UniversityKit` package holds the adapters, store, sync, secrets and file cache; the SwiftUI app target holds only views. Two adapters normalize everything into the same `uni_*` tables, and every view reads only from those tables.

```
 Moodle (REST, token)          CMS (.ics, HTML, session)
        │                               │
  Adapters/Moodle               Adapters/CMS
        └──────────────┬────────────────┘
              Sync/SyncScheduler  (in-app timers, upserts, events)
                       │
   SQLite (GRDB, uni_* tables)      Keychain (token, CMS password, cookies)
                       │                       ▲ adapters only
      Store observations · Summary · FileCache ──► source (bytes, first open only)
                       │
  Today · Deadlines · Announcements · Materials (PDFKit) · Schedule · Menu bar
```

The adapters never talk to the views, and the views never talk to Moodle or CMS; the only exception is `FileCache`, which downloads file bytes from the source on first open. Secrets live in the Keychain and are read only by the adapters.

Project layout:

```
University Portal/
  UniversityPortal.xcodeproj
  App/                          SwiftUI app target (views only)
    UniversityPortalApp.swift   window, Settings scene, menu bar extra
    Views/                      Today, tabs, PDF viewer
  UniversityKit/                Swift package, all logic
    Package.swift
    Sources/UniversityKit/
      Store/                    GRDB database, migrations, records
      Secrets/                  Keychain helper
      Logging/                  Log + Redactor
      Files/                    FileCache
      Adapters/Moodle/          REST client + the 5 calls        (Phase 2)
      Adapters/CMS/             login, news, ics, materials      (Phases 3–4)
      Sync/                     SyncScheduler, jobs, upserts     (Phase 2+)
      Summary.swift             Today and menu bar data          (Phase 5)
    Tests/UniversityKitTests/
      Fixtures/                 sanitized responses
```

Dependencies, pinned in `Package.swift`: GRDB.swift 7.11 (SQLite) and SwiftSoup 2.14 (HTML). Everything else is Apple frameworks: URLSession, AuthenticationServices, Security (Keychain), PDFKit, os (Logger), ServiceManagement (open at login), UserNotifications. The `.ics` parser is a small hand-written one (line unfolding, `DTSTART`/`DTEND` in UTC, `TZID` and `VALUE=DATE`, `UID`, `SUMMARY`, `LOCATION`).

Deployment target: macOS 15. The app is sandboxed with the outgoing-network entitlement only.

## Data model

Six SQLite tables via GRDB migrations, all prefixed `uni_`, in `~/Library/Application Support/UniversityPortal/uni.sqlite` (inside the sandbox container). Every external thing becomes one `uni_item` row, keyed by course, kind and external id, so re-syncs are idempotent upserts. Dates are stored in UTC.

| Table | Key columns | Notes |
| --- | --- | --- |
| `uni_source` | `id`, `kind` (`moodle` or `cms`), `status`, `last_sync_at`, `last_error` | `status`: `ok`, `needs_reconnect`, `degraded`, `error`. Drives the Today banner. |
| `uni_course` | `id`, `source_id`, `external_id`, `short_name`, `full_name`, `url`, `active`, `active_override`, `auto_active`, `offline`, `ics_url`, `hidden_categories` | Moodle: numeric course id. CMS: slug. `active` = `active_override` (the user's choice) if set, otherwise `auto_active`: a term in the course name (SoSe/SS, WiSe/WS, Sommer-/Wintersemester) decides, past terms are inactive; without one, the Moodle end date (0 = open-ended). `hidden_categories` (JSON array) drives per-course hiding in the Schedule tab. Unique on (`source_id`, `external_id`). |
| `uni_item` | `id`, `course_id`, `kind`, `external_id`, `title`, `body_html`, `starts_at`, `due_at`, `ends_at`, `location`, `all_day`, `url`, `category`, `is_exam`, `content_hash`, `first_seen_at`, `updated_at`, `read_at`, `done_at`, `done_source`, `missing_count`, `deleted_at` | `kind`: `deadline`, `announcement`, `event`, `material`. Unique on (`course_id`, `kind`, `external_id`). `category`: CMS calendar category name (`Lectures`, `Exam`, `Tutorial`…) for events, Moodle `modulename` (`assign`, `quiz`…) for deadlines, Moodle section name for materials. `done_source`: `user` or `moodle` (see Sync). |
| `uni_file` | `item_id`, `filename`, `mimetype`, `size_bytes`, `remote_url`, `remote_modified_at`, `sha256`, `local_path`, `fetched_at` | One per material item. Metadata on every sync. Bytes fetched lazily; `local_path` empty until first open. |
| `uni_sync_run` | `id`, `source_id`, `job`, `started_at`, `finished_at`, `ok`, `counts` (JSON), `error` | One row per job run. Used for debugging and the "last synced" label. |
| `uni_state` | `key`, `value` (JSON), `updated_at` | App state. Keys: `last_visit_at` (drives "new since last visit"), `pdf_dark_pages` (viewer toggle), `moodle_passport` (pending reconnect, with a 15-minute expiry). |

Secrets are not in the database. They are Keychain generic-password items under service `app.jayansh.UniversityPortal`, account `<kind>`: `moodle_token`, `moodle_private_token`, `cms_username`, `cms_password`, `cms_cookie_jar`.

External id per item kind:

- Moodle deadline: calendar event id. Moodle announcement: discussion id. Moodle material: module id + file path + file name.
- CMS event: a hash of summary, start, end and location (CMS regenerates `UID`s on every download). CMS news: the id in `/news/view/<id>`. CMS material: the id in `/dl/<id>/`.

`content_hash` = SHA-256 of the normalized fields shown in the UI (title, dates, body, file size and modified time). A changed hash means "updated"; a new row means "new".

## Moodle adapter

The Moodle adapter is a thin client over the official mobile web service: five functions cover everything, all verified with a real token except the deadlines call.

**Transport.** `POST https://moodle.uni-saarland.de/webservice/rest/server.php` via URLSession, form-encoded body with `wstoken`, `wsfunction`, `moodlewsrestformat=json`, then the function's arguments. Arrays are flattened as `courseids[0]=…&courseids[1]=…`. Errors come back as HTTP 200 with a JSON body containing `exception` and `errorcode`; check for it on every call.

**Calls, in sync order:**

1. `core_webservice_get_site_info` → `userid`, `release`. Cache `userid`; also serves as the token health check.
2. `core_enrol_get_users_courses(userid)` → `id`, `shortname`, `fullname`, `startdate`, `enddate`. A term in the name decides whether the course is current (`SoSe26` is past once WiSe 26/27 starts on 1 Oct). Only names without a term fall back to `enddate` (0 or in the future = active).
3. `core_calendar_get_action_events_by_timesort(timesortfrom = now − 7 days, timesortto = now + 120 days, limitnum = 50)` → `id`, `name`, `modulename`, `course.id`, `timesort` (Unix seconds, UTC), `url`, `action.name`. Becomes `deadline` items. Strip the suffix with `/\s+(ist fällig|is due)\.?$/`. Verified only with a browser session so far; confirm it with the token before anything else in Phase 2. Fallback if the token is refused: `core_calendar_get_calendar_upcoming_view` or `mod_assign_get_assignments(courseids)` (due dates per assignment), both part of the mobile service.
4. `mod_forum_get_forums_by_courses(courseids)` → keep `type === 'news'`. Then `mod_forum_get_forum_discussions(forumid, page = 0, perpage = 10)` per news forum → `discussion`, `subject`, `message` (HTML), `created`, `timemodified`, `userfullname`. Becomes `announcement` items.
5. `core_course_get_contents(courseid)` → sections → modules → `contents[]`. Keep `type === 'file'` (`filename`, `filepath`, `filesize`, `fileurl`, `timemodified`, `mimetype`) and modules with `modname === 'url'` as link materials. Becomes `material` items + `uni_file` rows.

**File download.** `fileurl` already points at `webservice/pluginfile.php`; append `token=<token>` (with `?` or `&`). Only `FileCache` does this, and the full URL is never logged.

**Pitfalls seen in testing:**

- Course and forum names contain HTML entities (`Deskriptive&amp;WR SoSe26`). Decode before storing.
- Past courses stay enrolled (Deskriptive SoSe26), and their `enddate` is not reliable: on 23 Oct SoSe26 still counted as current by end date (Moodle often defaults it to a year after the start). The term in the name wins; the user can override per course and reset to automatic.
- The browser-session AJAX endpoint (`/lib/ajax/service.php`) refuses the forum and contents functions. Always use the token REST endpoint.
- `errorcode === 'invalidtoken'` (or `accessexception` on site info) means the token is dead: set the source to `needs_reconnect` and stop that run.
- Moodle's `robots.txt` disallows crawlers. This adapter only uses the official app API, at app-like rates (see Sync), and never scrapes Moodle HTML.

## CMS adapter

CMS has no API, so the adapter combines public `.ics` feeds and news pages with logged-in HTML scraping for materials. It uses one URLSession with its own `HTTPCookieStorage` (not the shared one), SwiftSoup for HTML and the built-in `.ics` parser.

**Courses.** Each course is its own instance at `https://cms.sic.saarland/<slug>/`. `/system/courses` lists every course under `<h3>` term headings ("Winter term 2026/2027", "Summer term 2026", …). Course detection from the logged-in list was a heuristic, so Settings has a course picker (current and later terms by default, with search) and the user ticks their courses. Ticking stores the slug as a `uni_course` with `active_override = true`; unticking keeps its data but stops syncing and showing it.

**Schedule (public, no login).** `GET /<slug>/termine/events/download` returns the full iCalendar. Per-category feeds exist at `/download/<n>`; their ids and names come from the "Export a category" links on `/<slug>/termine` (Prog 1: 1 Lectures, 2 Exam, 3 Tutorial, 4 Events, 5 Other; i2cl uses German names such as Vorlesung, Übung, Klausur; some courses have none). Timed events are UTC; all-day events use `VALUE=DATE` (read as Saarbrücken calendar days).

CMS regenerates every `UID` on each download (verified 23 Oct: two downloads a few seconds apart shared 0 of 117 UIDs, with otherwise identical content). So `UID` is useless as a key and for matching categories. Instead each event is keyed by a hash of its summary, start, end and location, with a running number for exact duplicates, and the per-category feeds are matched to the full feed by that same hash. Consequence: a moved event appears as a new event, and the old one is soft-deleted after two runs. Set `is_exam` when the category name matches `/exam|klausur|prüfung/i`. Events in no category feed get category `Other`. Event items also use `ends_at`, `location` and `all_day` (migration v4).

**News (public).** `GET /<slug>/`. Each entry is an `<h4>` link to `/<slug>/news/view/<id>`, a byline ("Written on dd.mm.yy by \<name>", or in German courses "Geschrieben am … von \<name>") whose date tooltip carries the full timestamp (`dd.MM.yyyy HH:mm:ss`, Saarbrücken time), and the body. Long entries appear twice, shortened (`.collapse.show`) and full (`.collapse`); the full one is stored. Becomes `announcement` items keyed by the news id, with the author in `category`.

**Materials (login required).** `GET /<slug>/materials`. File links look like `/<slug>/dl/<id>/<filename>`; there is also a "Download all" link. Becomes `material` items keyed by the `dl` id; the list's hash detects new uploads. Logged out, the page says "You need to login in order to access more course material".

**Login.** The form posts to `/<slug>/users/login` and is a CakePHP 2 form protected by SecurityComponent:

1. `GET` any course page with the cookie jar; find the form that contains a password input.
2. Copy every hidden input exactly: `_method`, `data[_Token][key]`, `data[_Token][fields]`, `data[_Token][unlocked]`, `data[User][redirect]`.
3. Set `data[User][username]`, `data[User][password]` and `data[Auth][remember_me] = 1`.
4. `POST` to the form's action, follow redirects, save the cookie jar to the Keychain.
5. Success = the next page has no password form. Otherwise treat it as a failed login.

SecurityComponent rejects ("blackholes") any request whose fields differ from the rendered form, so never hand-build the field list: always take it from a fresh `GET`.

**Logout detection,** on every logged-in fetch: a redirect to `/users/login`, a password input in the page's main form, or the "You need to login" text. On detection: re-login once, retry the request once, then give up for this run.

**Out of scope for now:** Discourse forums linked from some courses (e.g. `prog126.forum.mi.uni-saarland.de`), points and submissions, and the personal status page.

## Sync and change detection

A `SyncScheduler` actor inside the app runs four jobs at roughly the rate the official Moodle app polls, one job per source at a time. Sync runs whenever the app is running, including with the main window closed (the menu bar extra keeps it alive); "Open at login" in Settings registers it with `SMAppService`.

| Job | Every | Does | Needs login |
| --- | --- | --- | --- |
| `moodle.fast` | 30 min | Site info, courses, deadlines, announcements | Token |
| `moodle.materials` | 3 h | `core_course_get_contents` for active courses | Token |
| `cms.public` | 60 min | News page + `.ics` per selected course | No |
| `cms.materials` | 3 h | Materials page per selected course | Session cookie |

**Rules for every job:**

- Jobs for the same source never overlap (serialized by the actor). Add up to 5 min of random jitter to each schedule.
- On launch and on wake from sleep (`NSWorkspace.didWakeNotification`), run every job whose last successful run is older than its interval. "Sync now" in the menu runs all jobs.
- Requests within a run are sequential, with at most one request per second to CMS.
- Each run writes a `uni_sync_run` row with counts (new, updated, unchanged, missing).
- Upsert on (`course_id`, `kind`, `external_id`). A new row publishes `itemCreated` on the in-app event stream; a changed `content_hash` publishes `itemUpdated`. A moved deadline is an update and is surfaced as "due date changed".
- An item missing from two consecutive successful runs gets soft-deleted (`missing_count >= 2`, sets `deleted_at`), never on the first miss.
- Exception for Moodle deadlines: the action-events call drops an assignment once it is submitted, so a deadline that goes missing before its `due_at` is marked done instead (`done_at` = now, `done_source = 'moodle'`) and stays visible under "Done". One that goes missing after `due_at` is soft-deleted as usual. A teacher deleting an assignment early also looks like "done"; accept that until `mod_assign_get_submission_status` (see Later) can tell the two apart.
- A run that suddenly returns zero items for a course that had items is treated as a parser failure: keep the old rows and set the source to `degraded`.

**Errors and backoff:**

- Network errors and 5xx: exponential backoff from 5 min up to 6 h, status `degraded`. Offline (no network path) skips the run without counting as a failure.
- Auth errors: stop immediately, status `needs_reconnect`, no retries until the user acts (CMS gets one automatic re-login first; see the next section).

**Files.** Sync stores file metadata only. `FileCache` fetches bytes on first open, saves them to `~/Library/Application Support/UniversityPortal/Files/<sha256>.<ext>` (the extension keeps them openable in Preview and Quick Look), and serves from disk afterwards. A per-course "keep offline" toggle (`uni_course.offline`) prefetches after each materials run. Settings shows the cache size and a "Clear cache" button.

## Auth, reconnect and secrets

Moodle is reconnected through your normal browser, because a native app can register the `moodlemobile://` link type that a website cannot. CMS re-logs in on its own with stored credentials. Your Moodle (university SSO) password never reaches the app's storage; only the Moodle token is stored. The CMS password is stored in the Keychain because automatic re-login needs it. If your CMS account shares a password with your university account, give CMS its own password first.

**Moodle reconnect flow:**

1. Settings or the Today banner shows "Connect in Browser". The app creates a random passport (16+ characters) and stores it in `uni_state` with a 15-minute expiry.
2. The app opens `https://moodle.uni-saarland.de/admin/tool/mobile/launch.php?service=moodle_mobile_app&passport=<passport>` in the default browser, where you are usually already logged in. You sign in with SSO if needed.
3. Moodle redirects to `moodlemobile://token=<base64>`. The app declares that scheme in its Info.plist (`CFBundleURLTypes`), so the browser asks to open University Portal and macOS delivers the URL to it (`onOpenURL`). If another app (e.g. the official Moodle desktop app) also claims `moodlemobile`, macOS may pick that one instead.
4. The app takes the part after `token=`, base64-decodes it and splits on `:::` into site hash, token and private token.
5. Check the site hash against the stored passport. Moodle computes it as `md5(wwwroot + passport)`, with `wwwroot = https://moodle.uni-saarland.de` (confirmed on the first real reconnect, 23 Oct).
6. Call `core_webservice_get_site_info`. On success, store the token in the Keychain, set status `ok`, run `moodle.fast` immediately.

**Fallback: in-app sheet.** `ASWebAuthenticationSession` with `callbackURLScheme = "moodlemobile"` keeps the whole flow inside the app. On 23 Oct it showed Moodle's login chooser but did not accept clicks; it now activates the app and anchors to a visible window first, which is still untested.

**Fallback: paste box.** If neither route returns the callback, Settings offers the manual route verified on 23 Oct: open the launch link in a browser where you are logged in, DevTools → Network (Preserve log) → the `launch.php` row (302) → Response Headers → copy the `location` value, and paste it into the app. Steps 4–6 then run as above.

The token is not tied to the web session: logging out of the Moodle website does not break it. It dies only on expiry (an admin setting, lifetime unknown) or a manual reset under Preferences → Security keys.

**CMS auto re-login:**

- Username and password in the Keychain; the cookie jar (serialized `HTTPCookie` properties) saved to the Keychain after each successful login and restored on launch.
- On logout detection: one login attempt, then retry the original request once.
- If the login fails (password form still shown), set `needs_reconnect` and stop. No further attempts until you update the password in Settings, and never more than one attempt per 15 minutes, so a wrong password cannot lock the account.
- One login at a time per source (serialized by the sync actor).

**Secrets handling:**

- Keychain generic-password items, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synced to iCloud. No secret is ever written to SQLite, `UserDefaults` or disk files.
- Secrets never reach the views: view models get status and metadata only, and files are opened from the local cache.
- All logging goes through `Log`, which runs `Redactor` on every message before it reaches `os.Logger`. It redacts `wstoken=`, `token=`, `moodlemobile://token=` and `data[User][password]`.
- Before go-live, reset the Moodle token used in testing on 23 Oct (it appeared in a chat log).

**Source states shown in the UI:**

| Status | Meaning | What you see |
| --- | --- | --- |
| `ok` | Last run succeeded | "Synced 12 min ago" |
| `degraded` | Network errors or a suspected parser break; old data kept | Grey warning, data still shown |
| `needs_reconnect` | Moodle token dead or CMS login failed | Banner on Today with a Reconnect button; badge on the menu bar icon |
| `error` | Unexpected exception | Error text in Settings, last good data still shown |

## UI

The UI is dark, quiet and small: one main window with a sidebar (Today plus four sections), a Settings window, a menu bar extra, and PDFs that open inside the app.

**Today (`Summary`):**

- A reconnect banner first, if any source is `needs_reconnect`.
- Next 3 deadlines in the next 7 days: course, title, relative due time ("in 2 days, 23:59"), link. Overdue and not done in red.
- Today's and tomorrow's lectures and exams from the calendars (by `category` and `is_exam`, skipping hidden categories).
- New since last visit: count of announcements and materials with `first_seen_at` after `uni_state.last_visit_at`, with the top 2 of each ("New in Process Mining: Lecture mode"). Leaving Today moves `last_visit_at` to now.

**Sidebar sections:**

| Section | Shows | Actions |
| --- | --- | --- |
| Deadlines | Open deadlines grouped by week, course filter; a collapsed "Done" group | Mark done (`done_at`, `done_source = 'user'`), undo, open in Moodle or CMS |
| Announcements | Feed across both platforms, unread first | Mark read, open original |
| Materials | Per course, grouped by section, "new" badge | Open in the built-in PDF viewer, open original page |
| Schedule | Week view from CMS calendars plus Moodle deadlines | Hide a category (e.g. tutorials) per course |

**Settings (⌘,):** each source's status and last sync; Reconnect Moodle (sheet or paste box); CMS username and password; choose CMS courses; toggle courses active or offline; open at login; file cache size and clear.

**Menu bar extra:** the next 3 deadlines, the new-items count, a reconnect warning if needed, "Sync now" and "Open University Portal".

All lists come from `uni_item` through GRDB `ValueObservation`, so they update live after each sync and both platforms look the same; a small source tag (Moodle or CMS) on each row is the only difference.

**Look and feel.** Dark only (`.preferredColorScheme(.dark)`), beautiful through restraint rather than effects:

- Plain SwiftUI: `NavigationSplitView`, `List`, `Table` only where columns help, standard toolbar. No custom chrome.
- Near-black window background, slightly lighter grouped rows, hairline separators, primary and secondary label colours.
- One accent colour for "new" and "due soon"; red only for overdue. No gradients or shadows; only the system's own animations.
- System font (SF Pro), three sizes. Generous spacing; reading content capped at about 720 pt wide.
- Lists, not dashboards: no charts, no widget grid. Each row is course tag, title, date, and a source tag.

**PDF viewer.** Materials open in a split view (file list on the left, PDF on the right); double-click opens a file in its own window.

- `PDFKit.PDFView` wrapped in `NSViewRepresentable`: native rendering, text selection, search (⌘F) and fast loading of large files from disk.
- Keep the toolbar minimal: page number, zoom in and out, "Open in Preview", "Show in Finder" and "Open original".
- A "dark pages" toggle that inverts the page content (Core Image `CIColorInvert` + hue rotation as the view's content filters), for reading slides at night. Remembered in `uni_state` (`pdf_dark_pages`).
- Non-PDF files (zip, pptx, ipynb) open in their default app via `NSWorkspace`, or Quick Look on space.
- Opening a file marks its material as read.

## Build phases

Five phases, each ending in an acceptance test against real data, so an implementation can't be marked done on its own say-so. Phases 1 and 2 can run in parallel.

1. **Scaffold.** Xcode project and app shell (dark window with the sidebar, empty sections, Settings window), `UniversityKit` package, GRDB migrations for the six tables, Keychain helper, `Log` and `Redactor`, `FileCache` stub.
   - Accept: `swift test` passes, covering: migrations apply to a fresh database, re-running them is a no-op, and a duplicate (`course_id`, `kind`, `external_id`) is rejected; a secret round-trips through the Keychain and is deleted afterwards; a log line containing `wstoken=abc` comes out redacted. `xcodebuild` builds the app and it launches to the empty dark window.
2. **Moodle adapter + reconnect.** First, call `core_calendar_get_action_events_by_timesort` with the token alone and switch to the fallback if it is refused, and check that the `moodlemobile://` callback reaches the app. Then the REST client, the five calls, upserts, browser reconnect with sheet and paste fallbacks, `moodle.fast` and `moodle.materials`.
   - Accept: reconnecting (sheet, or paste box if the sheet failed) sets status `ok`; one sync stores 7 courses (6 active, Deskriptive SoSe26 inactive), every open assignment visible on the Moodle dashboard, the latest announcements per course, and the files of every active course (56 across all 7 courses on 23 Oct, so slightly fewer with SoSe26 inactive; toggling SoSe26 active and re-running brings the total to 56); submitting an assignment on Moodle marks its deadline done within two runs instead of deleting it; opening one file through `FileCache` stores and returns a PDF; replacing the token with garbage sets `needs_reconnect` on the next run.
3. **CMS public data.** Course list scrape, course picker, `.ics` parser, news parser, `cms.public`.
   - Accept: with `prog1_26` selected, the Midterm on 11 Dec and the Endterm on 25 Feb appear as exam events; the "Tutorial Assignment" news from 20 Oct appears as an announcement; a second run reports 0 new, 0 updated.
   - Result (23 Oct, live against cms.sic.saarland with `prog1_26`, `i2cl_2627`, `introalgdat2627`): 170 items on the first run, 0 new and 0 updated on the second despite fresh UIDs; 5 exams found (Prog 1 Midterm, Midterm Retake, Endterm, Endterm Retake; i2cl "Klausur (1. Termin)"); news from all three courses including "Tutorial Assignment" (20 Oct).
4. **CMS login + materials.** Login flow, Keychain cookie jar, logout detection, materials parser, `cms.materials`.
   - Accept: materials for the three selected courses are stored (12, 6 and 13 links on 23 Oct); deleting the cookie jar triggers exactly one re-login and the run still succeeds; a wrong password produces one failed attempt and `needs_reconnect`, with no second attempt.
5. **UI + events.** Today, the four sections, the PDF viewer, the menu bar extra, the in-app event stream, open at login.
   - Accept: Today shows the next deadlines and the new-items counts; marking an announcement read clears it from the count; the reconnect banner and menu bar badge appear when a source needs it; a PDF opens in the viewer and the dark pages toggle survives a relaunch.

**Tests.** Swift Testing in `UniversityKitTests`. Record sanitized fixtures once per phase (JSON responses, HTML pages, one `.ics`) and run the parsers against them. Never commit tokens, cookies or passwords; strip them when recording. Views stay thin enough that the logic is covered by the package tests.

**Later (optional):** Moodle submission status (`mod_assign_get_submission_status`) to confirm auto-done deadlines were really submitted, filtering CMS tutorial slots to your own via the personal status page, Discourse forums, user notifications for new items and due-soon deadlines, a WidgetKit widget for Today, and the LSF timetable as a third source.

## Risks and open questions

The biggest risk is CMS markup changing under the scrapers; everything on the Moodle side uses a stable, versioned API.

| Risk or question | Impact | Mitigation |
| --- | --- | --- |
| CMS HTML changes | Materials or news stop syncing | Fixture tests; the zero-results guard marks the source `degraded` instead of deleting data |
| CMS login POST untested from the app | Phase 4 may need fixes | Built and verified first in Phase 4; the field list is always read from a fresh form |
| The `moodlemobile://` callback may not reach the app (another app claims the scheme, or the browser blocks the prompt) | One-click reconnect fails | The in-app sheet and the paste box remain; Settings shows which route connected |
| Sync only runs while the app runs | Stale data after the Mac was off or the app quit | Menu bar extra keeps it running, open at login, catch-up on launch and wake |
| Moodle token lifetime unknown | Reconnect frequency unknown | Handled by `needs_reconnect`; log the token's age at each failure to learn the real lifetime |
| Unsigned or re-signed dev builds | Keychain may prompt or lose access after re-signing | Sign with one Apple Development team from the start; reconnect re-stores secrets if they are lost |
| CMS events have no stable id (new `UID`s per download) | A moved event shows as new; the old copy lingers for one run | Content-hash keys; soft delete after two misses |
| CMS calendars list every tutorial slot | Schedule shows 3 parallel tutorials | Per-course category hiding now; personal status page parsing later |
| CMS account lockout | Locked out of CMS | One login attempt per failure, at most one per 15 min |
| Moodle `robots.txt` disallows crawling | Policy concern | Use only the official mobile API at app-like rates, never scrape Moodle HTML; personal use of your own data |
| Moodle courses carry no timetable | Lecture times for Moodle-only courses are missing | Add the LSF personal timetable `.ics` as a third source later |

## Appendix: endpoint reference

Every URL and function the app uses, in one place.

| Platform | Endpoint or function | Auth | Used for |
| --- | --- | --- | --- |
| Moodle | `POST /lib/ajax/service-nologin.php` with `tool_mobile_get_public_config` | None | Login type and launch URL check |
| Moodle | `GET /admin/tool/mobile/launch.php?service=moodle_mobile_app&passport=<p>` | Browser session | Token issuance (302 to `moodlemobile://token=…`) |
| Moodle | `POST /webservice/rest/server.php` | Token | All web service calls below |
| Moodle | `core_webservice_get_site_info` | Token | User id, health check |
| Moodle | `core_enrol_get_users_courses` | Token | Courses |
| Moodle | `core_calendar_get_action_events_by_timesort` | Token | Deadlines |
| Moodle | `mod_forum_get_forums_by_courses`, `mod_forum_get_forum_discussions` | Token | Announcements |
| Moodle | `core_course_get_contents` | Token | Materials and file URLs |
| Moodle | `<fileurl>&token=<token>` (`/webservice/pluginfile.php/…`) | Token | File download |
| CMS | `GET /system/courses` | None (marks enrolled when logged in) | Course list |
| CMS | `GET /<slug>/` | None | News |
| CMS | `GET /<slug>/termine/events/download` and `/download/<category>` | None | Calendar (`.ics`) |
| CMS | `GET /<slug>/materials` | Session | Materials list |
| CMS | `GET /<slug>/dl/<id>/<filename>` | Session | File download |
| CMS | `POST /<slug>/users/login` | Form + SecurityComponent tokens | Login |

**Fixtures to record** (sanitized, committed under `UniversityKit/Tests/UniversityKitTests/Fixtures`):

- [ ] Moodle: one response each for site info, courses, calendar events, forums, discussions, course contents.
- [ ] CMS: `/system/courses` logged in, one course main page with news, one `.ics`, one materials page logged in and one logged out, the login form HTML.
