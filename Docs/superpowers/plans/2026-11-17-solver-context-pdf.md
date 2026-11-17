# Solve: real PDFs, sheet rules and course memory — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Solve hands in a real, rule-following PDF (typed or handwritten) written with the whole course in mind.

**Architecture:**
- **UniversityKit (new `Solve/` folder):**
  - every piece that can be unit-tested: the course-memory store and builder, document assembly, submission-rule parsing and filling, student/course details, and the reply parser;
  - plus a course filter on `MaterialIndexer`.
- **App:** the wiring only.
  - `SolveModel` gains a memory phase, a rules phase and a richer context.
  - `SolvePanel` shows a `PDFView`, the rules row, the missing-details form and the source chips.
  - `CourseView` and `SettingsView` gain the memory view and the "Your Details" section.

**Tech Stack:** Swift 6, SwiftUI, GRDB (SQLite/FTS5), PDFKit, WKWebView, swift-testing; the ChatGPT plan via `ResponsesClient`.

**Spec:** `Docs/superpowers/specs/2026-11-17-solver-context-pdf-design.md`

## Global Constraints

**Branch.** Work on `solve-and-handwriting`; commit after every task.

**The AI never writes identity values.**
- Name, Matrikelnr., email, group, tutorial and partners come only from stored details, filled in by app code.
- A required value that is missing is asked for. It is never guessed.

**PDF bytes and contents.**
- The PDF shown in the panel is byte-for-byte the PDF that "Add to Submission" attaches and that "Open PDF" opens.
- Sources never appear in a PDF; only `<solution>` content is rendered.

**Course memory.**
- It reads course PDFs only (lectures and sheets) from the assignment's course plus `CourseLinks.related` courses.
- It never reads posts, announcements, forum threads, submissions or grades.
- It is built the first time Solve runs in a course. Nothing runs in the background before that.
- "Your notes" are never changed by an update or by Rebuild.
- An edited overview or digest is kept until the student chooses Re-read or Rebuild.

**Re-digesting.** A digest is re-made only when `uni_index.sha256` or `CourseMemory.promptVersion` changes. A model change does not trigger it.

**Solve never waits on a complete memory.** On a cancel, a failure or a usage limit, Solve goes on with the digests it has. The panel lists the files not read yet and offers "Retry".

**Limits.**

| What | Value |
|---|---|
| Digest length | 300–1,500 words |
| Part size for long files | ~60,000 characters |
| Memory sent per Solve | ~120,000 characters |

**Context per Solve.** It never calls `AskService.answer`, whose rules refuse graded solutions.

**Tests and builds.**
- Package tests: `cd UniversityKit && swift test`.
- App build: `xcodebuild -project UniversityPortal.xcodeproj -scheme UniversityPortal -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData build`.
- New files under `App/` are picked up automatically (synchronized group).

## Review Focus

1. **A sheet with no stated rules.** Expect a plain header (name, course, sheet title) and the filename `<assignment> - <name>.pdf`. It must not fail or come out empty. Covered by a test in Task 5.
2. **Model JSON wrapped in prose or code fences, or broken.** The rules parse from inside ```` ```json ```` or surrounding text. A broken reply falls back to "no rules", not an error. Covered by a test in Task 5.
3. **A file deleted from Moodle after it was digested.** Its digest leaves the memory, and an edited digest of a deleted file leaves too. Covered by a test in Task 2.
4. **A filename pattern with characters illegal in file names, or a placeholder with no value.** Expect `/ : \ * ? " < > |` replaced by `-`. An unfilled placeholder makes the field required, so it is asked for, never left as a literal `{group}`. Covered by a test in Task 5.
5. **The usage limit or a network error partway through the first build of a big course.** Digests already written are kept, the failed file gets `error` set, and the next run retries it. Covered by a test in Task 2.

---

### Task 1: Memory tables and course links

