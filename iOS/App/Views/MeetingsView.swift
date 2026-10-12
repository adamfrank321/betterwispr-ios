import BetterWisprCore
import SwiftUI

struct MeetingsView: View {
    @Environment(MobileModel.self) private var model
    @Environment(MeetingRecorderModel.self) private var recorder
    @Environment(DictationSession.self) private var session

    var body: some View {
        NavigationStack {
            List {
                Section {
                    RecorderCard()
                } footer: {
                    Text("Records through this iPhone's microphone and writes notes when you stop. Let everyone know they're being recorded.")
                }
                if !recorder.speakerDetectionInstalled, SpeakerDetection.isSupported {
                    Section {
                        if let progress = recorder.installingSpeakerDetection {
                            ProgressView("Downloading speaker detection", value: progress)
                        } else {
                            Button("Download speaker detection (about 21 MB)") { recorder.installSpeakerDetection() }
                        }
                    } footer: {
                        Text("Labels each line Speaker 1, Speaker 2 and so on, on this iPhone.")
                    }
                }
                if let message = recorder.message {
                    Section { Text(message).foregroundStyle(.red) }
                }
                Section("Notes") {
                    if model.meetings.isEmpty {
                        Text("Meetings from this iPhone and your synced Mac show up here.").foregroundStyle(.secondary)
                    }
                    ForEach(model.meetings) { meeting in
                        NavigationLink { MeetingDetailView(id: meeting.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meeting.displayTitle).lineLimit(1)
                                Text("\(meeting.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(Duration.seconds(meeting.duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            if meeting.id != recorder.activeMeetingID {
                                Button("Delete", systemImage: "trash", role: .destructive) { model.delete(meeting) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Meetings")
        }
    }
}

private struct RecorderCard: View {
    @Environment(MeetingRecorderModel.self) private var recorder
    @Environment(DictationSession.self) private var session

    var body: some View {
        HStack(spacing: 16) {
            Button {
                if recorder.isRecording { recorder.stop() } else {
                    session.endSession()
                    Task { await recorder.start() }
                }
            } label: {
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(recorder.isRecording ? Color.red : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(session.isBusy || (recorder.activity != .idle && !recorder.isRecording))
            .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private var title: String {
        switch recorder.activity {
        case .idle: "New meeting"
        case .recording: Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond))
        case .finishing: "Finishing the transcript…"
        case .findingSpeakers: "Telling the speakers apart…"
        case .writingNotes: "Writing notes…"
        }
    }

    private var detail: String {
        switch recorder.activity {
        case .recording: recorder.pendingPieces > 0 ? "Transcribing as you go" : "Listening"
        case .idle: "Tap to start"
        default: "This takes a moment"
        }
    }
}

struct MeetingDetailView: View {
    @Environment(MobileModel.self) private var model
    @Environment(MeetingRecorderModel.self) private var recorder
    let id: UUID
    @State private var tab = 0

    private var meeting: Meeting? { model.meetings.first { $0.id == id } }

    var body: some View {
        if let meeting {
            List {
                Picker("Show", selection: $tab) {
                    Text("Summary").tag(0)
                    Text("Transcript").tag(1)
                    Text("My notes").tag(2)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                switch tab {
                case 0: summary(meeting)
                case 1: transcript(meeting)
                default: notes(meeting)
                }
            }
            .navigationTitle(meeting.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ShareLink(item: meeting.markdown) { Label("Share notes", systemImage: "square.and.arrow.up") }
            }
        } else {
            ContentUnavailableView("Meeting deleted", systemImage: "trash")
        }
    }

    @ViewBuilder private func summary(_ meeting: Meeting) -> some View {
        if let summary = meeting.summary {
            Section { Text(summary.overview) }
            if !summary.keyPoints.isEmpty { Section("Key points") { ForEach(summary.keyPoints, id: \.self) { Text($0) } } }
            if !summary.decisions.isEmpty { Section("Decisions") { ForEach(summary.decisions, id: \.self) { Text($0) } } }
            if !summary.actionItems.isEmpty {
                Section("Action items") {
                    ForEach(summary.actionItems) { item in
                        Button { toggle(item.id) } label: {
                            Label(item.text, systemImage: item.isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
            if meeting.summaryNeedsUpdate {
                Section { Button("Update summary") { Task { await recorder.writeNotes(for: meeting.id) } } }
            }
        } else {
            Section {
                Button("Write notes") { Task { await recorder.writeNotes(for: meeting.id) } }
                    .disabled(!meeting.hasContent || recorder.activeMeetingID == meeting.id)
            } footer: {
                if case .unavailable(let reason) = MeetingNotesGenerator.availability(settings: model.settings) { Text(reason) }
            }
        }
    }

    @ViewBuilder private func transcript(_ meeting: Meeting) -> some View {
        if !meeting.participants.isEmpty {
            Section("Names") {
                ForEach(meeting.participants, id: \.self) { participant in
                    TextField("Speaker \(participant)", text: Binding(
                        get: { meeting.participantNames?[participant] ?? "" },
                        set: { name in
                            var updated = meeting
                            var names = updated.participantNames ?? [:]
                            names[participant] = name.isEmpty ? nil : name
                            updated.participantNames = names
                            model.save(updated)
                        }))
                }
            }
        }
        Section {
            ForEach(meeting.transcriptSegments) { segment in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(segment.timestamp) · \(segment.label(names: meeting.participantNames))").font(.caption).foregroundStyle(.secondary)
                    Text(segment.text).textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder private func notes(_ meeting: Meeting) -> some View {
        Section {
            TextEditor(text: Binding(get: { meeting.notes }, set: { text in
                var updated = meeting
                updated.notes = text
                model.save(updated)
            }))
            .frame(minHeight: 240)
        } footer: {
            Text("Your own notes go into the summary when you write or update it.")
        }
    }

    private func toggle(_ item: UUID) {
        guard var updated = meeting, let index = updated.summary?.actionItems.firstIndex(where: { $0.id == item }) else { return }
        updated.summary?.actionItems[index].isDone.toggle()
        model.save(updated)
    }
}
