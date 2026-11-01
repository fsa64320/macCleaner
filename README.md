# macCleaner

Utilitaire d'entretien pour macOS 14+, en SwiftUI, inspiré des fonctions de CleanMyMac.
C'est une réimplémentation indépendante : il ne contient ni code, ni assets, ni textes, ni base de règles de MacPaw.

## Fonctions

- Tableau de bord : disque, mémoire, charge processeur.
- Entretien rapide : caches et journaux, en une passe.
- Nettoyage : caches, Xcode, préférences cassées, corbeilles, résidus d'outils IA, modèles locaux, pièces jointes Mail.
- Encombrement : gros fichiers, doublons, vieux téléchargements.
- Carte du disque : treemap navigable.
- Désinstallation et restes d'applications.
- Agents de démarrage et tâches de maintenance.

## Sécurité

- L'analyse ne modifie rien. Toute suppression demande une sélection et une confirmation.
- Les fichiers vont à la Corbeille. Seul le contenu des corbeilles est supprimé définitivement.
- `SafetyPolicy` refuse les chemins sensibles (clés SSH, trousseaux, iCloud, dossiers racines, système).
- Pas d'agent root. Les tâches système passent par la demande de mot de passe de macOS.
- Journal : `~/Library/Logs/macCleaner/cleanup.log`.

Pour une analyse complète, accordez l'accès complet au disque dans Réglages Système.

## Compiler

Seuls les outils en ligne de commande Xcode sont nécessaires.

```bash
swift test
```

```bash
Scripts/build-app.sh
```

```bash
open build/macCleaner.app
```
