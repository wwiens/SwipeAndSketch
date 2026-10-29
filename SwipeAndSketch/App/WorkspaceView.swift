import SwiftUI
import UniformTypeIdentifiers

// Swipe & Sketch brand palette (Assets.xcassets, "ss-" color sets). Canvas geometry keeps its own
// modeling colors: blue selection, purple guides, gray solids.
private let ink = Color("ss-ink")
private let muted = Color("ss-muted")
private let violet = Color("ss-violet")
private let paper = Color("ss-paper")
private let hairline = Color("ss-border")
private let white = Color("ss-white")
private let coral = Color("ss-coral")
private let lavender = Color("ss-lavender")

struct WorkspaceView: View {
    @ObservedObject var session: ModelingSession
    @StateObject private var assistant: AssistantController
    @StateObject private var keyboard = KeyboardInset()
    /// Swipe & Sketch Pro and purchases (Licensing.swift).
    @ObservedObject private var license = LicenseStore.shared
    @State private var showItems = false
    /// The floating help card opened from the hint, the topic it shows, and where it was dragged.
    @State private var helpTopic: HelpTopic?
    @State private var helpOffset = CGSize.zero
    @State private var helpDragStart: CGSize?
    @State private var helpSize = CGSize.zero
    /// The assistant panel at the right edge, and a request to put the cursor in its field.
    @State private var showAssistant = false
    @State private var assistantFocus = 0
    /// The Files picker for Import STEP, or Import Mesh (STL or 3MF files).
    @State private var importingSTEP = false
    @State private var importingMesh = false
    /// About Swipe & Sketch: version, requirements, and the Open CASCADE notice and licenses.
    @State private var showAbout = false
    /// The dock group whose tools are popped up above it.
    @State private var openGroup: ToolGroup?
    /// Where each dock group tile is, so its tools can pop up above it.
    @State private var groupFrames: [ToolGroup: CGRect] = [:]
    /// Where Pattern's quantity is, so its keypad opens beside it.
    @State private var patternCountFrame = CGRect.zero
    @State private var taperFrame = CGRect.zero
    /// The Model Tree row being renamed, and the name being typed.
    @State private var renaming: ModelSelection?
    @State private var newName = ""
    /// Where a bar's clearance menu sits, for its keypad; and the workspace's size, for the project menu's.
    @State private var clearanceFrame = CGRect.zero
    @State private var threadBarFrame = CGRect.zero
    @State private var workspaceSize = CGSize.zero
    private let itemsWidth: CGFloat = 264
    /// The utility rail at the top left: model tree, snap, assistant, and measure.
    private let railWidth: CGFloat = 80
    private let assistantWidth: CGFloat = 340

    init(session: ModelingSession) {
        self.session = session
        _assistant = StateObject(wrappedValue: AssistantController(session: session))
    }
    /// Sketch tools show while sketching, and from the moment Sketch is tapped (before a plane is picked).
    private var sketching: Bool { (session.sketchMode != nil || session.isPickingPlane) && !session.isExtruding && !session.isRevolving && !session.isFinishing }
    /// An operation is being set up: its own controls replace the dock until Done or Cancel.
    private var operationActive: Bool {
        session.isExtruding || session.isRevolving || session.isFinishing || session.isShelling || session.holeDraft != nil || session.primitiveDraft != nil || session.pegDraft != nil || session.threadDraft != nil || session.screwLidDraft != nil || session.textDraft != nil || session.tool.isPlaneTool || session.tool.isConstructionTool || session.tool.isShapeTool ||
            session.projectionDraft != nil || session.splitDraft != nil || session.mirrorDraft != nil || session.patternDraft != nil || session.unionDraft != nil || session.subtractDraft != nil ||
            session.alignDraft != nil || session.isMeasuring || session.scaleDraft != nil || session.deleteFaceDraft != nil || session.section != nil ||
            session.offsetDraft != nil || session.sketchMirrorDraft != nil
    }

