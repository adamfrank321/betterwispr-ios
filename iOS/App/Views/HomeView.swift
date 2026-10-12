import BetterWisprCore
import SwiftUI

struct HomeView: View {
    @Environment(MobileModel.self) private var model
    @Environment(DictationSession.self) private var session
    @Environment(ModelManager.self) private var models

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    DictateCard()
                    if !models.isInstalled(model.selectedModel) {
                        NoticeCard(title: "Download a speech model", message: "\(model.selectedModel.name) isn't on this iPhone yet. Choose one in Settings > Speech model.", systemImage: "arrow.down.circle")
                    }
                    if KeyboardBridge().keyboardLastSeen == nil {
                        NavigationLink { KeyboardSetupView() } label: {
                            NoticeCard(title: "Dictate in any app", message: "Add the BetterWispr keyboard to dictate into Messages, Mail, Notes and everything else.", systemImage: "keyboard")
                        }
                        .buttonStyle(.plain)
                    }
                    StatsRow(insights: UsageInsights(model.history, period: .allTime))
                    RecentList()
                }
                .padding()
            }
            .navigationTitle("BetterWispr")
            .toolbar {
                if session.isWarm {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("End keyboard session") { session.endSession() }
                            .font(.footnote)
                    }
                }
            }
        }
    }
}

private struct DictateCard: View {
    @Environment(DictationSession.self) private var session

    var body: some View {
        VStack(spacing: 16) {
            Button(action: session.toggle) {
                ZStack {
                    Circle()
                        .fill(session.phase == .recording ? Color.red : Color.accentColor)
                        .frame(width: 120, height: 120)
                        .scaleEffect(session.phase == .recording ? 1 + CGFloat(session.level) * 0.15 : 1)
                        .animation(.easeOut(duration: 0.12), value: session.level)
                    if session.phase == .transcribing {
                        ProgressView().tint(.white).controlSize(.large)
                    } else {
                        Image(systemName: session.phase == .recording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(session.phase == .transcribing)
            .accessibilityLabel(session.phase == .recording ? "Stop dictating" : "Dictate")

            Group {
                switch session.phase {
                case .idle: Text("Tap to dictate. The text is copied when you finish.")
                case .recording: Text(session.status)
                case .transcribing: Text(session.status)
                case .done: Text("Copied. Paste it anywhere.")
                case .failed(let message): Text(message).foregroundStyle(.red)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            if session.phase == .recording {
                Button("Cancel", role: .cancel, action: session.cancel)
            }

            if case .done(let text) = session.phase {
                VStack(alignment: .leading, spacing: 12) {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                        Spacer()
                        ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    .font(.subheadline)
                }
                .padding()
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

struct NoticeCard: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct StatsRow: View {
    let insights: UsageInsights

    var body: some View {
        HStack(spacing: 12) {
            Stat(value: insights.current.words.formatted(), label: "Words")
            Stat(value: "\(insights.current.wordsPerMinute)", label: "Words a minute")
            Stat(value: "\(insights.currentStreak)", label: insights.currentStreak == 1 ? "Day streak" : "Day streak")
        }
    }

    private struct Stat: View {
        let value: String
        let label: String

        var body: some View {
            VStack(spacing: 4) {
                Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct RecentList: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        if !model.history.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent").font(.headline)
                ForEach(model.history.prefix(3)) { transcript in
                    NavigationLink { TranscriptDetailView(transcript: transcript) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(transcript.text).lineLimit(2).foregroundStyle(.primary)
                            Text(transcript.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
