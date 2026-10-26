import XCTest

/// The code in Shared/, which the app, its helper and the share extension compile in. The bundle
/// has no host app, so nothing here starts Lists; strings come back as their English keys.
final class MomentTests: XCTestCase {
    func testADayIsNamedAsSeenFromToday() {
        XCTAssertEqual(Moment.label("2026-10-17", today: "2026-10-17"), "Today")
        XCTAssertEqual(Moment.label("2026-10-18", today: "2026-10-17"), "Tomorrow")
        XCTAssertEqual(Moment.label("2026-10-16", today: "2026-10-17"), "Yesterday")
    }

    func testATimeFollowsTheDay() {
        XCTAssertEqual(Moment.label("2026-10-18T18:30", today: "2026-10-17"), "Tomorrow, 18:30")
    }

    func testAValueThatIsNotADateIsShownAsItIs() {
        XCTAssertEqual(Moment.label("someday", today: "2026-10-17"), "someday")
    }

    func testDatesTravelWithoutAZone() {
        XCTAssertFalse(Moment.hasTime("2026-10-17"))
        XCTAssertTrue(Moment.hasTime("2026-10-17T09:00"))
        XCTAssertEqual(Moment.day("2026-10-17T09:00"), "2026-10-17")
        let nine = Moment.date("2026-10-17T09:00")!
        XCTAssertEqual(Moment.string(nine, withTime: true), "2026-10-17T09:00")
        XCTAssertEqual(Moment.string(nine, withTime: false), "2026-10-17")
    }

    // R72: the row leaves out the day the heading of its group names.
    func testTheRowLeavesTheDayToTheHeading() {
        let tomorrow = Moment.string(Date().addingTimeInterval(36 * 3600), withTime: false)
        XCTAssertEqual(Moment.rowDate(due: tomorrow + "T18:30", open: true, dayInHeading: true)?.text, "18:30")
        XCTAssertNil(Moment.rowDate(due: tomorrow, open: true, dayInHeading: true))
        XCTAssertNil(Moment.rowDate(due: nil, open: true, dayInHeading: false))
    }

    func testAnOverdueRowKeepsItsDay() {
        let row = Moment.rowDate(due: "2020-01-01", open: true, dayInHeading: true)
        XCTAssertEqual(row?.late, true)
        XCTAssertEqual(row?.text.isEmpty, false)
        XCTAssertEqual(Moment.rowDate(due: "2020-01-01", open: false, dayInHeading: false)?.late, false)
    }
}

final class RepeatTests: XCTestCase {
    func testAPresetIsNamedByItsShape() {
        XCTAssertEqual(Repeat.every(.weekly, weekdays: [1, 2, 3, 4, 5]).presetName, "On weekdays")
        XCTAssertEqual(Repeat.every(.monthly, interval: 3).presetName, "Every quarter")
        var dated = Repeat.every(.monthly)
        dated.monthday = 17
        XCTAssertEqual(dated.presetName, "Every month", "the day of the month changes as the series goes on")
        var counted = Repeat.every(.daily)
        counted.count = 3
        XCTAssertNil(counted.presetName)
    }

    func testARuleThatIsNoPresetIsSpelledOut() {
        XCTAssertEqual(Repeat.every(.daily, interval: 3).summary, "Every 3 days")
        var last = Repeat.every(.monthly)
        last.nth = -1
        last.nthWeekday = 5
        XCTAssertEqual(last.summary, "Every month, last Fri")
        var done = Repeat.every(.weekly, interval: 2, weekdays: [3, 1])
        done.fromDone = true
        XCTAssertEqual(done.summary, "Every 2 weeks: Mon, Wed after completion")
    }
}

final class PriorityTests: XCTestCase {
    func testMarksGrowWithThePriority() {
        XCTAssertEqual(Priority.all.map(\.marks), ["", "!", "!!", "!!!"])
    }
}

/// R161: the sections of the sidebar collapse, and the row of the open view stays.
final class SidebarFoldingTests: XCTestCase {
    func testACollapsedSectionKeepsOnlyTheRowOfTheOpenView() {
        let lists = ["Work", "Home", "Trip"]
        XCTAssertEqual(SidebarFolding.shown(lists, folded: true) { $0 == "Home" }, ["Home"])
        XCTAssertEqual(SidebarFolding.shown(lists, folded: true) { _ in false }, [])
        XCTAssertEqual(SidebarFolding.shown(lists, folded: false) { $0 == "Home" }, lists)
    }

