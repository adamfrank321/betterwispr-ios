import BetterWisprCore
import SwiftUI

struct InsightsView: View {
    @Environment(MobileModel.self) private var model
    @State private var period: InsightsPeriod = .allTime

    var body: some View {
        let insights = UsageInsights(model.history, period: period)
        List {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(InsightsPeriod.allCases) { Text(periodName($0)).tag($0) }
                }
            }
            Section("Pace") {
                LabeledContent("Words a minute", value: "\(insights.current.wordsPerMinute)")
                LabeledContent("Average typing", value: "\(UsageInsights.typingWordsPerMinute)")
                LabeledContent("Time saved", value: Duration.seconds(insights.current.timeSaved).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
            }
            Section("Words") {
                LabeledContent("Dictated", value: insights.current.words.formatted())
                LabeledContent("Dictations", value: insights.current.dictations.formatted())
                LabeledContent("Cleaned up", value: insights.wordsCleaned.formatted())
                LabeledContent("Vocabulary fixes", value: insights.vocabularyFixes.formatted())
            }
            Section("Streak") {
                LabeledContent("Current", value: "\(insights.currentStreak) days")
                LabeledContent("Longest", value: "\(insights.longestStreak) days")
                LabeledContent("Active days", value: "\(insights.activeDays)")
            }
            Section {
                ShareLink(item: "I've dictated \(insights.current.words.formatted()) words at \(insights.current.wordsPerMinute) words a minute with BetterWispr.") {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("Computed on this iPhone from your history, including dictations synced from your other devices.")
            }
        }
        .navigationTitle("Insights")
    }

    private func periodName(_ period: InsightsPeriod) -> String {
        period.rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }
}
