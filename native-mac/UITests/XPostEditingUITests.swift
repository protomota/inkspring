import XCTest

final class WalkthroughTests: XCTestCase {
    func testPlanPreviewEditSaveAndAssistant() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--library-fixture", "--newsletter-fixture", "-inkspring.mobile.theme", "warm-paper"]
        app.launchEnvironment["INKSPRING_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        let open = app.buttons["plan.open"].firstMatch
        if !open.waitForExistence(timeout: 2) {
            let draft = app.staticTexts["A quieter way to draft"].firstMatch
            if !draft.exists, app.buttons["ToggleSidebar"].exists { app.buttons["ToggleSidebar"].tap() }
            XCTAssertTrue(draft.waitForExistence(timeout: 10)); draft.tap()
        }
        for _ in 0..<4 where !open.isHittable { app.swipeUp() }
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        if open.isHittable { open.tap() }
        else { open.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let markdown = app.buttons["Markdown"].firstMatch
        XCTAssertTrue(markdown.waitForExistence(timeout: 5)); markdown.tap()
        let editor = app.textViews["plan.markdown"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        editor.typeText("# Launch plan\n\n- [ ] Check the links\n- [ ] Review the opening\n\n[Inkspring](https://inkspring.ai/)")
        capture("Inline Plan Markdown editor", app)
        let save = app.buttons["plan.save"].firstMatch
        for _ in 0..<5 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable); save.tap()
        XCTAssertTrue(app.staticTexts["Plan saved on this device. Waiting for your Mac to apply it."].waitForExistence(timeout: 5))
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

    func testXArticleReviewsAccountAndPublishesFullTextThroughMac() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--library-fixture", "--script-fixture", "-inkspring.mobile.theme", "warm-paper"]
        app.launchEnvironment["INKSPRING_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        let menu = app.buttons["writing.new"].firstMatch
        if !menu.waitForExistence(timeout: 3), app.buttons["ToggleSidebar"].exists { app.buttons["ToggleSidebar"].tap() }
        XCTAssertTrue(menu.waitForExistence(timeout: 8)); menu.tap()
        app.buttons["New X article"].firstMatch.tap()
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

    func testLongFormMenuGroupsNewsletterArticleAndScript() {
        for theme in ["warm-paper", "graphite"] {
            let app = XCUIApplication()
            app.launchArguments = ["--library-fixture", "--script-fixture", "-inkspring.mobile.theme", theme]
            app.launchEnvironment["INKSPRING_FIXTURE_ID"] = UUID().uuidString
            app.launch()
            let menu = app.buttons["writing.new"].firstMatch
            if !menu.waitForExistence(timeout: 3), app.buttons["ToggleSidebar"].exists { app.buttons["ToggleSidebar"].tap() }
            XCTAssertTrue(menu.waitForExistence(timeout: 8)); menu.tap()
            for name in ["New Substack newsletter", "New X article", "New YouTube script", "New X post or thread"] {
                XCTAssertTrue(app.buttons[name].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
            }
            capture("Grouped long-form menu \(theme)", app)
            app.terminate()
        }
    }

    func testNewsletterCreationAndAskAIApplyBriefWithoutLeavingEditor() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--library-fixture", "--script-fixture", "--history-fixture", "-inkspring.mobile.theme", "warm-paper"]
        app.launchEnvironment["INKSPRING_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        let menu = app.buttons["writing.new"].firstMatch
        if !menu.waitForExistence(timeout: 3), app.buttons["ToggleSidebar"].exists { app.buttons["ToggleSidebar"].tap() }
        XCTAssertTrue(menu.waitForExistence(timeout: 8)); menu.tap()
        app.buttons["New Substack newsletter"].firstMatch.tap()
        let more = app.buttons["newsletter.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 8)); more.tap()
        app.buttons["Ask AI…"].firstMatch.tap()
        let prompt = app.textFields["writing.prompt"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 8), app.debugDescription)
        prompt.tap(); prompt.typeText("Write a quick brief about local AI models.")
        capture("Ask the Mac writing agent for a brief", app)
        let send = app.buttons["writing.send"].firstMatch
        XCTAssertTrue(send.isEnabled); send.tap()
        let reply = app.staticTexts["writing.reply"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertTrue(reply.label.contains("Wrote a short brief"))
        XCTAssertTrue(app.staticTexts["Applied"].firstMatch.exists)
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
        let app = XCUIApplication()
        app.launchArguments = ["--library-fixture", "--script-fixture", "--history-fixture", "-inkspring.mobile.theme", "warm-paper"]
        app.launchEnvironment["INKSPRING_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        let newMenu = app.buttons["writing.new"].firstMatch
        if !newMenu.waitForExistence(timeout: 3), app.buttons["ToggleSidebar"].exists { app.buttons["ToggleSidebar"].tap() }
        XCTAssertTrue(newMenu.waitForExistence(timeout: 8)); newMenu.tap()
        let newScript = app.buttons["New YouTube script"].firstMatch
        if !newScript.waitForExistence(timeout: 3), app.buttons["ToggleSidebar"].exists { app.buttons["ToggleSidebar"].tap() }
        XCTAssertTrue(newScript.waitForExistence(timeout: 8)); newScript.tap()
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
        let app = XCUIApplication()
        app.launchArguments = ["--library-fixture", "--script-fixture", "--history-fixture", "-inkspring.mobile.theme", "warm-paper"]
        app.launchEnvironment["INKSPRING_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        let newMenu = app.buttons["writing.new"].firstMatch
        if !newMenu.waitForExistence(timeout: 3), app.buttons["ToggleSidebar"].exists { app.buttons["ToggleSidebar"].tap() }
        XCTAssertTrue(newMenu.waitForExistence(timeout: 8)); newMenu.tap()
        app.buttons["New X article"].firstMatch.tap()
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

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