**Files:**
- Modify: `UniversityKit/Sources/UniversityKit/Store/Schema.swift`: add migration `v9_course_memory` after `v8_restore_uncertain_deadlines`.
- Create: `UniversityKit/Sources/UniversityKit/Solve/MemoryRecords.swift`
- Create: `UniversityKit/Sources/UniversityKit/Solve/CourseLinks.swift`
- Modify: `App/Solve/SheetFinder.swift`: `relatedCourses` calls `CourseLinks.related`.
- Test: `UniversityKit/Tests/UniversityKitTests/CourseMemoryTests.swift`

**Interfaces:**
- **Produces the table `uni_memory_file`:**
  - `item_id` INTEGER PK, references `uni_item` with cascade;
  - `course_id` INTEGER NOT NULL, indexed;
  - `sha256` TEXT, `prompt_version` INTEGER NOT NULL, `model` TEXT;
  - `digest` TEXT NOT NULL DEFAULT '', `edited` BOOLEAN NOT NULL DEFAULT 0;
  - `updated_at` DATETIME NOT NULL, `error` TEXT.
- **Produces the table `uni_memory`:**
  - `course_id` INTEGER PK;
  - `overview` TEXT NOT NULL DEFAULT '', `overview_edited` BOOLEAN NOT NULL DEFAULT 0;
  - `notes` TEXT NOT NULL DEFAULT '', `overview_signature` TEXT;
  - `updated_at` DATETIME NOT NULL.
- **Produces the records:**
  - `public struct MemoryFile: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable`, with `itemId, courseId, sha256, promptVersion, model, digest, edited, updatedAt, error`;
  - `public struct CourseMemoryRecord`, with `courseId, overview, overviewEdited, notes, overviewSignature, updatedAt`; its table is `uni_memory`.
- **Produces course matching:** `public enum CourseLinks { public static func related(courseId: Int64, courseName: String, courses: [(id: Int64, name: String, active: Bool)]) -> [Int64] }`. It returns the course itself first, then the active courses that share a distinctive word. This is the `words`/`filler` logic moved from `SheetFinder`, which keeps `numbers` and `sheetNumbers`.

- [ ] **Step 1: Write the failing tests**
  - `migrationCreatesMemoryTables`: open `UniDatabase(DatabaseQueue())`, insert a `MemoryFile` and a `CourseMemoryRecord`, then fetch both back equal.
  - `relatedFindsTheCMSTwin`: `related(courseId: 1, courseName: "Wirtschaftsinformatik 1", courses: [(1,"Wirtschaftsinformatik 1",true),(2,"Wirtschaftsinformatik 1 (CMS)",true),(3,"Statistik",true),(4,"Wirtschaftsinformatik alt",false)]) == [1, 2]`.
- [ ] **Step 2:** Run `cd UniversityKit && swift test --filter CourseMemoryTests`. Expected: FAIL, because the types are not defined.
- [ ] **Step 3:** Add the migration, the records and `CourseLinks`. Point `SheetFinder.relatedCourses` at `CourseLinks.related`, keeping its no-deadline branch.
- [ ] **Step 4:** Run the same command, then the full `swift test`, then the app build. Expected: all pass.
- [ ] **Step 5:** Commit with the message `Course memory tables; shared course matching`.

### Task 2: CourseMemory builder

**Files:**
- Create: `UniversityKit/Sources/UniversityKit/Solve/CourseMemory.swift`
- Test: `UniversityKit/Tests/UniversityKitTests/CourseMemoryTests.swift`

**Interfaces:**
- Consumes: the Task 1 records; `uni_page`, `uni_index` and `uni_item` (kind `material`, not deleted, `.pdf`).
- **Produces types:**
  - `public struct CourseMemory: Sendable`
  - `public typealias Complete = @Sendable (_ instructions: String, _ input: String) async throws -> String`
  - `public struct Progress: Sendable, Equatable { public var done, total: Int; public var current: String?; public var failed: [String] }`
