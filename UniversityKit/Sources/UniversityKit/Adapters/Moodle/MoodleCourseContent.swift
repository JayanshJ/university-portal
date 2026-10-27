import Foundation
import GRDB

/// Everything on a Moodle course beyond files and assignment deadlines: activity deadlines from the
/// calendar, forum threads with their replies, grades, course page text, assignment files and
/// direct messages.
extension MoodleSync {
    // MARK: - Activity deadlines

    /// Closing dates of feedback forms, quizzes, choices and other activities, from the course
    /// calendars. Assignments are left to the action events, which drop them once submitted.
    func fetchActivityDeadlines(courseIds: [String: Int64], activeMoodleIds: [Int], from: Int, to: Int,
                                known: Set<String>) async throws -> [ItemInput] {
        guard !activeMoodleIds.isEmpty else { return [] }
        let response: MoodleCalendarEvents = try await client.call("core_calendar_get_calendar_events", [
            .ints("events[courseids]", activeMoodleIds), .int("options[timestart]", from), .int("options[timeend]", to),
            .int("options[userevents]", 0), .int("options[siteevents]", 0),
        ])
        return response.events.compactMap { event in
            guard let module = event.modulename, module != "assign",
                  ["due", "close", "submissionclose"].contains(event.eventtype),
                  !known.contains(String(event.id)),
                  let moodleCourse = event.courseid, let courseId = courseIds[String(moodleCourse)] else { return nil }
            return ItemInput(
                courseId: courseId, kind: .deadline, externalId: String(event.id),
                title: Self.deadlineTitle(event.name),
                dueAt: Date(timeIntervalSince1970: TimeInterval(event.timestart)),
                url: client.siteURL.appending(path: "mod/\(module)/index.php")
                    .appending(queryItems: [URLQueryItem(name: "id", value: String(moodleCourse))]).absoluteString,
                category: module)
        }
    }

    // MARK: - Forums

    struct Thread {
        var forum: MoodleForum
        var courseId: Int64
        var discussion: MoodleDiscussions.Discussion
        /// All posts, oldest first, when the thread has replies; otherwise empty.
        var posts: [MoodlePosts.Post]
    }

    /// Every discussion in every forum of the active courses, with replies.
    func fetchThreads(courseIds: [String: Int64], activeMoodleIds: [Int]) async throws -> [Thread] {
        guard !activeMoodleIds.isEmpty else { return [] }
        let forums: [MoodleForum] = try await client.call(
            "mod_forum_get_forums_by_courses", [.ints("courseids", activeMoodleIds)])
        var threads: [Thread] = []
        for forum in forums {
            guard let courseId = courseIds[String(forum.course)] else { continue }
            var page = 0
            while page < 10 {
                let response: MoodleDiscussions = try await client.call(
                    "mod_forum_get_forum_discussions",
                    [.int("forumid", forum.id), .int("page", page), .int("perpage", 100)])
                for discussion in response.discussions {
                    var posts: [MoodlePosts.Post] = []
                    if (discussion.numreplies ?? 0) > 0 {
                        let response: MoodlePosts = try await client.call("mod_forum_get_discussion_posts", [
                            .int("discussionid", discussion.discussion), .value("sortby", "created"),
                            .value("sortdirection", "ASC"),
                        ])
                        posts = response.posts
                    }
                    threads.append(Thread(forum: forum, courseId: courseId, discussion: discussion, posts: posts))
                }
                guard response.discussions.count == 100 else { break }
                page += 1
            }
        }
        return threads
    }

