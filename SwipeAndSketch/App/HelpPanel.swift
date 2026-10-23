import SwiftUI

private let ink = Color("ss-ink")
private let muted = Color("ss-muted")
private let violet = Color("ss-violet")
private let paper = Color("ss-paper")
private let hairline = Color("ss-border")
private let white = Color("ss-white")

/// The floating help card opened from the hint: a plain-language overview of what the user is
/// doing. Drag its top bar to move it.
struct HelpPanel: View {
    @ObservedObject var session: ModelingSession
    /// The topic shown; it stays put while the user works, with a button to follow the current one.
    let topic: HelpTopic
    /// Moves the card by a drag of its top bar; `ended` is true at lift.
    var onDrag: (_ translation: CGSize, _ ended: Bool) -> Void
    var onShowTopic: (HelpTopic) -> Void
    var onAllControls: () -> Void
    var onClose: () -> Void

    static let width: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            overview
            footer
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .frame(width: Self.width, alignment: .leading)
        .background(white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("help.panel")
    }

    /// The grab bar, the topic, and close. Dragging anywhere on it moves the card.
    private var header: some View {
        VStack(spacing: 6) {
            Capsule().fill(hairline).frame(width: 36, height: 5).padding(.top, 7)
            HStack(spacing: 10) {
                SSIconGlyph(icon: topic.icon, size: 22, color: violet)
                Text(topic.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(ink)
                    .lineLimit(1).accessibilityIdentifier("help.title")
                Spacer(minLength: 8)
                Button(action: onClose) {
                    SSIconGlyph(icon: .exit, size: 20, color: muted).frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Close help").accessibilityIdentifier("help.close")
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named("workspace"))
                .onChanged { onDrag($0.translation, false) }
                .onEnded { onDrag($0.translation, true) }
        )
        .accessibilityHint("Drag to move the help card")
    }

    private var overview: some View {
        let content = topic.overview
        let current = session.helpTopic
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if current == topic, !session.hint.isEmpty {
                    // The hint above the canvas is cut to two lines; here it is whole.
                    Text(session.hint)
                        .font(.system(size: 14)).foregroundStyle(ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(violet.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("hint.detail")
                }
                Text(content.summary)
                    .font(.system(size: 15)).foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("help.summary")
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(content.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)").font(.system(size: 12, weight: .bold)).foregroundStyle(paper)
                                .frame(width: 20, height: 20).background(violet, in: Circle())
                            Text(step).font(.system(size: 15)).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !content.tips.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Good to know").font(.system(size: 12, weight: .semibold)).foregroundStyle(muted).textCase(.uppercase)
                        ForEach(content.tips, id: \.self) { tip in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(muted).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                                Text(tip).font(.system(size: 14)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if current != topic {
                    followButton(current)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The user has moved on to something else: offer its help without jumping there on its own.
    private func followButton(_ next: HelpTopic) -> some View {
        Button { onShowTopic(next) } label: {
            HStack(spacing: 8) {
                SSIconGlyph(icon: next.icon, size: 16, color: violet)
                Text("Now: \(next.title)").font(.system(size: 14, weight: .semibold)).foregroundStyle(violet)
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(violet.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain).accessibilityIdentifier("help.follow")
    }

    private var footer: some View {
        HStack {
            Button(action: onAllControls) {
                Label { Text("All controls") } icon: { SSIconGlyph(icon: .help, size: 18, color: violet) }
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(violet)
            }
            .buttonStyle(.plain).accessibilityIdentifier("hint.controls")
            Spacer()
        }
    }
}
