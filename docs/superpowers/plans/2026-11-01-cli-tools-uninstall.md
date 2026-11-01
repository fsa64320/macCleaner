# Désinstallation des outils CLI : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ajouter un module qui liste les outils Homebrew, npm et uv et les désinstalle sans casser leurs dépendants.

**Architecture:** Un scanner produit des `ScanItem` à partir de sorties de commandes injectées. La suppression passe par `CleanupRunner` avec une nouvelle `Removal.commandLineTool`, comme `.dockerImage`. Le calcul des dépendances exclusives est une fonction pure.

**Tech Stack:** Swift 5.10, SwiftPM, SwiftUI, Swift Testing, `Process`.

**Spec:** `docs/superpowers/specs/2026-11-01-cli-tools-uninstall-design.md`

## Global Constraints

- macOS 14+, Command Line Tools seulement. Pas de XCTest, pas de macro `@State`.
- Textes d'interface et commentaires en français.
- `selectedByDefault` toujours `false` pour un outil.
- Pas de `--force`, pas de `--ignore-dependencies`, pas de `brew autoremove`, pas de shell.
- Aucun test ne lance une vraie désinstallation.
- `main` est protégée : tout le travail va sur la branche `cli-tools-uninstall`, puis pull request.
- Si `swift test` échoue sur `TestingMacros`, faire `rm -rf .build` et relancer.

## Review Focus

1. Paquet npm à portée (`@anthropic-ai/claude-code`) : l'identifiant `npm:@anthropic-ai/claude-code` doit se relire entier, le `:` et le `/` compris.
2. Formule de tap (`arthur-ficial/tap/apfel-gui`) : son dossier est `Cellar/apfel-gui`, et le nom complet doit passer la validation.
3. Désinstallation longue : le délai des commandes de lecture ne doit pas tuer un `brew uninstall` en cours.
4. Outil déjà retiré entre l'analyse et le nettoyage : la commande échoue, l'échec remonte sans bloquer les outils suivants.
5. Sortie Homebrew sans dépendances enregistrées (`installed` vide) : la formule ne doit pas faire planter le décodage ni être comptée comme retirable à tort.

---

### Task 1: Retrait par commande dans le cœur

**Files:**
- Modify: `Sources/MacCleanerCore/Models.swift`, `Sources/MacCleanerCore/Cleanup.swift`, `Sources/MacCleanerCore/CleanupHistory.swift`
- Create: `Sources/MacCleanerCore/CommandLineTools.swift`
- Test: `Tests/MacCleanerCoreTests/CoreTests.swift`

**Interfaces:**
- Produces:
  - `Removal.commandLineTool`
  - `ScanItem.removalArguments: [String]` et `ScanItem.reinstallCommand: String?`, défauts `[]` et `nil`. Le second complète la spec : `recordHistory` a besoin de la commande par élément.
  - `FileRemoving.uninstallCommandLineTool(_ identifier: String, arguments: [String]) throws`
  - `HistoryEntry.reinstallCommands: [String]?`
  - `SystemFileRemover` appelle `CommandLineTools.uninstall(identifier:arguments:)`, défini à la tâche 2. Ici, créer `CommandLineTools.swift` avec cette fonction levant une erreur, le temps de compiler.

- [ ] **Step 1: Créer la branche `cli-tools-uninstall` et y commiter la spec et ce plan**

- [ ] **Step 2: Écrire les tests dans `CoreTests.swift`**

Étendre `RecordingRemover` pour enregistrer `(identifier, arguments)`, avec une liste d'identifiants qui lèvent.

```swift
@Test func testRunnerUninstallsCommandLineTool() throws {
    let url = home.appendingPathComponent("Cellar/ripgrep")
    let item = ScanItem(url: url, size: 10, removal: .commandLineTool, launchLabel: "brew:ripgrep",
                        removalArguments: ["pcre2"], reinstallCommand: "brew install ripgrep")
    let remover = RecordingRemover()
    let report = CleanupRunner(remover: remover, environment: env).run([item])
    #expect(remover.tools.map(\.identifier) == ["brew:ripgrep"])
    #expect(remover.tools.first?.arguments == ["pcre2"])
    #expect(report.permanentSize == 10)
}
```

