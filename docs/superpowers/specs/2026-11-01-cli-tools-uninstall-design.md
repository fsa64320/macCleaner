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

Exécutables cherchés dans des emplacements fixes : `/opt/homebrew/bin`, `/usr/local/bin`, et `~/.local/bin` pour uv. `HOMEBREW_NO_AUTO_UPDATE=1` et `HOMEBREW_NO_AUTOREMOVE=1` sont posés. `npm outdated` renvoie le statut 1 quand des paquets sont périmés : seule une sortie JSON illisible compte comme un échec. Si la lecture des périmés échoue, la liste s'affiche sans badge.

Outils listés :

- Homebrew : formules `installed_on_request` qu'aucune formule installée ne requiert, et tous les casks. Les dépendances n'ont pas de ligne propre.
- npm : tous les paquets globaux.
- uv : tous les outils.

Chaque outil devient un `ScanItem` :

- `url` : dossier du Cellar ou du Caskroom, dossier du paquet npm, ou dossier de l'outil uv. Il sert d'identifiant et rend les Exclusions applicables.
- `size` : `FileSystem.allocatedSize`, dépendances exclusives comprises pour Homebrew. Pour une formule à plusieurs versions, seul le dossier de la version active compte.
- `detail` : version, badge de mise à jour, dépendances emportées, mention des anciennes versions ou de l'épingle.
- `warning` : alerte éventuelle, sur sa propre ligne. Nouveau champ `ScanItem.warning: String?`, `nil` par défaut.
- `dependencyPaths` : dossiers du Cellar des dépendances emportées. Nouveau champ `ScanItem.dependencyPaths: [URL]`, vide par défaut.
- `removal` : `.commandLineTool`.
- `selectedByDefault` : toujours `false`.
- `locked` : voir Protections.
- `launchLabel` : identifiant de l'outil encodé `source:nom`, avec `cask` pour un cask, comme pour `.dockerImage`.

## Dépendances Homebrew

`brew autoremove` retire tous les orphelins de la machine, y compris ceux sans rapport, et n'est donc pas utilisé. `brew uninstall` le lance de lui-même : `HOMEBREW_NO_AUTOREMOVE=1` l'en empêche.

Une fonction pure calcule les dépendances exclusives à partir du JSON de `brew info` : le graphe `runtime_dependencies` donne la fermeture de l'outil ; une dépendance est exclusive si elle n'a pas `installed_on_request`, si elle n'est pas protégée, et si toutes les formules installées qui la requièrent sont l'outil ou d'autres dépendances exclusives. Le calcul se fait pour un outil à la fois. `installed_on_request` absent vaut `true`. `installed_as_dependency` n'existe pas dans le JSON de `brew info` et n'est pas utilisé.

Formules protégées, jamais candidates : `uv`, tout nom alerté (voir Protections), les formules épinglées, celles à plusieurs versions, et celles dont le dossier du Cellar est couvert par les Exclusions. Une formule protégée reste installée, donc ce qu'elle requiert reste aussi. Le scanner reçoit les Exclusions à chaque analyse. `CleanupRunner` ignore en plus un outil dont l'un des `dependencyPaths` est exclu, pour le cas d'une exclusion ajoutée après l'analyse.

Les dépendances exclusives vont dans un nouveau champ `ScanItem.removalArguments: [String]`, vide par défaut. `companions` ne convient pas : il désigne des fichiers mis à la Corbeille.

Le retrait lance `brew uninstall -- outil dep1 dep2…`, en une commande et sans `--ignore-dependencies` ni `--force`. Homebrew refuse donc toute formule encore requise, et l'échec remonte comme une erreur de l'élément. Une dépendance dont le dossier du Cellar a disparu entre-temps est retirée de la commande ; l'absence de l'outil lui-même reste un échec. Si deux outils sélectionnés partagent des dépendances, chacune reste protégée par l'autre au moment du calcul et peut survivre : c'est le comportement sûr, et l'interface ne promet pas le contraire.

## Formules épinglées et à plusieurs versions

La version retenue est `linked_keg`, sinon la dernière de `installed`. Les dépendances sont l'union de toutes les versions.

Sans `--force`, `brew uninstall` ne retire que la version active et rend 0. Une formule de premier niveau à plusieurs versions reste donc listée : sa taille ne compte que cette version, `detail` indique « les anciennes versions restent installées », et elle n'emporte aucune dépendance, puisque ses anciennes versions les requièrent encore.