- **Produces members:**
  - `public init(database: UniDatabase, complete: @escaping Complete, model: String)`
  - `public static let promptVersion = 1`
  - `static let partSize = 60_000`
  - `public func run(courseIds: [Int64], memoryCourseId: Int64, onProgress: @Sendable (Progress) -> Void) async -> Progress`. It returns normally when cancelled.
  - `public func pending(courseIds: [Int64]) throws -> [(itemId: Int64, title: String)]`
  - `public func unread(courseIds: [Int64]) throws -> [(title: String, reason: String)]`. This covers indexer errors, files skipped for size, and digest errors.
  - `public func reread(itemId: Int64) throws`. It clears `edited` and nulls `sha256`, so the next run re-digests the file.
  - `public func rebuild(memoryCourseId: Int64, courseIds: [Int64]) throws`. It clears all digests' `sha256` and `edited`, and sets `overview_edited = 0` and `overview_signature = nil`. It never touches `notes`.
  - `public func setNotes(_:courseId:)`, `public func setOverview(_:courseId:)` (sets `overview_edited`), and `public func setDigest(_:itemId:)` (sets `edited`).
- **The app adapts the ChatGPT client** as `{ try await client.complete(model: m, instructions: $0, input: [ChatMessage(role: .user, content: $1)]) }`.

**Behaviour that `run` must have.**

*Pending files.* A file is pending when it has `uni_index` with no error AND one of these holds:
- it has no `uni_memory_file` row;
- the row's `sha256` differs from `uni_index.sha256`;
- the row's `prompt_version` is below `promptVersion`;
- the row's `error` is not null.

A file with `edited = 1` is never pending.

*Digesting a file.*
- Join its `uni_page` text by `(page, ordinal)` with page markers `[p. N]`.
- If the text is at most `partSize`, make one `complete` call.
- Otherwise, split it at page boundaries into parts of at most `partSize`, digest each part, then make one condense call.
- On success, upsert the row with the digest, sha256, `promptVersion` and model, and set `error = nil`.
- On a thrown error, keep any older digest, set `error`, append the title to `progress.failed`, and continue with the next file.

*Removing files.* Delete `uni_memory_file` rows whose item is deleted or no longer among `courseIds`' PDFs, including edited ones.

*Overview.* After the files, if `overview_edited == 0` and the signature changed, make one `complete` call over all digests and store the overview with its signature. The signature is a hash of the sorted `itemId:sha256` pairs plus `promptVersion`.

*Cancelling.* `Task.isCancelled` is checked between calls. Rows already written stay.

- [ ] **Step 1: Write the failing tests.** Use a fake `Complete` that records its calls and returns `"digest of " + first 20 chars of input`, or throws for marked inputs.
  - `digestsEachIndexedFileOnce`: with 2 indexed PDFs, `run` gives 2 digests and 1 overview call; a second `run` makes 0 calls.
  - `aChangedFileIsReadAgain`: after changing `uni_index.sha256` for one item, `run` makes 1 digest call and 1 overview call.
  - `longFilesAreReadInPartsThenCondensed`: a file with 130,000 characters over 13 pages gives 3 part calls plus 1 condense call, and no part input exceeds `partSize` plus the instructions.
  - `editedDigestsAndNotesSurvive`: after `setDigest("mine", itemId:)`, `setNotes("keep")` and a sha change, `run` leaves the digest as "mine" and the notes as "keep"; `reread` then makes it pending again.
  - `deletedFilesLeaveTheMemory`: after marking an item `deleted_at`, `run` removes its row, even if it was edited.
  - `aFailureKeepsWhatWasDone`: when the fake throws on file 2 of 3, files 1 and 3 have digests, file 2 has `error` set, `progress.failed == [title2]`, and the next `run` with a working fake digests only file 2.
  - `rebuildKeepsNotes`: after `rebuild`, notes are unchanged and all files are pending.
  - `relatedCoursesAreIncluded`: with PDFs in courses 1 and 2, `run(courseIds: [1, 2], memoryCourseId: 1)` digests both, and their rows store their own `course_id`.
