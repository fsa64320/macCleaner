import AppKit
import AuthenticationServices
import MacCleanerCore
import SwiftUI

/// Même fenêtre de connexion que Safari, présentée au-dessus de l'app.
@MainActor
private final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func start(_ url: URL, onDismiss: @escaping @Sendable () -> Void) {
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { _, _ in onDismiss() }
        session.presentationContextProvider = self
        self.session = session
        session.start()
    }

    func close() {
        session?.cancel()
        session = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    }
}

@MainActor
final class CloudStore: ObservableObject {
    /// `nil` : fichiers synchronisés sur ce Mac, sans connexion.
    @Published var provider: RemoteProvider?
    @Published var connected: Set<RemoteProvider> = []
    @Published var items: [RemoteItem] = []
    @Published var selection: Set<String> = []
    @Published var busy: String?
    @Published var message: String?
    @Published var confirming = false

    private let credentials: CloudCredentials
    private let tokens = KeychainTokenStore()
    private let history: CleanupHistory
    private let webSignIn = WebSignIn()
    private var task: Task<Void, Never>?
    private var receiver: LoopbackReceiver?

    init(history: CleanupHistory) {
        self.history = history
        credentials = CloudCredentials.load(from: Bundle.main.url(forResource: "OAuthClients", withExtension: "json"))
        connected = Set(RemoteProvider.allCases.filter(tokens.hasTokens))
    }

    var selectedItems: [RemoteItem] { items.filter { selection.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    func isAvailable(_ provider: RemoteProvider) -> Bool {
        !credentials.clientID(for: provider).isEmpty
    }

    private func oauth(_ provider: RemoteProvider) -> OAuthClient {
        OAuthClient(
            provider: provider, clientID: credentials.clientID(for: provider),
            clientSecret: credentials.clientSecret(for: provider), store: tokens
        )
    }

    func select(_ provider: RemoteProvider?) {
        cancel()
        self.provider = provider
        items = []
        selection = []
        message = nil
    }

    func connect() {
        guard let provider, isAvailable(provider) else { return }
        let oauth = oauth(provider)
        let state = PKCE.randomString()
        let pkce = PKCE()
        guard let url = oauth.authorizationURL(state: state, pkce: pkce) else { return }
        let receiver = LoopbackReceiver(state: state)
        self.receiver = receiver
        let webSignIn = webSignIn
        run("Connexion à \(provider.title)…") { [weak self] in
            let code = try await receiver.waitForCode {
                Task { @MainActor in webSignIn.start(url) { receiver.cancel() } }
            }
            webSignIn.close()
            try await oauth.exchange(code: code, pkce: pkce)
            self?.connected.insert(provider)
        }
    }

    func disconnect() {
        guard let provider else { return }
        tokens.delete(for: provider)
        connected.remove(provider)
        items = []
        selection = []
    }

    func scan() {
        guard let provider else { return }
        let service = RemoteServices.make(provider, client: RemoteClient(oauth: oauth(provider)))
        run("Lecture du compte…") { [weak self] in
            let found = try await service.list()
            self?.items = found
            self?.selection = []
            if found.isEmpty { self?.message = "Rien de volumineux trouvé." }
        }
    }

    func trashSelection() {
        guard let provider else { return }
        let service = RemoteServices.make(provider, client: RemoteClient(oauth: oauth(provider)))
        let targets = selectedItems
        let title = provider.title
        run("Envoi à la corbeille du service…") { [weak self] in
            var moved: [RemoteItem] = []
            var failures = 0
            for item in targets {
                if Task.isCancelled { break }
                do {
                    try await service.moveToTrash(item)
                    moved.append(item)
                } catch is CancellationError {
                    break
                } catch {
                    failures += 1
                }
            }
            let ids = Set(moved.map(\.id))
            self?.items.removeAll { ids.contains($0.id) }
            self?.selection.subtract(ids)
            self?.message = "\(moved.count) élément(s) dans la corbeille de \(title), \(failures) échec(s)."
            // Objets et noms de fichiers restent hors de l'historique local.
            try? self?.history.recordRemote(module: title, count: moved.count, bytes: moved.reduce(0) { $0 + $1.size }, failures: failures)
        }
    }

    func cancel() {
        task?.cancel()
        receiver?.cancel()
        webSignIn.close()
    }

    private func run(_ title: String, _ work: @escaping @MainActor () async throws -> Void) {
        task?.cancel()
        busy = title
        message = nil
        task = Task { [weak self] in
            do {
                try await work()
            } catch is CancellationError {
                self?.message = nil
            } catch {
                self?.message = error.localizedDescription
            }
            self?.busy = nil
        }
    }
}

struct CloudView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: CloudStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .cloud)
            Picker("Service", selection: Binding(get: { store.provider }, set: { store.select($0) })) {
                Text("Sur ce Mac").tag(RemoteProvider?.none)
                ForEach(RemoteProvider.allCases) { Text($0.title).tag(RemoteProvider?.some($0)) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.bottom, 12)
            if let message = store.message {
                Text(message).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.yellow.opacity(0.18))
            }
            content
        }
        .confirmationDialog(
            "Envoyer \(store.selectedItems.count) élément(s) à la corbeille de \(store.provider?.title ?? "") ?",
            isPresented: $store.confirming, titleVisibility: .visible
        ) {
            Button("Envoyer à la corbeille", role: .destructive) { store.trashSelection() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("\(formatBytes(store.selectedSize)). Récupérable depuis le service, le temps de rétention dépend de celui-ci.")
        }
    }

    @ViewBuilder private var content: some View {
        if let busy = store.busy {
            ActivityView(title: busy, activity: ScanProgress.Snapshot(), onCancel: store.cancel)
        } else if let provider = store.provider {
            if store.connected.contains(provider) {
                account(provider)
            } else {
                connection(provider)
            }
        } else if let local = model.stores[.cloud] {
            ScanModuleView(module: .cloud, store: local, showsHeader: false)
        }
    }

    private func connection(_ provider: RemoteProvider) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Button("Se connecter à \(provider.title)", action: store.connect)
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(!store.isAvailable(provider))
            if store.isAvailable(provider) {
                Text("Identifiez-vous sur la page de \(provider.title). macCleaner ne voit jamais votre mot de passe.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Text("Ce build n'a pas d'identifiant d'application pour \(provider.title). Voir le README.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func account(_ provider: RemoteProvider) -> some View {
        VStack(spacing: 0) {
            if store.items.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    Button("Analyser \(provider.title)", action: store.scan).buttonStyle(.borderedProminent).controlSize(.large)
                    Text(provider.isEmail ? "Liste les messages volumineux." : "Liste les fichiers les plus volumineux.").foregroundStyle(.secondary)
                    Button("Déconnecter", action: store.disconnect).buttonStyle(.link)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(store.items) { item in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { store.selection.contains(item.id) },
                            set: { if $0 { store.selection.insert(item.id) } else { store.selection.remove(item.id) } }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).lineLimit(1)
                                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(formatBytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .scrollContentBackground(.hidden)
                HStack {
                    Button("Nouvelle analyse", action: store.scan)
                    Button("Déconnecter", action: store.disconnect)
                    Spacer()
                    Text("\(store.selection.count) élément(s) · \(formatBytes(store.selectedSize))").monospacedDigit()
                    Button("Corbeille…") { store.confirming = true }
                        .buttonStyle(.borderedProminent).disabled(store.selection.isEmpty)
                }
                .padding(14).background(.bar)
            }
        }
    }
}