    var body: some View {
        GeometryReader { geometry in
            // The model tree opens beside the utility rail; the tool chrome moves aside to make room.
            let railEdge: CGFloat = 10 + railWidth
            let inset: CGFloat = showItems ? railEdge + itemsWidth + 8 : 0
            let top = max(14, geometry.safeAreaInsets.top + 8)
            // Bottom chrome: the dock, and the selection strip or review bar over it.
            let bottomChrome: CGFloat = session.isReviewingAssistant || session.isAssistantWorking ? 128 : sketching || session.selection != nil ? 160 : 112
            let dockBottom = max(16, geometry.safeAreaInsets.bottom + 14)
            // With room (landscape), the dock moves aside for the model tree; otherwise the tree stops above it.
            let dockMoves = geometry.size.width - inset - 20 >= 660
            // The assistant panel takes the right edge. With room beside it (landscape), the right rail
            // and bottom bar move aside; on a narrow screen it covers the rail and stops above the dock.
            let roomy = geometry.size.width - assistantWidth >= 760
            let trailingInset: CGFloat = showAssistant ? assistantWidth + 9 : 0
            let barInset: CGFloat = roomy ? trailingInset : 0
            let centerPadding: CGFloat = geometry.size.width < 900 ? 150 : 200
            ZStack(alignment: .topLeading) {
                ModelingCanvas(session: session)
                if openGroup != nil {
                    // A tap anywhere else closes the group's pop-up.
                    Color.clear.contentShape(Rectangle()).onTapGesture { withAnimation(.easeOut(duration: 0.15)) { openGroup = nil } }
                        .accessibilityIdentifier("group.dismiss")
                }
                if showItems {
                    itemsPanel.frame(width: itemsWidth).frame(maxHeight: .infinity, alignment: .top)
                        .padding(.leading, railEdge + 8).padding(.top, top)
                        .padding(.bottom, dockMoves ? max(12, geometry.safeAreaInsets.bottom + 6) : dockBottom + bottomChrome)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                VStack(spacing: 10) {
                    // The project tab hangs from the top edge of the screen; the hint floats below it.
                    projectBar(topInset: geometry.safeAreaInsets.top)
                    hintBox
                }
                .frame(maxWidth: .infinity)
                .padding(.leading, showItems ? inset + 20 : centerPadding)
                .padding(.trailing, showAssistant ? trailingInset + (roomy ? centerPadding : 20) : centerPadding)
                utilityRail.padding(.leading, 10).padding(.top, top)
                if !showAssistant || roomy {
                    rightRail.frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 10 + trailingInset).padding(.top, top)
                }
                bottomBar.frame(maxHeight: .infinity, alignment: .bottom).padding(.leading, dockMoves ? inset : 0).padding(.trailing, barInset).padding(.horizontal, 10).padding(.bottom, dockBottom)
                if showAssistant {
                    // Bottom edge: above the software keyboard when it is up; else above the home
                    // indicator, or (narrow screens) above the dock and whatever sits over it.
                    let resting = roomy ? max(12, geometry.safeAreaInsets.bottom + 6) : dockBottom + bottomChrome
                    AssistantPanel(assistant: assistant, session: session, focusRequest: assistantFocus) {
                        withAnimation(.easeOut(duration: 0.2)) { showAssistant = false }
                    }
                    .frame(width: assistantWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, top)
                    .padding(.bottom, max(resting, keyboard.height + 8))
                    .padding(.trailing, 9)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if let topic = helpTopic {
                    HelpPanel(session: session, topic: topic) { translation, ended in
                        let start = helpDragStart ?? helpOffset
                        helpDragStart = ended ? nil : start
                        helpOffset = CGSize(width: start.width + translation.width, height: start.height + translation.height)
                        if ended { helpOffset = helpPlacement(in: geometry.size).offset }
                    } onShowTopic: { helpTopic = $0 } onAllControls: {
                        helpTopic = nil
                        session.showHelp = true
                    } onClose: {
                        withAnimation(.easeOut(duration: 0.15)) { helpTopic = nil }
                    }
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { helpSize = $0 }
                    .position(helpPlacement(in: geometry.size).center)
                    // Palm guard: a hand resting on the card while the Pencil draws presses nothing.
                    .allowsHitTesting(!session.isPencilDown)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(8)
                }
                if let group = openGroup, let frame = groupFrames[group] {
                    // Above its tile, kept on screen.
                    let height = CGFloat(group.tools.count) * 48 + 12 + 8
                    groupMenu(group)
                        .position(x: min(max(frame.midX, 120), geometry.size.width - 120), y: frame.minY - 10 - height / 2)
                        .transition(.opacity).zIndex(5)
                }
                if let edit = session.dimensionEdit {
                    DimensionKeypad(session: session, edit: edit)
                        .id(edit.id)
                        .frame(width: 318)
                        .position(keypadPosition(edit, in: geometry.size))
                        .zIndex(10)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { workspaceSize = $0 }
            .coordinateSpace(name: "workspace")
            .clipped()
        }
        .ignoresSafeArea()
        // The project tab takes the top edge, so the status bar steps aside, as in other full-screen
        // creative apps.
        .statusBarHidden(true)
        .tint(violet)
        .allowsHitTesting(!session.isProjectBusy)
        .sheet(isPresented: $session.showHelp) { ControlsGuide { session.showHelp = false }.presentationSizing(.page) }
        .sheet(isPresented: $showAbout) { AboutView { showAbout = false } }
        // A Keep that opened Purchases is done once Pro is bought, and forgotten if Purchases closes without it.
        .sheet(isPresented: $license.isShowingStore, onDismiss: { session.dropPendingPro() }) { PurchasesView { license.isShowingStore = false } }
        .sheet(item: $session.exportItem) { item in ShareSheet(url: item.url).ignoresSafeArea() }
        .sheet(item: $session.printSheet) { mode in PrintSheet(session: session, mode: mode) }
        .fileImporter(isPresented: Binding(get: { importingSTEP || importingMesh }, set: { if !$0 { importingSTEP = false; importingMesh = false } }),
                      allowedContentTypes: Self.importTypes(mesh: importingMesh)) { result in
            switch result {
            case .success(let url): if ["stl", "3mf"].contains(url.pathExtension.lowercased()) { session.importMesh(from: url) } else { session.importSTEP(from: url) }
            case .failure(let error): session.saveError = "Import failed. \(error.localizedDescription)"
            }
        }
        .alert("Project needs attention", isPresented: Binding(get: { session.saveError != nil }, set: { if !$0 { session.saveError = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(session.saveError ?? "") }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName).accessibilityIdentifier("rename.field")
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") { if let item = renaming { session.rename(item, to: newName) }; renaming = nil }
                .accessibilityIdentifier("rename.confirm")
        } message: { Text("Leave it empty to go back to its number.") }
        .background {
            // Keyboard shortcuts for a hardware keyboard: copy, paste, and duplicate the selection
            // (⌘Z and ⇧⌘Z are on the Undo and Redo buttons).
            Group {
                Button("Copy") { session.copy() }.keyboardShortcut("c", modifiers: .command).disabled(!session.canCopy)
                Button("Paste") { session.paste() }.keyboardShortcut("v", modifiers: .command).disabled(!session.canPaste)
                Button("Duplicate") { session.duplicate() }.keyboardShortcut("d", modifiers: .command).disabled(!session.canCopy || session.isEditingBlocked)
            }
            .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    /// Opens the rename field for a Model Tree row.
    private func beginRename(_ item: ModelSelection) {
        newName = session.name(of: item) ?? ""
        renaming = item
    }

    /// The colors a solid can be given, as a menu.
    private func colorMenu(_ id: UUID, current: BodyColor) -> some View {
        ForEach(BodyColor.allCases, id: \.self) { color in
            Button { session.setColor(color, of: id) } label: {
                Label { Text(color == current ? "\(color.title) (in use)" : color.title) } icon: {
                    Image(uiImage: Self.swatch(color))
                }
            }
            .accessibilityIdentifier("color.\(color.rawValue)")
        }
    }

    /// A small round sample of a color, for menus.
    private static func swatch(_ color: BodyColor) -> UIImage {
        let (r, g, b) = color.rgb
        return UIGraphicsImageRenderer(size: CGSize(width: 18, height: 18)).image { context in
            UIColor(red: r, green: g, blue: b, alpha: 1).setFill()
            let circle = UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 16, height: 16))
            circle.fill()
            UIColor(white: 0, alpha: 0.25).setStroke()
            circle.stroke()
        }.withRenderingMode(.alwaysOriginal)
    }

    /// The hint above the canvas: at most two lines, with a help button that opens the floating help
    /// card for what is being done.
    private var hintBox: some View {
        HStack(spacing: 10) {
            // What the hint is about, in a small lavender tile (not when that is just general help).
            let topicIcon = session.helpTopic.icon
            if topicIcon != .help {
                SSIconGlyph(icon: topicIcon, size: 20, color: violet)
                    .frame(width: 32, height: 32).background(Color("ss-lavender"), in: RoundedRectangle(cornerRadius: 9))
            }
            Text(session.hint)
                .font(.system(size: 15)).foregroundStyle(ink).multilineTextAlignment(.center)
                .lineLimit(2).truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("hint.text")
            Button {
                withAnimation(.easeOut(duration: 0.15)) { helpTopic = helpTopic == nil ? session.helpTopic : nil }
            } label: {
                SSIconGlyph(icon: .help, size: 22, color: helpTopic == nil ? muted : violet).frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Help").accessibilityIdentifier("hint.help")
        }
        .padding(.leading, session.helpTopic.icon == .help ? 22 : 10).padding(.trailing, 10).padding(.vertical, 10)
        .frame(minHeight: 56)
        .background(white.opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(hairline.opacity(0.5)))
        .frame(maxWidth: 540)
    }

    /// Where the help card sits: at the bottom right above the dock,
    /// moved by the user's drag and kept on screen. `offset` is the drag kept within bounds.
    private func helpPlacement(in size: CGSize) -> (center: CGPoint, offset: CGSize) {
        let card = helpSize == .zero ? CGSize(width: HelpPanel.width, height: 320) : helpSize
        let home = CGPoint(x: size.width - 20 - card.width / 2, y: size.height - 190 - card.height / 2)
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { low > high ? (low + high) / 2 : min(max(value, low), high) }
        let x = clamp(home.x + helpOffset.width, card.width / 2 + 8, size.width - card.width / 2 - 8)
        let y = clamp(home.y + helpOffset.height, card.height / 2 + 30, size.height - card.height / 2 - 16)
        return (CGPoint(x: x, y: y), CGSize(width: x - home.x, height: y - home.y))
    }

    /// The project tab, attached to the top edge of the screen: home, the project's name with its save
    /// state and contents underneath, and the project menu.
    private func projectBar(topInset: CGFloat) -> some View {
        HStack(spacing: 16) {
            Button { session.onOpenProjects?() } label: {
                SSIconGlyph(icon: .home, size: 25, color: ink).opacity(session.hasProjectFile ? 1 : 0.35)
            }
            .buttonStyle(.plain).accessibilityLabel("Projects").accessibilityIdentifier("project.home").disabled(!session.hasProjectFile)
            VStack(spacing: 1) {
                Text(session.projectName).font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    .accessibilityIdentifier("project.title")
                HStack(spacing: 4) {
                    Text(session.status).lineLimit(1)
                    Text("·").accessibilityHidden(true)
                    Text(Self.counts(sketches: session.workspace.sketches.count, solids: session.workspace.bodies.count))
                        .lineLimit(1).layoutPriority(1).accessibilityIdentifier("workspace.counts")
                }
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(muted)
            }
            .frame(maxWidth: 260)
            Menu {
                // The usual file order: New and Open, then Save and Save As.
                menuButton("New Project…", icon: .newProject) { session.onNewProject?() }
                    .disabled(!session.hasProjectFile).accessibilityIdentifier("project.new")
                menuButton("Open Project…", icon: .open) { session.onOpenProjects?() }
                    .disabled(!session.hasProjectFile).accessibilityIdentifier("project.open")
                menuButton("Save", icon: .save) { session.save() }
                    .disabled(!session.hasProjectFile || session.isReadOnly).accessibilityIdentifier("project.save")
                menuButton("Save As…", icon: .saveAs) { session.onSaveAs?() }
                    .disabled(!session.hasProjectFile).accessibilityIdentifier("project.saveAs")
                Divider()
                // Out to the printer first, then other files out and in.
                // 3MF is print-ready (named parts on the plate, a preview), so it opens its options first.
                menuButton("Send to Slicer…", icon: .send) { session.printSheet = .send }
                    .disabled(!session.canExport).accessibilityIdentifier("project.sendToSlicer")
                menuButton("Export 3MF…", icon: .export) { session.printSheet = .export }
                    .disabled(!session.canExport).accessibilityIdentifier("project.export.3mf")
                menuButton("Export STL…", icon: .export) { session.export(.stl) }
                    .disabled(!session.canExport).accessibilityIdentifier("project.export.stl")
                menuButton(proTitle("Import STEP…"), icon: .open) { session.withPro { importingSTEP = true } }
                    .disabled(session.isEditingBlocked).accessibilityIdentifier("project.importSTEP")
                menuButton("Import Mesh (STL, 3MF)…", icon: .mesh) { importingMesh = true }
                    .disabled(session.isEditingBlocked).accessibilityIdentifier("project.importMesh")
                Divider()
                // Plain buttons: an inline Picker here keeps the app from ever settling (UI tests wait on it).
                Menu {
                    ForEach(LengthUnit.allCases, id: \.self) { unit in
                        Button(unit == session.lengthUnit ? "\(unit.title) (in use)" : unit.title) { session.lengthUnit = unit }
                    }
                } label: {
                    Label { Text("Units: \(session.lengthUnit.title)") } icon: { Image(SSIcon.measure.assetName).renderingMode(.template) }
                }
                .accessibilityIdentifier("project.units")
                // The gap printed parts leave each other; the Fit Test print is how to find it.
                Menu {
                    ForEach(Fit.Preset.allCases, id: \.self) { preset in
                        let title = session.fitText(preset.clearance)
                        Button(session.fitClearance == preset.clearance ? "\(title) (in use)" : title) { session.setFitClearance(preset.clearance) }
                    }
                    Button(Fit.preset(for: session.fitClearance) == nil ? "Custom · \(session.lengthText(session.fitClearance)) (in use)…" : "Custom…") {
                        session.openDimension(.fitClearance, at: CGPoint(x: workspaceSize.width / 2 - 55, y: workspaceSize.height / 2 + 170))
                    }
                    Divider()
                    menuButton(proTitle("Add a Fit Test Print"), icon: .fitTest) { session.chooseTool(.fitTest) }
                        .accessibilityIdentifier("project.fitTest")
                } label: {
                    Label { Text("Fit Clearance: \(session.fitText(session.fitClearance))") } icon: { Image(SSIcon.fit.assetName).renderingMode(.template) }
                }
                .disabled(session.isEditingBlocked)
                .accessibilityIdentifier("project.fit")
                Divider()
                menuButton("Reset View", icon: .resetView) { session.requestCamera(.reset) }
                menuButton("Controls", icon: .help) { session.showHelp = true }
                menuButton("Your Plan: \(license.access.planName)", icon: .brand) { license.isShowingStore = true }
                    .accessibilityIdentifier("project.plan")
                    .accessibilityIdentifier("project.purchases")
                menuButton("About Swipe & Sketch", icon: .brand) { showAbout = true }.accessibilityIdentifier("project.about")
            } label: { SSIconGlyph(icon: .more, size: 25, color: ink) }
            .accessibilityLabel("Project menu")
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 18 + TopTab.flare).padding(.top, topInset + 4).padding(.bottom, 6).frame(minHeight: 54 + topInset)
        .background {
            TopTab().fill(white).shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                .overlay(TopTab().stroke(hairline.opacity(0.6)))
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("project.tab")
    }

    /// The utility rail at the top left, a small dock of its own, the same in every mode: the two side
    /// panels (Model Tree and Assistant), then the tools that look at the model without changing it
    /// (Measure and Section), then snapping.
    private var utilityRail: some View {
        VStack(spacing: 4) {
            dockTile("Model Tree", icon: .items, selected: showItems, id: "items.toggle") {
                withAnimation(.easeOut(duration: 0.2)) { showItems.toggle() }
                if !showItems { session.endSelectingRows() }
            }
            dockTile("Assistant", icon: .assistant, selected: showAssistant, id: "assistant.toggle") {
                withAnimation(.easeOut(duration: 0.2)) { showAssistant.toggle() }
                // With something selected, it opens ready to ask about it.
                if showAssistant && session.selection != nil { assistantFocus += 1 }
            }
            Rectangle().fill(hairline).frame(width: 40, height: 1).padding(.vertical, 4)
            dockTile("Measure", icon: .measure, selected: session.isMeasuring, id: "tool.measure") {
                openGroup = nil
                if session.isMeasuring { session.endMeasure() } else { session.chooseTool(.measure) }
            }
            .disabled(session.isViewingBlocked)
            dockTile("Section", icon: .section, selected: session.section != nil, id: "section.toggle") {
                openGroup = nil
                session.toggleSection()
            }
            .disabled(session.isViewingBlocked || session.workspace.bodies.isEmpty && session.section == nil)
            dockTile("X-ray", icon: .xray, selected: session.xrayAll, id: "xray.toggle") {
                openGroup = nil
                session.xrayAll.toggle()
            }
            .disabled(session.workspace.bodies.isEmpty && !session.xrayAll)
            dockTile("Snap", icon: session.snapEnabled ? .snapOn : .snapOff, selected: false, id: "snap.toggle",
                     subtitle: session.snapEnabled ? "On" : "Off") { session.snapEnabled.toggle() }
            if !license.access.ownsPro {
                // On the free plan: the way to Your Plan, styled like the PRO marks on the Pro tools.
                Rectangle().fill(hairline).frame(width: 40, height: 1).padding(.vertical, 4)
                Button { openGroup = nil; license.isShowingStore = true } label: {
                    VStack(spacing: 3) {
                        Text("PRO").font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(paper)
                            .frame(width: 43, height: 43).background(violet, in: RoundedRectangle(cornerRadius: 12))
                        Text("Get Pro").font(.system(size: 11, weight: .medium)).foregroundStyle(ink).lineLimit(1)
                    }
                    .frame(minWidth: 54).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Get Swipe & Sketch Pro").accessibilityIdentifier("rail.pro")
            }
        }
        .frame(width: railWidth - 12)
        .padding(.horizontal, 6).padding(.vertical, 8)
        .background(white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(hairline.opacity(0.6)))
        .compositingGroup()
        .shadow(color: .black.opacity(0.1), radius: 10, y: 2)
        .accessibilityElement(children: .contain).accessibilityIdentifier("utility.rail")
    }

    /// The dock at the bottom center: modeling tools, or sketch tools while sketching.
    /// There is no Select tool: with no tool chosen, taps select; tapping the active tool
    /// again puts it down. Group tiles (`ToolGroup`) pop up their tools above them.
    private var dock: some View {
        HStack(alignment: .top, spacing: 4) {
            if sketching {
                dockTile("Finish Sketch", icon: .done, selected: true, id: "sketch.exit") { session.exitSketch() }
                dockDivider
                ForEach([ModelingTool.line, .rectangle], id: \.rawValue) { tool in
                    dockTile(tool.title, icon: tool.icon, selected: session.tool == tool, id: "tool.\(tool.rawValue)",
                             subtitle: tool == .rectangle ? (session.rectangleFromCenter ? "Center" : "Corners") : nil) {
                        // Tapping the active Rectangle switches between corner and center drawing.
                        if tool == .rectangle && session.tool == .rectangle { session.rectangleFromCenter.toggle() } else { toggle(tool) }
                    }
                }
                groupTile(.curves)
                if session.sketchMode?.face != nil {
                    // Features placed on the face: Hole and Peg.
                    groupTile(.faceFeatures)
                }
                dockDivider
                groupTile(.modify)
                dockTile("Dimension", icon: .dimension, selected: session.tool == .dimension, id: "tool.dimension") { toggle(.dimension) }
                dockTile("Project", icon: .project, selected: session.tool == .project, id: "tool.project", pro: !session.ownsPro) { toggle(.project) }
            } else {
                // Left to right, the way a part is made: what to build on (sketches and planes), then
                // solids made, changed, and combined, then moved and copied, then fitted together.
                dockTile("Sketch", icon: .sketch, selected: false, id: "tool.sketch") { session.beginSketch() }
                dockTile("Project", icon: .project, selected: session.tool == .project, id: "tool.project", pro: !session.ownsPro) { toggle(.project) }
                groupTile(.planes)
                dockDivider
                groupTile(.create)
                groupTile(.edges)
                groupTile(.combine)
                dockDivider
                groupTile(.transform)
                groupTile(.fit)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(hairline.opacity(0.6)))
        .compositingGroup()
        .shadow(color: .black.opacity(0.1), radius: 10, y: 2)
        .onChange(of: sketching) { openGroup = nil }
        .accessibilityElement(children: .contain).accessibilityIdentifier("dock")
    }

    /// Picks a tool, or puts the active one down (back to selecting).
    private func toggle(_ tool: ModelingTool) {
        openGroup = nil
        session.chooseTool(session.tool == tool ? .select : tool)
    }

    private var dockDivider: some View {
        Rectangle().fill(hairline).frame(width: 1, height: 40).padding(.horizontal, 4).padding(.top, 2)
    }

    /// A brand tile with its name underneath.
    private func dockTile(_ title: String, icon: SSIcon, selected: Bool, id: String, subtitle: String? = nil, pro: Bool = false,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                BrandTile(icon: icon, selected: selected)
                    .overlay(alignment: .topTrailing) { if pro { ProBadge().offset(x: 8, y: -5) } }
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(ink).lineLimit(1)
                if let subtitle { Text(subtitle).font(.system(size: subtitle == "▴" ? 11 : 9, weight: .semibold)).foregroundStyle(muted).lineLimit(1) }
            }
            .frame(minWidth: 54).contentShape(Rectangle())
        }
        // "▴" marks a group of tools; VoiceOver would read the triangle itself.
        .buttonStyle(.plain).accessibilityLabel(pro ? "\(title), Pro" : title).accessibilityValue(subtitle == "▴" ? "Group of tools" : subtitle ?? "").accessibilityIdentifier(id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A tile standing for a group of tools: it shows the group's tool in use, and pops up the rest.
    private func groupTile(_ group: ToolGroup) -> some View {
        let active = group.tools.contains(session.tool) ? session.tool : nil
        return dockTile(active.map(group.title(for:)) ?? group.title, icon: active?.icon ?? group.icon,
                        selected: active != nil || openGroup == group, id: "tool.\(group.rawValue)", subtitle: "▴") {
            withAnimation(.easeOut(duration: 0.15)) { openGroup = openGroup == group ? nil : group }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("workspace")) } action: { groupFrames[group] = $0 }
    }

    /// A group's tools, popped up above its tile in a card with a pointer down to it: each tool's
    /// colored tile and name, the one in use in Swipe Violet.
    private func groupMenu(_ group: ToolGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(group.tools, id: \.rawValue) { tool in
                let active = session.tool == tool
                Button {
                    // Like a dock tile: tapping the tool in use puts it down.
                    toggle(tool)
                } label: {
                    HStack(spacing: 10) {
                        SSIconGlyph(icon: tool.icon, size: 24, color: active ? paper : ink)
                            .frame(width: 36, height: 36)
                            .background(active ? violet : tool.icon.tileColor, in: RoundedRectangle(cornerRadius: 10))
                        Text(group.title(for: tool)).font(.system(size: 15, weight: .semibold)).foregroundStyle(ink)
                        if tool.isPro && !session.ownsPro { ProBadge() }
                        Spacer(minLength: 12)
                    }
                    .padding(4).frame(minWidth: 168).frame(height: 44)
                    .background(active ? Color("ss-lavender") : .clear, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(tool.isPro && !session.ownsPro ? "\(group.title(for: tool)), Pro" : group.title(for: tool))
                .accessibilityIdentifier("tool.\(tool.rawValue)")
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(6).fixedSize()
        .background(white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(hairline.opacity(0.6)))
        .overlay(alignment: .bottom) {
            // Points down at the group's tile.
            Triangle().fill(white).frame(width: 18, height: 9).offset(y: 8)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.12), radius: 12, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("group.menu")
    }

    /// What the selection offers, in a strip just above the dock (the adaptive menu); while
    /// sketching, the plane being drawn on.
    @ViewBuilder private var contextStrip: some View {
        let content = HStack(spacing: 4) { contextContent }.fixedSize()
        if sketching || session.selection != nil {
            // Too many actions for a narrow screen scroll sideways rather than wrap their names.
            ViewThatFits(in: .horizontal) {
                content
                ScrollView(.horizontal, showsIndicators: false) { content }
            }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(white.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(hairline.opacity(0.5)))
                .accessibilityElement(children: .contain).accessibilityIdentifier("selection.strip")
        }
    }

    /// The strip's contents. Each kind of selection builds its own small view, erased, so no one
    /// SwiftUI type grows deep enough to trouble the Swift runtime on a device (October 21, 2026: one
    /// long if-else chain of many buttons failed in type metadata on an iPad, not in the simulator).
    private var contextContent: some View {
        HStack(spacing: 4) {
            selectionActions
            commonActions
        }
    }

    /// What the selection itself offers.
    private var selectionActions: AnyView {
        // Several regions picked inside an open sketch: Extrude and Revolve take them all.
        if sketching && !session.isMultipleSelection { return AnyView(sketchingActions) }
        if session.isMultipleSelection {
            if session.pickedBodies.count > 1 { return AnyView(pickedBodyActions) }
            if session.pickedEdges.count > 1 { return AnyView(pickedEdgeActions) }
            return AnyView(pickedActions)
        }
        if let plane = session.selectedConstructionPlane { return AnyView(planeActions(plane)) }
        if let face = session.selectedFace { return AnyView(faceActions(face)) }
        if session.selectedEdge != nil { return AnyView(edgeActions) }
        if let body = session.selectedBody { return AnyView(bodyActions(body)) }
        if let sketch = session.selectedSketch { return AnyView(sketchActions(sketch)) }
        if let group = session.selectedGroup { return AnyView(groupActions(group)) }
        if session.canExtrude { return AnyView(regionActions) }
        return AnyView(EmptyView())
    }

    @ViewBuilder private var sketchingActions: some View {
        // What the strokes draw on; informational only.
        stripLabel(session.sketchMode?.title ?? "No active plane", id: "sketch.title")
        if let shape = session.selectedShape, shape.kind != .point {
            // Construction geometry: a dashed reference that bounds no region.
            Toggle(isOn: Binding(get: { shape.isConstruction }, set: { _ in session.toggleConstruction() })) {
                HStack(spacing: 5) { SSIconGlyph(icon: .construction, size: 20, color: ink); Text("Construction").font(.system(size: 14, weight: .medium)) }
            }
            .toggleStyle(.button).accessibilityIdentifier("selection.construction")
        }
        if session.canExtrude {
            // A closed region picked while sketching extrudes or revolves straight from here.
            stripButton("Extrude", icon: .extrude, id: "selection.extrude") { session.beginExtrusion() }
            stripButton("Revolve", icon: .revolve, id: "selection.revolve") { session.beginRevolve() }
        }
    }

    @ViewBuilder private func planeActions(_ plane: ConstructionPlane) -> some View {
        stripLabel("Construction plane")
        stripButton("Sketch", icon: .sketch, id: "selection.sketch") { session.startPlaneSketch(plane) }
        stripButton("Offset Plane", icon: .offsetPlane, id: "selection.offsetPlane") { session.chooseTool(.offsetPlane) }
    }

    @ViewBuilder private func faceActions(_ face: FaceSelection) -> some View {
        if let finish = session.selectedFinish {
            // A fillet's or chamfer's face: its size is on the canvas, and it comes off whole.
            stripLabel(finish.kind.title)
            selectionMeasureLabel
            stripButton("Delete \(finish.kind.title)", icon: .deleteFace, id: "selection.deleteFinish") { session.deleteSelectedFinish() }
                .disabled(!session.canDeleteSelectedFinish)
            stripButton("Shell", icon: .shell, id: "selection.shell", pro: !session.ownsPro) { session.shellSelection() }
        } else {
            AnyView(plainFaceActions(face))
        }
    }

    @ViewBuilder private func plainFaceActions(_ face: FaceSelection) -> some View {
        if let feature = session.selectedFeature {
            // A finished hole, thread, text, or peg reopens in its tool.
            stripLabel(feature.title)
            selectionMeasureLabel
            stripButton("Edit \(feature.title)", icon: featureIcon(feature), id: "selection.editFeature") { session.editSelectedFeature() }
        } else {
            stripLabel(face.plane != nil ? "Flat face" : "Curved face")
            selectionMeasureLabel
        }
        if face.plane != nil {
            AnyView(flatFaceActions)
        }
        // Shell with this face (flat or curved) left open.
        stripButton("Shell", icon: .shell, id: "selection.shell", pro: !session.ownsPro) { session.shellSelection() }
        stripButton("Delete Face", icon: .deleteFace, id: "selection.deleteFace") { session.chooseTool(.deleteFace) }
        if session.canDeleteSelectedHole {
            // A hole's wall: the whole hole goes, with its thread and rim fillets.
            stripButton("Delete Hole", icon: .deleteFace, id: "selection.deleteHole") { session.deleteSelectedHole() }
        }
        if face.plane == nil {
            // A finished thread offers the part that screws onto it; a plain round face, a thread.
            if !session.matingChoices.isEmpty {
                matingMenu
            } else if session.canThreadSelectedFace {
                stripButton("Thread", icon: .thread, id: "selection.thread", pro: !session.ownsPro) { session.beginThread(bodyID: face.bodyID, face: face.face) }
                if session.canScrewLidSelectedFace {
                    stripButton("Screw Lid", icon: .screwLid, id: "selection.screwLid", pro: !session.ownsPro) { session.beginScrewLid(bodyID: face.bodyID, face: face.face) }
                }
            }
        } else {
            AnyView(flatFaceMoreActions)
        }
    }

    private func featureIcon(_ feature: EditableFeature) -> SSIcon {
        switch feature { case .hole: .hole; case .thread: .thread; case .text: .text; case .peg: .peg }
    }

    @ViewBuilder private var flatFaceActions: some View {
        stripButton("Extrude", icon: .extrude, id: "selection.extrudeFace") { session.beginFaceExtrusion() }
            .disabled(!session.canExtrudeSelectedFace)
        stripButton("Revolve", icon: .revolve, id: "selection.revolveFace") { session.beginRevolve() }
            .disabled(!session.canExtrudeSelectedFace)
        stripButton("Sketch", icon: .sketch, id: "selection.sketch") { session.beginFaceSketch() }
            .disabled(!session.canSketchOnSelectedFace)
        stripButton("Text", icon: .text, id: "selection.text", pro: !session.ownsPro) { session.chooseTool(.text) }
            .disabled(!session.canSketchOnSelectedFace)
    }

    @ViewBuilder private var flatFaceMoreActions: some View {
        stripButton("Align", icon: .align, id: "selection.align") { session.chooseTool(.align) }
        stripButton("Offset Plane", icon: .offsetPlane, id: "selection.offsetPlane") { session.chooseTool(.offsetPlane) }
    }

    @ViewBuilder private var edgeActions: some View {
        stripLabel("Edge")
        selectionMeasureLabel
        stripButton("Fillet", icon: .fillet, id: "selection.fillet") { session.finishSelectedEdge(.fillet) }
        stripButton("Chamfer", icon: .chamfer, id: "selection.chamfer") { session.finishSelectedEdge(.chamfer) }
        stripButton("Align", icon: .align, id: "selection.align") { session.chooseTool(.align) }
    }

    /// A solid's actions, in the dock's order: Modify (Shell, Split Body), Combine, Transform, Joints,
    /// then its color and a copy.
    @ViewBuilder private func bodyActions(_ body: SolidBody) -> some View {
        // The hint already says a solid is selected, so its size stands alone (VoiceOver still hears the kind).
        if let measure = session.selectionMeasure { measureLabel(measure, kind: "Solid body") } else { stripLabel("Solid body") }
        stripButton("Shell", icon: .shell, id: "selection.shell", pro: !session.ownsPro) { session.shellSelection() }
        stripButton("Split Body", icon: .split, id: "selection.split", pro: !session.ownsPro) { session.chooseTool(.split) }
        if session.workspace.bodies.count > 1 { AnyView(combineMenu) }
        AnyView(transformMenu(solid: true))
        if !session.matingChoices.isEmpty { matingMenu }
        if let feature = session.selectedFeature {
            // A separate peg's pin.
            stripButton("Edit \(feature.title)", icon: featureIcon(feature), id: "selection.editFeature") { session.editSelectedFeature() }
        }
        Menu { colorMenu(body.id, current: body.color ?? .gray) } label: { StripLabel(title: "Color", icon: .color, showsMenu: true) }
            .accessibilityLabel("Color").accessibilityIdentifier("selection.color")
    }

    /// Union, Subtract, and Intersect share one menu, like the dock's Combine group.
    private var combineMenu: some View {
        Menu {
            menuButton("Union", icon: .merge) { session.chooseTool(.union) }.accessibilityIdentifier("selection.union")
            menuButton("Subtract", icon: .subtract) { session.chooseTool(.subtract) }.accessibilityIdentifier("selection.subtract")
            menuButton("Intersect", icon: .intersect) { session.chooseTool(.intersect) }.accessibilityIdentifier("selection.intersect")
        } label: {
            StripLabel(title: "Combine", icon: .merge, showsMenu: true)
        }
        .accessibilityLabel("Combine").accessibilityIdentifier("selection.combine")
    }

    /// Align (solids only), Scale, Mirror, and Pattern share one menu, like the dock's Transform group.
    private func transformMenu(solid: Bool) -> some View {
        Menu {
            if solid {
                menuButton("Align", icon: .align) { session.chooseTool(.align) }.accessibilityIdentifier("selection.align")
            }
            menuButton("Scale", icon: .scale) { session.chooseTool(.scale) }.accessibilityIdentifier("selection.scale")
            menuButton("Mirror", icon: .mirror) { session.chooseTool(.mirror) }.accessibilityIdentifier("selection.mirror")
            menuButton(proTitle("Pattern"), icon: .pattern) { session.chooseTool(.pattern) }.accessibilityIdentifier("selection.pattern")
        } label: {
            StripLabel(title: "Transform", icon: .align, showsMenu: true)
        }
        .accessibilityLabel("Transform").accessibilityIdentifier("selection.transform")
    }

    /// A Model Tree group: everything in it moves with the widget, and transforms and exports
    /// together (Duplicate is in its row's menu).
    @ViewBuilder private func groupActions(_ id: UUID) -> some View {
        let contents = session.workspace.contents(of: id)
        stripLabel(session.workspace.groupNames[id] ?? "Group", id: "selection.groupName")
        if !(contents.bodies.isEmpty && contents.sketches.isEmpty) {
            AnyView(transformMenu(solid: false))
        }
        if !contents.bodies.isEmpty {
            stripButton("Export", icon: .export, id: "selection.export") { session.printSheet = .export }
        }
    }

    @ViewBuilder private func sketchActions(_ sketch: Sketch) -> some View {
        stripLabel(session.sketchName(of: sketch.id) ?? "Sketch", id: "selection.sketchName")
        if session.canExtrude {
            // Every region of the sketch at once.
            stripButton("Extrude", icon: .extrude, id: "selection.extrude") { session.beginExtrusion() }
            stripButton("Revolve", icon: .revolve, id: "selection.revolve") { session.beginRevolve() }
        }
        AnyView(transformMenu(solid: false))
    }

    /// Several solids picked together: they combine, transform, color, export, and delete together.
    @ViewBuilder private var pickedBodyActions: some View {
        let ids = session.pickedBodies
        stripLabel(session.pickedSummary, id: "selection.pickedCount")
        AnyView(combineMenu)
        AnyView(transformMenu(solid: true))
        Menu {
            ForEach(BodyColor.allCases, id: \.self) { color in
                Button { session.setColor(color, of: ids) } label: {
                    Label { Text(color.title) } icon: { Image(uiImage: Self.swatch(color)) }
                }
                .accessibilityIdentifier("color.\(color.rawValue)")
            }
        } label: { StripLabel(title: "Color", icon: .color, showsMenu: true) }
            .accessibilityLabel("Color").accessibilityIdentifier("selection.color")
        stripButton("Export", icon: .export, id: "selection.export") { session.printSheet = .export }
    }

    /// Several edges of one solid picked together: Fillet and Chamfer take them all.
    @ViewBuilder private var pickedEdgeActions: some View {
        stripLabel(session.pickedSummary, id: "selection.pickedCount")
        stripButton("Fillet", icon: .fillet, id: "selection.fillet") { session.finishSelectedEdge(.fillet) }
        stripButton("Chamfer", icon: .chamfer, id: "selection.chamfer") { session.finishSelectedEdge(.chamfer) }
    }

    /// Several sketch regions and whole sketches picked together: Extrude and Revolve take them all.
    @ViewBuilder private var pickedActions: some View {
        stripLabel(session.pickedSummary, id: "selection.pickedCount")
        stripButton("Extrude", icon: .extrude, id: "selection.extrude") { session.beginExtrusion() }
        stripButton("Revolve", icon: .revolve, id: "selection.revolve") { session.beginRevolve() }
    }

    @ViewBuilder private var regionActions: some View {
        // A region with holes says so: extruding it leaves the shapes inside open.
        let holes = session.selectedProfile?.holes?.count ?? 0
        stripLabel(holes == 0 ? "Region" : "Region · \(holes) \(holes == 1 ? "hole" : "holes")")
        stripButton("Extrude", icon: .extrude, id: "selection.extrude") { session.beginExtrusion() }
        stripButton("Revolve", icon: .revolve, id: "selection.revolve") { session.beginRevolve() }
    }

    /// Create Copy for the Move/Rotate widget, and Delete for whole items.
    @ViewBuilder private var commonActions: some View {
        if session.transformWidgetTarget != nil {
            // Move/Rotate widget option: each drag makes a copy, until turned off.
            Toggle("Create Copy", isOn: $session.transformCopies)
                .toggleStyle(.button).font(.system(size: 14, weight: .medium))
                .accessibilityIdentifier("transform.copy")
        }
        // Measure and the assistant work on the selection from the utility rail, so the strip leaves them out.
        if session.canDeleteSelection {
            // Whole items only: a face or edge belongs to its solid. The trash glyph alone, in Coral; VoiceOver reads Delete.
            Button { session.deleteSelection() } label: {
                SSIconGlyph(icon: .delete, size: 20, color: coral)
                    .frame(width: 36, height: 36)
                    .background(Color("ss-neutral"), in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Delete").accessibilityIdentifier("selection.delete")
        }
    }

    /// The parts that screw onto the selected thread, the likelier first.
    private var matingMenu: some View {
        Menu {
            ForEach(session.matingChoices, id: \.self) { kind in
                menuButton(kind.title, icon: .thread) { session.makeMatingPart(kind) }.accessibilityIdentifier("selection.mate.\(kind.rawValue)")
            }
        } label: {
            StripLabel(title: "Matching Part", icon: .thread, showsMenu: true, pro: !session.ownsPro)
        }
        .disabled(session.isMakingMatingPart)
        .accessibilityLabel(session.ownsPro ? "Matching Part" : "Matching Part, Pro").accessibilityIdentifier("selection.matingPart")
    }

    /// The selected edge's, face's, or solid's size, shown as soon as it is selected.
    @ViewBuilder private var selectionMeasureLabel: some View {
        if let measure = session.selectionMeasure { measureLabel(measure, kind: nil) }
    }

    /// `kind` names what was measured for VoiceOver when no label beside the value says so.
    private func measureLabel(_ measure: String, kind: String?) -> some View {
        Text(measure).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(ink)
            .padding(.horizontal, 8).accessibilityIdentifier("selection.measure")
            .accessibilityLabel(kind.map { "\($0), \(measure)" } ?? measure)
    }

    private func stripLabel(_ text: String, id: String? = nil) -> some View {
        Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(muted)
            .padding(.horizontal, 8).accessibilityIdentifier(id ?? "selection.kind")
    }

    /// A compact action: glyph and name side by side.
    private func stripButton(_ title: String, icon: SSIcon, id: String, pro: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { StripLabel(title: title, icon: icon, pro: pro) }
            .buttonStyle(.plain).accessibilityLabel(pro ? "\(title), Pro" : title).accessibilityIdentifier(id)
    }

    /// A menu item's name, marked when it is a Pro tool and Pro is not owned.
    private func proTitle(_ title: String) -> String { session.ownsPro ? title : "\(title) · Pro" }

    /// A Pro operation's Done: without Pro it offers to keep the result with Pro.
    private var proDone: String { session.ownsPro ? "Done" : "Keep with Pro" }

    /// Every solid and sketch: the Model Tree. Tapping a row selects it, including
    /// sketches hidden behind solids or drawn on another plane.
    private var itemsPanel: some View {
        let groups = session.itemGroups
        return VStack(spacing: 0) {
            ZStack(alignment: .trailing) {
                Text("Model Tree").font(.system(size: 17, weight: .semibold)).foregroundStyle(ink).frame(maxWidth: .infinity)
                // Select puts checkmarks on the rows, to act on several at once; Done ends it.
                Button(session.isSelectingRows ? "Done" : "Select") {
                    if session.isSelectingRows { session.endSelectingRows() } else { session.beginSelectingRows() }
                }
                .font(.system(size: 16, weight: .medium)).foregroundStyle(violet)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 14)
                .disabled(!session.isSelectingRows && (groups.isEmpty || !session.canEditGroups))
                .accessibilityIdentifier("items.select")
                HStack(spacing: 0) {
                    // A new, empty group at the top of the tree, ready to name.
                    Button {
                        if let id = session.newGroup() { beginRename(.group(id)) }
                    } label: { SSIconGlyph(icon: .groupAdd, size: 22, color: ink).frame(width: 44, height: 44) }
                        .buttonStyle(.plain).disabled(!session.canEditGroups || session.isSelectingRows)
                        .accessibilityLabel("New Group").accessibilityIdentifier("items.newGroup")
                    if session.canPaste && !session.isSelectingRows {
                        // Paste the copied solids or sketches, in this project or another.
                        Button { session.paste() } label: { SSIconGlyph(icon: .paste, size: 22, color: ink).frame(width: 44, height: 44) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(session.pasteTitle).accessibilityIdentifier("items.paste")
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(height: 50)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if groups.isEmpty {
                        Text("Sketches and solids you create appear here.").font(.system(size: 14)).foregroundStyle(muted)
                            .padding(12)
                    }
                    ForEach(groups) { group in
                        Text(group.title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 12).padding(.top, 12).padding(.bottom, 2)
                            // A row dropped on Bodies, Planes, or Sketches leaves its group.
                            .dropDestination(for: String.self) { rows, _ in
                                guard group.title != "Groups" else { return }
                                for row in rows { session.moveDropped(row, toGroup: nil) }
                            }
                        ForEach(group.items) { itemRow($0) }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
            if session.isSelectingRows { pickedBar }
        }
        .background(white, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(hairline.opacity(0.6)))
        .compositingGroup()
        .shadow(color: .black.opacity(0.08), radius: 10, y: 2)
        .disabled(!session.canSelectItems)
        .accessibilityIdentifier("items.panel")
    }

    private func itemRow(_ item: ModelItem) -> AnyView {
        if case .group(let id) = item.selection { return groupRow(item, id: id) }
        let picking = session.isSelectingRows
        let selected = !picking && session.isHighlighted(item)
        // Off the canvas by its own eye or a hidden group's.
        let hidden = item.isOffCanvas
        // While picking rows, a shape follows its sketch's row and takes no checkmark of its own.
        let isShape = if case .shape = item.selection { true } else { false }
        return AnyView(HStack(spacing: 4) {
            Button { picking ? session.togglePicked(item.selection) : session.selectItem(item.selection) } label: {
                HStack(spacing: 12) {
                    if picking && !isShape { checkmark(session.isPicked(item.selection)) }
                    SSIconGlyph(icon: item.icon, size: 22, color: selected ? paper : ink)
                    Text(item.name).font(.system(size: 16)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(selected ? paper : ink)
                .opacity(hidden ? 0.45 : session.canSelectItems || selected ? 1 : 0.4)
                .padding(.leading, 12 + CGFloat(item.indent) * 22).padding(.trailing, 12).frame(height: 44)
                .background(selected ? violet : picking && session.isPicked(item.selection) ? lavender : .clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            // Hidden items cannot be selected on the canvas, but can be picked to group or show them.
            .buttonStyle(.plain).disabled(picking ? isShape : hidden).accessibilityLabel(item.name).accessibilityIdentifier("item.\(item.name)")
            .accessibilityAddTraits(selected || picking && session.isPicked(item.selection) ? .isSelected : [])
            .contextMenu { itemMenu(item) }
            if let isHidden = item.isHidden {
                eyeButton(item, hidden: isHidden)
            }
        }
        .draggable(item.id))
    }

    /// Eye glyphs from the brand icon family: open when shown, slashed when hidden. Inside a hidden
    /// group the eye is faded: it keeps the item's own setting for when the group is shown.
    private func eyeButton(_ item: ModelItem, hidden: Bool) -> some View {
        Button { session.toggleHidden(item.selection) } label: {
            SSIconGlyph(icon: hidden ? .hidden : .visible, size: 22, color: hidden ? muted : ink)
                .opacity(item.isHiddenByGroup ? 0.4 : 1)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!session.canToggleVisibility)
        .accessibilityLabel("\(hidden ? "Show" : "Hide") \(item.name)")
        .accessibilityValue(item.isHiddenByGroup ? "In a hidden group" : "")
        .accessibilityIdentifier("item.visibility.\(item.name)")
    }

    /// A group's row: a disclosure arrow and the group's name fold its contents away or show them,
    /// the eye hides or shows everything in it, and rows dropped on it move into it.
    private func groupRow(_ item: ModelItem, id: UUID) -> AnyView {
        let picking = session.isSelectingRows, picked = session.isPicked(item.selection)
        let selected = !picking && session.isHighlighted(item)
        return AnyView(HStack(spacing: 4) {
            // The arrow folds the group away or shows its contents; the rest of the row selects the
            // group (everything in it), or picks it in Select mode.
            Button { session.toggleGroupCollapsed(id) } label: {
                SSIconGlyph(icon: .disclosure, size: 16, color: muted).rotationEffect(.degrees(item.isCollapsed ? 0 : 90))
                    .frame(width: 30, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.leading, CGFloat(item.indent) * 22)
            .accessibilityLabel(item.isCollapsed ? "Expand \(item.name)" : "Collapse \(item.name)")
            .accessibilityIdentifier("group.fold.\(item.name)")
            Button { picking ? session.togglePicked(item.selection) : session.selectItem(item.selection) } label: {
                HStack(spacing: 8) {
                    if picking { checkmark(picked) }
                    SSIconGlyph(icon: .group, size: 22, color: selected ? paper : ink)
                    Text(item.name).font(.system(size: 16, weight: .medium)).lineLimit(1)
                    Text("\(item.memberCount ?? 0)").font(.system(size: 13).monospacedDigit()).foregroundStyle(selected ? paper.opacity(0.8) : muted)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(selected ? paper : ink)
                .opacity(item.isOffCanvas ? 0.45 : 1)
                .padding(.leading, 2).padding(.trailing, 12).frame(height: 44)
                .background(selected ? violet : picking && picked ? lavender : .clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            // A hidden group, like a hidden item, is not on the canvas to select (it can still be picked).
            .buttonStyle(.plain).disabled(!picking && item.isHidden == true)
            .accessibilityLabel("\(item.name), group of \(item.memberCount ?? 0)")
            .accessibilityValue(picking ? (picked ? "Selected" : "") : selected ? "Selected" : item.isCollapsed ? "Collapsed" : "Expanded")
            .accessibilityHint(picking ? "" : "Selects everything in it")
            .accessibilityAddTraits(selected || picking && picked ? .isSelected : [])
            .accessibilityIdentifier("item.\(item.name)")
            .contextMenu { groupMenu(item, id: id) }
            eyeButton(item, hidden: item.isHidden == true)
        }
        .draggable(item.id)
        .dropDestination(for: String.self) { rows, _ in
            for row in rows where row != item.id { session.moveDropped(row, toGroup: id) }
        })
    }

    /// A row's checkmark while picking rows: an empty ring, or a filled one with a tick.
    private func checkmark(_ on: Bool) -> some View {
        ZStack {
            Circle().fill(on ? violet : .clear)
            Circle().stroke(on ? violet : muted, lineWidth: 1.5)
            if on { SSIconGlyph(icon: .done, size: 14, color: paper) }
        }
        .frame(width: 22, height: 22)
    }

    /// The actions for the picked rows, at the foot of the Model Tree: group them, move them, hide
    /// or show them, or delete them.
    private var pickedBar: some View {
        let none = session.pickedRows.isEmpty
        let hide = session.pickedIncludeShown
        return VStack(spacing: 0) {
            Divider().overlay(hairline)
            HStack(spacing: 2) {
                Text(session.pickedTitle).font(.system(size: 14, weight: .medium)).foregroundStyle(none ? muted : ink)
                    .lineLimit(1).fixedSize().accessibilityIdentifier("items.picked")
                Spacer(minLength: 4)
                pickedAction("Group", icon: .groupAdd, id: "items.picked.group") {
                    if let id = session.groupPicked() { beginRename(.group(id)) }
                }
                Menu {
                    ForEach(session.pickedGroupChoices, id: \.id) { choice in
                        Button(choice.title) { session.movePicked(toGroup: choice.id) }
                    }
                    Button("Out of Their Groups") { session.movePicked(toGroup: nil) }
                } label: { pickedLabel("Move", icon: .group) }
                .disabled(none || !session.canEditGroups).accessibilityLabel("Move to Group").accessibilityIdentifier("items.picked.move")
                pickedAction(hide ? "Hide" : "Show", icon: hide ? .hidden : .visible, id: "items.picked.visibility") {
                    session.setPickedHidden(hide)
                }
                .disabled(!session.canToggleVisibility)
                pickedAction("Delete", icon: .delete, color: coral, id: "items.picked.delete") { session.deletePicked() }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .disabled(none)
        }
    }

    private func pickedAction(_ title: String, icon: SSIcon, color: Color? = nil, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { pickedLabel(title, icon: icon, color: color) }
            .buttonStyle(.plain).disabled(!session.canEditGroups).accessibilityLabel(title).accessibilityIdentifier(id)
    }

    private func pickedLabel(_ title: String, icon: SSIcon, color: Color? = nil) -> some View {
        VStack(spacing: 2) {
            SSIconGlyph(icon: icon, size: 22, color: color ?? ink)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(color ?? ink)
        }
        .frame(width: 52, height: 48).contentShape(Rectangle())
    }

    /// Move to Group: a new group, any other group, or out to the top of the tree.
    @ViewBuilder private func moveToGroupMenu(_ item: ModelSelection) -> some View {
        let current = session.group(of: item)
        Menu {
            Button {
                if let id = session.newGroup(containing: item) { beginRename(.group(id)) }
            } label: { Label { Text("New Group") } icon: { SSIconGlyph(icon: .groupAdd, size: 20, color: ink) } }
            ForEach(session.groupChoices(for: item).filter { $0.id != current }, id: \.id) { choice in
                Button(choice.title) { session.move(item, toGroup: choice.id) }
            }
            if current != nil {
                Button("Out of Its Group") { session.move(item, toGroup: nil) }
            }
        } label: { Label { Text("Move to Group") } icon: { SSIconGlyph(icon: .group, size: 20, color: ink) } }
        .disabled(!session.canEditGroups)
    }

    /// A group row's menu (a long press): rename, a group inside it, move, duplicate, ungroup, and delete.
    @ViewBuilder private func groupMenu(_ item: ModelItem, id: UUID) -> some View {
        Button { beginRename(item.selection) } label: { Label { Text("Rename…") } icon: { SSIconGlyph(icon: .rename, size: 20, color: ink) } }
            .accessibilityIdentifier("group.rename")
        if !session.workspace.contents(of: id).bodies.isEmpty {
            Button { session.toggleXray(item.selection) } label: {
                Label { Text(session.isXrayed(item.selection) ? "Turn Off X-ray" : "X-ray") } icon: { SSIconGlyph(icon: .xray, size: 20, color: ink) }
            }
            .accessibilityIdentifier("item.xray")
        }
        Button {
            if let child = session.newGroup(in: id) { beginRename(.group(child)) }
        } label: { Label { Text("New Group Inside") } icon: { SSIconGlyph(icon: .groupAdd, size: 20, color: ink) } }
            .disabled(!session.canEditGroups)
        moveToGroupMenu(item.selection)
        if !(session.workspace.contents(of: id).bodies.isEmpty && session.workspace.contents(of: id).sketches.isEmpty) {
            Button { session.duplicate(item.selection) } label: { Label { Text("Duplicate") } icon: { SSIconGlyph(icon: .copy, size: 20, color: ink) } }
                .disabled(session.isEditingBlocked).accessibilityIdentifier("group.duplicate")
        }
        Button { session.ungroup(id) } label: {
            Label { Text("Ungroup") } icon: { SSIconGlyph(icon: .ungroup, size: 20, color: ink) }
        }
        .disabled(!session.canEditGroups).accessibilityIdentifier("group.ungroup")
        Button(role: .destructive) { session.deleteGroup(id) } label: {
            Label { Text("Delete Group and Contents") } icon: { SSIconGlyph(icon: .delete, size: 20, color: coral) }
        }
        .disabled(!session.canEditGroups).accessibilityIdentifier("group.delete")
    }

    /// A Model Tree row's menu (a long press): rename, color, copy, duplicate, and delete.
    @ViewBuilder private func itemMenu(_ item: ModelItem) -> some View {
        switch item.selection {
        case .body, .sketch, .plane:
            Button { beginRename(item.selection) } label: { Label { Text("Rename…") } icon: { SSIconGlyph(icon: .rename, size: 20, color: ink) } }
                .disabled(!session.canChangeRows).accessibilityIdentifier("item.rename")
        default: EmptyView()
        }
        if case .body(let id) = item.selection, let body = session.workspace.bodies.first(where: { $0.id == id }) {
            Menu { colorMenu(id, current: body.color ?? .gray) } label: { Label { Text("Color") } icon: { SSIconGlyph(icon: .color, size: 20, color: ink) } }
                .disabled(!session.canChangeRows)
        }
        switch item.selection {
        case .body, .group:
            // See this solid (or a group's solids) through, to look inside.
            Button { session.toggleXray(item.selection) } label: {
                Label { Text(session.isXrayed(item.selection) ? "Turn Off X-ray" : "X-ray") } icon: { SSIconGlyph(icon: .xray, size: 20, color: ink) }
            }
            .accessibilityIdentifier("item.xray")
        default: EmptyView()
        }
        switch item.selection {
        case .body, .sketch, .plane: moveToGroupMenu(item.selection)
        default: EmptyView()
        }
        switch item.selection {
        case .body, .sketch:
            Button { session.copy(item.selection) } label: { Label { Text("Copy") } icon: { SSIconGlyph(icon: .copy, size: 20, color: ink) } }
            Button { session.duplicate(item.selection) } label: { Label { Text("Duplicate") } icon: { SSIconGlyph(icon: .copy, size: 20, color: ink) } }
        default: EmptyView()
        }
        if session.canPaste {
            Button { session.paste() } label: { Label { Text(session.pasteTitle) } icon: { SSIconGlyph(icon: .paste, size: 20, color: ink) } }
        }
        switch item.selection {
        case .body, .sketch, .plane:
            Button(role: .destructive) { session.deleteItem(item.selection) } label: {
                Label { Text("Delete") } icon: { SSIconGlyph(icon: .delete, size: 20, color: coral) }
            }
            .disabled(!session.canChangeRows)
        default: EmptyView()
        }
    }

    /// The file types Import STEP (or Import Mesh) offers: whatever this iPad calls the extensions,
    /// plus the app's own declarations (Info.plist), so the files are never greyed out in the picker.
    static func importTypes(mesh: Bool) -> [UTType] {
        let extensions = mesh ? ["stl", "3mf"] : ["step", "stp"]
        let declared = (mesh ? ["stl", "3mf"] : ["step"]).compactMap { UTType("noventix.SwipeAndSketch.\($0)") }
        var types: [UTType] = []
        for type in extensions.compactMap({ UTType(filenameExtension: $0, conformingTo: .data) }) + declared where !types.contains(type) {
            types.append(type)
        }
        return types
    }

    /// "1 sketch · 2 solids": sketch objects (not shapes) and solids.
    static func counts(sketches: Int, solids: Int) -> String {
        "\(sketches) \(sketches == 1 ? "sketch" : "sketches") · \(solids) \(solids == 1 ? "solid" : "solids")"
    }

    /// The view cube, the only view control, with the grid spacing under it.
    private var rightRail: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ViewCube(session: session).frame(width: 112, height: 112)
            Text("Grid \(session.lengthText(session.gridSpacing))").font(.system(size: 11).monospacedDigit()).foregroundStyle(muted)
                .padding(.horizontal, 8).padding(.vertical, 3).background(white.opacity(0.7), in: Capsule())
        }
    }

    /// An operation's own controls, in place of the dock (part 1 of 4: split so no one SwiftUI type nests too deep).
    @ViewBuilder private var operationControls: some View {
        if session.isExtruding {
            VStack(spacing: 8) {
                if session.faceExtrusion != nil {
                    // A face extrusion follows the drag: out of the solid joins, into it cuts.
                    Text(abs(session.extrusionDepth) < 0.01 ? "Face" : session.extrusionMode.title)
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(ink)
                        .padding(.horizontal, 14).frame(height: 32)
                        .background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("extrusion.faceMode")
                } else {
                    HStack(spacing: 7) {
                        Picker("Operation", selection: Binding(get: { session.extrusionMode }, set: { session.chooseExtrusionMode($0) })) {
                            ForEach(ExtrusionMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).frame(width: 270)
                        .accessibilityIdentifier("extrusion.mode")
                        if session.extrusionMode == .cut {
                            Toggle("Through All", isOn: $session.cutThroughAll)
                                .toggleStyle(.button).font(.system(size: 15, weight: .medium))
                                .accessibilityIdentifier("extrusion.throughAll")
                        }
                    }
                    .padding(6).background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
                    // The Extrude options: both ways, a taper, up to a face, and how many regions.
                    HStack(spacing: 7) {
                        Toggle(isOn: $session.extrusionSymmetric) { optionLabel("Symmetric", icon: .symmetric) }
                            .toggleStyle(.button).accessibilityIdentifier("extrusion.symmetric")
                        Button {
                            session.openDimension(.extrusionTaper, at: CGPoint(x: taperFrame.midX - 55, y: taperFrame.minY - 20))
                        } label: {
                            optionLabel("Taper \(formatted(session.extrusionTaper))°", icon: .taper)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(violet, lineWidth: session.extrusionTaper == 0 ? 0 : 1.2))
                        }
                        .accessibilityLabel("Taper").accessibilityValue("\(formatted(session.extrusionTaper)) degrees").accessibilityIdentifier("extrusion.taper")
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("workspace")) } action: { taperFrame = $0 }
                        Toggle(isOn: $session.isPickingExtrusionTarget) { optionLabel("Up To", icon: .extrudeTo) }
                            .toggleStyle(.button).accessibilityIdentifier("extrusion.upTo")
                        if session.extrusionProfiles.count > 1 {
                            Text("Regions · \(session.extrusionProfiles.count)").font(.system(size: 15, weight: .medium)).foregroundStyle(ink)
                                .padding(.horizontal, 6).accessibilityIdentifier("extrusion.regions")
                        }
                    }
                    .disabled(session.extrusionMode == .cut && session.cutThroughAll)
                    .padding(6).background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
                }
                HStack(spacing: 8) {
                    actionButton("Cancel", icon: .exit, id: "extrusion.cancel") { session.cancelExtrusion() }
                    actionButton("Done", icon: .done, id: "extrusion.confirm") { session.confirmExtrusion() }
                        .disabled(!session.canConfirmExtrusion)
                }
            }
        } else if let draft = session.revolveDraft {
            VStack(spacing: 8) {
                if draft.face != nil {
                    // A face revolve follows the sweep: into the solid cuts, out of it joins.
                    Text(abs(draft.angle) < 0.1 ? "Face" : draft.mode.title)
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(ink)
                        .padding(.horizontal, 14).frame(height: 32)
                        .background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("revolve.faceMode")
                } else if draft.axis != nil {
                    Picker("Operation", selection: Binding(get: { draft.mode }, set: { session.chooseRevolveMode($0) })) {
                        ForEach(ExtrusionMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 270)
                    .padding(6).background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("revolve.mode")
                }
                HStack(spacing: 8) {
                    actionButton("Cancel", icon: .exit, id: "revolve.cancel") { session.cancelRevolve() }
                    actionButton("Done", icon: .done, id: "revolve.confirm") { session.confirmRevolve() }
                        .disabled(!session.canConfirmRevolve)
                }
            }
        } else if let draft = session.alignDraft {
            VStack(spacing: 8) {
                HStack(spacing: 7) {
                    // Three steps: the solids that move, then what on them goes where.
                    Picker("Pick", selection: Binding(get: { draft.step }, set: { session.chooseAlignStep($0) })) {
                        Text(draft.bodies.isEmpty ? "Bodies" : "Bodies · \(draft.bodies.count)").tag(AlignDraft.Step.bodies)
                        Text("From").tag(AlignDraft.Step.from)
                        Text("To").tag(AlignDraft.Step.to)
                    }
                    .pickerStyle(.segmented).frame(width: 300).accessibilityIdentifier("align.step")
                    Toggle("Flip", isOn: Binding(get: { draft.flip }, set: { session.setAlignFlip($0) }))
                        .toggleStyle(.button).font(.system(size: 15, weight: .medium)).accessibilityIdentifier("align.flip")
                        .disabled((session.alignPreview == nil && !draft.flip) || draft.to?.kind == .point)
                }
                .padding(6).background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 8) {
                    actionButton("Cancel", icon: .exit, id: "align.cancel") { session.cancelAlign() }
                    actionButton("Done", icon: .done, id: "align.confirm") { session.confirmAlign() }
                        .disabled(session.alignPreview == nil)
                }
            }
        } else if let draft = session.subtractDraft {
            VStack(spacing: 8) {
                HStack(spacing: 7) {
                    // Two picks: the targets (purple), then the solids taken away (blue).
                    Picker("Pick", selection: Binding(get: { draft.step }, set: { session.chooseSubtractStep($0) })) {
                        Text(draft.targets.isEmpty ? "Targets" : "Targets · \(draft.targets.count)").tag(SubtractDraft.Step.targets)
                        Text(draft.tools.isEmpty ? "Tools" : "Tools · \(draft.tools.count)").tag(SubtractDraft.Step.tools)
                    }
                    .pickerStyle(.segmented).frame(width: 260).accessibilityIdentifier("subtract.step")
                    Menu {
                        Picker("Keep", selection: Binding(get: { draft.keep }, set: { session.setSubtractKeep($0) })) {
                            ForEach(SubtractDraft.Keep.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Text("Keep: \(draft.keep.title)").font(.system(size: 15, weight: .medium)).padding(.horizontal, 8)
                    }
                    .accessibilityIdentifier("subtract.keep")
                    clearanceMenu(draft.clearance, allowsNone: true, id: "subtract.clearance") { session.setSubtractClearance($0) }
                }
                .padding(6).background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 8) {
                    actionButton("Cancel", icon: .exit, id: "subtract.cancel") { session.cancelSubtract() }
                    actionButton("Done", icon: .done, id: "subtract.confirm") { session.confirmSubtract() }
                        .disabled(session.subtractPreview == nil)
                }
            }
        } else if let draft = session.unionDraft {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Text(draft.bodies.isEmpty ? "Bodies" : "Bodies · \(draft.bodies.count)")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(ink).padding(.leading, 8)
                        .accessibilityIdentifier("union.count")
                    Toggle("Keep Input", isOn: Binding(get: { draft.keepOriginals }, set: { session.setUnionKeepOriginals($0) }))
                        .toggleStyle(.button).font(.system(size: 15, weight: .medium)).accessibilityIdentifier("union.keepOriginals")
                }
                .padding(6).background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 8) {
                    actionButton("Cancel", icon: .exit, id: "union.cancel") { session.cancelUnion() }
                    actionButton("Done", icon: .done, id: "union.confirm") { session.confirmUnion() }
                        .disabled(session.unionPreview == nil)
                }
            }
        } else if let draft = session.mirrorDraft {
            VStack(spacing: 8) {
                HStack(spacing: 7) {
                    // Two picks: what to mirror, and the plane to mirror it across.
                    let count = draft.bodies.count + draft.sketches.count
                    Picker("Pick", selection: Binding(get: { draft.step }, set: { session.chooseMirrorStep($0) })) {
                        Text(count == 0 ? "Objects" : "Objects · \(count)").tag(MirrorDraft.Step.items)
                        Text(draft.plane == nil ? "Mirror Plane" : "Mirror Plane · 1").tag(MirrorDraft.Step.plane)
                    }
                    .pickerStyle(.segmented).frame(width: 360).accessibilityIdentifier("mirror.step")
                    Toggle("Keep Input", isOn: Binding(get: { draft.keepOriginals }, set: { session.setMirrorKeepOriginals($0) }))
                        .toggleStyle(.button).font(.system(size: 15, weight: .medium)).accessibilityIdentifier("mirror.keepOriginals")
                }
                .padding(6).background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 8) {
                    actionButton("Cancel", icon: .exit, id: "mirror.cancel") { session.cancelMirror() }
                    actionButton("Done", icon: .done, id: "mirror.confirm") { session.confirmMirror() }
                        .disabled(session.mirrorPreview == nil)
                }
            }
        } else {
            AnyView(operationControlsB)
        }
    }

    /// An operation's own controls, in place of the dock (part 2 of 4: split so no one SwiftUI type nests too deep).
    @ViewBuilder private var operationControlsB: some View {
        if let draft = session.patternDraft {
            patternBar(draft)
        } else if let draft = session.scaleDraft {
            scaleBar(draft)
        } else if let draft = session.offsetDraft {
            VStack(spacing: 8) {
                HStack(spacing: 7) {
                    Button { session.flipOffset() } label: { Text("Flip").font(.system(size: 15, weight: .medium)).padding(.horizontal, 10).frame(height: 30) }
                        .accessibilityIdentifier("offset.flip")
                    Toggle("Both Sides", isOn: Binding(get: { draft.bothSides }, set: { session.setOffsetBothSides($0) }))
                        .toggleStyle(.button).font(.system(size: 15, weight: .medium)).accessibilityIdentifier("offset.bothSides")
                    Toggle("Rounded", isOn: Binding(get: { draft.rounded }, set: { session.setOffsetRounded($0) }))
                        .toggleStyle(.button).font(.system(size: 15, weight: .medium)).accessibilityIdentifier("offset.rounded")
                }
                .padding(6).background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 8) {
                    actionButton("Cancel", icon: .exit, id: "offset.cancel") { session.cancelOffset() }
                    actionButton("Done", icon: .done, id: "offset.confirm") { session.confirmOffset() }
                        .disabled(session.offsetPreview.isEmpty)
                }
            }
        } else if let draft = session.sketchMirrorDraft {
            VStack(spacing: 8) {
                Picker("Pick", selection: Binding(get: { draft.step }, set: { session.chooseSketchMirrorStep($0) })) {
                    Text(draft.shapes.isEmpty ? "Shapes" : "Shapes · \(draft.shapes.count)").tag(SketchMirrorDraft.Step.shapes)
                    Text(draft.line == nil ? "Mirror Line" : "Mirror Line · 1").tag(SketchMirrorDraft.Step.line)
                }
                .pickerStyle(.segmented).frame(width: 300).padding(6)
                .background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("sketchMirror.step")
                HStack(spacing: 8) {
                    actionButton("Cancel", icon: .exit, id: "sketchMirror.cancel") { session.cancelSketchMirror() }
                    actionButton("Done", icon: .done, id: "sketchMirror.confirm") { session.confirmSketchMirror() }
                        .disabled(session.sketchMirrorPreview == nil)
                }
            }
        } else if let section = session.section {
            VStack(spacing: 8) {
                HStack(spacing: 7) {
                    Picker("Plane", selection: Binding(get: { section.orientation }, set: { session.setSectionOrientation($0) })) {
                        ForEach(SketchPlane.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 240).accessibilityIdentifier("section.plane")
                    Button { session.flipSection() } label: { Text("Flip").font(.system(size: 15, weight: .medium)).padding(.horizontal, 10).frame(height: 30) }
                        .accessibilityIdentifier("section.flip")
                }
                .padding(6).background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
                actionButton("Done", icon: .done, id: "section.done") { session.endSection() }
            }
        } else if let draft = session.deleteFaceDraft {
            VStack(spacing: 8) {
                Text(draft.faces.isEmpty ? "Faces" : "Faces · \(draft.faces.count)").font(.system(size: 15, weight: .medium)).foregroundStyle(ink)
                    .padding(.horizontal, 12).padding(.vertical, 6).background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("deleteFace.count")
                HStack(spacing: 8) {
                    actionButton("Cancel", icon: .exit, id: "deleteFace.cancel") { session.cancelDeleteFace() }
                    actionButton("Done", icon: .done, id: "deleteFace.confirm") { session.confirmDeleteFace() }
                        .disabled(session.deleteFacePreview == nil)
                }
            }
        } else {
            AnyView(operationControlsC)
        }
    }

    /// An operation's own controls, in place of the dock (part 3 of 4: split so no one SwiftUI type nests too deep).
    @ViewBuilder private var operationControlsC: some View {
        if let draft = session.splitDraft {
            VStack(spacing: 8) {
                HStack(spacing: 7) {
                    // Two picks: what to split, and what to split it with.
                    Picker("Pick", selection: Binding(get: { draft.step }, set: { session.chooseSplitStep($0) })) {
                        Text(draft.bodies.isEmpty ? "Bodies to Split" : "Bodies to Split · \(draft.bodies.count)").tag(SplitDraft.Step.bodies)
                        Text(draft.tools.isEmpty ? "Splitting Tools" : "Splitting Tools · \(draft.tools.count)").tag(SplitDraft.Step.tools)
                    }
                    .pickerStyle(.segmented).frame(width: 360).accessibilityIdentifier("split.step")
                    Toggle("Keep Input", isOn: Binding(get: { draft.keepOriginals }, set: { session.setKeepOriginals($0) }))
                        .toggleStyle(.button).font(.system(size: 15, weight: .medium)).accessibilityIdentifier("split.keepOriginals")
                }
                .padding(6).background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 8) {
                    actionButton("Cancel", icon: .exit, id: "split.cancel") { session.cancelSplit() }
                    actionButton(proDone, icon: .done, id: "split.confirm") { session.confirmSplit() }
                        .disabled(session.splitPreview == nil)
                }
            }
        } else if let draft = session.projectionDraft {
            VStack(spacing: 8) {
                if !draft.fixedTarget {
                    // Two picks: what to project, then where.
                    Picker("Pick", selection: Binding(get: { draft.step }, set: { session.chooseProjectionStep($0) })) {
                        Text(draft.items.isEmpty ? "Geometry" : "Geometry · \(draft.items.count)").tag(ProjectionDraft.Step.items)
                        Text("Target Plane").tag(ProjectionDraft.Step.surface)
                    }
                    .pickerStyle(.segmented).frame(width: 400)
                    .padding(6).background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("projection.step")
                }
                HStack(spacing: 8) {
                    actionButton("Cancel", icon: .exit, id: "projection.cancel") { session.cancelProjection() }
                    actionButton(proDone, icon: .done, id: "projection.confirm") { session.confirmProjection() }
                        .disabled(session.projectionPreview.isEmpty)
                }
            }
        } else if session.tool.isShapeTool {
            HStack(spacing: 8) {
                if session.tool == .loft {
                    Toggle("Ruled", isOn: Binding(get: { session.shapeToolDraft?.ruled ?? false }, set: { session.setLoftRuled($0) }))
                        .toggleStyle(.button).font(.system(size: 15, weight: .medium)).accessibilityIdentifier("loft.ruled")
                        .padding(.horizontal, 8).frame(height: 48).background(white, in: RoundedRectangle(cornerRadius: 12))
                }
                if session.tool == .rib {
                    Button("Flip") { session.flipRib() }.font(.system(size: 15, weight: .medium)).accessibilityIdentifier("rib.flip")
                        .disabled(session.shapeToolPreview == nil)
                        .padding(.horizontal, 12).frame(height: 48).background(white, in: RoundedRectangle(cornerRadius: 12))
                }
                actionButton("Cancel", icon: .exit, id: "shapeTool.cancel") { session.cancelShapeTool() }
                actionButton(proDone, icon: .done, id: "shapeTool.confirm") { session.confirmShapeTool() }
                    .disabled(session.shapeToolPreview == nil)
            }
        } else if session.tool.isConstructionTool {
            HStack(spacing: 8) {
                actionButton("Cancel", icon: .exit, id: "construction.cancel") { session.cancelConstruction() }
                actionButton("Done", icon: .done, id: "construction.confirm") { session.confirmConstruction() }
                    .disabled(!session.canConfirmConstruction)
            }
        } else if session.tool.isPlaneTool {
            HStack(spacing: 8) {
                actionButton("Cancel", icon: .exit, id: "plane.cancel") { session.cancelPlane() }
                actionButton("Done", icon: .done, id: "plane.confirm") { session.confirmPlane() }
                    .disabled(session.planePreview == nil)
            }
        } else if session.isShelling {
            HStack(spacing: 8) {
                actionButton("Cancel", icon: .exit, id: "shell.cancel") { session.cancelShell() }
                actionButton(proDone, icon: .done, id: "shell.confirm") { session.confirmShell() }
                    .disabled(session.draftError != nil || session.shellPreview == nil)
            }
        } else if let hole = session.holeDraft {
            VStack(spacing: 8) {
                HStack(spacing: 7) {
                    Picker("Hole type", selection: Binding(get: { hole.spec.kind }, set: { session.chooseHole(kind: $0) })) {
                        ForEach(HoleSpec.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 360).accessibilityIdentifier("hole.kind")
                    Picker("Size", selection: Binding(get: { hole.spec.size }, set: { session.chooseHole(size: $0) })) {
                        ForEach(HolePresets.sizes, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 250).accessibilityIdentifier("hole.size")
                    Toggle("Through", isOn: Binding(get: { hole.depth == nil }, set: { session.setHoleThrough($0) }))
                        .toggleStyle(.button).font(.system(size: 15, weight: .medium)).accessibilityIdentifier("hole.through")
                }
                .padding(6).background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 8) {
                    actionButton("Cancel", icon: .exit, id: "hole.cancel") { session.cancelHole() }
                    actionButton("Done", icon: .done, id: "hole.confirm") { session.confirmHole() }
                        .disabled(session.draftError != nil || session.holePreview == nil)
                }
            }
        } else {
            AnyView(operationControlsD)
        }
    }

    /// An operation's own controls, in place of the dock (part 4 of 4: split so no one SwiftUI type nests too deep).
    @ViewBuilder private var operationControlsD: some View {
        if let draft = session.textDraft {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Text", text: Binding(get: { draft.text }, set: { session.setText($0) }))
                        .font(.system(size: 16)).textFieldStyle(.roundedBorder).frame(width: 200)
                        .autocorrectionDisabled().accessibilityIdentifier("text.content")
                    Menu {
                        ForEach(TextFonts.available, id: \.name) { font in
                            Button(font.name == draft.font ? "\(font.title) (in use)" : font.title) { session.setTextFont(font.name) }
                        }
                    } label: {
                        Text(TextFonts.title(for: draft.font)).font(.system(size: 15, weight: .medium)).padding(.horizontal, 6).lineLimit(1)
                    }
                    .accessibilityIdentifier("text.font")
                    Picker("Style", selection: Binding(get: { draft.depth > 0 }, set: { session.setTextRaised($0) })) {
                        Text("Raised").tag(true)
                        Text("Sunk").tag(false)
                    }
                    .pickerStyle(.segmented).frame(width: 150).accessibilityIdentifier("text.style")
                    Button { session.rotateText() } label: { Text("Rotate 90°").font(.system(size: 15, weight: .medium)) }
                        .accessibilityIdentifier("text.rotate")
                    if session.isBuildingText { ProgressView().controlSize(.small).padding(.trailing, 4) }
                }
                .padding(6).background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 8) {
                    actionButton("Cancel", icon: .exit, id: "text.cancel") { session.cancelText() }
                    actionButton(proDone, icon: .done, id: "text.confirm") { session.confirmText() }
                        .disabled(session.textPreview == nil || session.isBuildingText)
                }
            }
        } else if let draft = session.threadDraft {
            threadBar(draft)
        } else if let draft = session.screwLidDraft {
            screwLidBar(draft)
        } else if session.pegDraft != nil {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    let sockets = session.pegSockets.count
                    Text(sockets == 0 ? "No socket" : sockets == 1 ? "1 socket" : "\(sockets) sockets")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(ink).padding(.leading, 8)
                        .accessibilityIdentifier("peg.sockets")
                    Picker("Peg", selection: Binding(get: { session.pegDraft?.spec.separate ?? false }, set: { session.setPegSeparate($0) })) {
                        Text("Joined").tag(false)
                        Text("Separate").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 180).accessibilityIdentifier("peg.separate")
                    clearanceMenu(session.pegDraft?.spec.clearance, allowsNone: false, id: "peg.clearance") { value in
                        if let value { session.setPegClearance(value) }
                    }
                }
                .padding(6).background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 8) {
                    actionButton("Cancel", icon: .exit, id: "peg.cancel") { session.cancelPeg() }
                    actionButton(proDone, icon: .done, id: "peg.confirm") { session.confirmPeg() }
                        .disabled(session.draftError != nil || session.pegPreview == nil)
                }
            }
        } else if let draft = session.primitiveDraft {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    SSIconGlyph(icon: session.tool.icon, size: 22, color: ink).padding(.leading, 8)
                    Text(draft.kind.title).font(.system(size: 15, weight: .medium)).foregroundStyle(ink).padding(.trailing, 8)
                        .accessibilityIdentifier("primitive.kind")
                }
                .padding(6).background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 8) {
                    actionButton("Cancel", icon: .exit, id: "primitive.cancel") { session.cancelPrimitive() }
                    actionButton("Done", icon: .done, id: "primitive.confirm") { session.confirmPrimitive() }
                        .disabled(session.primitivePreview == nil)
                }
            }
        } else if session.isMeasuring {
            measureBar
        } else if session.isFinishing {
            HStack(spacing: 8) {
                actionButton("Cancel", icon: .exit, id: "finish.cancel") { session.cancelFinish() }
                actionButton("Done", icon: .done, id: "finish.confirm") { session.confirmFinish() }
                    .disabled(session.finishError != nil || session.finishPreview == nil)
            }
        }
    }

    private var bottomBar: some View {
        ZStack(alignment: .bottom) {
            HStack(alignment: .bottom, spacing: 6) {
                squareButton(.undo, label: "Undo", enabled: session.history.canUndo && !session.isEditingBlocked) { session.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                squareButton(.redo, label: "Redo", enabled: session.history.canRedo && !session.isEditingBlocked) { session.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                Spacer()
                squareButton(.help, label: "Controls") { session.showHelp = true }
            }
            if session.isReviewingAssistant || session.isAssistantWorking {
                assistantReviewBar
            } else if !operationActive {
                VStack(spacing: 8) {
                    contextStrip
                    dock.disabled(session.isEditingBlocked)
                        // Palm guard: a hand resting on the dock while the Pencil draws presses nothing.
                        .allowsHitTesting(!session.isPencilDown)
                }
            } else {
                AnyView(operationControls)
            }
        }
    }

    /// Measure's results replace the dock: each value on its own line, then Done.
    private var measureBar: some View {
        let result = session.measurements
        return VStack(spacing: 8) {
            if !result.values.isEmpty {
                HStack(spacing: 14) {
                    ForEach(Array(result.values.enumerated()), id: \.offset) { _, value in
                        VStack(spacing: 1) {
                            Text(value.kind.title).font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
                            Text(session.measureText(value)).font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(ink)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("measure.\(value.kind.rawValue)")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(white.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(hairline.opacity(0.5)))
            }
            actionButton("Done", icon: .done, id: "measure.done") { session.endMeasure() }
        }
    }

    /// The assistant's changes under review replace the dock, like an operation's Cancel and Done.
    private var assistantReviewBar: some View {
        let changes = assistant.pendingChanges
        return VStack(spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showAssistant = true }
            } label: {
                HStack(spacing: 6) {
                    SSIconGlyph(icon: .assistant, size: 20, color: violet)
                    Text(session.isAssistantWorking ? "Assistant working…" : changes.count == 1 ? changes[0] : "\(changes.count) assistant changes")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(ink).lineLimit(1)
                }
                .padding(.horizontal, 14).frame(height: 34).frame(maxWidth: 460)
                .background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain).accessibilityIdentifier("assistant.reviewSummary")
            HStack(spacing: 8) {
                if session.isAssistantWorking {
                    actionButton("Stop", icon: .stop, id: "assistant.stopRequest") { assistant.stop() }
                } else {
                    actionButton("Discard", icon: .exit, id: "assistant.discard") { assistant.discard() }
                    actionButton(session.ownsPro ? "Keep" : "Keep with Pro", icon: .done, id: "assistant.keep") { assistant.keep() }
                }
            }
        }
    }

    /// A project menu item with its brand glyph.
    private func menuButton(_ title: String, icon: SSIcon, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label { Text(title) } icon: { Image(icon.assetName).renderingMode(.template) } }
    }

    private func squareButton(_ icon: SSIcon, label: String, enabled: Bool = true, id: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { BrandTile(icon: icon) }
            .buttonStyle(.plain).disabled(!enabled).accessibilityLabel(label).accessibilityIdentifier(id ?? label)
    }

    /// Cancel / Done at the bottom center: a white button with a small brand tile (Done is violet).
    /// The pattern's controls: the type, Extent or Spacing, the quantity (step it, or tap it to type
    /// it), and for circular patterns whether copies turn with the pattern.
    private func patternBar(_ draft: PatternDraft) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Picker("Type", selection: Binding(get: { draft.spec.kind }, set: { session.setPatternKind($0) })) {
                    ForEach(PatternSpec.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 190).accessibilityIdentifier("pattern.kind")
                Menu {
                    Picker("Definition", selection: Binding(get: { draft.spec.definition }, set: { session.setPatternDefinition($0) })) {
                        ForEach(PatternSpec.Definition.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } label: {
                    Text(draft.spec.definition.title).font(.system(size: 15, weight: .medium)).padding(.horizontal, 8)
                }
                .accessibilityIdentifier("pattern.definition")
                HStack(spacing: 0) {
                    Button { session.setPatternCount(draft.count - 1) } label: { Text("−").frame(width: 30, height: 30) }
                        .disabled(draft.count <= PatternSpec.countRange.lowerBound).accessibilityLabel("Fewer").accessibilityIdentifier("pattern.fewer")
                    Button { session.openDimension(.patternCount, at: CGPoint(x: patternCountFrame.midX - 55, y: patternCountFrame.minY - 20)) } label: {
                        Text("× \(draft.count)").font(.system(size: 15, weight: .semibold)).frame(minWidth: 44, minHeight: 30)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(violet, lineWidth: 1.2))
                    }
                    .accessibilityLabel("Quantity").accessibilityValue("\(draft.count)").accessibilityIdentifier("pattern.count")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("workspace")) } action: { patternCountFrame = $0 }
                    Button { session.setPatternCount(draft.count + 1) } label: { Text("+").frame(width: 30, height: 30) }
                        .accessibilityLabel("More").accessibilityIdentifier("pattern.more")
                }
                .font(.system(size: 18, weight: .medium))
                if draft.spec.kind == .circular {
                    Menu {
                        Picker("Orientation", selection: Binding(get: { draft.spec.orientation }, set: { session.setPatternOrientation($0) })) {
                            ForEach(PatternSpec.Orientation.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Text(draft.spec.orientation.title).font(.system(size: 15, weight: .medium)).padding(.horizontal, 8)
                    }
                    .accessibilityIdentifier("pattern.orientation")
                }
            }
            .padding(6).background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 8) {
                actionButton("Cancel", icon: .exit, id: "pattern.cancel") { session.cancelPattern() }
                actionButton(proDone, icon: .done, id: "pattern.confirm") { session.confirmPattern() }
                    .disabled(session.patternPreview == nil)
            }
        }
    }

    /// A small option in an operation's bar: glyph and name.
    private func optionLabel(_ title: String, icon: SSIcon) -> some View {
        HStack(spacing: 5) {
            SSIconGlyph(icon: icon, size: 20, color: ink)
            Text(title).font(.system(size: 15, weight: .medium))
        }
        .padding(.horizontal, 4).frame(minHeight: 30)
    }

    private func scaleBar(_ draft: ScaleDraft) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                let count = draft.bodies.count + draft.sketches.count
                Text(count == 0 ? "Objects" : "Objects · \(count)").font(.system(size: 15, weight: .medium)).foregroundStyle(ink).padding(.leading, 8)
                    .accessibilityIdentifier("scale.count")
                Toggle("Uniform", isOn: Binding(get: { draft.uniform }, set: { session.setScaleUniform($0) }))
                    .toggleStyle(.button).font(.system(size: 15, weight: .medium)).accessibilityIdentifier("scale.uniform")
                Menu {
                    ForEach(ScaleDraft.Pivot.allCases, id: \.self) { pivot in
                        Button(pivot == draft.pivot ? "\(pivot.title) (in use)" : pivot.title) { session.setScalePivot(pivot) }
                    }
                } label: {
                    Text("About: \(draft.pivot.title)").font(.system(size: 15, weight: .medium)).padding(.horizontal, 8)
                }
                .accessibilityIdentifier("scale.pivot")
                Toggle("Create Copy", isOn: Binding(get: { draft.copy }, set: { session.setScaleCopy($0) }))
                    .toggleStyle(.button).font(.system(size: 15, weight: .medium)).accessibilityIdentifier("scale.copy")
            }
            .padding(6).background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 8) {
                actionButton("Cancel", icon: .exit, id: "scale.cancel") { session.cancelScale() }
                actionButton("Done", icon: .done, id: "scale.confirm") { session.confirmScale() }
                    .disabled(session.scalePreview == nil)
            }
        }
    }

    /// A fit's clearance: the presets, your Fit when it is a custom value, and Custom… for the keypad
    /// (with None for an operation where it is optional).
    // MARK: Thread bar

    /// The Thread tool's controls: the face it is on, Cut or Raised, then Size, Pitch, Length,
    /// Clearance, and Options menus, each saying what it does to the fit (October 21, 2026).
    private func threadBar(_ draft: ThreadDraft) -> AnyView {
        let spec = draft.spec
        let row = HStack(spacing: 10) {
            Text("\(spec.isInternal ? "Hole" : "Boss"): \(session.lengthText(spec.surfaceDiameter))")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(ink).padding(.leading, 8)
                .accessibilityIdentifier("thread.face")
            threadMadeMenu(draft)
            threadSizeMenu(draft)
            threadPitchMenu(draft)
            threadLengthMenu(draft)
            clearanceMenu(spec.clearance > 0 ? spec.clearance : nil, allowsNone: true, id: "thread.clearance") { value in
                session.setThreadClearance(value ?? 0)
            }
            threadOptionsMenu(draft)
            if session.isBuildingThread { ProgressView().controlSize(.small).padding(.trailing, 6) }
        }
        .padding(6)
        return AnyView(VStack(spacing: 8) {
            // Scrolls sideways only when it is wider than the screen (a long clearance or inch values in portrait).
            ViewThatFits(in: .horizontal) {
                row
                ScrollView(.horizontal, showsIndicators: false) { row }
            }
            .background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("workspace")) } action: { threadBarFrame = $0 }
            .padding(.horizontal, 12)
            HStack(spacing: 8) {
                actionButton("Cancel", icon: .exit, id: "thread.cancel") { session.cancelThread() }
                actionButton(proDone, icon: .done, id: "thread.confirm") { session.confirmThread() }
                    .disabled(session.threadPreview == nil || session.isBuildingThread)
            }
        })
    }

    /// Screw Lid's controls (October 26, 2026): the thread's pitch, starts, and turns to close, the
    /// lid's top, height, and grip, and the clearance; then Cancel and Done.
    private func screwLidBar(_ draft: ScrewLidDraft) -> AnyView {
        let spec = draft.spec
        let row = HStack(spacing: 10) {
            screwLidMenu("Pitch", session.lengthText(spec.pitch), id: "screwLid.pitch",
                         [2.0, 2.5, 3, 4, 5].map { ($0, session.lengthText($0), abs($0 - spec.pitch) < 1e-9) }, set: session.setScrewLidPitch)
            screwLidMenu("Starts", "\(spec.starts)", id: "screwLid.starts",
                         [1, 2, 3, 4].map { ($0, "\($0)", $0 == spec.starts) }, set: session.setScrewLidStarts)
            screwLidMenu("Turns", ThreadSpec.mm(spec.turns), id: "screwLid.turns",
                         [0.75, 1, 1.25, 1.5, 2].map { ($0, ThreadSpec.mm($0), abs($0 - spec.turns) < 1e-9) }, set: session.setScrewLidTurns)
            screwLidMenu("Top", session.lengthText(spec.top), id: "screwLid.top",
                         [1.2, 1.6, 2, 2.5, 3].map { ($0, session.lengthText($0), abs($0 - spec.top) < 1e-9) }, set: session.setScrewLidTop)
            screwLidHeightMenu(spec)
            screwLidMenu("Grip", spec.ribbed ? "Ribbed" : "Smooth", id: "screwLid.grip",
                         [true, false].map { ($0, $0 ? "Ribbed" : "Smooth", $0 == spec.ribbed) }, set: session.setScrewLidRibbed)
            clearanceMenu(spec.clearance, allowsNone: false, id: "screwLid.clearance") { value in session.setScrewLidClearance(value ?? spec.clearance) }
            if session.isBuildingScrewLid { ProgressView().controlSize(.small).padding(.trailing, 6) }
        }
        .padding(6)
        return AnyView(VStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                row
                ScrollView(.horizontal, showsIndicators: false) { row }
            }
            .background(white.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)
            HStack(spacing: 8) {
                actionButton("Cancel", icon: .exit, id: "screwLid.cancel") { session.cancelScrewLid() }
                actionButton("Test Print", icon: .fitTest, id: "screwLid.testPrint") { session.addScrewLidFitTest() }
                    .disabled(session.screwLidThread == nil || session.isBuildingScrewLidTest)
                actionButton(proDone, icon: .done, id: "screwLid.confirm") { session.confirmScrewLid() }
                    .disabled(session.screwLidPreview == nil || session.isBuildingScrewLid || session.isBuildingScrewLidTest)
            }
        })
    }

    /// One of Screw Lid's menus: (value, label, in use) choices.
    private func screwLidMenu<T: Hashable>(_ title: String, _ current: String, id: String, _ choices: [(T, String, Bool)],
                                           set: @escaping (T) -> Void) -> AnyView {
        AnyView(Menu {
            ForEach(choices, id: \.0) { choice in
                Button(choice.2 ? "\(choice.1) (in use)" : choice.1) { set(choice.0) }
            }
        } label: {
            Text("\(title): \(current)").font(.system(size: 15, weight: .medium)).padding(.horizontal, 8)
        }
        .accessibilityIdentifier(id))
    }

    /// The lid's height: just over its thread, or taller (a deeper skirt down the neck).
    private func screwLidHeightMenu(_ spec: ScrewLidSpec) -> AnyView {
        let threaded = session.screwLidThread?.threadedLength ?? 0
        let auto = threaded + spec.top + 1
        let taller = [3.0, 6, 10].map { ((auto + $0 - 1) * 10).rounded() / 10 }
        return AnyView(Menu {
            Button(spec.height == nil ? "Just Over the Thread (in use)" : "Just Over the Thread") { session.setScrewLidHeight(nil) }
            ForEach(taller, id: \.self) { height in
                let inUse = spec.height.map { abs($0 - height) < 1e-9 } ?? false
                Button(inUse ? "\(session.lengthText(height)) (in use)" : session.lengthText(height)) { session.setScrewLidHeight(height) }
            }
        } label: {
            Text("Height: \(session.lengthText(spec.height ?? auto))").font(.system(size: 15, weight: .medium)).padding(.horizontal, 8)
        }
        .accessibilityIdentifier("screwLid.height"))
    }

    /// Opens the keypad for a thread value just above the bar.
    private func openThreadKeypad(_ target: DimensionTarget) {
        session.openDimension(target, at: CGPoint(x: threadBarFrame.midX - 55, y: threadBarFrame.minY - 20))
    }

    /// Cut grooves into the face, or raise ridges onto it (October 22, 2026).
    private func threadMadeMenu(_ draft: ThreadDraft) -> AnyView {
        let raised = draft.spec.isRaised, hole = draft.spec.isInternal, profile = draft.spec.shape
        return AnyView(Menu {
            Button { session.setThreadRaised(false) } label: {
                Text(raised ? "Cut" : "Cut (in use)")
                Text(hole ? "Grooves cut into the wall, like a tapped hole" : "Grooves cut into the boss, like a machined bolt")
            }
            Button { session.setThreadRaised(true) } label: {
                Text(raised ? "Raised (in use)" : "Raised")
                Text(hole ? "Ridges added inside the hole, so a thin wall stays whole" : "Ridges added onto the boss, so a thin wall stays whole, as on a jar's neck")
            }
            // The cross-section (October 26, 2026): ISO for hardware, 45° for printed lids and jars.
            Section("Profile") {
                Button { session.setThreadProfile(.iso) } label: {
                    Text(profile == .iso ? "ISO 60° (in use)" : "ISO 60°")
                    Text("The standard for screws and nuts")
                }
                Button { session.setThreadProfile(.printable) } label: {
                    Text(profile == .printable ? "Printable 45° (in use)" : "Printable 45°")
                    Text("Shallower, with flanks that print without supports either way up, for lids and jars")
                }
            }
            if raised {
                Toggle(isOn: Binding(get: { draft.spec.taperedEnds == true }, set: { session.setThreadTaperedEnds($0) })) {
                    Text("Tapered Ends")
                    Text("Ridges fade out over a quarter turn instead of stopping square")
                }
            }
        } label: {
            Text((raised ? "Raised" : "Cut") + (profile == .printable ? " · 45°" : "")).font(.system(size: 15, weight: .medium)).padding(.horizontal, 8)
        }
        .accessibilityIdentifier("thread.made"))
    }

    private func threadSizeButton(_ choice: ThreadSizeChoice) -> some View {
        Button { session.chooseThreadSize(choice.size.name) } label: {
            Text(choice.inUse ? "\(choice.title) (in use)" : choice.title)
            Text(choice.note)
        }
        .disabled(choice.fit == .misses)
    }

    /// Sizes that fit the face as it is come first; the rest (which cut a hole out or turn a boss
    /// down, or miss it and are disabled, each saying so) and the other standard sit in submenus.
    private func threadSizeMenu(_ draft: ThreadDraft) -> AnyView {
        let spec = draft.spec
        let preferred: ThreadSize.Standard = session.lengthUnit == .inches ? .inch : .metric
        let choices = session.threadSizeChoices(preferred)
        let others = session.threadSizeChoices(preferred == .metric ? .inch : .metric)
        let fitting = choices.filter(\.fitsAsIs), rest = choices.filter { !$0.fitsAsIs }
        let face = spec.isInternal ? "hole" : "boss"
        return AnyView(Menu {
            Section("Fit this \(session.lengthText(spec.surfaceDiameter)) \(face)") {
                if fitting.isEmpty {
                    Button("No \(preferred == .metric ? "metric" : "inch") size fits; use Custom") {}.disabled(true)
                }
                ForEach(fitting, id: \.size.name) { threadSizeButton($0) }
            }
            Menu(preferred == .metric ? "Other Metric Sizes" : "Other Inch Sizes") {
                ForEach(rest, id: \.size.name) { threadSizeButton($0) }
            }
            Menu(preferred == .metric ? "Inch Sizes (UNC/UNF)" : "Metric Sizes") {
                ForEach(others, id: \.size.name) { threadSizeButton($0) }
            }
            Button {
                session.chooseThreadSize("")
                openThreadKeypad(.threadDiameter)
            } label: {
                Text(spec.size.isEmpty ? "Custom Diameter… (in use)" : "Custom Diameter…")
                Text("Any diameter, e.g. for a jar lid")
            }
        } label: {
            Text("Size: \(spec.standardSize?.name ?? "Custom")")
                .font(.system(size: 15, weight: .medium)).padding(.horizontal, 8)
        }
        .accessibilityIdentifier("thread.size"))
    }

    private func threadPitchMenu(_ draft: ThreadDraft) -> AnyView {
        let spec = draft.spec
        let current = spec.standardSize?.standard == .inch ? "\(ThreadSize.tpi(spec.pitch)) TPI" : session.lengthText(spec.pitch)
        return AnyView(Menu {
            Section("Distance between crests") {
                ForEach(session.threadPitchChoices, id: \.pitch) { choice in
                    Button { session.chooseThreadPitch(choice.pitch) } label: {
                        Text(abs(choice.pitch - spec.pitch) < 1e-6 ? "\(choice.title) (in use)" : choice.title)
                        if !choice.note.isEmpty { Text(choice.note) }
                    }
                    .disabled(!choice.usable)
                }
            }
            Button("Custom Pitch…") { openThreadKeypad(.threadPitch) }
        } label: {
            Text("Pitch: \(current)").font(.system(size: 15, weight: .medium)).padding(.horizontal, 8)
        }
        .accessibilityIdentifier("thread.pitchMenu"))
    }

    private func threadLengthMenu(_ draft: ThreadDraft) -> AnyView {
        let full = draft.spec.threadedLength, half = (full / 2 * 10).rounded() / 10
        return AnyView(Menu {
            Section("Threaded from the \(draft.spec.hasOpenEnd ? "open end" : "end")") {
                Button(draft.length == nil ? "Whole Face · \(session.lengthText(full)) (in use)" : "Whole Face · \(session.lengthText(full))") {
                    session.setThreadLength(nil)
                }
                if half >= draft.spec.shortestLength {
                    Button("Half · \(session.lengthText(half))") { session.setThreadLength(half) }
                }
            }
            Button("Custom Length…") { openThreadKeypad(.threadLength) }
        } label: {
            Text("Length: \(draft.length.map { session.lengthText($0) } ?? "Full")")
                .font(.system(size: 15, weight: .medium)).padding(.horizontal, 8)
        }
        .accessibilityIdentifier("thread.lengthMenu"))
    }

    /// Hand, lead-in, and starts: plain buttons, as in the other menus.
    private func threadOptionsMenu(_ draft: ThreadDraft) -> AnyView {
        let spec = draft.spec, left = spec.leftHanded == true, leadIn = spec.leadIn == true
        return AnyView(Menu {
            Section("Hand") {
                Button(left ? "Right-Hand" : "Right-Hand (in use)") { session.setThreadLeftHanded(false) }
                Button { session.setThreadLeftHanded(true) } label: {
                    Text(left ? "Left-Hand (in use)" : "Left-Hand")
                    Text("Tightens counterclockwise")
                }
            }
            Section("Ends") {
                Button { session.setThreadLeadIn(true) } label: {
                    Text(leadIn ? "45° Lead-in (in use)" : "45° Lead-in")
                    Text(spec.hasOpenEnd ? "A chamfer at the open end so it starts straight" : "There is no open end")
                }
                .disabled(!spec.hasOpenEnd)
                Button(leadIn ? "Square Ends" : "Square Ends (in use)") { session.setThreadLeadIn(false) }.disabled(!spec.hasOpenEnd)
            }
            Section("Starts") {
                ForEach(Array(ThreadSpec.startsRange), id: \.self) { starts in
                    Button { session.setThreadStarts(starts) } label: {
                        let title = starts == 1 ? "1 Start" : "\(starts) Starts"
                        Text(starts == spec.startCount ? "\(title) (in use)" : title)
                        Text("Each turn advances \(session.lengthText(spec.pitch * Double(starts)))" + (starts == 1 ? "" : ", for quick lids"))
                    }
                }
            }
        } label: {
            Text("Options").font(.system(size: 15, weight: .medium)).padding(.horizontal, 8)
        }
        .accessibilityIdentifier("thread.options"))
    }

    private func clearanceMenu(_ clearance: Double?, allowsNone: Bool, id: String, set: @escaping (Double?) -> Void) -> some View {
        Menu {
            // Plain buttons, as in the project menu: an inline Picker keeps the app from settling.
            if allowsNone { Button(clearance == nil ? "None (in use)" : "None") { set(nil) } }
            ForEach(Fit.Preset.allCases, id: \.self) { preset in
                let title = session.fitText(preset.clearance)
                Button(clearance == preset.clearance ? "\(title) (in use)" : title) { set(preset.clearance) }
            }
            if Fit.preset(for: session.fitClearance) == nil {
                Button("Your Fit · \(session.lengthText(session.fitClearance))") { set(session.fitClearance) }
            }
            Button("Custom…") {
                // The keypad edits the operation's clearance (Subtract's starts from your Fit).
                if clearance == nil { set(session.fitClearance) }
                session.openDimension(.clearance, at: CGPoint(x: clearanceFrame.midX - 55, y: clearanceFrame.minY - 20))
            }
        } label: {
            Text(clearance.map { "Clearance: \(session.fitText($0))" } ?? "Clearance: None")
                .font(.system(size: 15, weight: .medium)).padding(.horizontal, 8)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("workspace")) } action: { clearanceFrame = $0 }
        .accessibilityIdentifier(id)
    }

