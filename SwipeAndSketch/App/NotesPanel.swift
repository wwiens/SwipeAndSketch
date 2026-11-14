import SwiftUI
import UIKit

/// A project notebook that can stay beside the canvas. The native text view supplies selection,
/// links, dictation, Scribble, and text undo without changing the canvas's Pencil recognizers.
struct NotesPanel: View {
    let session: ModelingSession
    /// Whether the editor still shows the notebook. Closing it (its ×, the rail's Notes, opening the
    /// Assistant) fades the panel out, and meanwhile UIKit can offer the text view focus again, which
    /// started editing after it had ended and kept Undo and the dock disabled until the panel was gone
    /// (November 9, 2026). Asked when the text view would begin editing, so the answer is current.
    var isShown: () -> Bool = { true }
    var onHelp: () -> Void
    var close: () -> Void
    @State private var selectedOnly = false

    private let ink = Color("ss-ink")
    private let muted = Color("ss-muted")
    private let violet = Color("ss-violet")
    private let border = Color("ss-border")

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SSIconGlyph(icon: .text, size: 24, color: violet)
                Text("Notes").font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 0)
                Button(action: onHelp) { SSIconGlyph(icon: .help, size: 22, color: muted).frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("Notes Help").accessibilityIdentifier("notes.help")
                Button {
                    Self.dismissKeyboard()
                    session.closeNotes()
                    close()
                } label: { SSIconGlyph(icon: .exit, size: 22, color: muted).frame(width: 44, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel("Close Notes").accessibilityIdentifier("notes.close")
            }
            .buttonStyle(.plain).frame(minHeight: 44).padding(.horizontal, 14).padding(.vertical, 4)
            Divider().overlay(border.opacity(0.6))
            noteBrowser
            selectionOffer
            notebookHeader
            ZStack(alignment: .topLeading) {
                NotebookTextView(text: Binding(get: { session.notesText }, set: { session.updateNotes($0) }),
                                 editable: session.isEditingNotes || session.canEditNotes,
                                 editing: session.isEditingNotes,
                                 byteLimit: session.notesTextLimit,
                                 label: session.activeObjectNote.map { "Notes for \(session.workspace.name(for: $0) ?? $0.objectName)" } ?? "Project notes",
                                 isShown: isShown,
                                 beginEditing: { [noteID = session.selectedNoteID] in
                                     guard isShown(), session.selectedNoteID == noteID else { return false }
                                     if !session.isEditingNotes { session.beginEditingNotes() }
                                     return session.isEditingNotes
                                 }, endEditing: { [noteID = session.selectedNoteID] in
                                     if session.selectedNoteID == noteID && session.isEditingNotes { session.endEditingNotes(finalize: false) }
                                 })
                    .id(session.selectedNoteID)
                if session.notesText.isEmpty && !session.isEditingNotes {
                    Text(session.activeObjectNote.map { "Notes for \(objectName($0)) only: how to print it, fits, what to check. Tap here to type." } ??
                         "Keep requirements, design decisions, and print observations with this project. Tap here to type.")
                        .font(.body).foregroundStyle(muted).padding(16).allowsHitTesting(false)
                }
            }
            Text(session.isReadOnly ? "This file can't be changed right now · Close with ×" :
                 !session.hasEditingAccess ? "Viewing notes · Unlock Swipe & Sketch to edit" : "Changes save automatically · Close with ×")
                .font(.system(size: 12)).foregroundStyle(muted).frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .foregroundStyle(ink)
        .background(Color("ss-white"), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(border.opacity(0.6)))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 2)
        .allowsHitTesting(!session.isPencilDown)
        .accessibilityElement(children: .contain).accessibilityIdentifier("notes.panel")
        .onDisappear { session.closeNotes() }
    }

    private func objectName(_ note: ObjectNote) -> String { session.workspace.name(for: note) ?? note.objectName }

    /// Which notebook the text below belongs to, always named: the project's, or one object's.
    private var notebookHeader: some View {
        let note = session.activeObjectNote
        return HStack(spacing: 8) {
            SSIconGlyph(icon: note.map { $0.kind == .body ? .solid : .sketch } ?? .project, size: 20, color: violet)
            Text(note.map { "Note for \(objectName($0))" } ?? "Project Notes")
                .font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                .accessibilityIdentifier("notes.target")
            Spacer(minLength: 0)
            if let note, session.workspace.name(for: note) == nil {
                Text("Missing object").font(.system(size: 12)).foregroundStyle(muted)
                    .accessibilityIdentifier("notes.missing")
            }
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
    }

    /// With a solid or sketch selected and another notebook open, a button to write about it instead.
    /// Nothing changes until it is tapped: the open notebook stays where it was.
    @ViewBuilder private var selectionOffer: some View {
        if let target = session.selectionNoteTarget {
            let existing = session.note(for: target.item)
            // The open notebook may be a draft for it, stored only once something is typed.
            let open = session.activeObjectNote.map { target.item == ($0.kind == .body ? .body($0.objectID) : .sketch($0.objectID)) } ?? false
            if !open {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(target.name) is selected").font(.system(size: 12)).foregroundStyle(muted).lineLimit(1)
                        Button {
                            Self.dismissKeyboard()
                            session.openObjectNote(for: target.item)
                        } label: {
                            Text(existing == nil ? "Add Note to \(target.name)" : "Open Note for \(target.name)")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(violet).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .disabled(session.hasOperationInProgress || session.isProjectBusy || session.isAssistantBusy ||
                                  existing == nil && (session.isReadOnly || !session.hasEditingAccess))
                        .accessibilityIdentifier("notes.offer")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color("ss-lavender").opacity(0.45))
            }
        }
    }

    /// Dismiss from a button action, before SwiftUI removes/replaces the editor. Resigning inside
    /// updateUIView would synchronously publish the keyboard inset during a view update.
    static func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var noteBrowser: some View {
        VStack(spacing: 4) {
            Picker("Show notes", selection: $selectedOnly) {
                Text("All").tag(false)
                Text("Selected Object").tag(true)
            }
            .pickerStyle(.segmented).tint(violet).accessibilityIdentifier("notes.filter")
            ScrollView {
                VStack(spacing: 2) {
                    noteRow(title: "Project Notes", subtitle: nil, id: nil, icon: .project)
                    let nameOf = session.workspace.noteNames()
                    ForEach(session.listedObjectNotes.filter { !selectedOnly || session.noteMatchesSelection($0) }) { note in
                        let name = nameOf(note)
                        noteRow(title: name ?? note.objectName,
                                subtitle: name == nil ? "Missing object" : nil,
                                id: note.id, icon: note.kind == .body ? .solid : .sketch)
                            .contextMenu {
                                Button("Delete Note", role: .destructive) { session.deleteObjectNote(note.id) }
                                    .accessibilityIdentifier("notes.delete")
                                    .disabled(session.isReadOnly || session.isProjectBusy || session.isAssistantBusy || session.hasOperationInProgress)
                            }
                    }
                    if selectedOnly && !session.listedObjectNotes.contains(where: session.noteMatchesSelection) {
                        Text("No notes for the selected object.").font(.system(size: 12)).foregroundStyle(muted).padding(8)
                    }
                }
            }
            // Room for the "no notes" line when filtering, even with no linked notes at all.
            .frame(height: session.listedObjectNotes.isEmpty && !selectedOnly ? 44 : 132)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color("ss-paper"))
    }

    private func noteRow(title: String, subtitle: String?, id: UUID?, icon: SSIcon) -> some View {
        Button { Self.dismissKeyboard(); session.selectNote(id) } label: {
            HStack(spacing: 8) {
                SSIconGlyph(icon: icon, size: 20, color: violet)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(muted) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(minHeight: 44)
            .background(session.selectedNoteID == id ? Color("ss-lavender") : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.isViewingBlocked && !session.isEditingNotes || session.hasOperationInProgress)
        .accessibilityLabel(title).accessibilityValue(subtitle ?? "")
        .accessibilityIdentifier(id.map { "notes.entry.\($0.uuidString)" } ?? "notes.project")
    }

}

private struct NotebookTextView: UIViewRepresentable {
    @Binding var text: String
    var editable: Bool
    var editing: Bool
    var byteLimit: Int
    /// What VoiceOver calls it: the project's notes or a linked object's.
    var label: String
    var isShown: () -> Bool
    var beginEditing: () -> Bool
    var endEditing: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = UIColor(named: "ss-ink")
        view.tintColor = UIColor(named: "ss-violet")
        view.textContainerInset = UIEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
        view.isEditable = false
        view.dataDetectorTypes = [.link]
        view.keyboardDismissMode = .interactive
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text; view.undoManager?.removeAllActions() }
        if !editing && view.isFirstResponder { view.resignFirstResponder() }
        let detectors: UIDataDetectorTypes = editing ? [] : [.link]
        if view.dataDetectorTypes != detectors { view.dataDetectorTypes = detectors }
        view.accessibilityIdentifier = editable ? "notes.editor" : "notes.content"
        view.accessibilityLabel = label
        if view.isEditable != editable {
            view.isEditable = editable
            if !editable { view.resignFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NotebookTextView
        init(_ parent: NotebookTextView) { self.parent = parent }
        func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
            // A notebook being closed takes no more typing: not editable, UIKit stops offering it focus.
            if !parent.isShown() { textView.isEditable = false; return false }
            return parent.beginEditing()
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            parent.endEditing()
            textView.undoManager?.removeAllActions()
        }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            let updated = (textView.text as NSString).replacingCharacters(in: range, with: text)
            return updated.utf8.count <= parent.byteLimit
        }
    }
}
