import XCTest

final class WalkthroughTests: XCTestCase {
    func testIdeaDraftButtonSelectsTextFormatsAndQueuesForClaude() {
        continueAfterFailure = false
        let app = openIdea(theme: "warm-paper")
        let draft = app.buttons["idea.draft.open"].firstMatch
        for _ in 0..<4 where !draft.isHittable { app.swipeUp() }
        XCTAssertTrue(draft.isHittable, app.debugDescription)
        XCTAssertTrue(app.buttons["Skip idea"].exists)
        capture("Draft button above Skip idea", app)
        draft.tap()
        let x = app.buttons["idea.draft.platform.x"].firstMatch
        XCTAssertTrue(x.waitForExistence(timeout: 5), app.debugDescription)
        x.tap()
        for platform in ["linkedin-article", "substack"] {
            let option = app.buttons["idea.draft.platform.\(platform)"].firstMatch
            for _ in 0..<4 where !option.isHittable { app.swipeUp() }
            XCTAssertTrue(option.isHittable, app.debugDescription)
            option.tap()
        }
        XCTAssertFalse(app.buttons["idea.draft.platform.instagram"].exists)
        XCTAssertFalse(app.buttons["idea.draft.platform.tiktok"].exists)
        capture("Text formats selected for Claude", app)
        let send = app.buttons["idea.draft.send"].firstMatch
        for _ in 0..<5 where !send.isHittable { app.swipeUp() }
        XCTAssertTrue(send.isHittable && send.isEnabled, app.debugDescription)
        send.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        let queued = app.staticTexts["Queued for Claude on your Mac."].firstMatch
        if !queued.waitForExistence(timeout: 2), send.exists, send.isEnabled {
            send.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        }
        for _ in 0..<3 where !queued.isHittable { app.swipeUp() }
        XCTAssertTrue(queued.waitForExistence(timeout: 5), app.debugDescription)
        capture("Request queued for Claude on Mac", app)
    }

    func testIdeaDraftActionsInAllThemes() {
        continueAfterFailure = false
        for theme in ["graphite", "warm-paper", "native-light"] {
            verifyIdeaDraftActions(theme: theme)
        }
    }

    func testIdeaDraftActionsMatchSystem() {
        continueAfterFailure = false
        verifyIdeaDraftActions(theme: "system")
    }

