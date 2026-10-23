import SwiftUI

/// The ss-icon-* image sets (SwipeSketchIcons.xcassets, copied into the app's asset catalog). Glyphs and colored tiles stay separate.
enum SSIcon: String, CaseIterable {
    case brand = "brand"
    case items = "items"
    case select = "select"
    case line = "line"
    case rectangle = "rectangle"
    case circle = "circle"
    case extrude = "extrude"
    case fillet = "fillet"
    case chamfer = "chamfer"
    case shell = "shell"
    case hole = "hole"
    case sketch = "sketch"
    case merge = "merge"
    case cut = "cut"
    case newBody = "new-body"
    case throughAll = "through-all"
    case rectangleCorners = "rectangle-corners"
    case rectangleCenter = "rectangle-center"
    case holeSimple = "hole-simple"
    case holeCounterbore = "hole-counterbore"
    case holeCountersink = "hole-countersink"
    case holeInsert = "hole-insert"
    case home = "home"
    case more = "more"
    case snapOn = "snap-on"
    case snapOff = "snap-off"
    case undo = "undo"
    case redo = "redo"
    case delete = "delete"
    case help = "help"
    case exit = "exit"
    case done = "done"
    case save = "save"
    case saveAs = "save-as"
    case newProject = "new-project"
    case open = "open"
    case export = "export"
    case resetView = "reset-view"
    case backspace = "backspace"
    case solid = "solid"
    case visible = "visible"
    case hidden = "hidden"
    case plane = "plane"
    case offsetPlane = "offset-plane"
    case midplane = "midplane"
    case project = "project"
    case split = "split"
    case subtract = "subtract"
    case align = "align"
    case revolve = "revolve"
    case mirror = "mirror"
    case pattern = "pattern"
    case fit = "fit"
    case peg = "peg"
    case thread = "thread"
    case text = "text"
    case fitTest = "fit-test"
    case arc = "arc"
    case slot = "slot"
    case trim = "trim"
    case sketchFillet = "sketch-fillet"
    case dimension = "dimension"
    case measure = "measure"
    case assistant = "assistant"
    case send = "send"
    case stop = "stop"
    case intersect = "intersect"
    case scale = "scale"
    case offset = "offset"
    case polygon = "polygon"
    case ellipse = "ellipse"
    case point = "point"
    case construction = "construction"
    case extend = "extend"
    case deleteFace = "delete-face"
    case section = "section"
    case color = "color"
    case copy = "copy"
    case paste = "paste"
    case rename = "rename"
    case group = "group"
    case groupAdd = "groupAdd"
    case ungroup = "ungroup"
    case disclosure = "disclosure"
    case symmetric = "symmetric"
    case taper = "taper"
    case extrudeTo = "extrude-to"
    var assetName: String { "ss-icon-" + rawValue }
    var title: String {
        switch self {
        case .brand: "Swipe & Sketch"
        case .items: "Model Tree"
        case .select: "Select"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .circle: "Circle"
        case .extrude: "Extrude"
        case .fillet: "Fillet"
        case .chamfer: "Chamfer"
        case .shell: "Shell"
        case .hole: "Hole"
        case .sketch: "Sketch"
        case .merge: "Merge"
        case .cut: "Cut"
        case .newBody: "New Body"
        case .throughAll: "Through All"
        case .rectangleCorners: "Rectangle from Corners"
        case .rectangleCenter: "Rectangle from Center"
        case .holeSimple: "Simple Hole"
        case .holeCounterbore: "Counterbore"
        case .holeCountersink: "Countersink"
        case .holeInsert: "Heat-set Insert"
        case .home: "Projects"
        case .more: "Project Menu"
        case .snapOn: "Snap On"
        case .snapOff: "Snap Off"
        case .undo: "Undo"
        case .redo: "Redo"
        case .delete: "Delete"
        case .help: "Controls"
        case .exit: "Cancel / Finish Sketch"
        case .done: "Done / Apply"
        case .save: "Save"
        case .saveAs: "Save As"
        case .newProject: "New Project"
        case .open: "Open Project"
        case .export: "Export"
        case .resetView: "Reset View"
        case .backspace: "Backspace"
        case .solid: "Solid Body"
        case .visible: "Visible"
        case .hidden: "Hidden"
        case .plane: "Plane"
        case .offsetPlane: "Offset Plane"
        case .midplane: "Midplane"
        case .project: "Project"
        case .split: "Split Body"
        case .subtract: "Subtract"
        case .align: "Align"
        case .revolve: "Revolve"
        case .mirror: "Mirror"
        case .pattern: "Pattern"
        case .fit: "Fit"
        case .peg: "Peg & Socket"
        case .thread: "Thread"
        case .text: "Text"
        case .fitTest: "Fit Test"
        case .arc: "Arc"
        case .slot: "Slot"
        case .trim: "Trim"
        case .sketchFillet: "Sketch Fillet"
        case .dimension: "Dimension"
        case .measure: "Measure"
        case .assistant: "Assistant"
        case .send: "Send"
        case .stop: "Stop"
        case .intersect: "Intersect"
        case .scale: "Scale"
        case .offset: "Offset"
        case .polygon: "Polygon"
        case .ellipse: "Ellipse"
        case .point: "Point"
        case .construction: "Construction"
        case .extend: "Extend"
        case .deleteFace: "Delete Face"
        case .section: "Section"
        case .color: "Color"
        case .copy: "Copy"
        case .paste: "Paste"
        case .rename: "Rename"
        case .group: "Group"
        case .groupAdd: "New Group"
        case .ungroup: "Ungroup"
        case .disclosure: "Disclosure"
        case .symmetric: "Symmetric"
        case .taper: "Taper"
        case .extrudeTo: "Up To"
        }
    }
    var original: Bool { self == .brand }
    var tileColor: Color {
        switch self {
        case .brand: Color("ss-violet")
        case .select, .line, .rectangle, .circle, .sketch, .rectangleCorners, .rectangleCenter, .project, .arc, .slot, .trim, .sketchFillet, .dimension, .offset, .polygon, .ellipse, .point, .construction, .extend: Color("ss-lavender")
        case .extrude, .fillet, .chamfer, .shell, .hole, .merge, .cut, .newBody, .throughAll, .holeSimple, .holeCounterbore, .holeCountersink, .holeInsert, .solid, .plane, .offsetPlane, .midplane, .split, .subtract, .align, .revolve, .mirror, .pattern, .fit, .peg, .thread, .text, .fitTest, .intersect, .scale, .deleteFace, .symmetric, .taper, .extrudeTo: Color("ss-coralSoft")
        case .items, .snapOn, .done, .visible, .hidden, .assistant, .measure, .section, .send, .color, .rename, .group, .groupAdd, .ungroup: Color("ss-limeSoft")
        case .home, .more, .snapOff, .undo, .redo, .help, .exit, .save, .saveAs, .newProject, .open, .export, .resetView, .backspace, .stop, .copy, .paste, .disclosure: Color("ss-neutral")
        case .delete: Color("ss-coralSoft")
        }
    }
}

/// Use this bare glyph inside menus and Items rows; do not carry tile fills there.
struct SSIconGlyph: View {
    let icon: SSIcon
    var size: CGFloat = 30
    var color: Color = Color("ss-ink")
    var body: some View {
        Image(icon.assetName)
            .renderingMode(icon.original ? .original : .template)
            .resizable().scaledToFit().frame(width: size, height: size)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

/// 43pt visible tile inside a 44pt hit area when used by SSIconButton.
struct SSIconTile: View {
    let icon: SSIcon
    var selected = false
    var enabled = true
    var body: some View {
        SSIconGlyph(icon: icon, color: selected ? Color("ss-paper") : Color("ss-ink"))
            .opacity(enabled ? 1 : 0.32)
            .frame(width: 43, height: 43)
            .background((selected ? Color("ss-violet") : icon.tileColor).opacity(enabled ? 1 : 0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SSIconButton: View {
    let icon: SSIcon
    var selected = false
    var enabled = true
    var accessibilityLabel: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            SSIconTile(icon: icon, selected: selected, enabled: enabled)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(SSIconPressStyle()).disabled(!enabled)
        .accessibilityLabel(accessibilityLabel ?? icon.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct SSIconPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
