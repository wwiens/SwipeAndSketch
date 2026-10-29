import SceneKit
import SwiftUI

private let ink = Color("ss-ink")
private let muted = Color("ss-muted")
private let violet = Color("ss-violet")
private let paper = Color("ss-paper")
private let coral = Color("ss-coral")
private let hairline = Color("ss-border")
private let canvas = Color("ss-canvas")
private let card = Color("ss-white")

/// New Project (October 21, 2026): a blank project, or a template set up with a few sizes and
/// choices before it is made (Core/Templates.swift). Opened from the Files browser's + and the
/// project menu, and shown in Home's Templates (October 22, 2026, without Cancel); `onCreate` gets
/// the new project and its suggested file name, then the usual save sheet asks where to put it.
struct TemplateGallery: View {
    var title = "New Project"
    /// A category to show first (Home's Start Something cards).
    var category: ProjectTemplate.Category? = nil
    var onCreate: (Project, String) -> Void
    var onCancel: (() -> Void)?
    @State private var path: [String] = []
    @StateObject private var thumbnails = TemplateThumbnails.shared
    @ObservedObject private var license = LicenseStore.shared
    private let templates = TemplateCatalog.all

    var body: some View {
        NavigationStack(path: $path) {
          ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        Button { onCreate(Project(), "Untitled Project") } label: { blankCard }
                            .buttonStyle(.plain).accessibilityIdentifier("templates.blank")
                    }
                    ForEach(ProjectTemplate.Category.allCases, id: \.self) { category in
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.title).font(.system(size: 22, weight: .bold)).foregroundStyle(ink)
                                Text(category.summary).font(.system(size: 14)).foregroundStyle(muted)
                            }
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                                ForEach(templates.filter { $0.category == category }) { template in
                                    NavigationLink(value: template.id) { templateCard(template) }
                                        .buttonStyle(.plain).accessibilityIdentifier("templates.\(template.id)")
                                }
                            }
                            if let notice = category.notice {
                                Text(notice).font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("templates.notice.\(category.rawValue)")
                            }
                        }
                        .id(category)
                    }
                }
                .padding(24)
            }
            .onAppear { if let category { scroller.scrollTo(category, anchor: .top) } }
            .onChange(of: category) { _, category in
                if let category { withAnimation { scroller.scrollTo(category, anchor: .top) } }
            }
          }
            .background(canvas)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onCancel {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel).accessibilityIdentifier("templates.cancel") }
                }
            }
            .navigationDestination(for: String.self) { id in
                if let template = TemplateCatalog.template(id) { TemplateSetup(template: template, onCreate: onCreate) }
            }
        }
        .tint(violet)
        .task { thumbnails.load(templates) }
    }

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 16, alignment: .top)] }

    private var blankCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(canvas)
                SSIconTile(icon: .newProject)
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            VStack(alignment: .leading, spacing: 3) {
                Text("Blank Project").font(.system(size: 17, weight: .semibold)).foregroundStyle(ink)
                Text("Start from an empty grid.").font(.system(size: 13)).foregroundStyle(muted)
            }
        }
        .cardStyle()
    }

    private func templateCard(_ template: ProjectTemplate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(canvas)
                if let image = thumbnails.picture(of: template) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ProgressView()
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(template.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(ink)
                    if template.needsPro && !license.access.ownsPro {
                        Text("PRO").font(.system(size: 9, weight: .heavy)).foregroundStyle(paper)
                            .padding(.horizontal, 5).padding(.vertical, 2).background(violet, in: Capsule())
                            .accessibilityLabel("Pro")
                    }
                }
                Text(template.summary).font(.system(size: 13)).foregroundStyle(muted).lineLimit(4, reservesSpace: true)
            }
        }
        .cardStyle()
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(12)
            .background(card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// Card pictures of each template at its default sizes: drawn ahead of time into the asset catalog
/// (Scripts/render_template_pictures.sh), so the gallery opens at once. A template without one
/// (just added, say) is built and drawn here instead, once per launch.
@MainActor final class TemplateThumbnails: ObservableObject {
    static let shared = TemplateThumbnails()
    @Published private(set) var images: [String: UIImage] = [:]
    private var loading = false

    func picture(of template: ProjectTemplate) -> UIImage? { images[template.id] ?? UIImage(named: template.pictureName) }

    func load(_ templates: [ProjectTemplate]) {
        let missing = templates.filter { picture(of: $0) == nil }
        guard !loading, !missing.isEmpty else { return }
        loading = true
        Task {
            for template in missing {
                let parts = await Task.detached(priority: .userInitiated) { () -> [ModelPicture.Part] in
                    (try? template.workspace(template.pictureValues)).map(ModelPicture.parts(of:)) ?? []
                }.value
                if let image = ModelPicture.image(parts: parts, side: 480) { images[template.id] = image }
            }
            loading = false
        }
    }
}

// MARK: Setting up a template

/// A template's sizes and choices beside a live preview that fingers can turn and zoom.
struct TemplateSetup: View {
    let template: ProjectTemplate
    var onCreate: (Project, String) -> Void
    @State private var values: TemplateValues
    @StateObject private var preview = TemplatePreview()
    @ObservedObject private var license = LicenseStore.shared
    @State private var showPurchases = false
    private let unit = LengthUnit(rawValue: UserDefaults.standard.string(forKey: "lengthUnit") ?? "") ?? .millimeters

    init(template: ProjectTemplate, onCreate: @escaping (Project, String) -> Void) {
        self.template = template
        self.onCreate = onCreate
        _values = State(initialValue: template.defaults)
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                ModelPreviewView(parts: preview.parts, version: preview.version)
                    .accessibilityLabel("Preview of the \(template.title)")
                status.padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            panel.frame(width: 380)
        }
        .background(canvas)
        .navigationTitle(template.title).navigationBarTitleDisplayMode(.inline)
        .onAppear { preview.update(template, values) }
        .onChange(of: values) { _, values in preview.update(template, values) }
        .sheet(isPresented: $showPurchases) { PurchasesView { showPurchases = false } }
    }

    @ViewBuilder private var status: some View {
        switch preview.state {
        case .building:
            HStack(spacing: 8) { ProgressView(); Text("Building…").foregroundStyle(muted) }
                .font(.system(size: 14)).padding(.horizontal, 14).padding(.vertical, 8)
                .background(card, in: Capsule()).overlay(Capsule().stroke(hairline))
        case .failed(let message):
            Text(message).font(.system(size: 14, weight: .medium)).foregroundStyle(coral).multilineTextAlignment(.center)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(card, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(hairline))
                .accessibilityIdentifier("templates.error")
        case .ready:
            Text("Drag with a finger to turn it; pinch to zoom.").font(.system(size: 13)).foregroundStyle(muted)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(template.summary).font(.system(size: 15)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    ForEach(template.parameters.filter { $0.isShown(values) }) { parameter in
                        ParameterRow(parameter: parameter, value: binding(parameter), unit: unit)
                    }
                    Text("Once made, these are ordinary solids: change them with any tool.")
                        .font(.system(size: 13)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    if let notice = template.category.notice {
                        Text(notice).font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    }
                    if needsPro {
                        // Decision 8: every template sets up and previews for free; making this one needs Pro.
                        Text("Set it up and preview it for free. Making this template needs Swipe & Sketch Pro; the plain Gridfinity Baseplate and Bin are free.")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(violet).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Button("Defaults") { values = template.defaults }
                    .disabled(values == template.defaults).accessibilityIdentifier("templates.defaults")
                Spacer()
                Button(action: create) {
                    Text(needsPro ? "Create with Pro" : "Create Project").font(.system(size: 17, weight: .semibold)).foregroundStyle(paper)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(preview.isReady ? violet : muted.opacity(0.5), in: Capsule())
                }
                .buttonStyle(.plain).disabled(!preview.isReady).accessibilityIdentifier("templates.create")
            }
            .padding(16)
        }
        .background(card)
    }

    private func binding(_ parameter: TemplateParameter) -> Binding<Double> {
        Binding(get: { values[parameter.id] }, set: { values[parameter.id] = parameter.clamped($0) })
    }

    private var needsPro: Bool { template.needsPro && !license.access.ownsPro }

    private func create() {
        guard !needsPro else { showPurchases = true; return }
        guard let workspace = preview.workspace, preview.isReady else { return }
        var project = Project(workspace: workspace)
        project.preview = ModelPicture.image(parts: preview.parts, side: CGFloat(ProjectPreview.side))?.pngData()
            .flatMap { $0.count <= ProjectPreview.maximumBytes ? $0 : nil }
        onCreate(project, template.name(template.clamped(values)))
    }
}

/// One size or choice of a template.
private struct ParameterRow: View {
    let parameter: TemplateParameter
    @Binding var value: Double
    let unit: LengthUnit
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            control
            if let note = parameter.note {
                Text(note).font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("templates.parameter.\(parameter.id)")
    }

    @ViewBuilder private var control: some View {
        switch parameter.kind {
        case .count(let range):
            Stepper(value: Binding(get: { Int(value.rounded()) }, set: { value = Double($0) }), in: range) {
                HStack { title; Spacer(); Text("\(Int(value.rounded()))").font(.system(size: 17, weight: .semibold).monospacedDigit()).foregroundStyle(ink) }
            }
        case .length(_, let step):
            Stepper {
                HStack {
                    title
                    Spacer()
                    TextField("", text: $text)
                        .multilineTextAlignment(.trailing).keyboardType(.decimalPad).focused($editing)
                        .font(.system(size: 17, weight: .semibold).monospacedDigit()).foregroundStyle(ink)
                        .frame(width: 64)
                        .onSubmit(commit)
                    Text(unit.symbol).font(.system(size: 15)).foregroundStyle(muted)
                }
            } onIncrement: { value = value + step } onDecrement: { value = value - step }
            .onAppear { text = format(value) }
            .onChange(of: value) { _, new in if !editing { text = format(new) } }
            .onChange(of: editing) { _, now in if !now { commit() } }
        case .choice(let options):
            if options.count <= 3 && options.allSatisfy({ $0.count <= 14 }) {
                VStack(alignment: .leading, spacing: 8) {
                    title
                    Picker(parameter.title, selection: Binding(get: { Int(value.rounded()) }, set: { value = Double($0) })) {
                        ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            } else {
                // Long option names (boards) get a full-width row of their own, on one line.
                let selected = min(max(Int(value.rounded()), 0), options.count - 1)
                VStack(alignment: .leading, spacing: 8) {
                    title
                    Menu {
                        Picker(parameter.title, selection: Binding(get: { selected }, set: { value = Double($0) })) {
                            ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(options[selected]).font(.system(size: 16, weight: .medium)).foregroundStyle(violet)
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 8)
                            SSIconGlyph(icon: .disclosure, size: 16, color: violet).rotationEffect(.degrees(90))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(canvas, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(hairline))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityLabel(parameter.title)
                    .accessibilityValue(options[selected])
                    .accessibilityIdentifier("templates.menu.\(parameter.id)")
                }
            }
        case .toggle:
            Toggle(isOn: Binding(get: { value >= 0.5 }, set: { value = $0 ? 1 : 0 })) { title }
        }
    }

    private var title: some View { Text(parameter.title).font(.system(size: 16)).foregroundStyle(ink).layoutPriority(1) }

    /// Millimeters shown in the display unit, without trailing zeros.
    private func format(_ millimeters: Double) -> String {
        let shown = millimeters / unit.millimeters
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = unit.fractionDigits
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: shown)) ?? String(shown)
    }

    /// A typed value (it may carry a unit, or be a sum) in the display unit, kept within range.
    private func commit() {
        if let typed = DimensionExpression.evaluate(text, unit: unit) { value = typed * unit.millimeters }
        text = format(value)
    }
}

/// Builds a template's solids off the main thread as its values change, a moment after the last
/// change, keeping the last good picture on screen meanwhile.
@MainActor final class TemplatePreview: ObservableObject {
    enum State: Equatable { case building, ready, failed(String) }
    @Published private(set) var state = State.building
    @Published private(set) var parts: [ModelPicture.Part] = []
    /// Bumped with each new set of parts, so the preview view knows to redraw.
    @Published private(set) var version = 0
    private(set) var workspace: Workspace?
    private var task: Task<Void, Never>?
    var isReady: Bool { state == .ready && workspace != nil }

    func update(_ template: ProjectTemplate, _ values: TemplateValues) {
        task?.cancel()
        state = .building
        let first = version == 0
        task = Task {
            if !first {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            let built = await Task.detached(priority: .userInitiated) { () -> Result<(Workspace, [ModelPicture.Part]), Error> in
                Result { let workspace = try template.workspace(values); return (workspace, ModelPicture.parts(of: workspace)) }
            }.value
            guard !Task.isCancelled else { return }
            switch built {
            case .success(let (workspace, parts)) where parts.count == workspace.bodies.count:
                self.workspace = workspace
                self.parts = parts
                version += 1
                state = .ready
            case .success:
                workspace = nil
                state = .failed(TemplateError.failed(template.title).localizedDescription)
            case .failure(let error):
                workspace = nil
                state = .failed(error.localizedDescription)
            }
        }
    }
}

/// The live preview: SceneKit's own camera control, turning about the model's center with Z up.
/// A new set of parts keeps the angle the user turned to and fits the model again.
private struct ModelPreviewView: UIViewRepresentable {
    var parts: [ModelPicture.Part]
    var version: Int

    final class Coordinator { var shown = -1 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(named: "ss-canvas")
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.worldUp = SCNVector3(0, 0, 1)
        view.defaultCameraController.inertiaEnabled = true
        view.cameraControlConfiguration.allowsTranslation = false
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard context.coordinator.shown != version else { return }
        context.coordinator.shown = version
        guard let drawn = ModelPicture.scene(parts: parts, pixels: 0.85 * Double(view.contentScaleFactor)) else { view.scene = nil; return }
        if let previous = view.pointOfView, previous.camera != nil, view.scene != nil {
            // Keep the turned angle; look at the new model's center from there.
            drawn.camera.simdOrientation = previous.simdOrientation
            drawn.camera.simdPosition = drawn.center + previous.simdWorldFront * -50_000
        }
        view.scene = drawn.scene
        view.pointOfView = drawn.camera
        view.defaultCameraController.target = SCNVector3(drawn.center)
    }
}
