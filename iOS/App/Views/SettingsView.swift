import BetterWisprCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(MobileModel.self) private var model
    @Environment(MobileSync.self) private var sync

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    NavigationLink { ModelsView() } label: { LabeledContent("Speech model", value: model.selectedModel.name) }
                    Picker("Spoken language", selection: $model.settings.language) {
                        ForEach(languages, id: \.self) { code in Text(languageName(code)).tag(code) }
                    }
                    .onChange(of: model.settings.language) { model.save() }
                    NavigationLink { NotesModelView() } label: { LabeledContent("Notes model", value: model.settings.notesModelName) }
                } header: {
                    Text("Speech")
                } footer: {
                    Text("Built-in models run on this iPhone. An API connection sends audio to its provider only when you choose it.")
                }

                Section("Keyboard") {
                    NavigationLink("Set up the BetterWispr keyboard") { KeyboardSetupView() }
                }

                Section {
                    NavigationLink { SyncView() } label: {
                        LabeledContent("Sync", value: sync.isOn ? (sync.folderName ?? "On") : "Off")
                    }
                } footer: {
                    Text("Keep history, vocabulary, modes, style and meeting notes the same on your Mac and iPhone.")
                }

                Section("After you speak") {
                    Toggle("Learn from my corrections", isOn: $model.settings.learnCorrections)
                        .onChange(of: model.settings.learnCorrections) { model.save() }
                    Toggle("Save dictation history", isOn: $model.settings.saveHistory)
                        .onChange(of: model.settings.saveHistory) { model.save() }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $model.settings.theme) {
                        Text("System").tag(AppTheme.system)
                        Text("Light").tag(AppTheme.light)
                        Text("Dark").tag(AppTheme.dark)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model.settings.theme) { model.save() }
                }

                Section("Voice commands") {
                    ForEach(Array(voiceCommands.enumerated()), id: \.offset) { _, command in
                        LabeledContent(command.0, value: command.1)
                    }
                }

                Section {
                    Link("Source code", destination: URL(string: "https://github.com/adamfrank321/betterwispr-ios")!)
                    Link("BetterWispr for Mac", destination: URL(string: "https://betterwispr.com")!)
                } footer: {
                    Text("BetterWispr is open source under the Apache 2.0 license.")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var languages: [String] {
        let supported = model.selectedModel.languages ?? ["en", "de", "es", "fr", "it", "ja", "ko", "nl", "pl", "pt", "ru", "tr", "uk", "zh", "hi", "ar"]
        var codes = ["auto"] + supported
        if !codes.contains(model.settings.language) { codes.append(model.settings.language) }
        return codes
    }

    private func languageName(_ code: String) -> String {
        code == "auto" ? "Detect automatically" : (Locale.current.localizedString(forLanguageCode: code) ?? code)
    }

    private let voiceCommands = [
        ("“comma”, “question mark”, “full stop”", ", ? ."),
        ("“new line”, “new paragraph”", "Line breaks"),
        ("“scratch that”", "Deletes the last sentence"),
        ("“at the rate KV”", "@KV"),
        ("“write an email to Sam saying …”", "An email layout"),
    ]
}

// MARK: Models

struct ModelsView: View {
    @Environment(MobileModel.self) private var model
    @Environment(ModelManager.self) private var models

    var body: some View {
        List {
            Section {
                ForEach(model.models.filter { $0.engine != .api }) { speech in
                    ModelRow(speech: speech)
                }
            } footer: {
                Text("Parakeet Ultra is recommended for English and 24 European languages. Whisper covers the most languages. Models download only when you tap Download, over Wi-Fi or cellular.")
            }
            if !model.settings.speechConnections.isEmpty {
                Section("API connections") {
                    ForEach(model.models.filter { $0.engine == .api }) { ModelRow(speech: $0) }
                }
            }
            Section {
                NavigationLink("Add an API connection") { ConnectionEditor() }
            } footer: {
                Text("Keys stay in this iPhone's keychain and never sync.")
            }
        }
        .navigationTitle("Speech model")
    }
}

private struct ModelRow: View {
    @Environment(MobileModel.self) private var model
    @Environment(ModelManager.self) private var models
    let speech: SpeechModel

    var body: some View {
        let installed = models.isInstalled(speech)
        let selected = model.settings.selectedModelID == speech.id
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(speech.name).font(.headline)
                if speech.id == "parakeet-ultra" { Text("Recommended").font(.caption2).padding(4).background(.thinMaterial, in: Capsule()) }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
            }
            Text(speech.detail).font(.caption).foregroundStyle(.secondary)
            if let installation = models.installation, installation.modelID == speech.id {
                if let failure = installation.failure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                    Button("Retry") { install() }
                } else {
                    ProgressView(value: installation.progress)
                    Button("Cancel", role: .cancel) { models.cancelInstallation() }.font(.caption)
                }
            } else if !installed {
                HStack {
                    Button("Download \(speech.sizeLabel)") { install() }
                        .disabled(!models.isSuitable(speech) || models.installation != nil)
                    if !models.isSuitable(speech) { Text("Needs more memory than this iPhone has").font(.caption).foregroundStyle(.secondary) }
                }
                .font(.subheadline)
            } else if !selected {
                Button("Use this model") { select() }.font(.subheadline)
            }
        }
        .padding(.vertical, 4)
        .swipeActions {
            if installed, speech.engine == .parakeet || speech.engine == .whisperKit, !selected {
                Button("Remove", role: .destructive) { models.remove(speech) }
            }
        }
    }

    private func install() { models.install(speech) { select() } }

    private func select() {
        model.settings.selectedModelID = speech.id
        model.save()
        models.warmUp(speech)
    }
}

