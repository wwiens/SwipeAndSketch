import SwiftUI
import UniformTypeIdentifiers

/// SVG Import: a read drawing sized, grouped, and placed before it comes in, with a preview of
/// exactly what will be added and notes on what the file had that could not become geometry.
struct SVGImportSheet: View {
    @Bindable var session: ModelingSession
    let request: SVGImportRequest

    @State private var options: SVGImport.Options
    @State private var widthText = ""
    @State private var heightText = ""
    @State private var solidHeightText = ""
    @State private var makeSolids = false
    @State private var solidHeight = 2.0
    @State private var layout: SVGImport.Layout?
    @State private var problem: String?
    @State private var working = true

    private var drawing: SVGImport.Drawing { request.drawing }
    private var unit: LengthUnit { session.lengthUnit }
    /// Height over width, which the size keeps.
    private var aspect: Double {
        let bounds = drawing.bounds
        return bounds.width > 0 ? Double(bounds.height / bounds.width) : 1
    }

    init(session: ModelingSession, request: SVGImportRequest) {
        self.session = session
        self.request = request
        var options = SVGImport.defaultOptions(for: request.drawing)
        // On a face, a drawing bigger than the face starts at most two thirds of it.
        if let face = request.target.face, face.width > 0, face.height > 0 {
            let bounds = request.drawing.bounds
            let fit = min(Double(face.width) / max(1e-9, Double(bounds.width)), Double(face.height) / max(1e-9, Double(bounds.height))) * 2 / 3
            if fit < 1 { options.width = max(0.1, Double(bounds.width) * fit) }
        }
        _options = State(initialValue: options)
    }