    func testIdeaRevisionRequestUsesTheMacWritingConnection() {
        continueAfterFailure = false
        let app = openIdea(theme: "graphite", extraArguments: ["--script-fixture", "--revision-requests-fixture"])
        let addRequest = app.buttons["review.addRevisionRequest"].firstMatch
        let input = app.descendants(matching: .any).matching(identifier: "review.revisionRequest").firstMatch
        let send = app.buttons["Send revision request"].firstMatch
        let requests = ["Focus on one practical example.", "Keep the original source links."]
        for (index, text) in requests.enumerated() {
            for _ in 0..<4 where !addRequest.isHittable { app.swipeUp() }
            XCTAssertTrue(addRequest.isHittable)
            XCTAssertFalse(input.exists)
            addRequest.tap()
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            if index == 0 { capture("Idea revision request and example", app) }
            input.tap()
            input.typeText(text)
            for _ in 0..<4 where !send.isHittable { app.swipeUp() }
            XCTAssertTrue(send.isHittable)
            send.tap()
            XCTAssertTrue(app.staticTexts[text].firstMatch.waitForExistence(timeout: 8))
        }
        XCTAssertTrue(app.staticTexts["Acted on"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts.matching(identifier: "Acted on").count, 2)
        for text in requests { XCTAssertEqual(app.staticTexts.matching(identifier: text).count, 1) }
        capture("Both Inkspring revision requests marked acted on", app)
    }

    private func verifyIdeaDraftActions(theme: String) {
        let app = openIdea(theme: theme)
        defer { app.terminate() }
        let draft = app.buttons["idea.draft.open"].firstMatch
        let skip = app.buttons["Skip idea"].firstMatch
        for _ in 0..<4 where !draft.isHittable || !skip.isHittable { app.swipeUp() }
        XCTAssertTrue(draft.isHittable && draft.isEnabled)
        XCTAssertTrue(skip.isHittable)
        XCTAssertGreaterThanOrEqual(draft.frame.height, 44)
        XCTAssertLessThan(draft.frame.midY, skip.frame.midY)
        capture("Idea detail - \(theme)", app)
        draft.tap()

        let send = app.buttons["idea.draft.send"].firstMatch
        let x = app.buttons["idea.draft.platform.x"].firstMatch
        XCTAssertTrue(x.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isHittable)
        XCTAssertFalse(send.isEnabled)
        capture("Chooser without selection - \(theme)", app)
        x.tap()
        XCTAssertTrue(send.isHittable && send.isEnabled)
        XCTAssertGreaterThanOrEqual(send.frame.height, 44)
        capture("Chooser with selection - \(theme)", app)
    }

    private func openIdea(theme: String, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--library-fixture", "-inkspring.mobile.theme", theme] + extraArguments
        app.launchEnvironment["INKSPRING_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        let review = app.buttons["Review"].firstMatch
        if !review.waitForExistence(timeout: 3), app.buttons["ToggleSidebar"].exists { app.buttons["ToggleSidebar"].tap() }
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        review.tap()
        let filter = app.buttons["Ideas"].firstMatch
        let idea = app.staticTexts["Show the unfinished work"].firstMatch
        if !idea.exists { filter.tap() }
        if !idea.waitForExistence(timeout: 3), filter.isHittable { filter.tap() }
        XCTAssertTrue(idea.waitForExistence(timeout: 8), app.debugDescription)
        idea.tap()
        return app
    }

    func testMediaDraftsStartWithMediaAndCaption() {
        continueAfterFailure = false
        let app = openIdea(theme: "warm-paper")
        for (title, picker) in [("TikTok video", "Choose a video"), ("Instagram post", "Choose a photo or video")] {
            let media = app.buttons["idea.media.open"].firstMatch
            for _ in 0..<4 where !media.isHittable { app.swipeUp() }
            media.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
            let choice = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
            choice.tap()
            XCTAssertTrue(app.buttons[picker].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "Caption (optional)").firstMatch.exists)
            XCTAssertFalse(app.staticTexts["Hashtags"].exists)
            capture(title, app)
            app.buttons["Done"].firstMatch.tap()
        }
    }

    func testPlanPreviewEditSaveAndAssistant() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--library-fixture", "--newsletter-fixture", "-inkspring.mobile.theme", "warm-paper"]
        app.launchEnvironment["INKSPRING_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        let row = app.staticTexts["A better first paragraph"].firstMatch
        if !row.waitForExistence(timeout: 3), app.buttons["ToggleSidebar"].exists { app.buttons["ToggleSidebar"].tap() }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertFalse(app.buttons["outline.view"].exists)
        XCTAssertFalse(app.buttons["Create plan"].exists)
        app.buttons["newsletter.more"].firstMatch.tap()
        let add = app.buttons["outline.menu"].firstMatch
        XCTAssertEqual(add.label, "Add outline")
        add.tap()
        let markdown = app.buttons["Markdown"].firstMatch
        XCTAssertTrue(markdown.waitForExistence(timeout: 5)); markdown.tap()
        let editor = app.textViews["plan.markdown"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        editor.typeText("# Launch plan\n\n- [ ] Check the links\n- [ ] Review the opening\n\n[Inkspring](https://inkspring.ai/)")
        capture("Inline Plan Markdown editor", app)
        let save = app.buttons["plan.save"].firstMatch
        for _ in 0..<5 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable); save.tap()
        let view = app.buttons["outline.view"].firstMatch
        XCTAssertTrue(view.waitForExistence(timeout: 8))
        view.tap()
        XCTAssertTrue(app.staticTexts["Launch plan"].firstMatch.waitForExistence(timeout: 5))
        capture("Plan saved locally and queued for Mac", app)
    }
    func testAskInkspringScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["--library-fixture", "-inkspring.mobile.theme", "warm-paper"]
        app.launchEnvironment["INKSPRING_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        let ask = app.buttons["assistant.open"].firstMatch
        if !ask.waitForExistence(timeout: 2), app.buttons["ToggleSidebar"].exists { app.buttons["ToggleSidebar"].tap() }
        XCTAssertTrue(ask.waitForExistence(timeout: 15)); ask.tap()
        XCTAssertTrue(app.textFields["assistant.message"].waitForExistence(timeout: 5) || app.textViews["assistant.message"].exists)
        capture("Ask Inkspring on-device assistant", app)
    }

    func testPublishedIsATopLevelTabWithOriginalPostLinks() {
        let app = XCUIApplication()
        app.launchArguments = ["--library-fixture", "--schedule-fixture", "-inkspring.mobile.theme", "warm-paper"]
        app.launchEnvironment["INKSPRING_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        let upcoming = app.staticTexts["A quieter way to draft"]
        XCTAssertTrue(upcoming.waitForExistence(timeout: 10))
        XCTAssertFalse(app.segmentedControls["Schedule view"].exists)
        let publication = app.staticTexts["A quieter way to publish"]
        XCTAssertFalse(publication.exists)
        let publishedTab = app.buttons["Published"].firstMatch
        XCTAssertTrue(publishedTab.isHittable, app.debugDescription)
        capture("Schedule with Published in main navigation", app)
        publishedTab.tap()
        XCTAssertTrue(publication.waitForExistence(timeout: 5))
        XCTAssertFalse(upcoming.exists)
        let link = app.descendants(matching: .any).matching(identifier: "published.open.fixture-published.0").firstMatch
        XCTAssertTrue(link.exists)
        XCTAssertEqual(link.label, "Open on Substack")
        capture("Mobile Published feed and original post link", app)
        app.buttons["Schedule"].firstMatch.tap()
        XCTAssertTrue(upcoming.waitForExistence(timeout: 5))
        XCTAssertFalse(publication.exists)
    }

    func testXArticleReviewsAccountAndPublishesFullTextThroughMac() {
        continueAfterFailure = false
        let app = openExistingWriting("Untitled X article")
        let more = app.buttons["newsletter.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 8)); more.tap()
        app.buttons["Edit Markdown"].firstMatch.tap()
        let editor = app.textViews["newsletter.markdown"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        editor.typeText("# Our mission\n\nWe build real skills with AI and automation.\n\n[Visit our site](https://protomota.com)\n\n" + String(repeating: "Full article text. ", count: 30))
        app.buttons["Done"].firstMatch.tap()
        let review = app.buttons["article.reviewPublish"].firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 10)); XCTAssertTrue(review.isEnabled)
        capture("Full X Article preview and publishing controls", app)
        review.tap()
        let publish = app.buttons["Publish article now"].firstMatch
        XCTAssertTrue(publish.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "@fixture")).firstMatch.exists)
        capture("Review the X account before publishing", app)
        publish.tap()
        let link = app.links["View published X article"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Our mission"].firstMatch.exists)
        XCTAssertFalse(app.buttons["article.reviewPublish"].exists)
        capture("Confirmed X Article link and complete article", app)
        more.tap()
        XCTAssertFalse(app.buttons["Edit Markdown"].exists)
    }

    func testRoundNewIdeaButtonAcrossThemesAndOpensSavedIdea() {
        continueAfterFailure = false
        for theme in ["warm-paper", "graphite", "native-light", "system"] {
            let app = openReview(theme: theme, arguments: ["--idea-first-fixture"])
            let plus = app.buttons["idea.new"].firstMatch
            XCTAssertTrue(plus.waitForExistence(timeout: 8), app.debugDescription)
            XCTAssertEqual(plus.label, "Draft a new idea")
            XCTAssertEqual(plus.frame.width, plus.frame.height, accuracy: 2)
            capture("Round new idea button – " + theme, app)
            XCTAssertTrue(app.buttons["quickX.open"].exists)
            guard theme == "graphite" else {
                app.terminate()
                continue
            }
            plus.tap()
            let title = app.textFields["idea.new.title"].firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
            title.tap()
            title.typeText("Make time for careful work")
            let angle = app.textFields["idea.new.angle"].firstMatch
            title.typeText("\n")
            if !angle.hasFocus { angle.tap() }
            angle.typeText("Share one detail worth someone’s time.")
            let save = app.buttons["Save idea"].firstMatch
            for _ in 0..<3 where !save.isHittable { app.swipeUp() }
            XCTAssertTrue(save.isEnabled, app.debugDescription)
            save.tap()
            let draft = app.buttons["idea.draft.open"].firstMatch
            XCTAssertTrue(draft.waitForExistence(timeout: 10), app.debugDescription)
            let savedTitle = app.buttons["idea.detail.title"].firstMatch
            XCTAssertTrue(savedTitle.exists, app.debugDescription)
            XCTAssertEqual(savedTitle.label, "Make time for careful work")
            capture("Saved idea opens – " + theme, app)
            app.terminate()
        }
    }

    func testGenerateSelectAndSaveIdeaFromBothEntryPoints() {
        continueAfterFailure = false
        let notes = "Private Facebook chats went to the wrong users. Classic Facebook."
        let suggestionTitle = "Private chats sent to the wrong people"

        for fromReview in [false, true] {
            let arguments = ["--idea-first-fixture", "--idea-suggestions-fixture"]
            let app: XCUIApplication
            if fromReview {
                app = openReview(theme: "graphite", arguments: arguments)
                app.buttons["idea.new"].firstMatch.tap()
            } else {
                app = XCUIApplication()
                app.launchArguments = ["--library-fixture", "--ideas-fixture", "-inkspring.mobile.theme", "graphite"] + arguments
                app.launchEnvironment["INKSPRING_FIXTURE_ID"] = UUID().uuidString
                app.launch()
            }

            let title = app.textFields["idea.new.title"].firstMatch
            let angle = app.textFields["idea.new.angle"].firstMatch
            XCTAssertTrue(angle.waitForExistence(timeout: 8), app.debugDescription)
            angle.tap()
            angle.typeText(notes)
            XCTAssertEqual(angle.value as? String, notes, app.debugDescription)
            let generate = app.buttons["Generate ideas"].firstMatch
            for _ in 0..<3 where !generate.isHittable { app.swipeUp() }
            XCTAssertTrue(generate.isEnabled && generate.isHittable, app.debugDescription)
            generate.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.5)).tap()

            let result = app.buttons.matching(identifier: "idea.suggestion")
                .matching(NSPredicate(format: "label CONTAINS %@", suggestionTitle)).firstMatch
            for _ in 0..<3 where !result.isHittable { app.swipeUp() }
            XCTAssertTrue(result.waitForExistence(timeout: 5) && result.isHittable, app.debugDescription)
            XCTAssertTrue(result.label.contains(notes))
            capture("Generated suggestions – " + (fromReview ? "composer" : "New ideas"), app)
            result.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()

            XCTAssertTrue(title.isHittable, app.debugDescription)
            XCTAssertEqual(title.value as? String, suggestionTitle)
            XCTAssertEqual(angle.value as? String, notes)
            XCTAssertFalse(result.exists)
            capture("Selected idea is ready to edit – " + (fromReview ? "composer" : "New ideas"), app)
            let save = app.buttons["Save idea"].firstMatch
            XCTAssertTrue(save.isEnabled && save.isHittable, app.debugDescription)
            save.tap()

            let savedTitle = app.buttons["idea.detail.title"].firstMatch
            XCTAssertTrue(savedTitle.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertEqual(savedTitle.label, suggestionTitle)
            XCTAssertTrue(app.buttons[notes].firstMatch.exists, app.debugDescription)
            capture("Saved idea keeps the original point – " + (fromReview ? "composer" : "New ideas"), app)
            app.terminate()
        }
    }

