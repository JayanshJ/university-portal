# Solve: real PDFs, sheet rules and course memory

Date: 2026-11-17 · Branch: `solve-and-handwriting` · Status: draft for approval

## Why

Solve currently gives a typed answer as formatted text, or a handwritten PDF when the student has set up their handwriting. The student wants two things:

1. **A PDF they can hand in.** The typed format must be an actual PDF. It must also follow the rules each sheet sets for submissions: name, Matrikelnr., group, file naming and so on. Those rules differ from sheet to sheet, so the app has to read them from each sheet rather than having them hard-coded.
2. **A solver that knows the course.** It should have read the lectures and the other sheets, the way an agent keeps a memory file. Then its answers use the course's notation, definitions and methods instead of generic ones. Ask already has a good search engine over course PDFs, and Solve should use it.

What success looks like: the student clicks Solve, sees real A4 pages that already carry the right header and filename, and hands them in after a review. The method used matches what the lecture taught.

## Goals

- **Typed PDF preview.** The typed format shows real A4 PDF pages in the panel, and the PDF is re-made after each edit. The bytes the student previews are the bytes that get added to the submission.
- **Sheet rules.** The app reads each sheet's submission rules and applies them to the header and the filename, for both formats. The rules are shown in the panel.
- **Student details.**
  - Name, Matrikelnr. and email are entered once in Settings.
  - Group and partner names are remembered per course.
  - When a sheet needs a detail that is missing, the panel asks for it before the PDF is made.
  - The AI never writes these values. App code fills them in.
- **Course memory.** One memory per course, built from the course's PDFs (lectures and sheets).
  - It is built the first time Solve is clicked in that course.
  - After that, it is updated only for new or changed files.
  - The student can view and edit it on the course page, and their edits survive later updates.
- **Context for each task.** Each Solve gets three things: the course memory, Ask's search excerpts for the task, and the sheet itself as text and page images (as today).
- **Sources in the panel only.** The panel shows the sources the solution leaned on, and they are clickable. Sources never appear in the PDF.

## Non-goals

- The memory does not read posts, announcements, forum threads, earlier submissions or grades. PDFs only.
- No background or overnight memory building, and nothing runs before the first Solve in a course.
- No change to how the handwriting itself is rendered, beyond the header and filename.
- Ask's answers do not change. Ask can use the memory later, but not in this work.

## Anti-goals (a failure even if it "works")

- An invented or wrong Matrikelnr., name or group in a handed-in PDF.
- A preview that differs from the file that gets handed in.
- Source lists or "according to lecture 3" remarks inside the handed-in PDF.
- Student notes in the memory lost after an update.
- Course text sent anywhere other than the student's own ChatGPT plan.

## Approaches considered

- **A. File by file (picked).** The model writes a digest of each course PDF once. The app stores each digest with the file's fingerprint and assembles them into one course memory.
  - A new or changed file only costs reading that file.
  - Every request fits within the model's limits.
  - Picked by the student.
- **B. Whole course in one pass.** Rejected. Larger courses don't fit: Programming 1 has about 850k characters of PDF text, and Inv+Fin has a 622-page book. Every new file would mean re-reading everything.
- **C. Search only, no memory.** Rejected. It is cheapest and has no wait, but it is not the "read everything, keep a memory" the student asked for, and there is nothing to view or edit.

## Design

### 1. Course memory

**What a digest is.** One digest per course PDF: a compact Markdown summary of 300–1,500 words. It covers:

- the topics, definitions, notation and symbols, formulas and theorems, and worked methods;
- for a sheet: its tasks and its submission rules.

Each digest starts with the file's title and its Moodle section.