    private struct Key: Equatable { var options: SVGImport.Options; var solids: Double? }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SVGImportPreview(layout: layout, working: working)
                        .frame(height: 240)
                        .listRowInsets(EdgeInsets())
                        .accessibilityIdentifier("svgImport.preview")
                } footer: {
                    Text(summary).accessibilityIdentifier("svgImport.summary")
                }
                sizeSection
                groupingSection
                if drawing.hasStrokes { strokesSection }
                Section {
                    Picker("Detail", selection: $options.detail) {
                        ForEach(SVGImport.Detail.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).accessibilityIdentifier("svgImport.detail")
                } header: { Text("Curve Detail") } footer: {
                    Text("How closely lines and arcs follow the drawing's curves: within \(tolerance(.fine)) for Fine, \(tolerance(.standard)) for Standard, or \(tolerance(.coarse)) for Coarse, which makes the fewest shapes.")
                }
                if drawing.hasImages { picturesSection }
                Section {
                    Toggle("Keep the File's Position", isOn: $options.keepFilePosition).accessibilityIdentifier("svgImport.keepPosition")
                } footer: {
                    Text(options.keepFilePosition ? "The file's own origin (its top-left corner) goes on the \(request.target.face != nil ? "face's center" : "origin")."
                                                  : "The drawing is centered on the \(request.target.face != nil ? "selected face" : "origin of the \(request.target.placement.plane.title) plane").")
                }
                solidsSection
                if let problem {
                    Section { Text(problem).foregroundStyle(Color("ss-coral")) }
                        .accessibilityIdentifier("svgImport.problem")
                }
                if let notes = layout?.warnings.messages, !notes.isEmpty {
                    Section("Notes") {
                        ForEach(notes, id: \.self) { Text($0).font(.footnote).foregroundStyle(Color("ss-muted")) }
                    }
                    .accessibilityIdentifier("svgImport.notes")
                }
            }
            .scrollContentBackground(.hidden).background(Color("ss-canvas"))
            .navigationTitle("Import \(drawing.name)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { session.cancelSVGImport() }.accessibilityIdentifier("svgImport.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { if let layout { session.confirmSVGImport(layout) } }
                        .disabled(layout == nil || working || problem != nil || layout?.isEmpty == true && layout?.solids.isEmpty == true)
                        .accessibilityIdentifier("svgImport.confirm")
                }
            }
            .task(id: Key(options: options, solids: makeSolids ? solidHeight : nil)) { await relayout() }
            .onAppear { showSize(); solidHeightText = formatted(solidHeight) }
        }
        .tint(Color("ss-violet"))
        .preferredColorScheme(.light)
    }

    // MARK: Sections

    private var sizeSection: some View {
        Section {
            HStack {
                Text("Width")
                Spacer()
                TextField("Width", text: $widthText).multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation)
                    .frame(maxWidth: 140).onSubmit { applyWidth() }.accessibilityIdentifier("svgImport.width")
                Text(unit.symbol).foregroundStyle(Color("ss-muted"))
            }
            HStack {
                Text("Height")
                Spacer()
                TextField("Height", text: $heightText).multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation)
                    .frame(maxWidth: 140).onSubmit { applyHeight() }.accessibilityIdentifier("svgImport.height")
                Text(unit.symbol).foregroundStyle(Color("ss-muted"))
            }
            HStack {
                Button("As in the File") { options.width = Double(drawing.bounds.width); showSize() }
                    .accessibilityIdentifier("svgImport.originalSize")
                if let face = request.target.face {
                    Spacer()
                    Button("Fit to Face") { fit(face) }.accessibilityIdentifier("svgImport.fitFace")
                }
            }
            .buttonStyle(.borderless)
        } header: { Text("Size") } footer: {
            Text(drawing.hasPhysicalSize ? "The file gives its real size. Width and height keep its proportions."
                                         : "The file gives its size only in pixels, read at 96 to the inch (as browsers do). Type the size it should be.")
        }
    }

    private var groupingSection: some View {
        Section {
            Picker("Sketches", selection: $options.grouping) {
                Text(SVGImport.Grouping.single.title).tag(SVGImport.Grouping.single)
                if drawing.layerCount > 1 { Text(SVGImport.Grouping.layers.title).tag(SVGImport.Grouping.layers) }
                if drawing.colors.count > 1 { Text(SVGImport.Grouping.colors.title).tag(SVGImport.Grouping.colors) }
            }
            .pickerStyle(.segmented).accessibilityIdentifier("svgImport.grouping")
        } header: { Text("Sketches") } footer: {
            switch options.grouping {
            case .single: Text("Everything in one sketch. Shapes of one color that overlap are joined into one outline.")
            case .layers: Text("A sketch for each of the file's layers (its top-level groups), named after it.")
            case .colors: Text("A sketch for each color, holding only what shows of it: a color painted over another takes its place there.")
            }
        }
    }

    private var strokesSection: some View {
        Section {
            Picker("Strokes", selection: $options.strokes) {
                ForEach(SVGImport.Strokes.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).accessibilityIdentifier("svgImport.strokes")
        } header: { Text("Strokes") } footer: {
            switch options.strokes {
            case .auto: Text("Lines thinner than \(session.lengthText(SVGImport.hairline)), such as cut lines, come in as the line itself; wider ones as their outline, which can be extruded.")
            case .outline: Text("Every stroke comes in as the outline of its width, so line art can be extruded.")
            case .centerline: Text("Every stroke comes in as the line it follows. Closed ones bound regions; open ones are lines only.")
            }
        }
    }

    private var picturesSection: some View {
        Section {
            Toggle("Trace Pictures", isOn: $options.traceImages).accessibilityIdentifier("svgImport.trace")
            if options.traceImages {
                VStack(alignment: .leading) {
                    Text("Threshold \(Int((options.tracing.threshold * 100).rounded()))%").font(.subheadline)
                    Slider(value: $options.tracing.threshold, in: 0.05...0.95, step: 0.05).accessibilityIdentifier("svgImport.threshold")
                }
                Toggle("Trace the Light Parts", isOn: $options.tracing.invert).accessibilityIdentifier("svgImport.invert")
            }
        } header: { Text("Pictures") } footer: {
            Text("Pictures inside the file are traced into outlines: the dark parts, or the opaque ones of a picture with transparency. Raise the threshold to take in lighter shades.")
        }
    }

    private var solidsSection: some View {
        Section {
            Toggle("Make Solids", isOn: $makeSolids).accessibilityIdentifier("svgImport.solids")
            if makeSolids {
                HStack {
                    Text("Height")
                    Spacer()
                    TextField("Height", text: $solidHeightText).multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation)
                        .frame(maxWidth: 140).onSubmit { applySolidHeight() }.accessibilityIdentifier("svgImport.solidHeight")
                    Text(unit.symbol).foregroundStyle(Color("ss-muted"))
                }
                Toggle("Leave Out White", isOn: $options.leaveOutWhite).accessibilityIdentifier("svgImport.leaveOutWhite")
            }
        } header: { Text("Solids") } footer: {
            Text(makeSolids ? "A solid for each region of each color, standing on the \(request.target.face != nil ? "face" : "plane") and colored to match (the nearest of the app's colors), for a multicolor print. The sketches come in too, hidden."
                            : "Only sketches come in. Extrude their regions afterwards, or make solids here.")
        }
    }

    // MARK: Size entry

    private func formatted(_ millimeters: Double) -> String {
        let value = millimeters / unit.millimeters
        return value.formatted(.number.precision(.fractionLength(0...unit.fractionDigits)).grouping(.never))
    }

    /// A detail's tolerance, with as many decimals as it takes.
    private func tolerance(_ detail: SVGImport.Detail) -> String {
        (detail.tolerance / unit.millimeters).formatted(.number.precision(.significantDigits(1...2))) + " " + unit.symbol
    }

    private func showSize() {
        widthText = formatted(options.width)
        heightText = formatted(options.width * aspect)
    }

    private func applyWidth() {
        guard let value = DimensionExpression.evaluate(widthText, unit: unit), value > 0, value <= 50_000 else { showSize(); return }
        options.width = value
        showSize()
    }

    private func applyHeight() {
        guard let value = DimensionExpression.evaluate(heightText, unit: unit), value > 0, value <= 50_000, aspect > 0 else { showSize(); return }
        options.width = value / aspect
        showSize()
    }

    private func applySolidHeight() {
        guard let value = DimensionExpression.evaluate(solidHeightText, unit: unit), abs(value) >= 0.01, abs(value) <= 10_000 else {
            solidHeightText = formatted(solidHeight); return
        }
        solidHeight = value
        solidHeightText = formatted(value)
    }

    private func fit(_ face: CGSize) {
        let bounds = drawing.bounds
        let scale = min(Double(face.width) / max(1e-9, Double(bounds.width)), Double(face.height) / max(1e-9, Double(bounds.height))) * 0.8
        options.width = max(0.1, Double(bounds.width) * scale)
        showSize()
    }

    // MARK: Layout

    private var summary: String {
        if working { return "Fitting the drawing…" }
        guard let layout else { return problem ?? "" }
        let size = "\(session.lengthText(layout.size.width)) × \(session.lengthText(layout.size.height))"
        let sketches = layout.sketches.count, shapes = layout.shapeCount, solids = layout.solids.count
        return "\(size): \(sketches) \(sketches == 1 ? "sketch" : "sketches") of \(shapes) \(shapes == 1 ? "shape" : "shapes")" +
            (solids > 0 ? ", \(solids) \(solids == 1 ? "solid" : "solids")" : "")
    }

    private func relayout() async {
        working = true
        // Typing and dragging settle before the drawing is fitted again.
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        var options = options
        options.solidHeight = makeSolids ? solidHeight : nil
        let drawing = drawing, placement = request.target.placement
        let result = await Task.detached(priority: .userInitiated) {
            Result { try SVGImport.layout(drawing, options: options, placement: placement) }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let made):
            layout = made
            problem = made.isEmpty && made.solids.isEmpty ? "Nothing in the drawing makes a shape with these options." : nil
        case .failure(let error):
            layout = nil
            problem = error.localizedDescription
        }
        working = false
    }
}