    /// Announcements (the news forum) and discussions (every other forum), each with its replies.
    func threadItems(_ threads: [Thread]) -> (announcements: [ItemInput], discussions: [ItemInput]) {
        var announcements: [ItemInput] = []
        var discussions: [ItemInput] = []
        for thread in threads {
            let discussion = thread.discussion
            let replies = max(0, thread.posts.count - 1)
            let item = ItemInput(
                courseId: thread.courseId, kind: thread.forum.type == "news" ? .announcement : .discussion,
                externalId: String(discussion.discussion),
                title: HTMLText.decodeEntities(discussion.subject),
                bodyHtml: Self.threadHTML(first: discussion.message, posts: thread.posts),
                startsAt: Date(timeIntervalSince1970: TimeInterval(discussion.created)),
                url: client.siteURL.appending(path: "mod/forum/discuss.php")
                    .appending(queryItems: [URLQueryItem(name: "d", value: String(discussion.discussion))])
                    .absoluteString,
                category: discussion.userfullname,
                details: ["forum": HTMLText.decodeEntities(thread.forum.name), "replies": String(replies)]
                    .merging(discussion.pinned == true ? ["pinned": "1"] : [:]) { a, _ in a })
            if thread.forum.type == "news" { announcements.append(item) } else { discussions.append(item) }
        }
        return (announcements, discussions)
    }

    /// The first post, then each reply after a marker carrying its author and date
    /// (`PortalOverview.ItemRow.posts` splits them again).
    static func threadHTML(first: String, posts: [MoodlePosts.Post]) -> String {
        guard posts.count > 1 else { return first }
        return ([first] + posts.dropFirst().map { post in
            let author = (post.author?.fullname ?? "").replacingOccurrences(of: "\"", with: "'")
            return "<hr data-reply-author=\"\(author)\" data-reply-date=\"\(post.timecreated)\">\(post.message)"
        }).joined()
    }

    /// Files attached to forum posts, as materials filed under the forum's name.
    func threadMaterials(_ threads: [Thread]) -> [ItemInput] {
        threads.flatMap { thread -> [ItemInput] in
            let firstFiles = (thread.discussion.attachments ?? []).map { (post: thread.discussion.discussion, file: $0) }
            let replyFiles = thread.posts.dropFirst().flatMap { post in (post.attachments ?? []).map { (post: post.id, file: $0) } }
            let url = client.siteURL.appending(path: "mod/forum/discuss.php")
                .appending(queryItems: [URLQueryItem(name: "d", value: String(thread.discussion.discussion))]).absoluteString
            return (firstFiles + replyFiles).compactMap { entry in
                guard let link = entry.file.link else { return nil }
                return ItemInput(
                    courseId: thread.courseId, kind: .material,
                    externalId: "post:\(entry.post)/\(entry.file.filename)",
                    title: entry.file.filename, url: url, category: HTMLText.decodeEntities(thread.forum.name),
                    file: FileInput(filename: entry.file.filename, mimetype: entry.file.mimetype,
                                    sizeBytes: entry.file.filesize.map(Int64.init), remoteUrl: link,
                                    remoteModifiedAt: entry.file.timemodified.map { Date(timeIntervalSince1970: TimeInterval($0)) }))
            }
        }
    }

    // MARK: - Grades

    func fetchGrades(courses: [UniCourse], userId: Int) async throws -> [ItemInput] {
        var items: [ItemInput] = []
        for course in courses {
            guard let moodleId = Int(course.externalId), let courseId = course.id else { continue }
            let response: MoodleGradeItems = try await client.call(
                "gradereport_user_get_grade_items", [.int("courseid", moodleId), .int("userid", userId)])
            let report = client.siteURL.appending(path: "grade/report/user/index.php")
                .appending(queryItems: [URLQueryItem(name: "id", value: String(moodleId))]).absoluteString
            for (index, grade) in (response.usergrades.first?.gradeitems ?? []).enumerated() where grade.itemtype != "category" {
                let shown = { (text: String?) in text.map(HTMLText.plainText).flatMap { $0.isEmpty || $0 == "-" ? nil : $0 } }
                var details: [String: String] = [:]
                details["range"] = shown(grade.rangeformatted)
                details["percentage"] = grade.graderaw == nil ? nil : shown(grade.percentageformatted)
                details["weight"] = shown(grade.weightformatted)
                details["module"] = grade.itemmodule
                details["total"] = grade.itemtype == "course" ? "1" : nil
                items.append(ItemInput(
                    courseId: courseId, kind: .grade, externalId: String(grade.id),
                    title: grade.itemtype == "course" ? "Course total" : HTMLText.decodeEntities(grade.itemname ?? "Grade"),
                    bodyHtml: grade.feedback.flatMap { HTMLText.plainText($0).isEmpty ? nil : $0 },
                    startsAt: grade.gradedategraded.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
                    url: grade.cmid.flatMap { cmid in grade.itemmodule.map {
                        client.siteURL.appending(path: "mod/\($0)/view.php")
                            .appending(queryItems: [URLQueryItem(name: "id", value: String(cmid))]).absoluteString
                    } } ?? report,
                    category: grade.graderaw == nil ? nil : shown(grade.gradeformatted),
                    position: index, details: details))
            }
        }
        return items
    }