- [ ] **Step 2:** Run `swift test --filter CourseMemoryTests`. Expected: the new tests FAIL.
- [ ] **Step 3:** Implement `CourseMemory`. The digest instructions cover what the spec lists: title and section first; topics, definitions, notation and symbols, formulas and theorems, worked methods; for sheets, their tasks and submission rules; 300–1,500 words; Markdown.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit with the message `CourseMemory: per-file digests, incremental, edits kept`.

### Task 3: Memory document and its budget

**Files:**
- Modify: `UniversityKit/Sources/UniversityKit/Solve/CourseMemory.swift`
- Test: `CourseMemoryTests.swift`

**Interfaces:**
- **Produces the document type:** `public struct MemoryDocument: Sendable, Equatable`, with:
  - `notes`, `overview`;
  - `files: [Entry]`, where `Entry` has `itemId, title, section, digest, edited, changedSinceEdit: Bool`;
  - `unread: [(title, reason)]`, conforming to Equatable via a small struct.
- **Produces the functions:**
  - `public func document(memoryCourseId: Int64, courseIds: [Int64]) throws -> MemoryDocument`
  - `public static func text(_ document: MemoryDocument, keeping relevant: [Int64], budget: Int = 120_000) -> String`

**What `text` does.**
- It outputs "## Your notes", then "## Course overview", then one "## <title>" per file, in lecture order (`uni_item.position`, then the date).
- When the result is over budget, it drops file digests that are not in `relevant`, from the end of the list, until it fits.
- If it is still over budget, it drops relevant digests from the end.
- Notes and overview are never dropped.

- [ ] **Step 1: Write the failing tests.**
  - `documentOrderIsNotesOverviewFiles`.
  - `overBudgetDropsUnrelatedFilesFirst`: 5 digests of 30,000 characters each, with relevant `[id3]` and budget 100,000. The output contains notes, overview and id3, and has at most 100,000 characters.
  - `notesAndOverviewAreNeverDropped`.
  - `changedSinceEditIsReported`: an edited row whose `sha256` differs from `uni_index` gives `changedSinceEdit == true`.
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run them. Expected: PASS.
- [ ] **Step 5:** Commit with the message `Course memory document with a size budget`.

### Task 4: Index only the courses being solved

**Files:**
- Modify: `UniversityKit/Sources/UniversityKit/Ask/MaterialIndexer.swift`
- Modify: `App/AskModel.swift`: expose `func indexCourses(_ ids: [Int64]) async -> MaterialIndexer.Progress`, which also calls `refreshIndexStatus()`.
- Test: `UniversityKit/Tests/UniversityKitTests/AskTests.swift`

**Interfaces:**
- Produces `public func run(courseIds: [Int64]? = nil, onProgress:)`. With `nil` it behaves exactly as today. `pending(_:courseIds:)` adds `AND pdf.course_id IN (…)`; `pdfQuery` selects `i.course_id`.

- [ ] **Step 1:** Write the failing test `indexerCanBeLimitedToCourses`: `pending` with `courseIds: [1]` lists only course 1's PDFs.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Implement the change. Keep the existing `run(onProgress:)` call sites compiling.
- [ ] **Step 4:** Run `swift test`. Expected: all pass.
- [ ] **Step 5:** Commit with the message `Index chosen courses only`.

### Task 5: Submission rules and student details

**Files:**
- Create: `UniversityKit/Sources/UniversityKit/Solve/SubmissionRules.swift`
- Create: `UniversityKit/Sources/UniversityKit/Solve/StudentDetails.swift`
- Modify: `UniversityKit/Sources/UniversityKit/Store/AppState.swift`: add the keys `studentDetails = "student_details"`, `courseDetails = "course_details"` and `moodleFullName = "moodle_full_name"`.
- Modify: `UniversityKit/Sources/UniversityKit/Adapters/Moodle/MoodleModels.swift`: add `public var fullname: String?` to `MoodleSiteInfo`.
- Modify: `UniversityKit/Sources/UniversityKit/Adapters/Moodle/MoodleSync.swift`: store `fullname` under `.moodleFullName` when it is present.
- Test: `UniversityKit/Tests/UniversityKitTests/SubmissionRulesTests.swift`