**Source text.** Digests are written from text that is already indexed in `uni_page` (Ask's index), not by re-reading the PDFs.

- Before building, Solve runs `MaterialIndexer` for that course's unindexed PDFs.
- Some PDFs are currently unindexed: Inv+Fin 1/3, Programming 1 18/22, Winfo 12/13.
- PDFs the indexer skips are listed in the memory as "not read" with the reason: over 80 MB, no text (a scan), or failed.

**Long files.** A file too long for one request is read in parts of about 60k characters. Each part gets its own digest. A final call condenses the part digests into the file's digest.

**Fingerprint.** A file is re-digested only when its `uni_index.sha256`, the digest prompt version or the model changes. A file that disappears from Moodle has its digest removed from the memory.

**The memory document.** Assembled by app code, not by the model, in this order:

1. **Your notes:** free text owned by the student. It is never touched by updates.
2. **Course overview:** a short model-written synthesis across all digests: main topics in lecture order, notation that recurs, and how the sheets relate to the lectures. It is regenerated only when a digest changed.
3. **One section per file:** its digest.

**Storage.** A new migration `v9_course_memory` in `UniversityKit/Store/Schema.swift` adds two tables:

- `uni_memory_file`:
  - `course_id`, `item_id` (primary key), `sha256`, `prompt_version`, `model`
  - `digest`, `edited` (bool), `updated_at`, `error`
- `uni_memory`:
  - `course_id` (primary key)
  - `overview`, `notes`, `overview_signature`, `updated_at`

The builder is a new `CourseMemory` type in `UniversityKit/Ask/`, shaped like `TextSchedule`: a `Sendable` struct with `database` and `client`, plus a `run(courseId:model:onProgress:)`. Tests cover:

- change detection;
- digests removed when the file is deleted;
- edited digests being kept;
- notes being kept;
- splitting long files into parts.

**Building on the first Solve.**

- If the course has no memory yet, the panel shows "Reading the course: 7 of 22 files" with the current file name before solving. The student can cancel; files already digested are kept.
- If the memory exists, any new or changed files are read first, with the same progress line, and the student cannot skip this.
- In both cases the solve itself only starts once the memory is up to date.

**Viewing and editing.** A "Course Memory" section on the course page (`App/Views/CourseView.swift`) shows the document. Any of the three parts can be edited:

- **Notes:** saved as they are.
- **Overview:** an edit marks it as edited, and it is then not regenerated.
- **A file's digest:** an edit marks that digest as edited, and it is kept even if the file changes later. The section then shows "this file changed since you edited it" with a "Re-read" button that discards the edit.

There is also a "Rebuild" button, which re-reads every file and discards edited digests and the edited overview, never the notes. It asks for confirmation first.

### 2. Context for each Solve

For each Solve, the model receives:

- **Instructions:** as today, plus the course-memory rules: use the course's notation and methods, and name the sources the solution relied on in the `<sources>` block (below), never in the solution.
- **Course memory:** the full document. If it exceeds about 120k characters, the per-file digests of files unrelated to the sheet are dropped first, ranked by Ask's search scores against the sheet text. The notes and the overview are always kept.
- **Excerpts:** `Retriever.excerpts(for:courseId:)` called with each task of the sheet as its own query, each excerpt with its file, page and number. `AskService.answer` is not used: its rules refuse full solutions to graded tasks.
- **The sheet:** as today (text plus page images), plus the assignment description and deadline.

Follow-up edit requests in the chat reuse the same memory and excerpts. They don't search again unless the student's message names a new topic, which is detected by `Retriever.detect`.

### 3. Sheet rules

**Reading the rules.** Before solving, one model call reads the sheet text, the assignment description and the sheet's digest. It returns JSON describing the rules:

```json
{
  "header": ["name", "matrikelnr", "group", "partners", "email", "tutorial"],
  "filename": "Blatt{sheet}_{lastname}_{matrikelnr}.pdf",
  "other": ["max 2 students per group", "hand in as one PDF"],
  "quote": "Bitte geben Sie Name und Matrikelnummer an …"
}
```

- `header` lists only the fields the sheet asks for.
- `filename` is a pattern, or null when the sheet doesn't name one.
- `quote` is the sheet's own wording, so the student can check that the rules were read correctly.

If the sheet states no rules, the PDF gets a plain header (student name, course, sheet title) and the filename `<assignment> - <name>.pdf`.

**Filling in the details.** App code fills each field from:

- Settings: name, Matrikelnr., email;
- the per-course details: group, partners, tutorial;
- the assignment: sheet number, course.

Nothing comes from the model.

**Missing details.** If a required field is empty, the panel shows a small form above the preview, such as "This sheet asks for your group number." Saving it stores it in the right place (Settings or this course), then the PDF is made.

**In the panel.** A "Submission rules" row shows the fields found, the filename and the sheet's quote. It can be expanded, and the student can correct a value for this one PDF.

**Where the rules are applied.**

- **Typed:** the header is a block at the top of page 1 in `solution.html`.
- **Handwritten:** the header is written in the student's handwriting by passing it through the same renderer. If a header character is missing from their handwriting, the header is typed instead.
- **Filename:** the filename pattern replaces the current fixed `"<name> - Solution.pdf"`, with characters cleaned up for file names.

### 4. Typed PDF preview

The panel replaces `SolutionWebView` with a PDF view (`PDFKit`'s `PDFView`), showing the output of `SolutionPDF.make` plus the header.

- **While the model writes,** the panel shows the formatted text streaming in, as today.
- **When the revision finishes,** it switches to the PDF: one PDF per revision, made once and cached.
- **"Add to Submission"** attaches exactly the cached bytes.
- **"Open PDF"** opens the same file.
- **The format picker** switches between the cached typed and handwritten PDFs without re-rendering.

### 5. Sources in the panel

The model ends its reply with a `<sources>` block after `</solution>`, listing the excerpt numbers and memory sections it relied on.

- `SolveModel.parse` is extended to return `(note, solution?, sources)`, with a unit test.
- The panel shows the sources as chips under the chat. Clicking one opens the PDF at that page, the way Ask opens its citations.
- The `<sources>` block never reaches the PDF, because only the `<solution>` content is rendered.

### 6. Settings and privacy

**New Settings section, "Your Details":** name, Matrikelnr., email.

- Name can be pre-filled from Moodle's `fullname` if the site info provides it.
- Stored with the app's other settings, on this Mac.

**Per-course details** (group, partners, tutorial) are edited from the panel prompt or from the course page.

**Privacy text.** The current Settings and README privacy text says only the question and matching excerpts are sent. It is updated to say that Solve and the course memory send the course's PDF text to the student's own ChatGPT plan, file by file.

## What is left to the builder

- Exact digest and overview prompts, and the JSON shape for the rules (above is the intent).
- The exact limits (digest length, part size, memory budget), within the numbers above.
- Layout details of the memory view, the rules row and the missing-details form, following the app's existing Form style.
- How progress and cancellation are wired, following `MaterialIndexer.Progress`.

## Verification before calling it done

- `cd UniversityKit && swift test` is green, including the new tests:
  - `CourseMemory` change detection and edits;
  - the rules parser;
  - the `<sources>` parser.
- **Debug run on real data:** build the memory for one course with real sign-in. Report the digest count, time and characters, and check the memory reads correctly.
- **Real assignment, end to end:** solve one open assignment typed and one handwritten. Check the header, the filename, that the preview bytes equal the attached bytes, and that the sources open the right pages.