    // MARK: - Course page text and assignment files

    /// The course summary, section summaries, labels, activity descriptions, pages and assignment
    /// texts, in course page order; plus the files attached to assignments.
    func coursePage(courses: [UniCourse], sectionsByCourse: [Int64: [MoodleSection]]) async throws
        -> (notes: [ItemInput], files: [ItemInput]) {
        let ids = courses.compactMap { Int($0.externalId) }
        guard !ids.isEmpty else { return ([], []) }
        let courseByMoodleId = Dictionary(uniqueKeysWithValues: courses.compactMap { course in
            Int(course.externalId).flatMap { id in course.id.map { (id, $0) } }
        })
        let summaries: MoodleCourseSummaries = try await client.call("core_course_get_courses_by_field", [
            .value("field", "ids"), .value("value", ids.map(String.init).joined(separator: ",")),
        ])
        let pages: MoodlePages = try await client.call("mod_page_get_pages_by_courses", [.ints("courseids", ids)])
        let assignments: MoodleAssignmentIntros = try await client.call("mod_assign_get_assignments", [.ints("courseids", ids)])

        var notes: [ItemInput] = []
        var files: [ItemInput] = []
        for summary in summaries.courses {
            guard let courseId = courseByMoodleId[summary.id], let html = summary.summary, Self.hasText(html) else { continue }
            notes.append(ItemInput(courseId: courseId, kind: .note, externalId: "course", title: "About This Course",
                                   bodyHtml: html, url: Self.courseURL(client, summary.id), position: -1))
        }
        for (moodleId, courseId) in courseByMoodleId {
            let sections = sectionsByCourse[courseId] ?? []
            // Where each activity sits, for ordering and filing.
            var place: [Int: (section: String, position: Int)] = [:]
            for (sectionIndex, section) in sections.enumerated() {
                let sectionName = HTMLText.decodeEntities(section.name)
                let base = sectionIndex * 1000
                if let summary = section.summary, Self.hasText(summary) {
                    notes.append(ItemInput(
                        courseId: courseId, kind: .note, externalId: "section:\(section.id)", title: sectionName,
                        bodyHtml: summary, url: Self.courseURL(client, moodleId, section: section.section ?? sectionIndex),
                        category: sectionName, position: base))
                }
                for (moduleIndex, module) in section.modules.enumerated() {
                    place[module.id] = (sectionName, base + moduleIndex + 1)
                    guard let description = module.description, Self.hasText(description) else { continue }
                    notes.append(ItemInput(
                        courseId: courseId, kind: .note, externalId: "module:\(module.id)",
                        title: module.modname == "label" ? "" : HTMLText.decodeEntities(module.name),
                        bodyHtml: description, url: module.url ?? Self.courseURL(client, moodleId),
                        category: sectionName, position: base + moduleIndex + 1,
                        details: ["module": module.modname]))
                }
            }
            for page in pages.pages where page.course == moodleId {
                guard let content = page.content, Self.hasText(content) else { continue }
                notes.append(ItemInput(
                    courseId: courseId, kind: .note, externalId: "page:\(page.coursemodule)",
                    title: HTMLText.decodeEntities(page.name), bodyHtml: content,
                    url: client.siteURL.appending(path: "mod/page/view.php")
                        .appending(queryItems: [URLQueryItem(name: "id", value: String(page.coursemodule))]).absoluteString,
                    category: place[page.coursemodule]?.section, position: place[page.coursemodule]?.position,
                    details: ["module": "page"]))
            }
            let described = Set(notes.filter { $0.courseId == courseId }.map(\.externalId))
            for assignment in assignments.courses.first(where: { $0.id == moodleId })?.assignments ?? [] {
                let url = client.siteURL.appending(path: "mod/assign/view.php")
                    .appending(queryItems: [URLQueryItem(name: "id", value: String(assignment.cmid))]).absoluteString
                if let intro = assignment.intro, Self.hasText(intro), !described.contains("module:\(assignment.cmid)") {
                    notes.append(ItemInput(
                        courseId: courseId, kind: .note, externalId: "module:\(assignment.cmid)",
                        title: HTMLText.decodeEntities(assignment.name), bodyHtml: intro, url: url,
                        category: place[assignment.cmid]?.section, position: place[assignment.cmid]?.position,
                        details: ["module": "assign"]))
                }
                for file in assignment.introattachments ?? [] {
                    guard let link = file.link else { continue }
                    files.append(ItemInput(
                        courseId: courseId, kind: .material, externalId: "assign:\(assignment.cmid)/\(file.filename)",
                        title: file.filename, url: url,
                        category: place[assignment.cmid]?.section ?? HTMLText.decodeEntities(assignment.name),
                        file: FileInput(filename: file.filename, mimetype: file.mimetype,
                                        sizeBytes: file.filesize.map(Int64.init), remoteUrl: link,
                                        remoteModifiedAt: file.timemodified.map { Date(timeIntervalSince1970: TimeInterval($0)) })))
                }
            }
        }
        return (notes, files)
    }

