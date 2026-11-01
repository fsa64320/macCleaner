# Désinstallation des outils en ligne de commande

## Objectif

Permettre de retirer depuis macCleaner les outils CLI installés par Homebrew, npm et uv, sans casser ce qui en dépend. Succès : l'utilisateur voit ses outils de premier niveau, sait ce que chaque retrait emporte, et une suppression reste traçable.

Hors périmètre : pnpm, yarn, gem et cargo ; la mise à jour d'outils depuis ce module ; toute modification de l'écran Mises à jour.

## Module

Nouveau cas `Module.cliTools`, titre « Outils en ligne de commande », placé dans le groupe « Nettoyer » après `.devTools`. Il utilise `ScanStore` et `ScanModuleView`, avec une catégorie par source : Homebrew, npm, uv. Une source dont l'exécutable est absent ou dont la commande échoue n'affiche pas de catégorie.

## Inventaire

`CommandLineToolScanner` reçoit un exécuteur injecté `@Sendable (Tool, [String]) -> Docker.Output?`, sur le modèle de `Docker.run`. Le type `Output` est réutilisé. Chaque commande a un délai maximal.

| Source | Lecture | Périmés |
|---|---|---|
| Homebrew | `brew info --json=v2 --installed` | champ `outdated` du même JSON |
| npm | `npm ls -g --depth=0 --json` | `npm outdated -g --json` |
| uv | `uv tool list --show-paths` | `uv tool list --outdated` |

Exécutables cherchés dans des emplacements fixes : `/opt/homebrew/bin`, `/usr/local/bin`, et `~/.local/bin` pour uv. `HOMEBREW_NO_AUTO_UPDATE=1` est posé. `npm outdated` renvoie le statut 1 quand des paquets sont périmés : seule une sortie JSON illisible compte comme un échec. Si la lecture des périmés échoue, la liste s'affiche sans badge.

Outils listés :

- Homebrew : formules `installed_on_request` qu'aucune formule installée ne requiert, et tous les casks. Les dépendances n'ont pas de ligne propre.
- npm : tous les paquets globaux.
- uv : tous les outils.

Chaque outil devient un `ScanItem` :

- `url` : dossier du Cellar ou du Caskroom, dossier du paquet npm, ou dossier de l'outil uv. Il sert d'identifiant et rend les Exclusions applicables.
- `size` : `FileSystem.allocatedSize`, dépendances exclusives comprises pour Homebrew.
- `detail` : version, badge de mise à jour, dépendances emportées, alerte éventuelle.
- `removal` : `.commandLineTool`.
- `selectedByDefault` : toujours `false`.
- `locked` : voir Protections.
- `launchLabel` : identifiant de l'outil encodé `source:nom`, avec `cask` pour un cask, comme pour `.dockerImage`.

## Dépendances Homebrew

`brew autoremove` retire tous les orphelins de la machine, y compris ceux sans rapport, et n'est donc pas utilisé.

Une fonction pure calcule les dépendances exclusives à partir du JSON de `brew info` : le graphe `runtime_dependencies` donne la fermeture de l'outil ; une dépendance est exclusive si elle n'a pas `installed_on_request` et si toutes les formules installées qui la requièrent sont l'outil ou d'autres dépendances exclusives. Le calcul se fait pour un outil à la fois.

Les dépendances exclusives vont dans un nouveau champ `ScanItem.removalArguments: [String]`, vide par défaut. `companions` ne convient pas : il désigne des fichiers mis à la Corbeille.

Le retrait lance `brew uninstall -- outil dep1 dep2…`, en une commande et sans `--ignore-dependencies` ni `--force`. Homebrew refuse donc toute formule encore requise, et l'échec remonte comme une erreur de l'élément. Si deux outils sélectionnés partagent des dépendances, chacune reste protégée par l'autre au moment du calcul et peut survivre : c'est le comportement sûr, et l'interface ne promet pas le contraire.

## Protections

Verrouillés (`locked: true`, jamais retirés) : `npm` et `corepack` côté npm, ainsi que toute formule `uv` qui serait présente.

Alerte forte, retrait possible après confirmation :

- `node`, `node@*` : liste les paquets npm globaux, qui ne fonctionneraient plus.
- `python@*`, `openjdk*` : environnements d'exécution.
- `gh` : outil utilisé pour ce dépôt.
- `rea-agents` : fournit le serveur REA.

Noms validés avant toute exécution par une fonction commune, sur le modèle de `Homebrew.isValid`. Les paquets npm à portée, comme `@anthropic-ai/claude-code`, sont acceptés ; un nom commençant par `-` est refusé. Les commandes passent par `Process`, sans shell, et le séparateur `--` précède les noms.

## Exécution

Nouveau cas `Removal.commandLineTool`. `FileRemoving` gagne `uninstallCommandLineTool(_ identifier: String, arguments: [String]) throws`. Dans `CleanupRunner.run`, ce cas est traité comme `.dockerImage` : les contrôles `locked` et Exclusions s'appliquent, `SafetyPolicy` ne s'applique pas puisqu'aucun fichier n'est touché directement, et la suppression est définitive.

Commandes : `brew uninstall [--cask] -- …`, `npm uninstall -g -- nom`, `uv tool uninstall -- nom`. Un statut non nul lève une erreur portant la sortie bornée de la commande.

`CleanupReport.permanentSize` compte `.commandLineTool`. `ScanModuleView` le compte comme définitif dans sa confirmation, et ajoute une phrase pour rappeler qu'il n'y a pas de Corbeille.

## Historique

`HistoryEntry` gagne `reinstallCommands: [String]?`, optionnel pour relire les anciennes lignes. `recordHistory` y met `brew install outil`, `brew install --cask outil`, `npm install -g nom@version` ou `uv tool install nom==version`. Les dépendances ne sont pas listées : elles reviennent avec l'outil. `HistoryView` affiche ces commandes.

## Tests

Tous dans `CoreTests` ou une nouvelle suite, sans jamais désinstaller un vrai outil, avec un exécuteur simulé :

- décodage des sorties des trois sources, y compris sortie vide et JSON illisible ;
- statut 1 de `npm outdated` accepté avec un JSON valide ;
- exclusion des dépendances de la liste Homebrew ;
- dépendances exclusives : dépendance partagée conservée, `installed_on_request` conservée, chaîne transitive retirée ;
- refus des noms dangereux, acceptation des portées npm ;
- `npm` et `corepack` verrouillés ;
- `CleanupRunner` : outil exclu ignoré, arguments transmis, échec remonté, taille comptée en définitive ;
- ancienne ligne d'historique lisible et commandes de réinstallation écrites.

## Formats observés

- `brew info --json=v2 --installed` : champ `outdated` présent sur les formules et les casks. `runtime_dependencies` est dans `installed[0]`, avec `full_name` pour chaque entrée.
- `uv tool list --outdated` : ligne `nom vX.Y.Z [latest: A.B.C]`, suivie de lignes `- commande`. Sortie sans JSON, décodée ligne par ligne.