    private func actionButton(_ title: String, icon: SSIcon, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { ActionLabel(title: title, icon: icon) }
            .buttonStyle(.plain).accessibilityLabel(title).accessibilityIdentifier(id)
    }

    private func keypadPosition(_ edit: DimensionEdit, in size: CGSize) -> CGPoint {
        let x = max(348, min(size.width - 184, edit.anchor.x + 55))
        let top = max(148, min(size.height - 388, edit.anchor.y - 345))
        return CGPoint(x: x, y: top + 170)
    }
}

/// The system share sheet for an exported file: AirDrop, Save to Files, and slicer apps.
private struct ShareSheet: UIViewControllerRepresentable {
    var url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The project tab's outline: attached along the top edge with flared shoulders and rounded lower
/// corners, so it reads as part of the screen's edge rather than a floating card.
struct TopTab: Shape {
    static let flare: CGFloat = 14
    var radius: CGFloat = 20
    func path(in rect: CGRect) -> Path {
        let flare = Self.flare
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY - 1))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.minX + flare, y: rect.minY), tangent2End: CGPoint(x: rect.minX + flare, y: rect.maxY), radius: flare)
        path.addArc(tangent1End: CGPoint(x: rect.minX + flare, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - flare, y: rect.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.maxX - flare, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - flare, y: rect.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.maxX - flare, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: flare)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY - 1))
        path.closeSubpath()
        return path
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A brand tile that dims with its button's enabled state.
private struct BrandTile: View {
    let icon: SSIcon
    var selected = false
    @Environment(\.isEnabled) private var enabled
    var body: some View { SSIconTile(icon: icon, selected: selected, enabled: enabled) }
}