    static func hasText(_ html: String) -> Bool {
        !HTMLText.plainText(html).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func courseURL(_ client: MoodleClient, _ moodleId: Int, section: Int? = nil) -> String {
        var components = URLComponents(url: client.siteURL.appending(path: "course/view.php"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: String(moodleId))]
        if let section { components.fragment = "section-\(section)" }
        return components.url!.absoluteString
    }

    // MARK: - Messages

    /// Direct-message conversations with their latest 50 messages, replacing what is stored.
    func syncConversations(userId: Int, sourceId: Int64) async throws -> Int {
        let response: MoodleConversations = try await client.call("core_message_get_conversations", [
            .int("userid", userId), .int("limitfrom", 0), .int("limitnum", 50),
        ])
        var rows: [UniConversation] = []
        for conversation in response.conversations {
            let detail: MoodleConversationMessages = try await client.call("core_message_get_conversation_messages", [
                .int("currentuserid", userId), .int("convid", conversation.id), .int("limitfrom", 0),
                .int("limitnum", 50), .int("newest", 1),
            ])
            let members = (conversation.members ?? []) + (detail.members ?? [])
            let names = Dictionary(members.map { ($0.id, $0.fullname) }, uniquingKeysWith: { a, _ in a })
            let others = names.filter { $0.key != userId }.map(\.value).sorted()
            let name = conversation.name.flatMap { $0.isEmpty ? nil : $0 }
                ?? (conversation.type == 3 ? "Personal space" : others.joined(separator: ", "))
            let messages = detail.messages.map { message in
                UniConversation.Message(
                    id: message.id, author: names[message.useridfrom] ?? "Unknown", mine: message.useridfrom == userId,
                    text: HTMLText.plainText(message.text),
                    sentAt: Date(timeIntervalSince1970: TimeInterval(message.timecreated)))
            }.sorted { $0.sentAt < $1.sentAt }
            rows.append(UniConversation(
                sourceId: sourceId, externalId: String(conversation.id), name: name.isEmpty ? "Conversation" : name,
                unreadCount: conversation.unreadcount ?? 0, lastMessageAt: messages.last?.sentAt, messages: messages,
                url: client.siteURL.appending(path: "message/index.php")
                    .appending(queryItems: [URLQueryItem(name: "convid", value: String(conversation.id))]).absoluteString))
        }
        let found = rows
        try await database.writer.write { db in
            let existing = try UniConversation.filter(Column("source_id") == sourceId).fetchAll(db)
            let byExternal = Dictionary(uniqueKeysWithValues: existing.map { ($0.externalId, $0) })
            for var row in found {
                row.id = byExternal[row.externalId]?.id
                try row.save(db)
            }
            let keep = Set(found.map(\.externalId))
            for row in existing where !keep.contains(row.externalId) { try row.delete(db) }
        }
        return found.count
    }
}