**Interfaces:**
- **`StudentDetails`:**
  - `public struct StudentDetails: Codable, Sendable, Equatable { var name, matrikelnr, email: String }`
  - It has `load(_ db: UniDatabase)` and `save`. When it is empty, `name` defaults to `.moodleFullName`.
- **`CourseDetails`:**
  - `public struct CourseDetails: Codable, Sendable, Equatable { var group, tutorial: String; var partners: [Partner] }`
  - `public struct Partner: Codable, Sendable, Equatable, Identifiable { var id: UUID; var name, matrikelnr, email: String }`
  - Storage is a `[String: CourseDetails]` dictionary under `.courseDetails`, keyed by course id, with `load(courseId:)` and `save(_:courseId:)`.
- **`SubmissionRules`:**
  - `public struct SubmissionRules: Codable, Sendable, Equatable { var header: [Field]; var filename: String?; var other: [String]; var quote: String? }`
  - `public enum Field: String, Codable, CaseIterable { case name, matrikelnr, email, group, tutorial, partnerNames = "partner_names", partnerMatrikelnr = "partner_matrikelnr" }`
  - `public static let none` is a header of `[.name]`, no filename, empty other, and no quote.
  - `public static let instructions: String` asks for that JSON only, with the placeholders `{name} {lastname} {firstname} {matrikelnr} {group} {sheet} {course}` in `filename`.
  - `public static func parse(_ reply: String) -> SubmissionRules`. It takes the outermost `{…}` and decodes it. Unknown fields are dropped; any failure gives `.none`.
  - `public func missing(student: StudentDetails, course: CourseDetails) -> [Field]`. This covers header fields plus filename placeholders that are empty. `partnerMatrikelnr` is missing if any partner lacks one, and `partnerNames` is missing if there are no partners.
  - `public func header(student:course:courseName:sheetTitle:) -> [(label: String, value: String)]`. The labels are German when the quote looks German (`Name`, `Matrikelnummer`, `Gruppe`, `Übungsgruppe`, `Partner`), otherwise English.
  - `public func filename(student:course:assignment:sheet: Int?, courseShort: String) -> String`. It fills the pattern, or falls back to `"<assignment> - <name>.pdf"`. It replaces `[/\\:*?"<>|]` with `-` and ensures a `.pdf` suffix.

- [ ] **Step 1: Write the failing tests.**
  - `parsesJSONInsideProseAndFences`.
  - `garbageGivesNoRules`: `parse("Sorry") == .none`.
  - `noRulesGivesPlainHeaderAndFilename`: `.none.filename(... assignment: "Übungsblatt 3", name "Ada Lovelace") == "Übungsblatt 3 - Ada Lovelace.pdf"`.
  - `filenamePatternIsFilledAndCleaned`: the pattern `Blatt{sheet}_{lastname}_{matrikelnr}.pdf`, with sheet 3, name "Ada Lovelace" and Matrikelnr. "2571234", gives `Blatt3_Lovelace_2571234.pdf`. A group of `"A/B"` becomes `A-B`.
  - `emptyPlaceholderIsMissing`: the pattern `{group}.pdf` with an empty group gives `missing == [.group]`.
  - `partnerMatrikelnrIsMissingWhenAPartnerLacksIt`.
  - `germanLabelsForGermanSheets`.
  - `siteInfoDecodesFullname`: an existing site-info fixture with `"fullname": "Ada Lovelace"` added.
  - `courseDetailsRoundTripPerCourse`.
- [ ] **Step 2:** Run `swift test --filter SubmissionRulesTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test`. Expected: all pass.
- [ ] **Step 5:** Commit with the message `Submission rules, student and course details`.