private struct ConnectionEditor: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var connection = SpeechConnection()
    @State private var key = ""
    @State private var problem: String?

    var body: some View {
        Form {
            Picker("Provider", selection: $connection.api) {
                ForEach(SpeechAPI.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .onChange(of: connection.api) {
                connection.endpoint = connection.api.endpoint
                connection.modelID = connection.api.defaultModel
                connection.name = connection.api.name
            }
            TextField("Name", text: $connection.name)
            TextField("Endpoint", text: $connection.endpoint).textInputAutocapitalization(.never).keyboardType(.URL)
            TextField("Model", text: $connection.modelID).textInputAutocapitalization(.never)
            SecureField("API key", text: $key)
            if let problem { Text(problem).foregroundStyle(.red) }
            Button("Save") { save() }
        }
        .navigationTitle("API connection")
    }

    private func save() {
        do {
            _ = try connection.validatedURL()
            try connection.validateAPIKey(key)
            try SpeechAPIKeyStore().save(key, for: connection)
            model.settings.speechConnections.append(connection)
            model.save()
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: Notes model

struct NotesModelView: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        Form {
            Section {
                Button { choose(.apple) } label: { row("Apple Intelligence", selected: model.settings.notesSelection == .apple) }
                ForEach(model.settings.notesConnections) { connection in
                    Button { choose(.connection(connection.id)) } label: {
                        row("\(connection.name) · \(connection.modelID)", selected: model.settings.notesSelection == .connection(connection.id))
                    }
                }
            } footer: {
                Text(footer)
            }
        }
        .navigationTitle("Notes model")
    }

    private var footer: String {
        var text = "Writes meeting notes, makes Medium cleanup edits and reviews corrections before they're learned. Apple Intelligence runs on this iPhone (iOS 26 on a supported iPhone)."
        if case .unavailable(let reason) = MeetingNotesGenerator.availability(settings: model.settings) { text += "\n\n" + reason }
        if case .cli = model.settings.notesSelection { text += "\n\nYour Mac uses a command-line notes model, which can't run on iPhone. Choose one here for this iPhone." }
        return text
    }

    private func row(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            if selected { Image(systemName: "checkmark") }
        }
    }

    private func choose(_ selection: NotesModelSelection) {
        model.settings.notesSelection = selection
        model.save()
    }
}

// MARK: Sync

struct SyncView: View {
    @Environment(MobileSync.self) private var sync
    @State private var picking = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder", value: sync.folderName ?? "None")
                Button(sync.isOn ? "Choose another folder" : "Choose a folder") { picking = true }
            } footer: {
                Text("Pick the same folder you chose in BetterWispr on your Mac, such as iCloud Drive. BetterWispr keeps its files in a BetterWispr folder inside it, and each device writes only its own files.")
            }
            if sync.isOn {
                Section("Status") {
                    if let problem = sync.problem {
                        Text(problem).foregroundStyle(.red)
                    } else if let last = sync.lastSync {
                        LabeledContent("Last synced", value: last.formatted(.relative(presentation: .named)))
                    } else {
                        Text(sync.isSyncing ? "Syncing…" : "Waiting for the first sync.")
                    }
                    if sync.pendingDownloads > 0 {
                        Text("Waiting for iCloud to download \(sync.pendingDownloads) file\(sync.pendingDownloads == 1 ? "" : "s").").font(.footnote)
                    }
                    ForEach(sync.devices) { device in
                        LabeledContent(device.name, value: device.lastSync.formatted(.relative(presentation: .named)))
                    }
                    Button("Sync now") { Task { await sync.syncNow() } }.disabled(sync.isSyncing)
                }
                Section {
                    Button("Stop syncing", role: .destructive) { sync.stop() }
                } footer: {
                    Text("Removes this iPhone's files from the folder. Everything stays on this iPhone and your other devices.")
                }
            }
            Section("What syncs") {
                Text("History, vocabulary and learned words, writing modes, style and cleanup settings, spoken language, and meeting notes.")
                Text("Stays on each device: API keys, the speech model you picked, and keyboard settings.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Sync")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { sync.choose(url) }
        }
    }
}

// MARK: Keyboard setup

struct KeyboardSetupView: View {
    var body: some View {
        let bridge = KeyboardBridge()
        List {
            Section {
                Step(number: 1, text: "Open Settings > General > Keyboard > Keyboards > Add New Keyboard, and choose BetterWispr.")
                Step(number: 2, text: "Tap BetterWispr in that list and turn on Allow Full Access. The keyboard needs it to reach this app, which does the listening.")
                Step(number: 3, text: "In any app, hold the globe key and choose BetterWispr. Tap the microphone: this app opens and starts listening. Swipe back to your app, speak, and tap the button again to insert your words.")
                Step(number: 4, text: "For the next few minutes, the keyboard records without leaving your app. iOS shows the orange microphone dot while BetterWispr is ready to listen.")
            }
            Section {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Section("Status") {
                LabeledContent("Keyboard added", value: bridge.keyboardLastSeen == nil ? "Not yet" : "Yes")
                LabeledContent("Full Access", value: bridge.keyboardHasFullAccess ? "On" : "Off")
            }
        }
        .navigationTitle("Keyboard")
    }

    private struct Step: View {
        let number: Int
        let text: String

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Text("\(number)").font(.headline).frame(width: 24, height: 24).background(Circle().fill(.thinMaterial))
                Text(text)
            }
            .padding(.vertical, 4)
        }
    }
}