/// The laid-out drawing as it will come in: each sketch's shapes in its color, and solids filled.
struct SVGImportPreview: View {
    var layout: SVGImport.Layout?
    var working: Bool

    var body: some View {
        ZStack {
            Color("ss-white")
            if let layout, !layout.isEmpty || !layout.solids.isEmpty {
                Canvas { context, size in draw(layout, in: &context, size: size) }
                    .padding(16)
            }
            if working { ProgressView().controlSize(.large) }
        }
    }

    private func draw(_ layout: SVGImport.Layout, in context: inout GraphicsContext, size: CGSize) {
        let outlines = layout.sketches.flatMap(\.shapes).map(\.outline) + layout.solids.map(\.profile.outline)
        let points = outlines.flatMap { $0 }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(), let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return }
        let scale = min(size.width / max(1e-9, maxX - minX), size.height / max(1e-9, maxY - minY))
        let offset = CGPoint(x: (size.width - (maxX - minX) * scale) / 2, y: (size.height - (maxY - minY) * scale) / 2)
        // Sketch Y runs up; the screen's down.
        func p(_ point: Point2) -> CGPoint { CGPoint(x: offset.x + (point.x - minX) * scale, y: offset.y + (maxY - point.y) * scale) }
        func color(_ svg: SVGColor?) -> Color {
            guard let svg else { return Color("ss-ink") }
            return Color(red: svg.red, green: svg.green, blue: svg.blue)
        }
        for solid in layout.solids {
            var path = Path()
            for loop in [solid.profile.outline] + (solid.profile.holes ?? []).map(\.outline) where loop.count > 2 {
                path.move(to: p(loop[0]))
                for point in loop.dropFirst() { path.addLine(to: p(point)) }
                path.closeSubpath()
            }
            let rgb = (solid.color ?? .gray).rgb
            context.fill(path, with: .color(Color(red: rgb.red, green: rgb.green, blue: rgb.blue).opacity(0.85)), style: FillStyle(eoFill: true))
        }
        for sketch in layout.sketches {
            var path = Path()
            for shape in sketch.shapes {
                let outline = shape.outline
                guard let first = outline.first else { continue }
                path.move(to: p(first))
                for point in outline.dropFirst() { path.addLine(to: p(point)) }
                if shape.isClosed { path.closeSubpath() }
            }
            // A white sketch would vanish on white: drawn in a mid gray.
            let shown = sketch.color.map { $0.isWhite ? Color("ss-muted") : color($0) } ?? Color("ss-ink")
            context.stroke(path, with: .color(layout.solids.isEmpty ? shown : shown.opacity(0.4)), lineWidth: 1)
        }
    }
}