### Task 6: Reply parser with sources, and the Solve context

**Files:**
- Create: `UniversityKit/Sources/UniversityKit/Solve/SolveReply.swift`
- Create: `UniversityKit/Sources/UniversityKit/Solve/SolveContext.swift`
- Modify: `App/Solve/SolveModel.swift`: replace `static func parse` with `SolveReply.parse`.
- Test: `UniversityKit/Tests/UniversityKitTests/SolveReplyTests.swift`

**Interfaces:**
- **`SolveReply`:**
  - `public struct SolveReply: Equatable { var note: String; var solution: String?; var sources: [Source] }`
  - `public enum Source: Equatable { case excerpt(Int), memory(String) }`
  - `public static func parse(_ raw: String) -> SolveReply`.
  - It keeps today's streaming behaviour: a partial `<solution`/`</solution` tag at the end is hidden.
  - `<sources>` after `</solution>` lists the items one per line: `[3]` for an excerpt, `memory: <section title>` for a memory section.
  - A partial `<sources` tag is hidden too. Nothing from `<sources>` ever enters `solution` or `note`.
- **`SolveContext`:**
  - `public struct SolveContext`
  - `public static func excerpts(retriever: Retriever, tasks: [String], courseIds: [Int64], already: Set<String>) throws -> [Excerpt]`. It runs `retriever.excerpts(for:courseId:)` per task and per course id, de-duplicates by `"\(itemId):\(page)"`, and renumbers from 1 (or after the highest number already sent).
  - `public static func tasks(in sheetText: String) -> [String]`. It splits on lines starting with `Aufgabe|Task|Exercise|Problem` + a number, or with `^\d+[.)]`. If nothing matches, it returns the whole text, capped at 2,000 characters per query.

- [ ] **Step 1: Write the failing tests.**
  - `sourcesAreReadAndKeptOutOfTheSolution`.
  - `partialSourcesTagIsHiddenWhileStreaming`.
  - `oldRepliesWithoutSourcesStillParse`: the existing `<solution>` cases are moved over.
  - `tasksSplitOnAufgabeAndNumbers`.
  - `excerptsAreDedupedAcrossCoursesAndRenumbered`: seed `uni_page` in 2 courses, as `AskTests` does.
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement, and switch `SolveModel` to `SolveReply.parse`.
- [ ] **Step 4:** Run `swift test` and the app build. Expected: all pass.
- [ ] **Step 5:** Commit with the message `Solve replies carry sources; per-task excerpts`.

### Task 7: SolveModel — memory, rules and context

**Files:**
- Modify: `App/Solve/SolveModel.swift`
- Modify: `App/Views/SubmissionView.swift`, which passes `database`, the course ids and the course names.
- Modify: `App/AskModel.swift`: expose `var database: UniDatabase` (internal) and `func memory() -> CourseMemory?`, built from `client` and `model`.

**Interfaces:**
- Consumes: Tasks 2–6 and `AskModel.indexCourses`.
- **New phases:**
  - `.memory(CourseMemory.Progress)`
  - `.rules`
  - `.needsDetails([SubmissionRules.Field])`
- **New state:**
  - `private(set) var rules: SubmissionRules?`. The assignment's existing `rules: AssignmentRules` is renamed to `assignment` to avoid confusion.
  - `private(set) var unread: [(title: String, reason: String)]`
  - `private(set) var sources: [SolveReply.Source]`
  - `private(set) var excerpts: [Excerpt]`
- **New functions:**
  - `func skipMemory()`, which cancels the memory build and continues.
  - `func retryMemory()`.
  - `func saveDetails(student: StudentDetails, course: CourseDetails)`, which resumes from `.needsDetails`.
  - `func overrideHeader(_ field: SubmissionRules.Field, value: String)`, which applies only to this PDF.