`brew uninstall` n'échoue pas sur une formule épinglée : il affiche une erreur et rend 0. Une formule épinglée de premier niveau est donc verrouillée, avec une mention dans `detail`.

## Protections

Verrouillés (`locked: true`, jamais retirés) : `npm` et `corepack` côté npm, toute formule `uv` qui serait présente, et les formules épinglées.

Alerte forte pour toutes les sources, retrait possible après confirmation :

- `node`, `node@*` : liste les paquets npm globaux, qui ne fonctionneraient plus.
- `python@*`, `openjdk*` : environnements d'exécution.
- `gh` : outil utilisé pour ce dépôt.
- `rea-agents` : fournit le serveur REA.

Une ligne alertée n'est pas cochée par la case de sa catégorie : il faut la cocher elle-même.

Noms validés avant toute exécution par une fonction commune, sur le modèle de `Homebrew.isValid`. Les paquets npm à portée, comme `@anthropic-ai/claude-code`, sont acceptés ; un nom commençant par `-` est refusé. Les commandes passent par `Process`, sans shell, et le séparateur `--` précède les noms.

## Exécution

Nouveau cas `Removal.commandLineTool`. `FileRemoving` gagne `uninstallCommandLineTool(_ identifier: String, arguments: [String]) throws`. Dans `CleanupRunner.run`, ce cas est traité comme `.dockerImage` : les contrôles `locked` et Exclusions s'appliquent, `SafetyPolicy` ne s'applique pas puisqu'aucun fichier n'est touché directement, et la suppression est définitive.

Commandes : `brew uninstall [--cask] -- …`, `npm uninstall -g -- nom`, `uv tool uninstall -- nom`. Un statut non nul lève une erreur portant la sortie bornée de la commande.

`CleanupReport.permanentSize` compte `.commandLineTool`. `ScanModuleView` le compte comme définitif dans sa confirmation.

La confirmation vient d'une fonction pure, `CommandLineToolConfirmation.message(for:formattedSize:)`. Elle rappelle que le retrait est définitif et sans Corbeille, et nomme chaque outil, ses dépendances (depuis `removalArguments`) et son alerte. La liste s'arrête à 12 outils et 8 dépendances par outil, avec « et N autre(s) ». Les outils alertés passent en tête, et le reliquat signale combien portent une alerte. Une sélection mixte affiche la même liste après son message habituel.

## Historique

`HistoryEntry` gagne `reinstallCommands: [String]?`, optionnel pour relire les anciennes lignes. `recordHistory` y met `brew install outil`, `brew install --cask outil`, `npm install -g nom@version` ou `uv tool install nom==version`. La version n'y figure que si elle respecte `^[A-Za-z0-9._+-]+$`. Les dépendances n'ont pas de commande : elles reviennent avec l'outil. `HistoryView` affiche ces commandes.

`dependencyPaths` s'ajoute aux `paths` de l'historique, et le journal écrit une ligne par dépendance. Une raison d'échec y tient sur une seule ligne.

## Tests

Tous dans `CoreTests` ou une nouvelle suite, sans jamais désinstaller un vrai outil, avec un exécuteur simulé :

- environnement sans `autoremove`, correspondance `cask` vers `brew` ;
- décodage des sorties des trois sources, y compris sortie vide et JSON illisible ;
- statut 1 de `npm outdated` accepté avec un JSON valide ;
- exclusion des dépendances de la liste Homebrew ;
- dépendances exclusives : dépendance partagée conservée, `installed_on_request` conservée, chaîne transitive retirée, cascade, cycle, formules protégées et ce qu'elles requièrent ;
- version active, formule épinglée, formule à plusieurs versions ;
- texte de confirmation et limites de liste ;
- refus des noms dangereux, acceptation des portées npm ;
- `npm` et `corepack` verrouillés ;
- `CleanupRunner` : outil exclu ou à dépendance exclue ignoré, arguments transmis, échec remonté, taille comptée en définitive, traces des dépendances ;
- ancienne ligne d'historique lisible et commandes de réinstallation écrites.

## Formats observés

- `brew info --json=v2 --installed` : champ `outdated` présent sur les formules et les casks. `runtime_dependencies` est dans chaque entrée de `installed`, avec `full_name`. `installed` est trié par version croissante. `linked_keg` est `null` pour une formule keg-only. Observé avec Homebrew 7.0.11.
- `uv tool list --outdated` : ligne `nom vX.Y.Z [latest: A.B.C]`, suivie de lignes `- commande`. Sortie sans JSON, décodée ligne par ligne.