    func testTheCollapsedSectionsAreKeptByName() {
        XCTAssertEqual(SidebarFolding.stored([.filters, .lists]), ["lists", "filters"])
        XCTAssertEqual(SidebarFolding.folded(["filters", "lists"]), [.lists, .filters])
        XCTAssertEqual(SidebarFolding.folded(["archive", "tags"]), [.tags], "a name of no section is left out")
        XCTAssertEqual(SidebarFolding.folded(nil), [])
    }
}

/// R161: the sidebar grows half as fast as the tasks.
final class SidebarTextTests: XCTestCase {
    func testTheSidebarGrowsHalfAsFastAsTheTasks() {
        XCTAssertEqual(SidebarText.scale(1), 1)
        XCTAssertEqual(SidebarText.scale(1.15), 1.075, accuracy: 0.0001)
        XCTAssertEqual(13 * SidebarText.scale(1.5), 16.25, accuracy: 0.0001)
        XCTAssertEqual(SidebarText.scale(0.9), 0.95, accuracy: 0.0001)
    }
}

/// R35: the steps of the text size start from a "Regular" larger than the system size.
final class TextSizeTests: XCTestCase {
    func testASavedStepStaysAndNothingSavedIsRegular() {
        XCTAssertEqual(TextSize.step(nil), 1.15)
        XCTAssertEqual(TextSize.step(1.15), 1.15, "the old Large is the new Regular")
        XCTAssertEqual(TextSize.step(1.3), 1.3)
        XCTAssertEqual(TextSize.step(1.7), 1.7)
    }

    func testAFactorOfAnEarlierVersionIsTheNearestStep() {
        XCTAssertEqual(TextSize.step(0.9), 1.0)
        XCTAssertEqual(TextSize.step(1.05), 1.0)
        XCTAssertEqual(TextSize.step(2), 1.7)
    }
}

/// The bindings reach the Rust core: the static library is linked and a store opens and takes a task.
final class CoreTests: XCTestCase {
    func testAStoreOpensThroughTheBindingsAndTakesATask() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lists-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store.open(dir: dir.path)
        let task = try store.quickAdd(text: "check the bindings", listId: nil)
        XCTAssertEqual(task.title, "check the bindings")
        XCTAssertTrue(try store.tasks(view: .inbox).contains { $0.id == task.id })
    }
}

/// R123: several tasks dragged to another place of a list sorted by hand.
final class ReorderTests: XCTestCase {
    private func apply(_ order: [String], _ moves: [(id: String, after: String?)]) -> [String] {
        var order = order
        for move in moves {
            order.removeAll { $0 == move.id }
            order.insert(move.id, at: move.after.flatMap { order.firstIndex(of: $0).map { $0 + 1 } } ?? 0)
        }
        return order
    }

    func testOneTaskGoesToThePlace() {
        let order = ["a", "b", "c", "d"]
        XCTAssertEqual(apply(order, Reorder.moves(order, moving: ["d"], to: 1)), ["a", "d", "b", "c"])
        XCTAssertEqual(apply(order, Reorder.moves(order, moving: ["a"], to: 4)), ["b", "c", "d", "a"])
    }

    func testSeveralTasksStandTogetherInTheirOrder() {
        let order = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(apply(order, Reorder.moves(order, moving: ["d", "b"], to: 0)), ["b", "d", "a", "c", "e"])
        XCTAssertEqual(apply(order, Reorder.moves(order, moving: ["a", "c"], to: 4)), ["b", "d", "a", "c", "e"])
        XCTAssertEqual(apply(order, Reorder.moves(order, moving: ["a", "e"], to: 2)), ["b", "a", "e", "c", "d"])
    }

    func testADropWhereTheTasksStandMovesNothing() {
        let order = ["a", "b", "c", "d"]
        XCTAssertTrue(Reorder.moves(order, moving: ["b", "c"], to: 1).isEmpty)
        XCTAssertTrue(Reorder.moves(order, moving: ["b", "c"], to: 3).isEmpty)
    }
}