**`start()` order:**
1. Pick the sheet, as today.
2. `.memory`: run `ask.indexCourses(courseIds)`, then `CourseMemory.run`. Cancelling or `skipMemory` continues with what exists.
3. Set `unread`.
4. `.rules`: one `complete(SubmissionRules.instructions, sheet text + assignment intro + the sheet's digest)`.
5. Compute `missing`. If it is not empty, go to `.needsDetails`, and stop until `saveDetails`.
6. `reply(to: nil)`.

**Model input for each reply:**
- `instructions` + a course-memory paragraph telling the model to use the course's notation and methods, and to end with a `<sources>` block listing `[n]` excerpt numbers and `memory: <section>` names, never in the solution;
- `CourseMemory.text(document, keeping: [sheet item id] + excerpt item ids)`;
- the numbered excerpts;
- the task (text and images) as today.

Follow-ups call `SolveContext.excerpts` with `[request]` and `already`, and append new excerpts to the same input.

- [ ] **Step 1:** Implement the phases and wiring above. Keep `showDemo` working by setting `rules = .none`.
- [ ] **Step 2:** Build the app. Expected: success.
- [ ] **Step 3:** Extend `App/Debug/SolveCheck.swift` with `--solve-check memory <courseId>`. It runs `CourseMemory.run` for the course and its related courses with the real sign-in and prints `MEMORY files=<n> digested=<n> failed=<n> chars=<n> seconds=<n>`, then the first 1,500 characters of `text(...)`. Run it on one small course (Algorithms, 9 PDFs) and check that the digests read correctly.
- [ ] **Step 4:** Commit with the message `Solve reads the course memory, rules and excerpts`.

### Task 8: Real PDFs with the header and filename

**Files:**
- Modify: `App/Solve/SolutionDocument.swift`: `SolutionPDF.make(markdown:title:header:)`.
- Modify: `App/Chat/solution.html`: a `.header` block (two-column label/value table, 10pt) above the title.
- Modify: `App/Solve/Handwriter.swift` and `App/Solve/SolveModel.swift`: handwritten header.
- Modify: `App/Solve/SolvePanel.swift`: `PDFPreview` replaces `SolutionWebView` once a revision is done.

**Interfaces:**
- `static func make(markdown: String, title: String, header: [(label: String, value: String)]) async throws -> Data`
- **`SolveModel` additions:**
  - `private(set) var output: [Format: (revision: Int, data: Data)]`, the cache;
  - `func pdf() async throws -> Data`, which returns the cached bytes for `(format, revision)` or makes and caches them;
  - `var suggestedFilename` = `rules.filename(...)`.
- **Handwritten header:** prepend `header` lines as markup lines (`Label: value`) before the converted solution.
  - If any header character is not in `HandwritingProfile` metadata, render the solution handwritten and stamp a typed header onto page 1 with `CGContext` text at the top margin.
  - The demo path keeps working.
- **`PDFPreview`** is an `NSViewRepresentable` wrapping `PDFView` (`autoScales`, `displayMode = .singlePageContinuous`), taking `data: Data`.
  - While `phase == .writing`, the panel still shows `SolutionWebView`.
  - When a revision finishes, `SolveModel` calls `pdf()` for the current format, and the panel shows `PDFPreview(data:)`.
- "Add to Submission", "Open PDF" and the format switch all use `pdf()`, which comes from the cache.

- [ ] **Step 1:** Implement the changes.
- [ ] **Step 2:** Build. Use `--solve-check` (the existing demo path plus the screenshots) to print `SHOT:` images of the typed PDF with a German header, and a handwritten one using the template-check glyph library. Check them visually.
- [ ] **Step 3:** In the debug check, assert that the bytes passed to `attach` equal `output[format].data` (`PDFSAME true`).
- [ ] **Step 4:** Commit with the message `Typed and handwritten PDFs carry the sheet's header and filename`.

### Task 9: Panel — rules row, details form, sources, memory progress

**Files:**
- Modify: `App/Solve/SolvePanel.swift`
- Create: `App/Solve/DetailsForm.swift`