/// A strip action: brand glyph and name, dimming with its button's enabled state.
private struct StripLabel: View {
    let title: String
    let icon: SSIcon
    /// Marks an action that opens a menu of tools.
    var showsMenu = false
    /// Marks a Pro tool while Pro is not owned.
    var pro = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing: 5) {
            SSIconGlyph(icon: icon, size: 20, color: icon == .delete ? Color("ss-coral") : ink)
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(ink).lineLimit(1).fixedSize()
            if pro { ProBadge() }
            if showsMenu { Text("▾").font(.system(size: 11, weight: .semibold)).foregroundStyle(muted).accessibilityHidden(true) }
        }
        .opacity(enabled ? 1 : 0.4)
        .padding(.horizontal, 8).frame(height: 36)
        .background(Color("ss-neutral"), in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
    }
}

/// Marks a Pro tool while Pro is not owned: the tool still opens and previews, and keeping what it
/// makes asks for Swipe & Sketch Pro.
private struct ProBadge: View {
    var body: some View {
        Text("PRO").font(.system(size: 8, weight: .heavy)).foregroundStyle(paper)
            .padding(.horizontal, 4).padding(.vertical, 1.5)
            .background(violet, in: Capsule())
            .accessibilityHidden(true)
    }
}

/// Dock tiles that stand for several tools, which pop up above the tile. Each group is named for what
/// its tools do, never for one of them (October 22, 2026): Create makes solids, Modify changes one solid,
/// Combine joins or cuts solids with others, Transform moves, resizes, and copies, Joints makes parts
/// that fit together, and Planes adds construction planes. Case names keep their earlier spellings
/// because they are the tiles' accessibility identifiers (`tool.edges` is Modify, `tool.fit` Joints).
enum ToolGroup: String, CaseIterable {
    case create, edges, combine, fit, transform, planes
    /// Sketch dock groups: more shapes to draw, the tools that change drawn shapes, and features placed on a face.
    case curves, modify, faceFeatures
    var tools: [ModelingTool] {
        switch self {
        case .curves: [.circle, .arc, .slot, .ellipse, .polygon, .spline, .point]
        case .modify: [.trim, .extend, .cornerFillet, .offset, .sketchMirror]
        case .create: [.extrude, .revolve, .loft, .sweep, .rib, .box, .cylinder, .sphere, .torus]
        case .edges: [.fillet, .chamfer, .shell, .draft, .deleteFace, .split]
        case .combine: [.union, .subtract, .intersect]
        case .fit: [.peg, .thread, .screwLid, .fitTest]
        case .faceFeatures: [.hole, .peg, .text]
        case .transform: [.align, .scale, .mirror, .pattern]
        case .planes: [.offsetPlane, .midplane, .planeAngle, .plane3Point, .planeTangent, .axis]
        }
    }
    var title: String {
        switch self {
        case .create: "Create"; case .edges: "Modify"; case .combine: "Combine"; case .fit: "Joints"; case .transform: "Transform"; case .planes: "Planes"
        case .curves: "Shapes"; case .modify: "Modify"; case .faceFeatures: "Features"
        }
    }
    var icon: SSIcon {
        switch self {
        case .create: .extrude; case .edges: .fillet; case .combine: .merge; case .fit: .peg; case .transform: .align; case .planes: .plane
        case .curves: .circle; case .modify: .trim; case .faceFeatures: .hole
        }
    }
    func title(for tool: ModelingTool) -> String {
        switch tool {
        case .split: "Split Body"
        case .peg: "Peg & Socket"
        default: tool.title
        }
    }
}

