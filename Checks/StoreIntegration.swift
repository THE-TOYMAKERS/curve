import AppKit
import Foundation
import WebKit
import BrowserCore

@main
struct StoreIntegration {
    @MainActor static func waitUntil(_ predicate:@escaping ()->Bool) async ->Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds:25_000_000)
        }
        return predicate()
    }
    @MainActor static func main() {
        let app=NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let parent = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) : FileManager.default.temporaryDirectory
            let base = parent.appendingPathComponent("StoreIntegration-\(UUID().uuidString)", isDirectory: true)
            try! FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
            setenv("CURVE_DATA_DIR",base.appendingPathComponent("shared-history").path,1)
            let clipboard=NSPasteboard.general.pasteboardItems?.map { item in
                item.types.reduce(into:[NSPasteboard.PasteboardType:Data]()) { result,type in result[type]=item.data(forType:type) }
            } ?? []
            var passes:[String]=[]
            var failures:[String]=[]
            func check(_ ok:Bool,_ name:String) { if ok {passes.append(name)}else{failures.append(name)} }
            let space=BrowserSpace(name:"Test",emoji:"T",colorHex:"BDB6DD")
            var fixture=BrowserState(spaces:[space])
            let primary=fixture.open(url:"curve://start",title:"Primary")
            let store=BrowserStore(mode:.normal,directory:base.appendingPathComponent("normal"),seed:fixture)
            store.open("https://example.org/split",inSplit:true)
            let secondary=store.splitID!
            check(primary != secondary && store.state.selectedTabID == primary && store.state.tabs.count == 2,"open in split preserves distinct primary and secondary")
            let index=store.state.tabs.firstIndex(where:{$0.id==secondary})!
            store.state.tabs[index].customTitle="Research [notes] \\ ideas"
            store.state.tabs[index].title="Research [notes] \\ ideas"
            store.engine.onPageChanged?(secondary,"Server page title","https://example.org/split")
            check(store.state.tabs.first(where:{$0.id==secondary})?.title == "Research [notes] \\ ideas","custom tab name survives page progress/title callbacks")
            store.saveNow()
            check(store.persistence.load().tabs.first(where:{$0.id==secondary})?.customTitle == "Research [notes] \\ ideas","custom title persists in session file")
            store.focusSplit(2)
            check(store.currentID == secondary && store.state.selectedTabID == primary,"focusSplit targets secondary without replacing primary")
            store.copyURL(markdown:true)
            check(NSPasteboard.general.string(forType:.string) == #"[Research \[notes\] \\ ideas](<https://example.org/split>)"#,"copy Markdown uses focused split with escaped custom title")
            store.focusSplit(1)
            check(store.currentID == primary,"focusSplit returns to primary")
            store.setSplit(nil)
            let beforeClear=Set(store.today.map(\.id))
            store.clearToday()
            let cleared=await waitUntil {store.today.isEmpty}
            check(cleared && Set(store.state.archive.map{$0.tab.id}) == beforeClear,"clear Today archives tabs reversibly")
            let archivedID=store.state.archive.first!.tab.id
            store.restoreLast()
            check(store.state.tabs.count == 1 && store.state.selectedTabID == archivedID,"restoreLast restores identity and selection")
            store.close(archivedID,remove:true)
            check(store.state.tabs.isEmpty && store.state.selectedTabID == nil,"close last tab leaves valid empty start state")
            let hiddenWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            hiddenWindow.isReleasedWhenClosed=false
            store.window=hiddenWindow
            var closed=false
            let observer=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:hiddenWindow,queue:.main){_ in closed=true}
            store.performKeyAction(.closeTab)
            check(closed,"close shortcut closes window when no tabs remain")
            NotificationCenter.default.removeObserver(observer)
            var routes:[String]=[]
            store.onNewWindow={ mode in switch mode {case .normal:routes.append("normal");case .incognito:routes.append("private");case .little:routes.append("little")} }
            store.performKeyAction(.newWindow);store.performKeyAction(.incognitoWindow);store.performKeyAction(.littleArc)
            check(routes == ["normal","private","little"],"new window actions route all three modes")
            store.open("https://example.org/pin",kind:.pinned)
            let pinnedID=store.currentID!
            let pinIndex=store.state.tabs.firstIndex(where:{$0.id==pinnedID})!
            store.state.tabs[pinIndex].url="https://example.org/elsewhere"
            store.close(pinnedID)
            check(store.state.tabs.contains(where:{$0.id==pinnedID && $0.url == "https://example.org/pin"}),"close pinned tab resets saved URL and preserves pin")
            store.close(pinnedID,remove:true)
            check(!store.state.tabs.contains(where:{$0.id==pinnedID}) && store.state.archive.contains(where:{$0.tab.id==pinnedID}),"explicit pin removal is reversible")
            // Space menu operations preserve global favorites while copying or
            // reversibly removing the space's own folders and tab identities.
            let sourceSpace = BrowserSpace(name: "Research", emoji: "R", colorHex: "AABBCC")
            let otherSpace = BrowserSpace(name: "Other", emoji: "O", colorHex: "CCBBAA")
            var menuFixture = BrowserState(spaces: [sourceSpace, otherSpace])
            let sourceFolder = menuFixture.addFolder(name: "Reading", spaceID: sourceSpace.id)
            let sourcePin = menuFixture.open(url: "https://example.org/pinned", title: "Pinned reading", kind: .pinned, spaceID: sourceSpace.id, folderID: sourceFolder)
            let sourceToday = menuFixture.open(url: "https://example.org/today", title: "Today reading", spaceID: sourceSpace.id)
            let globalFavorite = menuFixture.open(url: "https://example.org/favorite", title: "Global favorite", kind: .favorite, spaceID: sourceSpace.id)
            menuFixture.select(sourceToday)
            menuFixture.spaces[0].splitTabID = sourcePin; menuFixture.spaces[0].splitVertical = true
            let menuStore = BrowserStore(mode: .normal, directory: base.appendingPathComponent("space-menus"), seed: menuFixture)
            menuStore.duplicateSpace(sourceSpace.id)
            let copiedSpace = menuStore.activeSpace
            let copiedFolders = menuStore.state.folders.filter { $0.spaceID == copiedSpace.id }
            let copiedTabs = menuStore.state.tabs.filter { $0.spaceID == copiedSpace.id && $0.kind != .favorite }
            let copiedPin = copiedTabs.first { $0.kind == .pinned }
            check(copiedSpace.id != sourceSpace.id && copiedSpace.name == "Research Copy" && copiedSpace.emoji == "R" && copiedSpace.colorHex == "AABBCC", "duplicate Space copies theme with a new identity")
            check(copiedFolders.count == 1 && copiedFolders.first?.id != sourceFolder && copiedFolders.first?.name == "Reading" && copiedPin?.folderID == copiedFolders.first?.id, "duplicate Space remaps copied folders and pinned membership")
            check(copiedTabs.count == 2 && Set(copiedTabs.map(\.id)).isDisjoint(with: [sourcePin, sourceToday]) && Set(copiedTabs.map(\.url)) == ["https://example.org/pinned", "https://example.org/today"], "duplicate Space creates new tab IDs and preserves addresses")
            check(menuStore.state.tabs.filter { $0.kind == .favorite }.map(\.id) == [globalFavorite], "duplicate Space preserves one global favorite")
            check(copiedTabs.contains { $0.id == menuStore.state.selectedTabID }, "duplicate Space selects a copied tab")
            menuStore.removeSpace(sourceSpace.id)
            check(!menuStore.state.spaces.contains { $0.id == sourceSpace.id } && !menuStore.state.folders.contains { $0.id == sourceFolder } && Set(menuStore.state.archive.map { $0.tab.id }).isSuperset(of: [sourcePin, sourceToday]), "remove Space archives its tabs and removes its folders")
            check(menuStore.state.tabs.filter { $0.id == globalFavorite }.count == 1 && menuStore.state.tabs.first { $0.id == globalFavorite }?.spaceID != sourceSpace.id, "remove Space preserves the global favorite")
            menuStore.restoreRemovedSpace()
            check(menuStore.state.spaces.contains { $0.id == sourceSpace.id } && menuStore.state.folders.contains { $0.id == sourceFolder && $0.spaceID == sourceSpace.id } && menuStore.state.tabs.contains { $0.id == sourcePin && $0.folderID == sourceFolder } && menuStore.state.tabs.contains { $0.id == sourceToday }, "restore removed Space restores original folders and tab IDs")
            check(menuStore.state.selectedTabID == sourceToday && menuStore.splitID == sourcePin && menuStore.activeSpace.splitVertical, "restore removed Space preserves original primary split and orientation instead of archive iteration order")
            let restoredTabIDs = menuStore.state.tabs.map(\.id)
            menuStore.restoreRemovedSpace()
            check(menuStore.state.tabs.map(\.id) == restoredTabIDs && Set(restoredTabIDs).count == restoredTabIDs.count, "repeated Space restore does not duplicate tabs")
            let invalidRestore = BrowserStore(mode: .normal, directory: base.appendingPathComponent("invalid-space-restore"), seed: menuFixture)
            invalidRestore.removeSpace(sourceSpace.id)
            invalidRestore.state.archive.removeAll { $0.tab.id == sourceToday || $0.tab.id == sourcePin }
            invalidRestore.restoreRemovedSpace()
            check(invalidRestore.state.activeSpaceID == sourceSpace.id && invalidRestore.state.selectedTabID == nil && invalidRestore.splitID == nil && !invalidRestore.state.tabs.contains { $0.id == sourceToday || $0.id == sourcePin }, "Space restore never revives primary or split references removed from the archive")
            invalidRestore.shutdown()
            menuStore.switchSpace(sourceSpace.id)
            menuStore.select(sourcePin)
            menuStore.focusedPane = sourcePin
            menuStore.move(sourcePin, space: otherSpace.id)
            check(menuStore.focusedPane == nil && menuStore.state.tabs.first { $0.id == sourcePin }?.spaceID == otherSpace.id, "move tab clears stale pane focus")
            menuStore.select(sourceToday)
            menuStore.setSplit(sourcePin)
            check(menuStore.state.activeSpaceID == sourceSpace.id && menuStore.state.selectedTabID == sourceToday && menuStore.splitID == sourcePin && menuStore.state.tabs.first { $0.id == sourcePin }?.spaceID == sourceSpace.id, "foreign Space split moves tab into the active Space")
            menuStore.shutdown()
            let historyBefore=try? Data(contentsOf:store.historyPersistence.historyURL)
            let privateDirectory=base.appendingPathComponent("must-not-be-created")
            let privateStore=BrowserStore(mode:.incognito,directory:privateDirectory)
            privateStore.open("https://private.invalid/secret")
            _ = privateStore.state.addFolder(name: "Private unsaved folder")
            let privateID=privateStore.currentID!
            privateStore.engine.onPageChanged?(privateID,"Private page","https://private.invalid/secret")
            privateStore.saveNow();privateStore.saveSoon()
            try? await Task.sleep(nanoseconds:600_000_000)
            check(!FileManager.default.fileExists(atPath:privateDirectory.path),"private session never writes state directory")
            check((try? Data(contentsOf:store.historyPersistence.historyURL)) == historyBefore,"private visits never change persistent history")
            check(privateStore.history.contains(where:{$0.url == "https://private.invalid/secret"}),"private history exists only in window memory")
            let publicSpace = BrowserSpace(name: "Public seed", emoji: "P", colorHex: "DDEEFF")
            var publicSeed = BrowserState(spaces: [publicSpace])
            let publicSeedID = publicSeed.open(url: "https://example.org/public", title: "Public saved page")
            let sharedDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CURVE_DATA_DIR"]!, isDirectory: true)
            try! StatePersistence(directory: sharedDirectory).save(publicSeed)
            let previousActive = BrowserCoordinator.shared.activeStore
            BrowserCoordinator.shared.activeStore = privateStore
            let normalAfterPrivate = BrowserCoordinator.shared.makeStore(mode: .normal, sessionID: UUID())
            check(normalAfterPrivate.state.tabs.contains { $0.id == publicSeedID } && !normalAfterPrivate.state.tabs.contains { $0.url.contains("private.invalid") }, "new normal window seeds saved normal state while private window is active")
            normalAfterPrivate.saveNow()
            let persistedNormal = normalAfterPrivate.persistence.load()
            check(!persistedNormal.tabs.contains { $0.url.contains("private.invalid") } && persistedNormal.tabs.contains { $0.id == publicSeedID }, "private session never leaks into a new normal window's saved state")
            normalAfterPrivate.shutdown()
            BrowserCoordinator.shared.activeStore = previousActive
            privateStore.shutdown()
            check(privateStore.state.tabs.isEmpty && privateStore.history.isEmpty && privateStore.state.folders.isEmpty && privateStore.engine.liveCount==0,"private shutdown clears in-memory session and engine views")
            store.shutdown()
            NSPasteboard.general.clearContents()
            let items=clipboard.map { representations -> NSPasteboardItem in
                let item=NSPasteboardItem()
                for (type,data) in representations {item.setData(data,forType:type)}
                return item
            }
            if !items.isEmpty {NSPasteboard.general.writeObjects(items)}
            try? FileManager.default.removeItem(at: base)
            print("STORE INTEGRATION \(failures.isEmpty ? "PASS":"FAIL")")
            for name in passes {print("PASS \(name)")}
            for name in failures {print("FAIL \(name)")}
            fflush(stdout)
            exit(failures.isEmpty ? 0:1)
        }
        app.run()
    }
}