    func testQuickXProofreadReviewAndPublishConfirmation() {
        continueAfterFailure = false
        let app = openReview(theme: "graphite", arguments: ["--quick-x-fixture"])
        let quick = app.buttons["quickX.open"].firstMatch
        XCTAssertTrue(quick.waitForExistence(timeout: 8))
        quick.tap()
        let field = app.descendants(matching: .any)["quickX.text"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Share teh work.")
        let hide = app.keyboards.buttons["Hide keyboard"].firstMatch
        if hide.isHittable { hide.tap() }
        let proofread = app.buttons["proofread.start"].firstMatch
        XCTAssertTrue(proofread.isHittable && proofread.isEnabled, app.debugDescription)
        proofread.tap()
        let apply = app.buttons["proofread.apply"].firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Before: teh"].exists)
        XCTAssertTrue(app.staticTexts["After: the"].exists)
        capture("Review Apple Intelligence proofreading suggestions", app)
        apply.tap()
        XCTAssertTrue((field.value as? String ?? "").contains("Share the work."))
        app.buttons["quickX.review"].firstMatch.tap()
        let publish = app.buttons["Publish to X"].firstMatch
        XCTAssertTrue(publish.waitForExistence(timeout: 5), app.debugDescription)
        capture("Quick X confirmation includes account and final copy", app)
        publish.tap()
        let result = app.descendants(matching: .any)["quickX.published"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10), app.debugDescription)
    }