private struct ActionLabel: View {
    let title: String
    let icon: SSIcon
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing: 7) {
            SSIconGlyph(icon: icon, size: 25, color: icon == .done ? paper : ink)
                .frame(width: 32, height: 32)
                .background(icon == .done ? violet : Color("ss-neutral"), in: RoundedRectangle(cornerRadius: 9))
            Text(title).font(.system(size: 16)).foregroundStyle(ink)
        }
        .opacity(enabled ? 1 : 0.4)
        .padding(.leading, 8).padding(.trailing, 16).frame(height: 48)
        .background(white, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}

func formatted(_ value: Double) -> String { value.formatted(.number.grouping(.never).precision(.fractionLength(0...2))) }
/// A length given in millimeters, in `unit`, without the unit's symbol.
func formatted(length millimeters: Double, unit: LengthUnit) -> String {
    (millimeters / unit.millimeters).formatted(.number.grouping(.never).precision(.fractionLength(0...unit.fractionDigits)))
}

private struct DimensionKeypad: View {
    @ObservedObject var session: ModelingSession
    let edit: DimensionEdit
    @State private var expression = ""
    @State private var replaceAll = true
    @State private var error: String?
    private let spacing: CGFloat = 4
    /// Lengths are typed in the chosen unit; angles in degrees.
    private var unit: LengthUnit { edit.target.isLength ? session.lengthUnit : .millimeters }
    /// The typed value in millimeters (or degrees).
    private var evaluated: Double? { DimensionExpression.evaluate(expression, unit: unit).map { $0 * unit.millimeters } }
    private var valid: Bool { evaluated.map { $0.isFinite && abs($0) >= 0.01 && abs($0) <= 10_000 && (edit.target.allowsNegative || $0 > 0) } ?? false }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(expression.isEmpty ? "0" : expression)
                        .font(.system(size: 23)).foregroundStyle(ink)
                        .padding(.horizontal, 3)
                        .background(replaceAll ? violet.opacity(0.11) : .clear)
                        .lineLimit(1).minimumScaleFactor(0.45)
                        .accessibilityIdentifier("keypad.expression").accessibilityValue(expression)
                    if let error { Text(error).font(.system(size: 10)).foregroundStyle(coral) }
                    else if edit.target.unit.isEmpty { Text(session.dimensionTitle(edit.target)).font(.system(size: 10)).foregroundStyle(muted) }
                    else { Text("\(session.dimensionTitle(edit.target)) · \(edit.target.isLength ? session.lengthUnit.symbol : edit.target.unit)").font(.system(size: 10)).foregroundStyle(muted) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { session.dimensionEdit = nil } label: { SSIconGlyph(icon: .exit, size: 22, color: ink).frame(width: 28, height: 34) }
                    .foregroundStyle(ink).accessibilityLabel("Cancel dimension").accessibilityIdentifier("keypad.cancel")
            }
            .padding(.horizontal, 10).frame(height: 49)
            .background(Color("ss-lavender"), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 2) {
                ForEach(["(", ")", "mm", "cm", "m", "in"], id: \.self) { value in
                    Button(value) { input(value) }.font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ink).frame(maxWidth: .infinity).frame(height: 29)
                        .accessibilityIdentifier("keypad.\(value)")
                }
            }
            HStack(alignment: .top, spacing: spacing) {
                VStack(spacing: spacing) {
                    keyRow(["7", "8", "9", "÷"])
                    keyRow(["4", "5", "6", "×"])
                    keyRow(["1", "2", "3", "−"])
                    keyRow(["±", "0", ".", "+"])
                }
                VStack(spacing: spacing) {
                    key("⌫", icon: .backspace)
                    key("C")
                    Button { confirm() } label: {
                        SSIconGlyph(icon: .done, size: 30, color: paper)
                            .frame(width: 55, height: 96).background(violet.opacity(valid ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain).disabled(!valid).accessibilityLabel("Apply dimension").accessibilityIdentifier("keypad.confirm")
                }
            }
        }
        .padding(9)
        .background(white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(hairline))
        .compositingGroup()
        .shadow(color: .black.opacity(0.16), radius: 22, y: 7)
        .onAppear { expression = edit.target.isLength ? formatted(length: edit.value, unit: unit) : formatted(edit.value) }
    }

    private func keyRow(_ keys: [String]) -> some View {
        HStack(spacing: spacing) { ForEach(keys, id: \.self) { key($0) } }
    }
    private func key(_ value: String, icon: SSIcon? = nil) -> some View {
        Button { input(value) } label: {
            Group {
                if let icon { SSIconGlyph(icon: icon, size: 26, color: ink) }
                else { Text(value).font(.system(size: 23, weight: .medium)) }
            }
            .foregroundStyle(ink).frame(width: 55, height: 46)
            .background(Color("ss-neutral"), in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).accessibilityLabel(value == "⌫" ? "Backspace" : value)
            .accessibilityIdentifier("keypad.\(value)")
    }
    private func input(_ value: String) {
        error = nil
        switch value {
        case "C": expression = ""; replaceAll = false
        case "⌫":
            if replaceAll { expression = "" } else if !expression.isEmpty { expression.removeLast() }
            replaceAll = false
        case "±":
            if expression.hasPrefix("-") { expression.removeFirst() } else { expression = "-(\(expression))" }
            replaceAll = false
        default:
            let extends = ["+", "−", "×", "÷", "mm", "cm", "m", "in", ")"].contains(value)
            // Retyping a negative value keeps its sign: the new amount is most likely negative too.
            if replaceAll && !extends { expression = expression.hasPrefix("-") || expression.hasPrefix("−") ? "-" : "" }
            replaceAll = false
            if expression.count + value.count <= 128 { expression += value }
        }
    }
    private func confirm() {
        guard let value = evaluated, session.applyDimension(value, target: edit.target) else {
            error = session.dimensionError ?? "This value would collapse a joined edge."; return
        }
    }
}