Ajouter :
- `testRunnerSkipsExcludedAndLockedTools` : `report.skipped.count == 2`, aucun appel.
- `testRunnerContinuesAfterToolFailure` : premier outil en erreur, second retiré ; `report.failures.count == 1`, `report.removed.count == 1`, le `url` n'existe pas sur disque.
- `testHistoryKeepsReinstallCommands` : `load().entries.first?.reinstallCommands == ["brew install ripgrep"]`.
- `testHistoryReadsOldLines` : une ligne JSON sans `reinstallCommands` se relit, `unreadableLines == 0`.

- [ ] **Step 3: Vérifier l'échec**

Run: `swift test --filter CoreTests`
Expected: erreur de compilation, `commandLineTool` inconnu.

- [ ] **Step 4: Implémenter**

Dans `CleanupRunner.run`, traiter `.commandLineTool` avec `.dockerImage`, après le contrôle `locked`/Exclusions et avant `entryExists`. Le `switch` reçoit un `case .commandLineTool: break`. `permanentSize` compte ce cas. `recordHistory` met `report.removed.compactMap(\.reinstallCommand)`, ou `nil` si la liste est vide.

- [ ] **Step 5: Vérifier le succès**

Run: `swift test`
Expected: tous les tests passent.

- [ ] **Step 6: Commiter** avec le message `Add command line tool removal to the cleanup runner`.

### Task 2: Identifiants et exécution

**Files:**
- Modify: `Sources/MacCleanerCore/CommandLineTools.swift`
- Test: `Tests/MacCleanerCoreTests/CoreTests.swift`

**Interfaces:**
- Produces:

```swift
public enum CommandLineTools {
    public enum Source: String, Sendable { case brew, cask, npm, uv }
    public struct Identifier: Equatable, Sendable {
        public let source: Source
        public let name: String
        public var encoded: String        // "npm:@a/b"
        public init(source: Source, name: String)
        public init?(encoded: String)     // coupe au premier ":"
    }
    public typealias Runner = @Sendable (_ tool: Source, _ arguments: [String], _ timeout: TimeInterval) -> Docker.Output?
    public static let run: Runner
    static func isValid(name: String) -> Bool
    static func uninstallArguments(_ id: Identifier, extra: [String]) throws -> [String]
    public static func uninstall(identifier: String, arguments: [String]) throws
}
```

- [ ] **Step 1: Écrire les tests**

```swift
@Test func testToolIdentifierKeepsScopedName() throws {
    let id = try #require(CommandLineTools.Identifier(encoded: "npm:@anthropic-ai/claude-code"))
    #expect(id.source == .npm && id.name == "@anthropic-ai/claude-code")
    #expect(CommandLineTools.Identifier(encoded: "pip:x") == nil)
}

@Test func testToolNameValidation() {
    for name in ["ripgrep", "node@24", "@anthropic-ai/claude-code", "arthur-ficial/tap/apfel-gui", "graphifyy"] {
        #expect(CommandLineTools.isValid(name: name))
    }
    for name in ["--force", "-g", "a b", "a;rm", "", "../x"] {
        #expect(!CommandLineTools.isValid(name: name))
    }
}

@Test func testUninstallArguments() throws {
    let brew = CommandLineTools.Identifier(source: .brew, name: "graphviz")
    #expect(try CommandLineTools.uninstallArguments(brew, extra: ["gts"]) == ["uninstall", "--", "graphviz", "gts"])
    let cask = CommandLineTools.Identifier(source: .cask, name: "1password-cli")
    #expect(try CommandLineTools.uninstallArguments(cask, extra: []) == ["uninstall", "--cask", "--", "1password-cli"])
    let npm = CommandLineTools.Identifier(source: .npm, name: "omniroute")
    #expect(try CommandLineTools.uninstallArguments(npm, extra: []) == ["uninstall", "-g", "--", "omniroute"])
    let uv = CommandLineTools.Identifier(source: .uv, name: "graphifyy")
    #expect(try CommandLineTools.uninstallArguments(uv, extra: []) == ["tool", "uninstall", "--", "graphifyy"])
    #expect(throws: (any Error).self) { try CommandLineTools.uninstallArguments(brew, extra: ["--force"]) }
}
```

