import XCTest

@MainActor final class SwipeAndSketchUITests: XCTestCase {
    func testFilesProjectSaveAsCancelAndNewProject() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-documents", "--reset-document-tests", "--select-document-sketch"]
        app.launch()
        let title = app.staticTexts["project.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertTrue(title.label.hasPrefix("Document Test "))
        let originalName = title.label
        XCTAssertTrue(app.staticTexts["2 sketches · 1 solid"].exists)
        app.buttons["dimension.width"].tap()
        app.buttons["keypad.7"].tap(); app.buttons["keypad.5"].tap(); app.buttons["keypad.confirm"].tap()
        app.buttons["Project menu"].tap(); app.buttons["project.save"].tap()
        app.buttons["Project menu"].tap(); app.buttons["project.saveAs"].tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        let picker = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        picker.name = "Native Files Save As picker"; picker.lifetime = .keepAlways; add(picker)
        cancel.tap()
        XCTAssertEqual(title.label, originalName)
        XCTAssertEqual(app.buttons["dimension.width"].value as? String, "75")
        app.buttons["Project menu"].tap(); app.buttons["project.new"].tap()
        // New Project opens the template gallery first.
        let blank = app.buttons["templates.blank"]
        XCTAssertTrue(blank.waitForExistence(timeout: 10)); blank.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        let name = app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        let previous = name.value as? String ?? ""
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + originalName + " Empty")
        if app.buttons["done"].exists { app.buttons["done"].tap() }
        let create = app.buttons["DOCPicker.actionButton"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", originalName + " Empty"), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 15), .completed)
        XCTAssertTrue(app.staticTexts["0 sketches · 0 solids"].exists)
        XCTAssertFalse(app.buttons["Undo"].isEnabled)
        app.buttons["project.home"].tap()
        let original = app.buttons["home.recent.\(originalName)"]
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        let home = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        home.name = "Home with recent projects"; home.lifetime = .keepAlways; add(home)
        XCTAssertEqual(app.buttons.matching(identifier: "home.recent.\(originalName)").count, 1, "Opening the project must not leave a same-named duplicate to reopen by mistake")
        XCTAssertTrue(app.buttons["home.recent.\(originalName) Empty"].exists)
        original.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.label, originalName)
        XCTAssertTrue(app.staticTexts["2 sketches · 1 solid"].exists)
        XCTAssertEqual(app.buttons["dimension.width"].value as? String, "75")
    }
    func testNewProjectFromATemplate() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-documents", "--reset-document-tests"]
        app.launch()
        let title = app.staticTexts["project.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        app.buttons["Project menu"].tap(); app.buttons["project.new"].tap()
        let bin = app.buttons["templates.gridfinity.bin"]
        XCTAssertTrue(bin.waitForExistence(timeout: 10))
        // Card pictures ship in the asset catalog, so they are there as soon as the gallery is.
        let gallery = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        gallery.name = "New Project template gallery"; gallery.lifetime = .keepAlways; add(gallery)
        app.swipeUp()
        let more = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        more.name = "Template gallery scrolled"; more.lifetime = .keepAlways; add(more)
        app.swipeDown()
        bin.tap()
        let create = app.buttons["templates.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: create)], timeout: 20), .completed)
        // One more grid unit across.
        app.buttons["templates.parameter.columns-Increment"].tap()
        sleep(1)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: create)], timeout: 20), .completed)
        let setup = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        setup.name = "Gridfinity bin set up 3 x 1"; setup.lifetime = .keepAlways; add(setup)
        create.tap()
        let save = app.buttons["DOCPicker.actionButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields.firstMatch.value as? String, "Gridfinity Bin 3×1×6")
        save.tap()
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Gridfinity Bin 3×1×6"), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 20), .completed)
        XCTAssertTrue(app.staticTexts["0 sketches · 1 solid"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Undo"].exists)
        sleep(2)
        let made = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        made.name = "Project made from the Gridfinity bin template"; made.lifetime = .keepAlways; add(made)

        // An electronics template, from Home's Start Something this time; going back leaves nothing behind.
        app.buttons["project.home"].tap()
        let electronics = app.buttons["home.category.electronics"]
        XCTAssertTrue(electronics.waitForExistence(timeout: 10)); electronics.tap()
        let pi = app.buttons["templates.electronics.pi-case"]
        XCTAssertTrue(pi.waitForExistence(timeout: 10)); pi.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: create)], timeout: 20), .completed)
        let piShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        piShot.name = "Raspberry Pi case set up"; piShot.lifetime = .keepAlways; add(piShot)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(pi.waitForExistence(timeout: 10))
        app.buttons["home.section.home"].tap()
        XCTAssertTrue(electronics.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["home.recent.Gridfinity Bin 3×1×6"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.recent.Raspberry'")).firstMatch.exists)
    }
    func testTemplatesWaitForUnlockWhenViewOnly() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-documents", "--reset-document-tests", "--license-ended"]
        app.launch()
        XCTAssertTrue(app.staticTexts["project.title"].waitForExistence(timeout: 20))
        // The trial offer may open by itself; close it first.
        if app.buttons["purchases.done"].waitForExistence(timeout: 3) { app.buttons["purchases.done"].tap() }
        app.buttons["Project menu"].tap(); app.buttons["project.new"].tap()
        let bin = app.buttons["templates.gridfinity.bin"]
        XCTAssertTrue(bin.waitForExistence(timeout: 10))
        bin.tap()
        // A template is a model made for you: view-only sees Purchases instead of a new project.
        let create = app.buttons["templates.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: create)], timeout: 20), .completed)
        XCTAssertEqual(create.label, "See Purchases")
        create.tap()
        XCTAssertTrue(app.staticTexts["purchases.status"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["DOCPicker.actionButton"].exists)
    }

    func app(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + arguments
        app.launch()
        return app
    }
    func testFilesSaveAsCreatesIndependentCopyAndBrowserCreatesNamedProject() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-documents", "--reset-document-tests", "--select-document-sketch"]
        app.launch()
        let title = app.staticTexts["project.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        let originalName = title.label
        app.buttons["Project menu"].tap()
        let menu = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        menu.name = "Project menu with Save Save As New and Open"; menu.lifetime = .keepAlways; add(menu)
        app.buttons["project.saveAs"].tap()
        XCTAssertTrue(app.buttons["DOCPicker.actionButton"].waitForExistence(timeout: 10))
        app.buttons["DOCPicker.actionButton"].tap()
        let copyOpened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", originalName + " Copy"), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [copyOpened], timeout: 15), .completed)
        app.buttons["dimension.width"].tap()
        app.buttons["keypad.9"].tap(); app.buttons["keypad.0"].tap(); app.buttons["keypad.confirm"].tap()
        app.buttons["Project menu"].tap(); app.buttons["project.new"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertEqual(title.label, originalName + " Copy")
        XCTAssertEqual(app.buttons["dimension.width"].value as? String, "90")
        app.buttons["project.home"].tap()
        let original = app.buttons["home.recent.\(originalName)"]
        XCTAssertTrue(original.waitForExistence(timeout: 10)); original.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.label, originalName)
        XCTAssertEqual(app.buttons["dimension.width"].value as? String, "60")
        app.buttons["project.home"].tap()
        let copy = app.buttons["home.recent.\(originalName) Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10)); copy.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["dimension.width"].value as? String, "90")
        app.buttons["project.home"].tap()
        // Files keeps the system browser, with its own + for a new project.
        let files = app.buttons["home.section.files"]
        XCTAssertTrue(files.waitForExistence(timeout: 10)); files.tap()
        let create = app.buttons["FullDocumentManagerViewControllerNavigationBarCreateButtonIdentifier"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        let browser = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        browser.name = "Projects in the native Files browser inside Home"; browser.lifetime = .keepAlways; add(browser)
        create.tap()
        let blank = app.buttons["templates.blank"]
        XCTAssertTrue(blank.waitForExistence(timeout: 10)); blank.tap()
        let name = app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap()
        let previous = name.value as? String ?? ""
        let newName = originalName + " Browser New"
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + newName)
        if app.buttons["done"].exists { app.buttons["done"].tap() }
        app.buttons["DOCPicker.actionButton"].tap()
        let namedProject = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", newName), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [namedProject], timeout: 15), .completed)
        XCTAssertTrue(app.staticTexts["0 sketches · 0 solids"].exists)
        XCTAssertFalse(app.buttons["Undo"].isEnabled)
    }
    func testShadedSolidWithVisibleEdgesAndOrbit() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = app(arguments: ["--ui-testing-solid"])
        XCTAssertTrue(app.staticTexts["1 sketch · 1 solid"].waitForExistence(timeout: 10))
        let canvas = app.otherElements["modeling.canvas"]
        canvas.pinch(withScale: 1.5, velocity: 1)
        let initial = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        initial.name = "Gray solid with shaded faces and visible borders"
        initial.lifetime = .keepAlways
        add(initial)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.55))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.58)))
        XCTAssertTrue(app.staticTexts["1 sketch · 1 solid"].exists)
        let rotated = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        rotated.name = "Shaded solid after finger orbit"
        rotated.lifetime = .keepAlways
        add(rotated)
    }
    func testViewCubeFacesFollowOrbitAndDoubleTapResets3DView() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = app(arguments: ["--ui-testing-solid"])
        let canvas = app.otherElements["modeling.canvas"]
        func face(_ name: String) -> XCUIElement { app.buttons["view.cube.\(name)"] }
        func expectFace(_ name: String) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", name.capitalized), object: face(name))
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 4), .completed)
        }
        func reset(from name: String) {
            face(name).doubleTap()
            XCTAssertTrue(face("top").waitForExistence(timeout: 4))
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '3D'"), object: face("top"))
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 4), .completed)
            XCTAssertTrue(face("front").exists); XCTAssertTrue(face("right").exists)
        }
        XCTAssertTrue(face("front").waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Sketch plane"].exists)
        for name in ["top", "front", "right"] { XCTAssertFalse(app.buttons["plane.\(name)"].exists) }
        for name in ["front", "top", "right"] {
            face(name).tap(); expectFace(name)
            reset(from: name)
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Rotating orientation cube in default 3D view"
        screenshot.lifetime = .keepAlways; add(screenshot)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.27, dy: 0.6)))
        XCTAssertTrue(face("back").waitForExistence(timeout: 4))
        XCTAssertTrue(face("left").exists)
        let rotated = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        rotated.name = "View cube synchronized after orbit"
        rotated.lifetime = .keepAlways; add(rotated)
        face("back").tap(); expectFace("back"); reset(from: "back")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        XCTAssertTrue(face("bottom").waitForExistence(timeout: 4))
        face("bottom").tap(); expectFace("bottom"); reset(from: "bottom")
        XCTAssertTrue(app.staticTexts["1 sketch · 1 solid"].exists)
    }
    func testItemsAloneTopLeftAndBrandControls() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = app()
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        // Items stands alone at the top left: no brand badge, and no project label beside it.
        let items = app.buttons["items.toggle"]
        XCTAssertTrue(items.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["brand.badge"].exists, "No S badge on the canvas")
        XCTAssertLessThan(items.frame.minX, 60, "Items sits at the left edge")
        let dock = app.otherElements["dock"]
        XCTAssertTrue(dock.exists)
        for label in app.staticTexts.matching(identifier: "Project").allElementsBoundByIndex {
            XCTAssertTrue(dock.frame.contains(label.frame), "The only Project text is the dock's Project tool")
        }
        XCTAssertFalse(app.staticTexts["Modeling"].exists)
        XCTAssertFalse(app.buttons["tool.select"].exists, "No Select tool: with nothing chosen, taps select")
        shot("Brand workspace")
        app.buttons["dimension.width"].tap()
        XCTAssertTrue(app.buttons["keypad.confirm"].waitForExistence(timeout: 5))
        shot("Brand keypad")
        app.buttons["keypad.cancel"].tap()
        app.buttons["Project menu"].tap()
        XCTAssertTrue(app.buttons["Controls"].waitForExistence(timeout: 5))
        shot("Brand project menu")
        // Dismiss the menu (a finger tap on the canvas never creates or selects geometry).
        app.otherElements["modeling.canvas"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertTrue(app.buttons["selection.extrude"].waitForExistence(timeout: 5))
        app.buttons["selection.extrude"].tap()
        XCTAssertTrue(app.buttons["extrusion.confirm"].waitForExistence(timeout: 5))
        shot("Brand extrusion actions")
        app.buttons["extrusion.cancel"].tap()
        XCTAssertFalse(app.buttons["extrusion.confirm"].exists)
    }

    func testProjectToolPicksFromItemsAndShowsItsSteps() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = app(arguments: ["--ui-testing-solid"])
        let toggle = app.buttons["items.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.tap()
        let body = app.buttons["item.Body 01"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        body.tap()
        // The selected solid becomes the item; the surface comes next.
        app.buttons["tool.project"].tap()
        XCTAssertFalse(app.otherElements["dock"].exists, "Project's own controls replace the dock")
        let step = app.segmentedControls["projection.step"]
        XCTAssertTrue(step.waitForExistence(timeout: 5))
        XCTAssertTrue(step.buttons["Geometry · 1"].exists)
        XCTAssertTrue(step.buttons["Target Plane"].isSelected)
        XCTAssertTrue(body.isSelected, "The picked solid is highlighted in Items")
        XCTAssertFalse(app.buttons["projection.confirm"].isEnabled, "No surface yet")
        // Its own sketch as the surface: the outline is already there, so nothing to add.
        app.buttons["item.Sketch 01"].tap()
        XCTAssertTrue(app.staticTexts["Nothing new to project: seen from this surface, the items lie edge-on or are already there."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["projection.confirm"].isEnabled)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Project tool"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["projection.cancel"].tap()
        XCTAssertTrue(step.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["dock"].waitForExistence(timeout: 5), "The dock is back")
        XCTAssertTrue(app.staticTexts["1 sketch · 1 solid"].exists, "Cancel changes nothing")
    }
    func testSplitBodyStartsFromASelectedSolid() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = app(arguments: ["--ui-testing-solid"])
        let toggle = app.buttons["items.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.tap()
        let body = app.buttons["item.Body 01"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        body.tap()
        let split = app.buttons["selection.split"]
        XCTAssertTrue(split.waitForExistence(timeout: 5), "A selected solid offers Split Body")
        XCTAssertFalse(app.buttons["selection.combine"].exists, "One solid has nothing to combine with")
        split.tap()
        XCTAssertFalse(app.otherElements["dock"].exists, "Split's own controls replace the dock")
        let step = app.segmentedControls["split.step"]
        XCTAssertTrue(step.waitForExistence(timeout: 5))
        XCTAssertTrue(step.buttons["Bodies to Split · 1"].exists)
        XCTAssertTrue(step.buttons["Splitting Tools"].isSelected, "Next, what to split it with")
        XCTAssertTrue(app.descendants(matching: .any)["split.keepOriginals"].exists)
        XCTAssertFalse(app.buttons["split.confirm"].isEnabled, "Nothing to split with yet")
        XCTAssertTrue(body.isSelected, "The solid to split is highlighted in Items")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Split Body tool"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["split.cancel"].tap()
        XCTAssertTrue(step.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 sketch · 1 solid"].exists, "Cancel changes nothing")
    }
    func testUnionPicksSolidsFromItems() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = app(arguments: ["--ui-testing-solid"])
        let toggle = app.buttons["items.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.tap()
        app.buttons["tool.combine"].tap()
        XCTAssertTrue(app.buttons["tool.union"].waitForExistence(timeout: 5))
        app.buttons["tool.union"].tap()
        XCTAssertFalse(app.otherElements["group.menu"].exists, "Choosing a tool closes the pop-up")
        XCTAssertTrue(app.staticTexts["Bodies"].waitForExistence(timeout: 5))
        let body = app.buttons["item.Body 01"]
        body.tap()
        XCTAssertTrue(app.staticTexts["Bodies · 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(body.isSelected, "The picked solid is highlighted in Items")
        XCTAssertTrue(app.descendants(matching: .any)["union.keepOriginals"].exists)
        XCTAssertFalse(app.buttons["union.confirm"].isEnabled, "One solid has nothing to unite with")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Union tool"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["union.cancel"].tap()
        XCTAssertTrue(app.buttons["tool.sketch"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 sketch · 1 solid"].exists)
    }
    func testBottomDockSwapsModelingAndSketchToolsWithGroups() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = app(arguments: ["--ui-testing-solid"])
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        let dock = app.otherElements["dock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(dock.frame.minY, app.frame.height / 2, "The dock is at the bottom")
        // Modeling: modeling tools only, no Select tile.
        for id in ["tool.sketch", "tool.project", "tool.planes", "tool.create", "tool.edges", "tool.combine", "tool.transform", "tool.fit"] {
            XCTAssertTrue(app.buttons[id].exists, id)
        }
        XCTAssertEqual(["tool.planes", "tool.create", "tool.edges", "tool.combine", "tool.transform", "tool.fit"].map { app.buttons[$0].label },
                       ["Planes", "Create", "Modify", "Combine", "Transform", "Joints"], "Groups are named for what their tools do")
        for id in ["tool.select", "tool.line", "tool.union", "tool.fillet", "tool.shell", "tool.extrude", "tool.revolve"] { XCTAssertFalse(app.buttons[id].exists, id) }
        app.buttons["tool.combine"].tap()
        for id in ["tool.union", "tool.subtract", "tool.intersect"] { XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5), id) }
        XCTAssertFalse(app.buttons["tool.split"].exists, "Split Body divides a solid, so it is under Modify")
        shot("Dock with Combine open")
        app.otherElements["group.dismiss"].tap()
        XCTAssertTrue(app.buttons["tool.union"].waitForNonExistence(timeout: 5))
        // Modify group, and putting a tool down by tapping it again.
        app.buttons["tool.edges"].tap()
        for id in ["tool.fillet", "tool.chamfer", "tool.shell", "tool.deleteFace", "tool.split"] { XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5), id) }
        shot("Dock with Modify open")
        app.buttons["tool.chamfer"].tap()
        XCTAssertEqual(app.buttons["tool.edges"].label, "Chamfer", "The group shows the tool in use")
        XCTAssertTrue(app.buttons["tool.edges"].isSelected)
        // Create group: Extrude and Revolve.
        app.buttons["tool.create"].tap()
        for id in ["tool.extrude", "tool.revolve"] { XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5), id) }
        shot("Dock with Create open")
        app.buttons["tool.revolve"].tap()
        XCTAssertEqual(app.buttons["tool.create"].label, "Revolve", "The group shows the tool in use")
        XCTAssertTrue(app.buttons["tool.create"].isSelected)
        // Shell is under Modify; the Create tile goes back to its own name.
        app.buttons["tool.edges"].tap()
        app.buttons["tool.shell"].tap()
        XCTAssertEqual(app.buttons["tool.edges"].label, "Shell")
        XCTAssertEqual(app.buttons["tool.create"].label, "Create")
        app.buttons["tool.edges"].tap()
        app.buttons["tool.shell"].tap()
        XCTAssertEqual(app.buttons["tool.edges"].label, "Modify", "Tapping the active tool puts it down")
        XCTAssertFalse(app.buttons["tool.edges"].isSelected)
        // Joints: Peg & Socket, Thread, and Fit Test.
        app.buttons["tool.fit"].tap()
        for id in ["tool.peg", "tool.thread", "tool.fitTest"] { XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5), id) }
        XCTAssertEqual(app.buttons["tool.peg"].label, "Peg & Socket")
        shot("Dock with Joints open")
        app.otherElements["group.dismiss"].tap()
        // Sketch: sketch tools at once, before a plane is picked.
        app.buttons["tool.sketch"].tap()
        XCTAssertTrue(app.buttons["sketch.exit"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["sketch.title"].label, "No active plane")
        for id in ["tool.line", "tool.rectangle", "tool.curves", "tool.modify", "tool.dimension", "tool.project"] { XCTAssertTrue(app.buttons[id].exists, id) }
        XCTAssertTrue(app.buttons["tool.line"].isSelected, "Line is ready")
        for id in ["tool.create", "tool.edges", "tool.combine"] { XCTAssertFalse(app.buttons[id].exists, id) }
        XCTAssertEqual(["tool.curves", "tool.modify"].map { app.buttons[$0].label }, ["Shapes", "Modify"])
        shot("Sketch dock")
        // Circle, Arc, and Slot share Shapes; Trim and Fillet are under Modify.
        app.buttons["tool.curves"].tap()
        for id in ["tool.circle", "tool.arc", "tool.slot"] { XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5), id) }
        shot("Sketch dock with Shapes open")
        app.buttons["tool.slot"].tap()
        XCTAssertEqual(app.buttons["tool.curves"].label, "Slot", "The group shows the tool in use")
        app.buttons["tool.modify"].tap()
        for id in ["tool.trim", "tool.cornerFillet"] { XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5), id) }
        app.buttons["tool.cornerFillet"].tap()
        XCTAssertEqual(app.buttons["tool.modify"].label, "Fillet")
        XCTAssertTrue(app.buttons["tool.measure"].exists, "Measure is beside the view controls")
        app.buttons["sketch.exit"].tap()
        XCTAssertTrue(app.buttons["tool.create"].waitForExistence(timeout: 5))
        // A selected solid's actions sit in the strip above the dock.
        app.buttons["items.toggle"].tap()
        app.buttons["item.Body 01"].tap()
        app.buttons["items.toggle"].tap()
        let strip = app.otherElements["selection.strip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        for id in ["selection.shell", "selection.split", "selection.transform", "selection.delete", "transform.copy"] {
            XCTAssertTrue(app.descendants(matching: .any)[id].exists, id)
        }
        XCTAssertLessThan(strip.frame.maxY, dock.frame.minY + 1, "Just above the dock")
        shot("Solid selected")
    }
    func testItemsListSelectsSketchesAndSolids() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = app(arguments: ["--ui-testing-solid"])
        let toggle = app.buttons["items.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.tap()
        let body = app.buttons["item.Body 01"], rectangle = app.buttons["item.Rectangle 01"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["SKETCHES"].exists)
        XCTAssertTrue(app.buttons["item.Sketch 01"].exists, "Each sketch is a row, its shapes under it")
        // Hide and show the solid from its row.
        let visibility = app.buttons["item.visibility.Body 01"]
        XCTAssertEqual(visibility.label, "Hide Body 01")
        visibility.tap()
        XCTAssertTrue(app.buttons["Show Body 01"].waitForExistence(timeout: 5))
        app.buttons["Show Body 01"].tap()
        XCTAssertTrue(app.buttons["Hide Body 01"].waitForExistence(timeout: 5))
        body.tap()
        XCTAssertTrue(app.staticTexts["selection.measure"].waitForExistence(timeout: 5))
        XCTAssertTrue(body.isSelected)
        // The solid's source rectangle lies under its base, out of the Pencil's reach on the canvas.
        rectangle.tap()
        XCTAssertTrue(app.buttons["dimension.width"].waitForExistence(timeout: 5))
        XCTAssertTrue(rectangle.isSelected)
        XCTAssertFalse(body.isSelected)
        XCTAssertTrue(app.buttons["selection.extrude"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Items list with a sketch selected"; shot.lifetime = .keepAlways; add(shot)
        toggle.tap()
        XCTAssertTrue(body.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["dimension.width"].exists, "Closing the list keeps the selection")
    }

    func testExtrudeUndoRedoAndDelete() {
        let app = app()
        XCTAssertTrue(app.buttons["selection.extrude"].waitForExistence(timeout: 10))
        app.buttons["selection.extrude"].tap()
        XCTAssertTrue(app.buttons["dimension.depth"].waitForExistence(timeout: 5))
        app.buttons["dimension.depth"].tap()
        XCTAssertTrue(app.buttons["keypad.3"].waitForExistence(timeout: 5))
        app.buttons["keypad.3"].tap()
        app.buttons["keypad.0"].tap()
        app.buttons["keypad.confirm"].tap()
        app.buttons["extrusion.confirm"].tap()
        XCTAssertTrue(app.staticTexts["selection.measure"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 sketch · 1 solid"].exists)
        XCTAssertEqual(app.buttons["dimension.depth"].value as? String, "30")
        app.buttons["selection.delete"].tap()
        XCTAssertTrue(app.staticTexts["1 sketch · 0 solids"].exists)
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.staticTexts["1 sketch · 1 solid"].exists)
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.staticTexts["1 sketch · 0 solids"].exists)
        app.buttons["Redo"].tap()
        XCTAssertTrue(app.staticTexts["1 sketch · 1 solid"].exists)
        // Extruding kept the view from straight above; the cube's double-tap returns to the 3D angle.
        app.buttons["view.cube.top"].doubleTap()
        XCTAssertTrue(app.buttons["view.cube.front"].waitForExistence(timeout: 4))
        app.buttons["view.cube.front"].tap()
        // Drawing tools appear only while sketching; the Sketch tile shows the planes to pick.
        XCTAssertFalse(app.buttons["tool.line"].exists)
        app.buttons["tool.sketch"].tap()
        let canvas = app.otherElements["modeling.canvas"]
        let a = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45))
        let b = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
        a.press(forDuration: 0.05, thenDragTo: b)
        XCTAssertTrue(app.staticTexts["1 sketch · 1 solid"].exists)
    }
    func testOnCanvasDimensionsOpenKeypadAndReplaceSelectedValue() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = app()
        let width = app.buttons["dimension.width"]
        XCTAssertTrue(width.waitForExistence(timeout: 10))
        XCTAssertEqual(width.value as? String, "60")
        XCTAssertTrue(app.buttons["dimension.height"].exists)
        width.tap()
        XCTAssertTrue(app.buttons["keypad.7"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.keyboards.count, 0, "Dimension input must not depend on the system keyboard")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "On-canvas dimension keypad"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["keypad.7"].tap()
        app.buttons["keypad.5"].tap()
        app.buttons["keypad.confirm"].tap()
        XCTAssertEqual(width.value as? String, "75")
        XCTAssertFalse(app.buttons["keypad.confirm"].exists)
        app.buttons["dimension.height"].tap()
        app.buttons["keypad.2"].tap()
        app.buttons["keypad.5"].tap()
        app.buttons["keypad.confirm"].tap()
        XCTAssertEqual(app.buttons["dimension.height"].value as? String, "25")
        XCTAssertEqual(width.value as? String, "75")
        app.buttons["Undo"].tap()
        XCTAssertFalse(app.buttons["dimension.width"].exists)
        app.buttons["Redo"].tap()
        XCTAssertTrue(app.staticTexts["1 sketch · 0 solids"].exists)
    }
    func testKeypadValidationCancelAndArithmeticInPortrait() {
        let app = app()
        let width = app.buttons["dimension.width"]
        XCTAssertTrue(width.waitForExistence(timeout: 10))
        width.tap()
        app.buttons["keypad.0"].tap()
        XCTAssertFalse(app.buttons["keypad.confirm"].isEnabled)
        app.buttons["keypad.cancel"].tap()
        XCTAssertEqual(width.value as? String, "60")
        width.tap()
        app.buttons["keypad.2"].tap()
        app.buttons["keypad.cm"].tap()
        app.buttons["keypad.+"].tap()
        app.buttons["keypad.4"].tap()
        app.buttons["keypad.confirm"].tap()
        XCTAssertEqual(width.value as? String, "24")
        width.tap()
        app.buttons["keypad.9"].tap()
        app.buttons["keypad.⌫"].tap()
        XCTAssertFalse(app.buttons["keypad.confirm"].isEnabled)
        app.buttons["keypad.cancel"].tap()
        XCTAssertEqual(width.value as? String, "24")
    }
    func testExtrusionReferencePreviewAndSignedDepthKeypad() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = app()
        XCTAssertTrue(app.buttons["selection.extrude"].waitForExistence(timeout: 10))
        app.buttons["selection.extrude"].tap()
        let depth = app.buttons["dimension.depth"]
        XCTAssertTrue(depth.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(depth.frame.height, depth.frame.width, "Depth value should be vertical above the double-arrow")
        XCTAssertGreaterThan(app.buttons["extrusion.confirm"].frame.midY, app.frame.height * 0.8)
        depth.tap()
        XCTAssertTrue(app.buttons["keypad.3"].waitForExistence(timeout: 5))
        app.buttons["keypad.3"].tap()
        app.buttons["keypad.confirm"].tap()
        XCTAssertEqual(depth.value as? String, "3")
        let preview = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        preview.name = "Extrusion double-arrow and depth value"
        preview.lifetime = .keepAlways
        add(preview)
        depth.tap()
        XCTAssertTrue(app.buttons["keypad.±"].waitForExistence(timeout: 5))
        let keypad = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        keypad.name = "Extrusion depth keypad"
        keypad.lifetime = .keepAlways
        add(keypad)
        app.buttons["keypad.±"].tap()
        app.buttons["keypad.confirm"].tap()
        XCTAssertEqual(depth.value as? String, "-3")
        // Retyping a negative value keeps its sign and replaces only the amount.
        depth.tap()
        XCTAssertTrue(app.buttons["keypad.5"].waitForExistence(timeout: 5))
        app.buttons["keypad.5"].tap()
        XCTAssertEqual(app.staticTexts["keypad.expression"].value as? String, "-5")
        app.buttons["keypad.confirm"].tap()
        XCTAssertEqual(depth.value as? String, "-5")
        app.buttons["extrusion.cancel"].tap()
        XCTAssertTrue(app.staticTexts["1 sketch · 0 solids"].exists)
        XCTAssertFalse(app.buttons["extrusion.confirm"].exists)
    }

    func testRevolveAboutALineWithTheAngleKeypad() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = app(arguments: ["--ui-testing-axis"])
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertTrue(app.buttons["selection.revolve"].waitForExistence(timeout: 10))
        app.buttons["selection.revolve"].tap()
        let confirm = app.buttons["revolve.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertFalse(confirm.isEnabled, "Nothing to make before the axis and angle")
        XCTAssertGreaterThan(confirm.frame.midY, app.frame.height * 0.8, "Cancel and Done at the bottom center")
        XCTAssertFalse(app.otherElements["dock"].exists, "The revolve's controls replace the dock")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'axis'")).firstMatch.exists)
        // Pencil taps pick the axis on the canvas; the Items list picks it too.
        app.buttons["items.toggle"].tap()
        XCTAssertTrue(app.buttons["item.Line 01"].waitForExistence(timeout: 5))
        app.buttons["item.Line 01"].tap()
        app.buttons["items.toggle"].tap()
        let angle = app.buttons["dimension.revolve.angle"]
        XCTAssertTrue(angle.waitForExistence(timeout: 5))
        XCTAssertEqual(angle.value as? String, "0")
        XCTAssertTrue(app.segmentedControls["revolve.mode"].exists)
        angle.tap()
        XCTAssertTrue(app.buttons["keypad.3"].waitForExistence(timeout: 5))
        app.buttons["keypad.2"].tap(); app.buttons["keypad.7"].tap(); app.buttons["keypad.0"].tap()
        app.buttons["keypad.confirm"].tap()
        XCTAssertEqual(angle.value as? String, "270")
        XCTAssertTrue(confirm.isEnabled)
        XCTAssertTrue(app.segmentedControls["revolve.mode"].buttons["New Body"].isSelected)
        shot("Revolve preview, axis, and angle")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["1 sketch · 1 solid"].waitForExistence(timeout: 5))
        XCTAssertFalse(confirm.exists)
        let bodyAngle = app.buttons["dimension.angle"]
        XCTAssertTrue(bodyAngle.waitForExistence(timeout: 5), "The new solid is selected with its angle")
        XCTAssertEqual(bodyAngle.value as? String, "270")
        shot("Revolved solid")
        app.buttons["Undo"].tap()
        XCTAssertTrue(app.staticTexts["1 sketch · 0 solids"].waitForExistence(timeout: 5))
    }


    /// The assistant panel opens from the right rail; a request's changes preview with Keep and
    /// Discard in place of the dock, Keep is one undo step, and Discard leaves the model alone.
    /// The model is scripted (--ui-testing-assistant), so this checks the interface, not a model.
    func testAssistantPreviewsChangesForKeepOrDiscard() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-solid", "--ui-testing-assistant"]
        app.launch()
        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        let toggle = app.buttons["assistant.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        toggle.tap()
        XCTAssertTrue(app.otherElements["assistant.panel"].waitForExistence(timeout: 5) || app.buttons["assistant.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["assistant.suggestion"].firstMatch.exists, "suggestions fill the empty panel")
        shot("Assistant panel")

        let input = app.textFields["assistant.input"].exists ? app.textFields["assistant.input"] : app.textViews["assistant.input"]
        input.tap()
        input.typeText("Round the vertical edges 3 mm")
        app.buttons["assistant.send"].tap()
        let keep = app.buttons["assistant.keep"]
        XCTAssertTrue(keep.waitForExistence(timeout: 10), "Keep replaces the dock")
        XCTAssertTrue(app.buttons["assistant.discard"].exists)
        XCTAssertFalse(app.buttons["tool.sketch"].exists, "the dock is replaced while reviewing")
        XCTAssertTrue(app.descendants(matching: .any)["assistant.changes"].exists, "the reply lists its changes")
        XCTAssertFalse(app.buttons["Undo"].isEnabled, "editing waits for Keep or Discard")
        shot("Assistant changes under review")
        keep.tap()
        XCTAssertTrue(app.buttons["tool.sketch"].waitForExistence(timeout: 5), "the dock returns")
        XCTAssertTrue(app.buttons["Undo"].isEnabled)

        // A second request, discarded.
        input.tap()
        input.typeText("Chamfer the top edges 1 mm")
        app.buttons["assistant.send"].tap()
        XCTAssertTrue(app.buttons["assistant.discard"].waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["assistant.discard"].waitForExistence(timeout: 5))
        shot("Assistant review in portrait")
        app.buttons["assistant.discard"].tap()
        XCTAssertTrue(app.buttons["tool.sketch"].waitForExistence(timeout: 5))
        app.buttons["assistant.close"].tap()
        XCTAssertFalse(app.buttons["assistant.close"].waitForExistence(timeout: 1))
        // Undo removes the kept fillet in one step.
        app.buttons["Undo"].tap()
        XCTAssertFalse(app.buttons["Undo"].isEnabled)
    }

    func testUnitsMenuShowsInchesAndTheKeypadTakesThem() {
        let app = app()
        let width = app.buttons["dimension.width"]
        XCTAssertTrue(width.waitForExistence(timeout: 10))
        XCTAssertEqual(width.label, "Width, 60 mm")
        app.buttons["Project menu"].tap()
        app.buttons["project.units"].tap()
        app.buttons["Inches"].tap()
        XCTAssertTrue(app.buttons["dimension.width"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["dimension.width"].label, "Width, 2.362 in")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Rectangle dimensioned in inches"; shot.lifetime = .keepAlways; add(shot)
        // A bare number is inches; the stored value is millimeters.
        app.buttons["dimension.width"].tap()
        app.buttons["keypad.3"].tap()
        app.buttons["keypad.confirm"].tap()
        XCTAssertEqual(app.buttons["dimension.width"].label, "Width, 3 in")
        app.buttons["Project menu"].tap()
        app.buttons["project.units"].tap()
        app.buttons["Millimeters"].tap()
        XCTAssertEqual(app.buttons["dimension.width"].label, "Width, 76.2 mm")
    }

    func testHintStaysWithinTwoLinesAndHelpShowsTheRest() {
        let app = app(arguments: ["--ui-testing-solid"])
        let toggle = app.buttons["items.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.tap()
        app.buttons["item.Body 01"].tap()
        toggle.tap()
        // A selected solid has the longest hint: it is cut to two lines.
        let hint = app.staticTexts["hint.text"]
        XCTAssertTrue(hint.waitForExistence(timeout: 5))
        XCTAssertLessThan(hint.frame.height, 46, "At most two lines of 15 pt text")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Two-line hint with help"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["hint.help"].tap()
        // The help card opens on the topic for what is being done, with the whole hint.
        XCTAssertTrue(app.staticTexts["help.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["help.title"].label, "Moving a Solid")
        let detail = app.staticTexts["hint.detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertTrue(detail.label.hasPrefix("Solid selected."), detail.label)
        XCTAssertTrue(detail.label.hasSuffix("keep the original."), "The whole hint")
        XCTAssertTrue(app.staticTexts["help.summary"].exists, "A plain-language overview")
        let overview = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        overview.name = "Help card overview"; overview.lifetime = .keepAlways; add(overview)
        // The card moves by its top bar.
        let title = app.staticTexts["help.title"]
        let before = title.frame
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)))
        XCTAssertGreaterThan(abs(title.frame.midX - before.midX) + abs(title.frame.midY - before.midY), 40, "Dragged")
        app.buttons["help.close"].tap()
        XCTAssertFalse(app.staticTexts["help.title"].waitForExistence(timeout: 1))
        app.buttons["hint.help"].tap()
        app.buttons["hint.controls"].tap()
        XCTAssertTrue(app.navigationBars["Controls"].waitForExistence(timeout: 5), "All controls opens the guide")
    }
}
