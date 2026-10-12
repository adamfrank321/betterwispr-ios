import BetterWisprCore
import SwiftUI

struct HistoryView: View {
    @Environment(MobileModel.self) private var model
    @State private var search = ""

    private var filtered: [Transcript] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.history }
        return model.history.filter { $0.text.localizedCaseInsensitiveContains(query) || $0.rawText.localizedCaseInsensitiveContains(query) }
    }

    private var days: [(day: Date, items: [Transcript])] {
        let groups = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.createdAt) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                if model.history.isEmpty {
                    ContentUnavailableView("No dictations yet", systemImage: "waveform",
                                           description: Text("Dictations from this iPhone and your other synced devices show up here."))
                }
                ForEach(days, id: \.day) { group in
                    Section(group.day.formatted(date: .complete, time: .omitted)) {
                        ForEach(group.items) { transcript in
                            NavigationLink { TranscriptDetailView(transcript: transcript) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(transcript.text).lineLimit(3)
                                    Text("\(transcript.createdAt.formatted(date: .omitted, time: .shortened)) · \(transcript.wordCount) words")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { model.delete(transcript) }
                                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = transcript.text }
                                    .tint(.blue)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle("History")
            .toolbar {
                if !model.history.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: exportText) { Label("Export", systemImage: "square.and.arrow.up") }
                    }
                }
            }
        }
    }

    /// The same JSON the Mac's Export history writes.
    private var exportText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(model.history)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}

struct TranscriptDetailView: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let transcript: Transcript
    @State private var text = ""
    @FocusState private var editing: Bool

    private var current: Transcript { model.history.first { $0.id == transcript.id } ?? transcript }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 160)
                    .focused($editing)
            } footer: {
                if model.settings.learnCorrections {
                    Text("Fix a misheard word and BetterWispr adds it to Vocabulary.")
                }
            }
            if current.rawText.trimmingCharacters(in: .whitespacesAndNewlines) != current.text {
                Section("Original transcription") {
                    Text(current.rawText).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Use Original") {
                        model.restoreOriginal(current)
                        text = current.rawText
                    }
                }
            }
            Section {
                LabeledContent("Model", value: current.modelName)
                LabeledContent("Length", value: Duration.seconds(current.duration).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))
                LabeledContent("Words", value: "\(current.wordCount)")
                if let fixes = current.vocabularyFixes, fixes > 0 { LabeledContent("Vocabulary fixes", value: "\(fixes)") }
            }
            Section {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = current.text }
                ShareLink(item: current.text) { Label("Share", systemImage: "square.and.arrow.up") }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    model.delete(current)
                    dismiss()
                }
            }
        }
        .navigationTitle(current.createdAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { text = current.text }
        .toolbar {
            if editing {
                Button("Save") {
                    editing = false
                    model.updateTranscript(current, text: text)
                }
            }
        }
    }
}