- [ ] **Step 2: Vérifier l'échec**

Run: `swift test --filter CoreTests`
Expected: erreur de compilation sur `Identifier`.

- [ ] **Step 3: Implémenter**

- `isValid` : regex `^@?[A-Za-z0-9][A-Za-z0-9@._+-]*(/[A-Za-z0-9][A-Za-z0-9@._+-]*)*$`, et refus de `..`.
- `run` : exécutables cherchés dans `/opt/homebrew/bin`, `/usr/local/bin`, plus `~/.local/bin` pour uv. Environnement : `HOMEBREW_NO_AUTO_UPDATE=1`, `PATH` étendu à ces dossiers, comme `Homebrew.run`. Stdout et stderr dans le même tube pour l'exécution, chien de garde comme `Docker.run`. Pour la lecture, stderr va vers `FileHandle.nullDevice` afin de garder le JSON propre : ajouter un paramètre interne `mergeErrors: Bool`.
- `uninstall` : délai de 300 s ; lecture : 60 s. Statut non nul : `NSError` portant les 500 premiers caractères de la sortie.
- Lire le tube jusqu'à la fin avant `waitUntilExit`.

- [ ] **Step 4: Vérifier le succès**

Run: `swift test`
Expected: tous les tests passent.

- [ ] **Step 5: Commiter** avec le message `Add command line tool identifiers and execution`.

### Task 3: Décodage et dépendances exclusives

**Files:**
- Create: `Sources/MacCleanerCore/CommandLineToolParsers.swift`
- Test: `Tests/MacCleanerCoreTests/CoreTests.swift`

**Interfaces:**
- Produces:

```swift
struct HomebrewFormula: Equatable {
    let name: String            // full_name, tap compris
    let version: String
    let onRequest: Bool
    let outdated: Bool
    let dependencies: [String]  // full_name des runtime_dependencies
}
struct InstalledPackage: Equatable { let name: String; let version: String; let latest: String? }
enum CommandLineToolParsers {
    static func homebrew(_ data: Data) -> (formulae: [HomebrewFormula], casks: [InstalledPackage])?
    static func topLevel(_ formulae: [HomebrewFormula]) -> [HomebrewFormula]
    static func exclusiveDependencies(of tool: String, in formulae: [HomebrewFormula]) -> [String]
    static func npmPackages(_ data: Data) -> [InstalledPackage]?
    static func npmOutdated(_ data: Data) -> [String: String]?
    static func uvTools(_ text: String) -> [InstalledPackage]
    static func uvOutdated(_ text: String) -> [String: String]
}
```

- [ ] **Step 1: Écrire les tests**

```swift
private func formula(_ name: String, _ deps: [String] = [], onRequest: Bool = false) -> HomebrewFormula {
    HomebrewFormula(name: name, version: "1", onRequest: onRequest, outdated: false, dependencies: deps)
}

@Test func testExclusiveDependencies() {
    let all = [
        formula("graphviz", ["gts", "librsvg"], onRequest: true),
        formula("gts", ["netpbm"]), formula("netpbm"),
        formula("librsvg"), formula("other", ["librsvg"], onRequest: true),
        formula("kept"), formula("tool", ["kept2"], onRequest: true), formula("kept2", onRequest: true),
    ]
    #expect(Set(CommandLineToolParsers.exclusiveDependencies(of: "graphviz", in: all)) == ["gts", "netpbm"])
    #expect(CommandLineToolParsers.exclusiveDependencies(of: "tool", in: all).isEmpty)
}

@Test func testTopLevelHidesDependencies() {
    let all = [formula("a", ["b"], onRequest: true), formula("b", onRequest: true), formula("c")]
    #expect(CommandLineToolParsers.topLevel(all).map(\.name) == ["a"])
}
```

