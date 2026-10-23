import SwiftUI

private let ink = Color("ss-ink")
private let muted = Color("ss-muted")
private let violet = Color("ss-violet")
private let paper = Color("ss-paper")
private let hairline = Color("ss-border")
private let canvas = Color("ss-canvas")
private let card = Color("ss-white")

/// What Home shows and what its buttons ask of the controller that owns the projects.
@MainActor final class HomeModel: ObservableObject {
    enum Section: String { case home, templates, files }
    @Published var section = Section.home { didSet { if section == .files { filesShown = true } } }
    /// The template category a Start Something card asked for.
    @Published var category: ProjectTemplate.Category?
    /// The Files browser stays loaded once shown, so it keeps its place between visits.
    @Published private(set) var filesShown = false
    /// Changed after a template is made, so Templates starts from its gallery again.
    @Published var galleryID = UUID()

    var newBlankProject: () -> Void = { }
    var create: (Project, String) -> Void = { _, _ in }
    var open: (RecentProject) -> Void = { _ in }
    var showInFiles: (RecentProject) -> Void = { _ in }
}

/// The app's opening page (October 22, 2026): a rail of brand tiles (Home, Templates, Files); Home
/// itself has a Start Something shelf (Blank Project and the template categories) and the recent
/// projects with their pictures. Files is the system document browser, for everything else.
struct HomeView: View {
    @ObservedObject var model: HomeModel
    let browser: UIViewController
    @ObservedObject private var recents = RecentProjects.shared
    @ObservedObject private var license = LicenseStore.shared
    @StateObject private var thumbnails = TemplateThumbnails.shared
    @State private var showAbout = false
    @State private var showPurchases = false

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle().fill(hairline).frame(width: 1).ignoresSafeArea()
            ZStack {
                if model.filesShown {
                    // Kept loaded but out of sight (and out of reach) while another section shows.
                    FilesBrowser(controller: browser)
                        .ignoresSafeArea(edges: [.top, .bottom])
                        .opacity(model.section == .files ? 1 : 0)
                        .allowsHitTesting(model.section == .files)
                        .accessibilityHidden(model.section != .files)
                }
                switch model.section {
                case .home: home
                case .templates:
                    TemplateGallery(title: "Templates", category: model.category, onCreate: { project, name in model.create(project, name) })
                        .id(model.galleryID)
                case .files: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(canvas.ignoresSafeArea())
        .tint(violet)
        .sheet(isPresented: $showAbout) { AboutView { showAbout = false } }
        .sheet(isPresented: $showPurchases) { PurchasesView { showPurchases = false } }
        .onAppear { recents.refresh() }
        // Projects may have changed in Files meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in recents.refresh() }
        .task { thumbnails.load(TemplateCatalog.all) }
    }

    // MARK: Rail

    private var rail: some View {
        VStack(spacing: 14) {
            // The brand S is Paper and Coral, so it sits on its Violet tile.
            SSIconGlyph(icon: .brand, size: 36)
                .frame(width: 48, height: 48)
                .background(violet, in: RoundedRectangle(cornerRadius: 14))
                .padding(.top, 8).padding(.bottom, 6)
                .accessibilityHidden(true)
            railButton(.home, "Home", icon: .home)
            railButton(.templates, "Templates", icon: .solid)
            railButton(.files, "Files", icon: .open)
            Spacer()
            Button { showAbout = true } label: { railLabel("About", icon: .help, selected: false) }
                .buttonStyle(.plain).accessibilityIdentifier("home.about")
        }
        .padding(.vertical, 12)
        .frame(width: 84)
        .background(card.ignoresSafeArea())
    }

    private func railButton(_ section: HomeModel.Section, _ title: String, icon: SSIcon) -> some View {
        Button {
            if section == .templates { model.category = nil }
            model.section = section
        } label: { railLabel(title, icon: icon, selected: model.section == section) }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.section.\(section.rawValue)")
        .accessibilityAddTraits(model.section == section ? [.isSelected] : [])
    }

    private func railLabel(_ title: String, icon: SSIcon, selected: Bool) -> some View {
        VStack(spacing: 4) {
            SSIconTile(icon: icon, selected: selected)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(selected ? violet : muted)
        }
        .frame(width: 72, height: 64).contentShape(Rectangle())
        .accessibilityElement(children: .ignore).accessibilityLabel(title)
    }

    // MARK: Home

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("Start something")
                    LazyVGrid(columns: shelfColumns, alignment: .leading, spacing: 14) {
                        Button(action: model.newBlankProject) { blankCard }
                            .buttonStyle(.plain).accessibilityIdentifier("home.blank")
                        ForEach(ProjectTemplate.Category.allCases, id: \.self) { category in
                            Button {
                                model.category = category
                                model.section = .templates
                            } label: { categoryCard(category) }
                            .buttonStyle(.plain).accessibilityIdentifier("home.category.\(category.rawValue)")
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        sectionTitle("Recent projects")
                        Spacer()
                        Button("Browse Files") { model.section = .files }
                            .font(.system(size: 15, weight: .semibold)).accessibilityIdentifier("home.browse")
                    }
                    if recents.projects.isEmpty { emptyRecents } else {
                        LazyVGrid(columns: recentColumns, alignment: .leading, spacing: 14) {
                            ForEach(recents.projects.prefix(24)) { project in recentCard(project) }
                        }
                    }
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 24)
        }
        .background(canvas)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Swipe & Sketch").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(ink)
                Text("Design parts for your 3D printer with Apple Pencil.").font(.system(size: 15)).foregroundStyle(muted)
            }
            Spacer(minLength: 12)
            if LicenseStore.enforcesPurchases {
                Button { showPurchases = true } label: {
                    Text(license.access.status).font(.system(size: 13, weight: .semibold)).foregroundStyle(violet)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color("ss-lavender"), in: Capsule())
                }
                .buttonStyle(.plain).accessibilityIdentifier("home.purchases")
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 20, weight: .bold)).foregroundStyle(ink).accessibilityAddTraits(.isHeader)
    }

    private var shelfColumns: [GridItem] { [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 14, alignment: .top)] }
    private var recentColumns: [GridItem] { [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 14, alignment: .top)] }

    private var blankCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SSIconGlyph(icon: .newProject, size: 34, color: paper)
            Spacer(minLength: 16)
            Text("Blank Project").font(.system(size: 17, weight: .semibold)).foregroundStyle(paper)
            Text("Start from an empty grid.").font(.system(size: 13)).foregroundStyle(Color("ss-lavender"))
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 172, alignment: .topLeading)
        .background(violet, in: RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }

    private func categoryCard(_ category: ProjectTemplate.Category) -> some View {
        let first = TemplateCatalog.all.first { $0.category == category }
        let count = TemplateCatalog.all.filter { $0.category == category }.count
        return VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12).fill(Self.tint(category))
                .frame(height: 104)
                .overlay {
                    if let first, let image = thumbnails.picture(of: first) {
                        // The picture's light gray ground takes the category tint.
                        Image(uiImage: image).resizable().scaledToFill().blendMode(.multiply)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 1) {
                Text(category.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                Text("\(count) templates").font(.system(size: 13)).foregroundStyle(muted)
            }
        }
        .cardStyle()
    }

    /// The brand's category tints: lime for Gridfinity, coral for electronics, lavender for boxes.
    private static func tint(_ category: ProjectTemplate.Category) -> Color {
        switch category {
        case .gridfinity: Color("ss-limeSoft")
        case .electronics: Color("ss-coralSoft")
        case .enclosures: Color("ss-lavender")
        }
    }

    private func recentCard(_ project: RecentProject) -> some View {
        Button { model.open(project) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(canvas)
                    if let image = recents.pictures[project.id] {
                        Image(uiImage: image).resizable().scaledToFit().padding(4)
                    } else {
                        SSIconGlyph(icon: .solid, size: 40, color: muted.opacity(0.6))
                    }
                }
                .aspectRatio(4 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                    Text(detail(project)).font(.system(size: 12)).foregroundStyle(muted).lineLimit(1)
                }
            }
            .cardStyle()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(project.name)
        .accessibilityValue(detail(project))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("home.recent.\(project.name)")
        .contextMenu {
            Button("Open") { model.open(project) }
            Button("Show in Files") { model.showInFiles(project) }
            Button("Remove from Recents", role: .destructive) { recents.remove(project) }
        }
    }

    private func detail(_ project: RecentProject) -> String {
        var parts = [project.date.formatted(.relative(presentation: .named)).capitalizedFirst]
        if let solids = project.solids { parts.append("\(solids) \(solids == 1 ? "solid" : "solids")") }
        // Most projects are on this iPad; only other places are named.
        if project.place != .iPad { parts.append(project.place.title) }
        return parts.joined(separator: " · ")
    }

    private var emptyRecents: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your projects show up here").font(.system(size: 17, weight: .semibold)).foregroundStyle(ink)
            Text("Start with a blank project or a template, or open one from Files.").font(.system(size: 14)).foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(hairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.empty")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

private extension View {
    func cardStyle() -> some View {
        padding(10)
            .background(card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// The system document browser inside Home's Files.
private struct FilesBrowser: UIViewControllerRepresentable {
    let controller: UIViewController
    func makeUIViewController(context: Context) -> UIViewController { controller }
    func updateUIViewController(_ controller: UIViewController, context: Context) { }
}
