import BetterWisprCore
import SwiftUI

struct PersonalizeView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink { VocabularyView() } label: {
                    Label { LinkText(title: "Vocabulary", detail: "Names and terms to spell your way") } icon: { Image(systemName: "character.book.closed") }
                }
                NavigationLink { StyleView() } label: {
                    Label { LinkText(title: "Style", detail: "Cleanup and writing tone") } icon: { Image(systemName: "textformat") }
                }
                NavigationLink { ModesView() } label: {
                    Label { LinkText(title: "Modes", detail: "Settings you switch on with a spoken word") } icon: { Image(systemName: "wand.and.stars") }
                }
                NavigationLink { InsightsView() } label: {
                    Label { LinkText(title: "Insights", detail: "Your pace, words and streak") } icon: { Image(systemName: "chart.bar") }
                }
            }
            .navigationTitle("Personalize")
        }
    }
}

private struct LinkText: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: Vocabulary

struct VocabularyView: View {
    @Environment(MobileModel.self) private var model
    @Environment(ModelManager.self) private var models
    @State private var phrase = ""
    @State private var replacement = ""
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                TextField("What you say, such as post hog", text: $phrase)
                    .textInputAutocapitalization(.never)
                TextField("Write as (optional), such as PostHog", text: $replacement)
                    .textInputAutocapitalization(.never)
                Button("Add") {
                    problem = model.addVocabulary(phrase: phrase, replacement: replacement)
                    if problem == nil { phrase = ""; replacement = "" }
                }
                .disabled(phrase.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text(problem ?? "Speech models use these words while they listen, and BetterWispr respells what they write. A misheard voice command works too: add what it wrote and write it as the command, such as “Coma” written as “comma”.")
                    .foregroundStyle(problem == nil ? Color.secondary : Color.red)
            }

            if model.selectedModel.engine == .parakeet, !models.phraseBoosterInstalled {
                Section {
                    Button("Download the phrase booster") { models.installPhraseBooster() }
                } footer: {
                    Text("Parakeet models need it to use your words while recognizing speech.")
                }
            }

            Section("\(model.vocabulary.count) of 200") {
                ForEach(model.vocabulary) { entry in
                    HStack {
                        Text(entry.phrase)
                        if !entry.replacement.isEmpty {
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                            Text(entry.replacement).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entry.learned { Text("Learned").font(.caption2).padding(4).background(.thinMaterial, in: Capsule()) }
                    }
                }
                .onDelete { offsets in offsets.map { model.vocabulary[$0] }.forEach(model.deleteVocabulary) }
            }
        }
        .navigationTitle("Vocabulary")
    }
}

// MARK: Style

struct StyleView: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Cleanup", selection: $model.settings.cleanup) {
                    Text("None").tag(CleanupLevel.none)
                    Text("Light").tag(CleanupLevel.light)
                    Text("Medium").tag(CleanupLevel.medium)
                }
                .pickerStyle(.segmented)
                .onChange(of: model.settings.cleanup) { model.save() }
            } header: {
                Text("Auto cleanup")
            } footer: {
                Text(cleanupCaption)
            }

            Section {
                ForEach(StyleContext.allCases, id: \.self) { context in
                    Picker(contextName(context), selection: Binding(
                        get: { model.settings.tone(for: context) },
                        set: { model.settings.styles[context] = $0; model.save() })) {
                        ForEach(context.tones, id: \.self) { Text(toneName($0)).tag($0) }
                    }
                }
            } header: {
                Text("Writing tone")
            } footer: {
                Text("iOS doesn't tell keyboards which app you're in, so pick Personal, Work, Email or Other on the BetterWispr keyboard. Dictations in this app use Other. Tones change English dictation only.")
            }

            Section {
                Toggle("Use text around the cursor", isOn: $model.settings.useScreenContext)
                    .onChange(of: model.settings.useScreenContext) { model.save() }
            } footer: {
                Text("With Medium cleanup, the keyboard sends the text before your cursor to your notes model so it can spell what you see. Your notes model may be a cloud service.")
            }
        }
        .navigationTitle("Style")
    }

    private var cleanupCaption: String {
        switch model.settings.cleanup {
        case .none: "Keeps your words as recognized. Voice commands and Vocabulary still apply."
        case .light: "Removes filler words like “um” and “you know”, and stutters."
        case .medium: "Also edits English for clarity with your notes model (\(model.settings.notesModelName)). Choose it in Settings."
        }
    }
}