Ajouter :
- `testHomebrewParsing` : JSON minimal avec une formule normale, un cask `outdated: true`, et une formule à `installed: []` qui est ignorée ; données illisibles → `nil`.
- `testNpmParsing` : `dependencies` à clé `@a/b` décodé ; `npmOutdated` de `{"x":{"current":"1","latest":"2"}}` → `["x": "2"]` ; `{}` → `[:]` ; texte illisible → `nil`.
- `testUvParsing` : sur la sortie ci-dessous, `uvOutdated == ["graphifyy": "0.9.100", "specify-cli": "1.2.5"]`, `uvTools` donne deux outils, versions `0.9.95` et `1.2.3` ; `""` → vide.

```text
graphifyy v0.9.95 [latest: 0.9.100]
- graphify
- graphify-mcp
specify-cli v1.2.3 [latest: 1.2.5]
- specify
```

- [ ] **Step 2: Vérifier l'échec**

Run: `swift test --filter CoreTests`
Expected: erreur de compilation sur `HomebrewFormula`.

- [ ] **Step 3: Implémenter**

`exclusiveDependencies` : prendre la fermeture transitive de l'outil, puis retirer en boucle jusqu'à stabilité toute dépendance `onRequest`, ou requise par une formule installée hors de `{outil} ∪ candidats`. La dépendance `runtime_dependencies` de Homebrew étant déjà transitive, la boucle reste correcte dans les deux cas. `uvTools` lit `uv tool list --show-paths` aussi : ignorer les lignes commençant par `-`, et couper le nom au premier espace, la version sans son `v`.

- [ ] **Step 4: Vérifier le succès**

Run: `swift test`
Expected: tous les tests passent.

- [ ] **Step 5: Commiter** avec le message `Parse command line tools and exclusive dependencies`.

### Task 4: Scanner

**Files:**
- Create: `Sources/MacCleanerCore/CommandLineToolScanner.swift`
- Test: `Tests/MacCleanerCoreTests/CoreTests.swift`

**Interfaces:**
- Consumes: `CommandLineTools.Runner`, `CommandLineToolParsers`, `ScanItem.removalArguments`, `ScanItem.reinstallCommand`.
- Produces:

```swift
public struct CommandLineToolScanner: Sendable {
    public struct Locations: Sendable {
        public let homebrew: URL   // contient Cellar et Caskroom
        public let npmRoot: URL    // node_modules global
        public let uvTools: URL
    }
    public init(environment: ScanEnvironment, run: CommandLineTools.Runner = CommandLineTools.run, locations: Locations? = nil)
    public func scan() -> ScanResult
}
```

- `locations == nil` : `/opt/homebrew` s'il existe, sinon `/usr/local` ; `npm root -g` ; `uv tool dir`.
- Catégories : ids `cli.brew`, `cli.npm`, `cli.uv`, titres `Homebrew`, `npm`, `uv`.

- [ ] **Step 1: Écrire les tests**

Avec un `run` simulé renvoyant des sorties par `(source, arguments)` et des dossiers créés sous `home` :