**Interfaces:**
- Consumes: the Task 7 phases and state.

**What the panel shows:**
- **`.memory(progress)`:** "Reading the course: done of total files", the current file name, and "Skip for Now", which calls `skipMemory()`.
- **Not-read banner:** when `unread` is not empty, a one-line banner "N files not read" that expands into a list of titles and reasons, with a "Retry" button.
- **Rules row ("Submission rules"):** collapsed to `Name · Matrikelnr. · Gruppe → Blatt3_Lovelace_2571234.pdf`. Expanded, it shows each header value with an inline edit (`overrideHeader`), `other` as bullets, and the quote in italics.
- **`DetailsForm(fields:)`:** shown for `.needsDetails`.
  - Student fields are saved to Settings.
  - Course fields (group, tutorial, a partner list with name and Matrikelnr. rows, add/remove) are saved for this course.
  - The primary button is "Save and Solve".
- **Source chips:** under the last assistant bubble.
  - An `[n]` excerpt chip reads "<title> p. <page>" and opens through `openMaterial` at the page, the way Ask opens citations.
  - A memory chip reads "Memory: <section>" and opens the course page's memory view, scrolled to that section.

- [ ] **Step 1:** Implement the panel changes.
- [ ] **Step 2:** Build. Take `--solve-check` screenshots of each state (memory progress, needs details, rules row expanded, source chips), and check them in light and dark.
- [ ] **Step 3:** Commit with the message `Solve panel: rules, details, sources, memory progress`.

### Task 10: Course page memory view, Settings, privacy text

**Files:**
- Create: `App/Views/CourseMemoryView.swift`
- Modify: `App/Views/CourseView.swift`: add a "Course Memory" section with a summary row ("22 files · updated 2 h ago") that opens `CourseMemoryView` in a sheet.
- Modify: `App/Views/SettingsView.swift`: add a "Your Details" section (name, Matrikelnr., email) before `HandwritingSection`; when empty, the name is prefilled from `.moodleFullName`.
- Modify: `README.md` and the ChatGPT privacy text in `SettingsView`.

**Interfaces:**
- Consumes: `CourseMemory.document`, `setNotes`, `setOverview`, `setDigest`, `reread`, `rebuild`, and `CourseDetails`.

**What the memory view shows:**
- **Notes:** a `TextEditor`, saved on change with a 1 s debounce.
- **Overview:** shown as Markdown, with an "Edit" button that switches to a `TextEditor`.
- **Per-file disclosure groups:** each one has its title, its digest (editable the same way), an "edited" badge, and "This file changed since you edited it" with "Re-read".
- **Not read yet:** a list.
- **Course details:** group, tutorial and partners, the same fields as `DetailsForm`.
- **"Rebuild…":** shows the confirmation "Re-read every file? Your notes are kept; edits to the overview and file summaries are replaced."

**If no memory exists:** "Built the first time you use Solve in this course."

**New privacy text:** "Ask sends only your question and matching excerpts. Solve and the course memory send the course's PDF text to your ChatGPT plan, file by file."

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Build, and take `--snapshot` or `--solve-check` screenshots of the memory view (with an edited digest) and of Settings.
- [ ] **Step 3:** Run `cd UniversityKit && swift test`. Expected: all pass, at least 136 plus the new tests.
- [ ] **Step 4:** Commit with the message `Course memory view, Your Details, privacy text`.

### Task 11: Real-assignment run

- [ ] **Step 1:** Run `./Scripts/install.sh`, then open one open assignment and click Solve, typed.
  - Expect the memory progress, then the rules row with the sheet's quote, and the details form if anything is missing.
  - Check that the PDF preview shows the header, that the filename matches the rules, and that the sources open the right pages.
- [ ] **Step 2:** Switch to Handwritten (if set up) and check its header. Then use "Open PDF" and compare it with the panel preview.
- [ ] **Step 3:** Report the results to the student with screenshots. Do not hand anything in.
