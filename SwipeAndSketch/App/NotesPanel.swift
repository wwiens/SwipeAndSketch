import SwiftUI
import UIKit

/// A project notebook that can stay beside the canvas. The native text view supplies selection,
/// links, dictation, Scribble, and text undo without changing the canvas's Pencil recognizers.
struct NotesPanel: View {
    @ObservedObject var session: ModelingSession
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
            if let note = session.activeObjectNote {
                HStack(spacing: 8) {
                    Text(session.workspace.name(for: note) ?? note.objectName)
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if session.workspace.name(for: note) == nil {
                        Text("Missing object").font(.system(size: 12)).foregroundStyle(muted)
                            .accessibilityIdentifier("notes.missing")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            ZStack(alignment: .topLeading) {
                NotebookTextView(text: Binding(get: { session.notesText }, set: { session.updateNotes($0) }),
                                 editable: session.isEditingNotes || session.canEditNotes,
                                 editing: session.isEditingNotes,
                                 byteLimit: session.notesTextLimit,
                                 label: session.activeObjectNote.map { "Notes for \(session.workspace.name(for: $0) ?? $0.objectName)" } ?? "Project notes",
                                 beginEditing: { [noteID = session.selectedNoteID] in
                                     guard session.selectedNoteID == noteID else { return false }
                                     if !session.isEditingNotes { session.beginEditingNotes() }
                                     return session.isEditingNotes
                                 }, endEditing: { [noteID = session.selectedNoteID] in
                                     if session.selectedNoteID == noteID && session.isEditingNotes { session.endEditingNotes(finalize: false) }
                                 })
                    .id(session.selectedNoteID)
                if session.notesText.isEmpty && !session.isEditingNotes {
                    Text("Keep requirements, design decisions, and print observations with this project. Tap here to type.")
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
                    ForEach(session.listedObjectNotes.filter { !selectedOnly || session.noteMatchesSelection($0) }) { note in
                        noteRow(title: session.workspace.name(for: note) ?? note.objectName,
                                subtitle: session.workspace.name(for: note) == nil ? "Missing object" : nil,
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
        func textViewShouldBeginEditing(_ textView: UITextView) -> Bool { parent.beginEditing() }
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