- `testToolScanListsTopLevelOnly` : `ripgrep` listé, `pcre2` absent. `removalArguments == ["pcre2"]`, `size` compte les deux dossiers du Cellar, `selectedByDefault == false`, `removal == .commandLineTool`, `launchLabel == "brew:ripgrep"`, `reinstallCommand == "brew install ripgrep"`.
- `testToolScanResolvesTapFolder` : `arthur-ficial/tap/apfel-gui` a pour `url` `Cellar/apfel-gui`.
- `testToolScanLocksCorePackages` : `npm` et `corepack` ont `locked == true` ; `omniroute` non.
- `testToolScanWarnsForRuntimes` : `detail` de `node@24` contient `omniroute`, et ceux de `python@3.14`, `openjdk@21`, `gh`, `rea-agents` contiennent `Attention`.
- `testToolScanShowsUpdates` : `detail` de `graphifyy` contient `0.9.100` ; `reinstallCommand == "uv tool install graphifyy==0.9.95"` ; pour npm, `"npm install -g omniroute@3.8.52"`.
- `testToolScanKeepsListWhenOutdatedFails` : `npm outdated` en `nil` : les paquets restent, sans badge.
- `testToolScanAcceptsNpmOutdatedStatusOne` : `Output(status: 1)` avec un JSON valide, badge présent.
- `testToolScanSkipsMissingSources` : `run` renvoie `nil` pour uv : pas de catégorie `cli.uv`.

- [ ] **Step 2: Vérifier l'échec**

Run: `swift test --filter CoreTests`
Expected: erreur de compilation sur `CommandLineToolScanner`.

- [ ] **Step 3: Implémenter**

`detail` : `version`, puis ` · mise à jour X`, puis ` · emporte N dépendance(s)`, puis ` · Attention : …`. Alertes : `node`/`node@*` listent les noms npm hors verrouillés, `python@*` et `openjdk*` « environnement d'exécution », `gh` « outil de ce dépôt », `rea-agents` « fournit le serveur REA ». Verrouillés : `npm`, `corepack`, formule `uv`. Les trois sources tournent l'une après l'autre avec `ScanProgress.current?.update`, et `ScanProgress.shouldStop` est vérifié entre chaque.

- [ ] **Step 4: Vérifier le succès**

Run: `swift test`
Expected: tous les tests passent.

- [ ] **Step 5: Commiter** avec le message `Add command line tool scanner`.

### Task 5: Interface, Historique et documentation

**Files:**
- Modify: `Sources/MacCleaner/AppModel.swift`, `Sources/MacCleaner/MacCleanerApp.swift:32`, `Sources/MacCleaner/ScanModuleView.swift:128-134`, `Sources/MacCleaner/HistoryView.swift:25`, `README.md`

**Interfaces:**
- Consumes: `CommandLineToolScanner`, `Removal.commandLineTool`, `HistoryEntry.reinstallCommands`.

- [ ] **Step 1: Ajouter `Module.cliTools`**

Titre « Outils en ligne de commande », sous-titre « Homebrew, npm et uv : retirez ce qui ne sert plus. », icône `terminal`, couleur `.orange`, `ScanStore` associé, placé après `.devTools` dans « Nettoyer ».

- [ ] **Step 2: Adapter la confirmation**

`permanent` compte `.commandLineTool`. Si tous les éléments sélectionnés sont des outils, message fixe : `"\(formatBytes(store.selectedSize)) seront libérés. Ces outils seront désinstallés définitivement, sans passer par la Corbeille."`

- [ ] **Step 3: Afficher les commandes dans `HistoryView`**

Sous `entry.paths`, un `Text` sélectionnable par commande de `entry.reinstallCommands ?? []`, en `.caption` monospace.

- [ ] **Step 4: Ajouter la ligne au README**

Dans « Fonctions » : `- Outils en ligne de commande : outils Homebrew, npm et uv, retirés avec leurs dépendances exclusives. La suppression est définitive et sa commande de réinstallation reste dans l'Historique.`

- [ ] **Step 5: Vérifier**

Run: `swift test && Scripts/build-app.sh`
Expected: tous les tests passent, `build/macCleaner.app` affiché.

- [ ] **Step 6: Vérifier l'analyse dans la vraie app, sans rien désinstaller**

Run: `open build/macCleaner.app`, ouvrir le module et lancer l'analyse.
Expected : trois catégories, `ripgrep` avec un badge, `omniroute` autour de 2,5 Go, `npm` non sélectionnable, `node@24` avec son alerte, aucune ligne pour `gnupg`.

- [ ] **Step 7: Commiter, pousser et ouvrir la pull request**

Commit `Add command line tools module`, puis pull request vers `main`.