    private func openReview(theme: String, arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--library-fixture", "-inkspring.mobile.theme", theme] + arguments
        app.launchEnvironment["INKSPRING_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        let review = app.buttons["Review"].firstMatch
        if !review.waitForExistence(timeout: 3), app.buttons["ToggleSidebar"].exists { app.buttons["ToggleSidebar"].tap() }
        XCTAssertTrue(review.waitForExistence(timeout: 8))
        review.tap()
        return app
    }

    private func openExistingWriting(_ title: String, arguments: [String] = []) -> XCUIApplication {
        let app = openReview(theme: "warm-paper", arguments: ["--script-fixture", "--existing-writing-fixture"] + arguments)
        let item = app.staticTexts[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 8), app.debugDescription)
        item.tap()
        return app
    }

    func testNewsletterCreationAndAskAIApplyBriefWithoutLeavingEditor() {
        continueAfterFailure = false
        let app = openExistingWriting("Untitled newsletter", arguments: ["--history-fixture"])
        let more = app.buttons["newsletter.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 8)); more.tap()
        app.buttons["Ask AI…"].firstMatch.tap()
        let addRequest = app.buttons["writing.addRevisionRequest"].firstMatch
        XCTAssertTrue(addRequest.waitForExistence(timeout: 8))
        addRequest.tap()
        let prompt = app.textFields["writing.prompt"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 8), app.debugDescription)
        prompt.tap(); prompt.typeText("Write a quick brief about local AI models.")
        capture("Ask the Mac writing agent for a brief", app)
        let send = app.buttons["writing.send"].firstMatch
        XCTAssertTrue(send.isEnabled); send.tap()
        let reply = app.staticTexts["writing.reply"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertTrue(reply.label.contains("Wrote a short brief"))
        XCTAssertTrue(app.staticTexts["Acted on"].firstMatch.exists)
        capture("Saved writing request and applied response", app)
        app.buttons["writing.close"].tap()
        let editor = app.textViews["newsletter.markdown"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String ?? "").contains("# Local AI models"))
        let title = app.textFields["script.title"].firstMatch
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 19) + "Local models newsletter")
        editor.tap()
        editor.typeText("\n\nAn author addition.\n\n")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Local AI models"].firstMatch.waitForExistence(timeout: 8))
        capture("Newsletter brief rendered with author changes", app)
        more.tap(); app.buttons["Edit Markdown"].firstMatch.tap()
        XCTAssertTrue((editor.value as? String ?? "").contains("An author addition."))
        XCTAssertEqual(title.value as? String, "Local models newsletter")
        app.buttons["writing.tools"].firstMatch.tap()
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        capture("Writing request history survives reopening", app)
    }

    func testFullHeightNewsletterEditingKeepsCursorAndFindsText() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--library-fixture", "--newsletter-fixture", "--history-fixture", "-inkspring.mobile.theme", "warm-paper"]
        app.launchEnvironment["INKSPRING_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        let row = app.staticTexts["A better first paragraph"].firstMatch
        if !row.waitForExistence(timeout: 3), app.buttons["ToggleSidebar"].exists { app.buttons["ToggleSidebar"].tap() }
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        app.buttons["newsletter.more"].firstMatch.tap()
        app.buttons["Edit Markdown"].firstMatch.tap()
        let editor = app.textViews["newsletter.markdown"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        XCTAssertGreaterThan(editor.frame.height, 200)
        XCTAssertFalse(app.buttons["history.open"].exists)
        editor.typeText("ANCHOR")
        Thread.sleep(forTimeInterval: 2)
        editor.typeText(" CONTINUED\n\nA real new paragraph.\n")
        XCTAssertTrue((editor.value as? String ?? "").contains("ANCHOR CONTINUED\n\nA real new paragraph.\n"))
        app.buttons["editor.find"].firstMatch.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        search.typeText("paragraph")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "newsletter-find"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testYouTubeScriptsCreateEditAndReopenWithoutPublishing() {
        continueAfterFailure = false
        let app = openExistingWriting("Untitled YouTube script", arguments: ["--history-fixture"])
        let more = app.buttons["newsletter.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 8)); more.tap()
        app.buttons["Edit Markdown"].firstMatch.tap()
        let editor = app.textViews["newsletter.markdown"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let title = app.textFields["script.title"].firstMatch
        XCTAssertTrue(title.exists)
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 23) + "Hallway brief")
        editor.tap()
        editor.typeText("We build useful skills.\n\nWe protect our signal.")
        Thread.sleep(forTimeInterval: 2)
        editor.typeText("\n\nWe keep learning.")
        XCTAssertTrue((editor.value as? String ?? "").contains("We protect our signal.\n\nWe keep learning."))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["We build useful skills."].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Schedule post…"].exists)
        XCTAssertFalse(app.buttons["Publish"].exists)
        more.tap(); app.buttons["Edit Markdown"].firstMatch.tap()
        XCTAssertTrue((editor.value as? String ?? "").contains("We keep learning."))
        editor.typeText("\n\nA second editing session.")
        app.buttons["Done"].firstMatch.tap()
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "youtube-script-preview"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testXArticleIsClearlyLabeledAndEditsAsLongForm() {
        continueAfterFailure = false
        let app = openExistingWriting("Untitled X article", arguments: ["--history-fixture"])
        XCTAssertTrue(app.navigationBars["X article"].waitForExistence(timeout: 8))
        let more = app.buttons["newsletter.more"].firstMatch
        more.tap(); app.buttons["Edit Markdown"].firstMatch.tap()
        let editor = app.textViews["newsletter.markdown"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        editor.typeText("# Our mission\n\nWe build real skills with AI and automation.\n\n" + String(repeating: "We protect our signal. ", count: 20))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Our mission"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["X article"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Schedule post…"].exists)
        capture("X article badge and full long-form preview", app)
    }

    func testNewsletterHistoryRestoresEarlierMarkdown() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--library-fixture", "--newsletter-fixture", "--history-fixture", "-inkspring.mobile.theme", "warm-paper"]
        app.launchEnvironment["INKSPRING_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        let newsletter = app.staticTexts["A better first paragraph"].firstMatch
        if !newsletter.waitForExistence(timeout: 3) {
            let platforms = app.buttons["review.platformFilter"].firstMatch
            if !platforms.exists, app.buttons["ToggleSidebar"].exists { app.buttons["ToggleSidebar"].tap() }
            XCTAssertTrue(platforms.waitForExistence(timeout: 5)); platforms.tap()
            let substack = app.buttons["Substack"].firstMatch
            XCTAssertTrue(substack.waitForExistence(timeout: 5)); substack.tap()
        }
        XCTAssertTrue(newsletter.waitForExistence(timeout: 10)); newsletter.tap()
        let more = app.buttons["newsletter.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
        app.buttons["Edit Markdown"].firstMatch.tap()
        let editor = app.textViews["newsletter.markdown"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        editor.typeText("\n\n[Revision link](https://example.com/history)\n\n")
        XCTAssertTrue((editor.value as? String ?? "").contains("[Revision link](https://example.com/history)"))
        app.buttons["Done"].firstMatch.tap()
        let history = app.buttons["history.open"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5)); history.tap()
        let older = app.buttons["history.version.1"].firstMatch
        XCTAssertTrue(older.waitForExistence(timeout: 10))
        capture("Newsletter saves retained in revision history", app)
        older.tap()
        let restore = app.buttons["history.restore"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        for _ in 0..<5 where !restore.isHittable { app.swipeUp() }
        XCTAssertTrue(restore.isEnabled)
        restore.tap()
        if app.buttons["history.version.0"].waitForExistence(timeout: 2) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap(); app.buttons["Edit Markdown"].firstMatch.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse((editor.value as? String ?? "").contains("Revision link"))
        capture("Earlier newsletter Markdown restored inline", app)
    }

    func testHistoryRestoresAnOlderSaveAndKeepsTheNewerOne() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--library-fixture", "--x-thread-fixture", "--history-fixture", "-inkspring.mobile.theme", "warm-paper"]
        app.launchEnvironment["INKSPRING_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        let title = app.staticTexts["I started a cult"].firstMatch
        if !title.waitForExistence(timeout: 3), app.buttons["ToggleSidebar"].exists { app.buttons["ToggleSidebar"].tap() }
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.tap()
        app.buttons["x.reply.0"].firstMatch.tap()
        let opening = app.buttons["x.editPost.0"].firstMatch
        XCTAssertTrue(opening.waitForExistence(timeout: 5)); opening.tap()
        let editor = app.textViews["x.postText.0"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: editor.frame.width - 12, dy: 15)).tap()
        editor.typeText("\n\nA later revision.")
        XCTAssertEqual(editor.value as? String, "We build useful tools and give them away.\n\nA later revision.")
        app.buttons["x.backToThread"].tap()
        app.buttons["Done"].firstMatch.tap()
        let history = app.buttons["history.open"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5)); history.tap()
        let older = app.buttons["history.version.1"].firstMatch
        XCTAssertTrue(older.waitForExistence(timeout: 10))
        capture("History retains both saves with timestamps", app)
        older.tap()
        let restore = app.buttons["history.restore"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        for _ in 0..<5 where !restore.isHittable { app.swipeUp() }
        XCTAssertTrue(restore.isEnabled)
        capture("Inspect the earlier version before restoring", app)
        restore.tap()
        if app.buttons["history.version.0"].waitForExistence(timeout: 2) {
            capture("Restoring adds a version and keeps later saves", app)
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        let restored = app.buttons["x.reply.0"].firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertFalse(restored.label.contains("A later revision."))
        capture("Earlier text restored in the draft", app)
        history.tap()
        let newer = app.buttons["history.version.1"].firstMatch
        XCTAssertTrue(newer.waitForExistence(timeout: 5))
        XCTAssertTrue(newer.label.contains("A later revision."))
    }

    func testReturnCreatesParagraphsAndKeepsTwoSeparateReplies() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--library-fixture", "--x-thread-fixture", "-inkspring.mobile.theme", "warm-paper"]
        app.launchEnvironment["INKSPRING_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        let opening = app.buttons["x.reply.0"].firstMatch
        if !opening.waitForExistence(timeout: 3) {
            let draft = app.staticTexts["I started a cult"].firstMatch
            if !draft.exists, app.buttons["ToggleSidebar"].exists { app.buttons["ToggleSidebar"].tap() }
            XCTAssertTrue(draft.waitForExistence(timeout: 10)); draft.tap()
        }
        XCTAssertTrue(opening.waitForExistence(timeout: 10)); opening.tap()
        let openEditor = app.buttons["x.editPost.0"].firstMatch
        XCTAssertTrue(openEditor.waitForExistence(timeout: 10)); openEditor.tap()
        let editor = app.textViews["x.postText.0"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: editor.frame.width - 12, dy: 15)).tap()
        // Actual Return keys at the end and between words, not a final fixture assignment.
        editor.typeText("\n")
        XCTAssertEqual(editor.value as? String, "We build useful tools and give them away.\n")
        editor.typeText("\nA second paragraph.")
        let expected = "We build useful tools and give them away.\n\nA second paragraph."
        XCTAssertEqual(editor.value as? String, expected)
        editor.typeText("\nThird line.")
        let savedText = expected + "\nThird line."
        XCTAssertEqual(editor.value as? String, savedText)
        capture("Return preserves blank lines and subsequent typing", app)
        app.buttons["x.backToThread"].tap()
        let secondReply = app.buttons["x.editPost.2"].firstMatch
        for _ in 0..<4 where !secondReply.isHittable { app.swipeUp() }
        XCTAssertTrue(secondReply.waitForExistence(timeout: 5))
        capture("Newsletter and Discord remain two follow-up replies", app)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["x.reply.0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["x.reply.0"].label.contains("A second paragraph."))
        XCTAssertTrue(app.buttons["x.reply.2"].exists)
        capture("Saved draft retains paragraphs and three parts", app)
        app.terminate()
        app.launch()
        let reopened = app.buttons["x.reply.0"].firstMatch
        if !reopened.waitForExistence(timeout: 3) { app.staticTexts["I started a cult"].firstMatch.tap() }
        XCTAssertTrue(reopened.waitForExistence(timeout: 10))
        XCTAssertTrue(reopened.label.contains("A second paragraph."))
        reopened.tap()
        XCTAssertTrue(openEditor.waitForExistence(timeout: 10)); openEditor.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, savedText)
        capture("Relaunch restores exact paragraph breaks", app)
    }

    func testLinkedReplyOpensTheEditableXArticle() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--library-fixture", "--x-thread-fixture", "--article-link-fixture"]
        app.launchEnvironment["INKSPRING_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        let draft = app.staticTexts["I started a cult"].firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.tap()
        let article = app.buttons["X article · The manifesto"].firstMatch
        for _ in 0..<4 where !article.isHittable { app.swipeUp() }
        XCTAssertTrue(article.isHittable)
        capture("Thread with linked X article", app)
        article.tap()
        XCTAssertTrue(app.navigationBars["X article"].waitForExistence(timeout: 6))
        app.buttons["newsletter.more"].firstMatch.tap()
        app.buttons["Edit Markdown"].firstMatch.tap()
        XCTAssertTrue(app.textViews["newsletter.markdown"].firstMatch.waitForExistence(timeout: 6))
        capture("Linked article open for editing", app)
    }

    func testFirstLaunchSavesAnIdeaBeforeMacSetup() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--unpaired-fixture"]
        app.launchEnvironment["INKSPRING_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.staticTexts["Welcome to Inkspring"].waitForExistence(timeout: 10))
        capture("01 Welcome", app)
        let proceed = app.buttons["welcome.primary"]
        if !proceed.isHittable { app.swipeUp() }
        proceed.tap()
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        capture("02 Capture an idea", app)
        title.tap()
        title.typeText("A field guide to native apps")
        let notes = app.descendants(matching: .any).matching(identifier: "Angle or notes").firstMatch
        notes.tap()
        notes.typeText("Compare how the same draft feels on iPhone and Mac.")
        app.buttons["Save idea"].tap()
        XCTAssertTrue(app.staticTexts["Saved on this device"].firstMatch.waitForExistence(timeout: 6))
        capture("03 Saved on this device", app)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Your writing workspace"].waitForExistence(timeout: 8))
        capture("04 Workspace", app)
        app.buttons["Mac setup guide"].tap()
        XCTAssertTrue(app.staticTexts["Welcome to Inkspring"].waitForExistence(timeout: 5))
        let done = app.buttons["welcome.primary"]
        if !done.isHittable { app.swipeUp() }
        done.tap()
        app.buttons["Write an idea"].tap()
        XCTAssertTrue(app.staticTexts["A field guide to native apps"].firstMatch.waitForExistence(timeout: 5))
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