func contextName(_ context: StyleContext) -> String {
    switch context {
    case .personal: "Personal messages"
    case .work: "Work messages"
    case .email: "Email"
    case .other: "Other"
    }
}

func toneName(_ tone: StyleTone) -> String {
    switch tone {
    case .formal: "Formal"
    case .casual: "Casual"
    case .veryCasual: "Very casual"
    case .excited: "Excited"
    }
}

// MARK: Modes

struct ModesView: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(model.settings.modes) { mode in
                    NavigationLink { ModeEditor(id: mode.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.name.isEmpty ? "Untitled mode" : mode.name)
                            Text(mode.triggerWords.isEmpty ? "No trigger word" : "Say “\(mode.triggerWords.joined(separator: "”, “"))”")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .opacity(mode.isEnabled ? 1 : 0.5)
                    }
                }
                .onDelete { offsets in
                    model.settings.modes.remove(atOffsets: offsets)
                    model.save()
                }
                .onMove { from, to in
                    model.settings.modes.move(fromOffsets: from, toOffset: to)
                    model.save()
                }
            } footer: {
                Text("Start or end a dictation with a mode's trigger word to use its settings; the word is removed from the text. Modes you set up for apps or websites on your Mac sync here too and work by trigger word on iPhone.")
            }
        }
        .navigationTitle("Modes")
        .toolbar {
            EditButton()
            Button("Add", systemImage: "plus") {
                model.settings.modes.append(WritingMode(name: "New mode"))
                model.save()
            }
        }
    }
}

private struct ModeEditor: View {
    @Environment(MobileModel.self) private var model
    let id: UUID
    @State private var mode = WritingMode()
    @State private var triggers = ""

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $mode.name)
                Toggle("On", isOn: $mode.isEnabled)
            }
            Section {
                TextField("Trigger words, separated by commas", text: $triggers)
                    .textInputAutocapitalization(.never)
            } footer: {
                Text("Pick a phrase you wouldn't otherwise say, such as “casual mode”.")
            }
            Section("Settings") {
                Picker("Cleanup", selection: $mode.cleanup) {
                    Text("Same as default").tag(CleanupLevel?.none)
                    ForEach(CleanupLevel.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(CleanupLevel?.some($0)) }
                }
                Picker("Tone", selection: $mode.tone) {
                    Text("Same as default").tag(StyleTone?.none)
                    ForEach(StyleTone.allCases, id: \.self) { Text(toneName($0)).tag(StyleTone?.some($0)) }
                }
            }
            Section {
                TextEditor(text: $mode.instructions).frame(minHeight: 100)
            } header: {
                Text("Instructions for Medium cleanup")
            } footer: {
                Text("Such as “Use British spelling.”")
            }
            if !mode.apps.isEmpty || !mode.websites.isEmpty {
                Section {
                    ForEach(mode.apps + mode.websites, id: \.self) { Text($0).foregroundStyle(.secondary) }
                } header: {
                    Text("Apps and websites on your Mac")
                } footer: {
                    Text("Kept for your Mac. iOS can't tell BetterWispr which app or website you're in.")
                }
            }
        }
        .navigationTitle(mode.name.isEmpty ? "Mode" : mode.name)
        .onAppear {
            if let saved = model.settings.modes.first(where: { $0.id == id }) {
                mode = saved
                triggers = saved.triggerWords.joined(separator: ", ")
            }
        }
        .onDisappear(perform: commit)
    }

    private func commit() {
        guard let index = model.settings.modes.firstIndex(where: { $0.id == id }) else { return }
        mode.triggerWords = triggers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        mode.instructions = String(mode.instructions.prefix(WritingMode.instructionLimit))
        guard model.settings.modes[index] != mode else { return }
        model.settings.modes[index] = mode
        model.save()
    }
}
