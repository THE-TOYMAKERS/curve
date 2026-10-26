import AppKit
import Foundation
import UniformTypeIdentifiers
import BrowserCore

@main
struct DragChecks {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let parent = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : FileManager.default.temporaryDirectory
            let directory = parent.appendingPathComponent("DragChecks-\(UUID().uuidString)")
            setenv("CURVE_DATA_DIR", directory.path, 1)
            var failures: [String] = []; var passed: [String] = []
            func check(_ ok: Bool, _ name: String) { if ok { passed.append(name) } else { failures.append(name) } }
            let work = BrowserSpace(name: "Work", emoji: "W", colorHex: "BDB6DD")
            let play = BrowserSpace(name: "Play", emoji: "P", colorHex: "AACCDD")
            let focus = BrowserSpace(name: "Focus", emoji: "F", colorHex: "DDBBAA")
            var fixture = BrowserState(spaces: [work, play, focus])
            let root = fixture.addFolder(name: "Work", spaceID: work.id)
            let research = fixture.addFolder(name: "Work / Research", spaceID: work.id)
            let papers = fixture.addFolder(name: "Work / Research / Papers", spaceID: work.id)
            let inbox = fixture.addFolder(name: "Inbox", spaceID: work.id)
            let primary = fixture.open(url: "curve://start", title: "Primary", spaceID: work.id)
            let reading = fixture.open(url: "https://example.org/reading", title: "Reading", kind: .pinned, spaceID: work.id, folderID: research)
            let paper = fixture.open(url: "https://example.org/paper", title: "Paper", kind: .pinned, spaceID: work.id, folderID: papers)
            let other = fixture.open(url: "https://example.org/other", title: "Other", kind: .pinned, spaceID: work.id, folderID: inbox)
            let first = fixture.open(url: "https://example.org/first", title: "First", spaceID: work.id)
            let second = fixture.open(url: "https://example.org/second", title: "Second", spaceID: work.id)
            let favorite = fixture.open(url: "https://example.org/favorite", title: "Favorite", kind: .favorite, spaceID: work.id)
            fixture.select(primary)
            let store = BrowserStore(mode: .normal, directory: directory.appendingPathComponent("source"), seed: fixture)
            @MainActor func drop(_ item: BrowserDragItem, _ target: BrowserDropTarget, _ position: BrowserDropPosition = .inside) -> Bool {
                store.commitDrop(store.dragPayload(for: item), from: store, on: target, position: position)
            }
            @MainActor func tab(_ id: UUID) -> BrowserTab { store.state.tabs.first { $0.id == id }! }
            let access = tab(primary).lastAccessed
            check(drop(.tab(second), .tab(first), .before) && store.state.tabs.firstIndex(where: { $0.id == second })! < store.state.tabs.firstIndex(where: { $0.id == first })!, "tab drop inserts before the hovered row")
            check(drop(.tab(second), .tab(first), .after) && store.state.tabs.firstIndex(where: { $0.id == second })! == store.state.tabs.firstIndex(where: { $0.id == first })! + 1, "tab drop inserts after the hovered row")
            check(store.state.selectedTabID == primary && tab(primary).lastAccessed == access, "reordering preserves page selection and MRU time")
            check(drop(.tab(first), .pinned) && tab(first).kind == .pinned && tab(first).savedURL == tab(first).url, "Today to pinned saves its home address")
            check(drop(.tab(first), .today) && tab(first).kind == .today && tab(first).folderID == nil && tab(first).savedURL == nil, "pinned to Today clears folder and home address")
            check(drop(.tab(first), .favorites) && tab(first).kind == .favorite && tab(first).folderID == nil, "drag into favorites creates a global favorite")
            store.state.switchSpace(play.id)
            check(store.state.visibleTabs.contains { $0.id == first }, "favorite remains visible in another space")
            store.state.switchSpace(work.id)
            check(drop(.tab(first), .folder(research)) && tab(first).kind == .pinned && tab(first).folderID == research && store.state.folders.first { $0.id == research }!.isExpanded, "folder drop pins and reveals the moved tab")
            store.state.select(first); store.focusedPane = first
            check(drop(.tab(first), .space(play.id)) && tab(first).spaceID == play.id && tab(first).folderID == nil && store.state.selectedTabID != first && store.focusedPane == nil, "moving active tab to another space repairs selection and focus")
            store.state.select(primary)
            check(drop(.tab(second), .splitRight) && store.state.selectedTabID == primary && store.splitID == second, "right split drop preserves primary and adds secondary")
            check(drop(.tab(other), .splitLeft) && store.state.selectedTabID == other && store.splitID == primary, "left split drop places dragged tab first")
            let beforeSelf = store.state
            check(!drop(.tab(other), .splitRight) && store.state == beforeSelf, "self split drop is a no-op")
            store.setSplit(nil); store.state.select(primary)
            let beforeCycle = store.state
            check(!drop(.folder(root), .folder(research)) && store.state == beforeCycle, "folder cannot move into its own descendant")
            check(drop(.folder(research), .folder(inbox)) && store.state.folders.first { $0.id == research }?.name == "Inbox / Research" && store.state.folders.first { $0.id == papers }?.name == "Inbox / Research / Papers" && tab(reading).folderID == research && tab(paper).folderID == papers, "nesting folder updates descendant paths and preserves tab membership")
            check(drop(.folder(research), .folder(inbox), .before) && store.state.folders.first { $0.id == research }?.name == "Research" && store.state.folders.firstIndex(where: { $0.id == research })! < store.state.folders.firstIndex(where: { $0.id == inbox })!, "folder edge drop reorders and reparents as a sibling")
            check(drop(.folder(research), .space(play.id)) && store.state.folders.filter { $0.id == research || $0.id == papers }.allSatisfy { $0.spaceID == play.id } && tab(reading).spaceID == play.id && tab(paper).spaceID == play.id, "cross-space folder move carries the entire tree and its tabs")
            store.state.switchSpace(work.id)
            check(drop(.folder(research), .pinned) && store.state.folders.first { $0.id == research }?.spaceID == work.id && store.state.folders.first { $0.id == research }?.name == "Research", "folder can return to the root of the active space")
            _ = store.state.addFolder(name: "Research", spaceID: play.id)
            check(drop(.folder(research), .space(play.id)) && store.state.folders.first { $0.id == research }?.name == "Research 2" && store.state.folders.first { $0.id == papers }?.name == "Research 2 / Papers", "folder path collision gets a unique name across its descendants")
            let selectedSpace = store.state.activeSpaceID
            check(drop(.space(work.id), .space(focus.id), .after) && store.state.spaces.last?.id == work.id && store.state.activeSpaceID == selectedSpace, "space reorder changes order without changing current space")
            let beforeInvalid = store.state
            check(!drop(.folder(research), .favorites) && store.state == beforeInvalid, "invalid local folder destination cannot mutate state")
            let destination = BrowserSpace(name: "Destination", emoji: "D", colorHex: "AACCDD")
            var destinationFixture = BrowserState(spaces: [destination])
            _ = destinationFixture.open(url: "curve://start", title: "Destination")
            let target = BrowserStore(mode: .normal, directory: directory.appendingPathComponent("target"), seed: destinationFixture)
            let beforeForeign = target.state
            check(!target.commitDrop(store.dragPayload(for: .folder(research)), from: store, on: .favorites) && target.state == beforeForeign, "invalid cross-window drop rolls back the entire snapshot copy")
            let sourceBeforeCopy = store.state
            let tabPayload = store.dragPayload(for: .tab(second))
            check(target.commitDrop(tabPayload, from: store, on: .today) && target.state.tabs.contains { $0.id != second && $0.url == tab(second).url && $0.kind == .today } && store.state == sourceBeforeCopy, "cross-window tab drop copies with fresh identity and leaves source unchanged")
            let folderPayload = store.dragPayload(for: .folder(research))
            check(target.commitDrop(folderPayload, from: store, on: .pinned) && Set(target.state.folders.map(\.id)).isDisjoint(with: folderPayload.folders.map(\.id)) && target.state.tabs.contains { $0.url == tab(reading).url && $0.folderID != research }, "cross-window folder copy remaps every folder and tab membership")
            var cloneFixture = store.state; cloneFixture.switchSpace(play.id)
            let clone = BrowserStore(mode: .normal, directory: directory.appendingPathComponent("clone"), seed: cloneFixture)
            let originalFolders = clone.state.folders; let originalTabs = clone.state.tabs
            check(clone.commitDrop(folderPayload, from: store, on: .folder(inbox)) && originalFolders.allSatisfy { folder in clone.state.folders.first { $0.id == folder.id } == folder } && originalTabs.allSatisfy { tab in clone.state.tabs.first { $0.id == tab.id } == tab }, "cross-window folder copy cannot capture a cloned destination tree with matching paths")
            let spacesBefore = target.state.spaces.count
            check(target.commitDrop(store.dragPayload(for: .space(play.id)), from: store, on: .space(destination.id), position: .before) && target.state.spaces.count == spacesBefore + 1 && target.state.spaces.first?.id != play.id && store.state == sourceBeforeCopy, "cross-window space copy creates a new space and preserves source")
            store.state.switchSpace(work.id)
            check(store.dropExternalURL("https://example.org/external", on: .folder(inbox)) && store.state.tabs.contains { $0.url == "https://example.org/external" && $0.kind == .pinned && $0.folderID == inbox }, "external URL drop creates a pinned folder tab")
            let beforeUnsafe = store.state
            check(!store.dropExternalURL("javascript:alert(1)", on: .today) && !store.dropExternalURL("file:///tmp/private", on: .today) && !store.dropExternalURL("search text", on: .today) && store.state == beforeUnsafe, "URL drops reject scripts files and non-URL text")
            check(!store.dropExternalURL("https://example.org/missing-folder", on: .folder(UUID())) && store.state == beforeUnsafe, "failed external URL drop restores tab selection and the entire state")
            store.drop(second.uuidString, kind: .pinned)
            check(tab(second).kind == .pinned, "legacy string drops retain supported behavior")
            let provider = store.drag.begin(.tab(second), store: store, monitorMouse: false)
            check(provider.hasItemConformingToTypeIdentifier(UTType.curveTab.identifier) && !provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier), "internal item provider uses a dedicated type instead of text-field data")
            let providedData: Data? = await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: UTType.curveDrag.identifier) { data, _ in continuation.resume(returning: data) }
            }
            check(providedData.flatMap { try? JSONDecoder().decode(BrowserDragPayload.self, from: $0) }?.item == .tab(second), "native item provider vends its eager custom-data snapshot")
            check(target.drag.activeTabID == second && target.drag.item == .tab(second) && !target.drag.isSource(.tab(second)), "receiving windows expose split targets without dimming matching cloned tabs")
            store.drag.finish(cancelled: true)
            check(!target.drag.isDragging && !clone.drag.isDragging, "source cancellation clears drag feedback in every receiving window")
            _ = store.drag.begin(.tab(second), store: store, monitorMouse: false)
            target.drag.prepareForDrop(); target.drag.cancelDrop()
            check(!store.drag.isDragging && !target.drag.isDragging && !clone.drag.isDragging, "rejected cross-window drop clears its pending source and receiver sessions")
            _ = store.drag.begin(.tab(second), store: store)
            try? await Task.sleep(nanoseconds: 650_000_000)
            check(store.drag.isDragging && store.drag.activeTabID == second, "drag stays alive until an actual release event even without a physical mouse button")
            store.drag.finish(cancelled: true)
            store.drag.updateDropFrames([
                BrowserDropFrame(target: .today, rect: CGRect(x: 0, y: 0, width: 300, height: 300), axis: .vertical),
                BrowserDropFrame(target: .tab(other), rect: CGRect(x: 20, y: 20, width: 180, height: 36), axis: .vertical)
            ])
            _ = store.drag.begin(.tab(second), store: store, monitorMouse: false)
            check(store.drag.commitRegisteredDrop(at: CGPoint(x: 30, y: 53), payload: store.dragPayload(for: .tab(second)), from: store, store: store) && tab(second).folderID == tab(other).folderID && store.state.tabs.firstIndex(where: { $0.id == second })! == store.state.tabs.firstIndex(where: { $0.id == other })! + 1, "fast release fallback prefers the nested row target and inserts after its midpoint")
            let beforeMiss = store.state
            _ = store.drag.begin(.tab(second), store: store, monitorMouse: false)
            check(!store.drag.commitRegisteredDrop(at: CGPoint(x: 400, y: 400), payload: store.dragPayload(for: .tab(second)), from: store, store: store) && store.state == beforeMiss, "release outside registered targets cannot move a tab")
            store.drag.finish(cancelled: true)
            let horizontal = BrowserDropFrame(target: .tab(other), rect: CGRect(x: 10, y: 10, width: 80, height: 40), axis: .horizontal)
            check(horizontal.position(for: .tab(second), at: CGPoint(x: 20, y: 40)) == .before && horizontal.position(for: .tab(second), at: CGPoint(x: 80, y: 20)) == .after, "favorite insertion geometry follows its horizontal midpoint")
            let clipped = BrowserDropFrame(target: .tab(other), rect: CGRect(x: 20, y: 20, width: 180, height: 36), axis: .vertical, viewport: CGRect(x: 0, y: 45, width: 300, height: 200))
            store.drag.updateDropFrames([clipped]); let beforeClipped = store.state
            _ = store.drag.begin(.tab(second), store: store, monitorMouse: false)
            check(!store.drag.commitRegisteredDrop(at: CGPoint(x: 30, y: 30), payload: store.dragPayload(for: .tab(second)), from: store, store: store) && store.state == beforeClipped, "off-viewport row geometry cannot capture a header or footer drop")
            store.drag.finish(cancelled: true)
            check(clipped.visibleRect.contains(CGPoint(x: 30, y: 47)) && clipped.position(for: .tab(second), at: CGPoint(x: 30, y: 47)) == .after, "a partially visible row keeps its original insertion midpoint")
            target.drag.updateDropFrames([BrowserDropFrame(target: .today, rect: CGRect(x: 0, y: 0, width: 100, height: 100), axis: .vertical)])
            let sourceBeforeFallback = store.state; let targetCount = target.state.tabs.count
            _ = store.drag.begin(.tab(second), store: store, monitorMouse: false)
            check(target.drag.commitRegisteredDrop(at: CGPoint(x: 20, y: 20), payload: store.dragPayload(for: .tab(second)), from: store, store: target) && target.state.tabs.count == targetCount + 1 && store.state == sourceBeforeFallback && !store.drag.isDragging, "registered release fallback preserves cross-window copy and lifecycle semantics")
            let beforeStale = target.state
            let stalePayload = providedData.flatMap { try? JSONDecoder().decode(BrowserDragPayload.self, from: $0) }
            check(stalePayload.map { !target.drag.importPayload($0, store: target, on: .today) } == true && target.state == beforeStale, "a provider from a finished internal drag cannot replay as a copied tab")
            let freshImport = store.dragPayload(for: .tab(second)); let importCount = target.state.tabs.count
            check(target.drag.importPayload(freshImport, store: target, on: .today) && !target.drag.importPayload(freshImport, store: target, on: .today) && target.state.tabs.count == importCount + 1, "an incoming native drag token can commit only once")
            let cancelledToken = store.drag.beginGesture(.tab(second), store: store)
            store.drag.finish(cancelled: true)
            if let cancelledToken { store.drag.updateGesture(at: CGPoint(x: 30, y: 30), token: cancelledToken) }
            check(!store.drag.isDragging && store.drag.presentation.point == nil && store.drag.presentation.item == nil, "motion from an escaped internal gesture cannot restart it or retain its preview")
            if let i = store.state.folders.firstIndex(where: { $0.id == inbox }) { store.state.folders[i].isExpanded = false }
            _ = store.drag.begin(.tab(second), store: store, monitorMouse: false)
            store.drag.hover(.folder(inbox), position: .inside, store: store)
            try? await Task.sleep(nanoseconds: 500_000_000)
            check(store.state.folders.first { $0.id == inbox }?.isExpanded == true, "hovering a folder expands it after the delay")
            store.drag.finish(cancelled: true)
            check(store.state.folders.first { $0.id == inbox }?.isExpanded == false && !store.drag.isDragging, "cancel restores hover expansion and clears drag feedback")
            store.state.switchSpace(work.id)
            _ = store.drag.begin(.tab(second), store: store, monitorMouse: false)
            store.drag.hover(.space(play.id), position: .inside, store: store)
            try? await Task.sleep(nanoseconds: 620_000_000)
            check(store.state.activeSpaceID == play.id, "hovering a space switches to it after the delay")
            store.drag.finish(cancelled: true)
            check(store.state.activeSpaceID == work.id && tab(second).spaceID == work.id, "cancel restores original space without moving the dragged tab")
            _ = store.drag.begin(.tab(second), store: store, monitorMouse: false)
            store.drag.hover(.space(play.id), position: .inside, store: store)
            try? await Task.sleep(nanoseconds: 620_000_000)
            let moved = store.commitDrop(store.dragPayload(for: .tab(second)), from: store, on: .space(play.id))
            store.drag.didCommit()
            check(moved && store.state.activeSpaceID == play.id && tab(second).spaceID == play.id && !store.drag.isDragging, "successful drop keeps the hovered space and clears the session")
            let roundtrip = try? JSONDecoder().decode(BrowserDragPayload.self, from: JSONEncoder().encode(folderPayload))
            check(roundtrip?.folders == folderPayload.folders && roundtrip?.tabs == folderPayload.tabs, "drag snapshot serialization preserves the folder bundle")
            store.saveNow()
            check(store.persistence.load() == store.state, "dragged order and memberships survive session persistence")
            check(store.state.tabs.contains { $0.id == favorite && $0.kind == .favorite }, "unrelated favorites remain intact through all drag operations")
            let folderSpace = BrowserSpace(name: "Folder menus", emoji: "F", colorHex: "BDB6DD")
            let foreignFolderSpace = BrowserSpace(name: "Other folders", emoji: "O", colorHex: "AACCDD")
            let folderStore = BrowserStore(mode: .normal, directory: directory.appendingPathComponent("folder-menus"), seed: BrowserState(spaces: [folderSpace, foreignFolderSpace]))
            @MainActor func folderName(_ id: UUID) -> String { folderStore.state.folders.first { $0.id == id }!.name }
            let readingOne = folderStore.addFolder(named: "Reading")!
            let readingTwo = folderStore.addFolder(named: "Reading")!
            let readingThree = folderStore.addFolder(named: "reading")!
            check(folderName(readingOne) == "Reading" && folderName(readingTwo) == "Reading 2" && folderName(readingThree) == "reading 3", "folder creation assigns bounded unique sibling names including case variants")
            let container = folderStore.addFolder(named: "Container")!
            let child = folderStore.addFolder(named: "Notes", parentID: container)!
            let grandchild = folderStore.addFolder(named: "Papers", parentID: child)!
            let member = folderStore.state.open(url: "https://example.org/member", title: "Folder member", kind: .pinned, folderID: grandchild)
            _ = folderStore.addFolder(named: "Inbox")!
            check(folderStore.renameFolder(container, to: "Inbox") && folderName(container) == "Inbox 2" && folderName(child) == "Inbox 2 / Notes" && folderName(grandchild) == "Inbox 2 / Notes / Papers" && folderStore.state.tabs.first { $0.id == member }?.folderID == grandchild, "conflicting folder rename preserves the complete subtree and tab identities")
            let folderBeforeInvalid = folderStore.state
            check(folderStore.addFolder(named: " ") == nil && folderStore.addFolder(named: "A / B") == nil && !folderStore.renameFolder(child, to: "A / B") && folderStore.state == folderBeforeInvalid, "folder menu names cannot create empty or ambiguous path components")
            _ = folderStore.addFolder(named: "Other")!
            check(folderStore.renameFolder(child, to: "New name") && folderName(grandchild) == "Inbox 2 / New name / Papers", "nested rename updates descendants without changing their IDs")
            folderStore.toggleFolder(container)
            let secondChild = folderStore.addFolder(named: "New name", parentID: container)!
            check(folderName(secondChild) == "Inbox 2 / New name 2" && folderStore.state.folders.first { $0.id == container }?.isExpanded == true, "creating a conflicting child chooses a unique name and reveals its parent")
            _ = folderStore.state.addFolder(name: "Reserved / Orphan", spaceID: folderSpace.id)
            let reserved = folderStore.addFolder(named: "Reserved")!
            check(folderName(reserved) == "Reserved 2" && folderStore.renameFolder(readingTwo, to: "Reserved") && folderName(readingTwo) == "Reserved 3", "create and rename reserve orphan descendant namespaces instead of adopting their trees")
            let foreignParent = folderStore.state.addFolder(name: "Foreign", spaceID: foreignFolderSpace.id)
            let foreignChild = folderStore.addFolder(named: "Notes", parentID: foreignParent)!
            check(folderName(foreignChild) == "Foreign / Notes" && folderStore.state.folders.first { $0.id == foreignChild }?.spaceID == foreignFolderSpace.id && folderStore.state.activeSpaceID == folderSpace.id, "new child belongs to its actual parent space without switching the current space")
            let beforeMissingParent = folderStore.state
            check(folderStore.addFolder(named: "Lost", parentID: UUID()) == nil && folderStore.state == beforeMissingParent, "a stale parent cannot silently create a folder at the root")
            _ = folderStore.addFolder(named: "New name")!
            folderStore.removeFolder(container)
            let paths = folderStore.state.folders.filter { $0.spaceID == folderSpace.id }.map { $0.name.lowercased() }
            check(!folderStore.state.folders.contains { $0.id == container } && Set(paths).count == paths.count && folderName(grandchild) == folderName(child) + " / Papers" && folderStore.state.tabs.first { $0.id == member }?.folderID == grandchild, "removing a folder promotes children with unique names and intact descendant membership")
            let repeatParent = folderStore.addFolder(named: "Repeat")!
            let repeatChild = folderStore.addFolder(named: "Repeat", parentID: repeatParent)!
            let repeatGrandchild = folderStore.addFolder(named: "Leaf", parentID: repeatChild)!
            let repeatSibling = folderStore.addFolder(named: "Leaf", parentID: repeatParent)!
            folderStore.removeFolder(repeatParent)
            check(folderName(repeatChild) == "Repeat" && folderName(repeatGrandchild) == "Repeat / Leaf" && folderName(repeatSibling) == "Leaf", "child promotion cannot capture another branch after its prefix changes")
            folderStore.saveNow()
            check(folderStore.persistence.load() == folderStore.state, "unique folder paths and preserved memberships survive persistence")
            let favoriteHome = BrowserSpace(name: "Favorite home", emoji: "H", colorHex: "BDB6DD")
            let favoriteActive = BrowserSpace(name: "Favorite active", emoji: "A", colorHex: "AACCDD")
            var favoriteFixture = BrowserState(spaces: [favoriteHome, favoriteActive])
            let homePrimary = favoriteFixture.open(url: "curve://start", title: "Home primary", spaceID: favoriteHome.id)
            let activePrimary = favoriteFixture.open(url: "curve://start", title: "Active primary", spaceID: favoriteActive.id)
            let global = favoriteFixture.open(url: "https://example.org/global", title: "Global", kind: .favorite, spaceID: favoriteHome.id)
            favoriteFixture.select(homePrimary)
            favoriteFixture.spaces[0].splitTabID = global
            favoriteFixture.switchSpace(favoriteActive.id); favoriteFixture.select(global)
            let favoriteStore = BrowserStore(mode: .normal, directory: directory.appendingPathComponent("favorite-menu"), seed: favoriteFixture)
            favoriteStore.focusedPane = global; favoriteStore.toggleFavorite(global)
            check(favoriteStore.state.tabs.first { $0.id == global }?.kind == .pinned && favoriteStore.state.tabs.first { $0.id == global }?.spaceID == favoriteActive.id && favoriteStore.state.selectedTabID == global && favoriteStore.currentID == global && favoriteStore.state.spaces[0].splitTabID == nil, "Remove from Favorites keeps a foreign-space favorite visible and repairs old split references")
            favoriteFixture.spaces[1].selectedTabID = activePrimary; favoriteFixture.spaces[1].splitTabID = global
            let favoritePinStore = BrowserStore(mode: .normal, directory: directory.appendingPathComponent("favorite-shortcut"), seed: favoriteFixture)
            favoritePinStore.focusedPane = global; favoritePinStore.performKeyAction(.togglePin)
            check(favoritePinStore.state.tabs.first { $0.id == global }?.kind == .pinned && favoritePinStore.state.tabs.first { $0.id == global }?.spaceID == favoriteActive.id && favoritePinStore.state.selectedTabID == activePrimary && favoritePinStore.splitID == global && favoritePinStore.currentID == global && favoritePinStore.state.spaces[0].splitTabID == nil, "Command-D on a foreign-space favorite preserves focused split and primary selection")
            favoritePinStore.shutdown(); favoriteStore.shutdown(); folderStore.shutdown()
            clone.shutdown(); target.shutdown(); store.shutdown(); try? FileManager.default.removeItem(at: directory)
            for name in passed { print("PASS \(name)") }; for name in failures { print("FAIL \(name)") }
            print("DragChecks: \(passed.count + failures.count) checks, \(failures.count) failures")
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
    }
}
