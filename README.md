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
- Confidentialité : historique, cookies et sessions des navigateurs, permissions accordées (consultation seule). Mots de passe et favoris ne sont jamais proposés.
- Mises à jour : détection via Homebrew, flux Sparkle et App Store. Seul Homebrew installe depuis l'app.
- Surveillance : menu bar, alerte de disque faible et analyse planifiée, sans suppression automatique.
- Images similaires et modèles IA locaux listés un par un.
- Exclusions : chemins à ne jamais proposer ni retirer.
- Historique des nettoyages.

## Sécurité

- L'analyse ne modifie rien. Toute suppression demande une sélection et une confirmation.
- Les fichiers vont à la Corbeille. Seul le contenu des corbeilles est supprimé définitivement.
- `SafetyPolicy` refuse les chemins sensibles (clés SSH, trousseaux, iCloud, dossiers racines, système).
- Pas d'agent root. Les tâches système passent par la demande de mot de passe de macOS.
- Une exclusion protège aussi le dossier parent du chemin exclu. Si `exclusions.json` est illisible, toute suppression est bloquée.
- Journal : `~/Library/Logs/macCleaner/cleanup.log`.
- Exclusions et historique : `~/Library/Application Support/macCleaner/`.

Pour une analyse complète, accordez l'accès complet au disque dans Réglages Système.

## Compiler

Seuls les outils en ligne de commande Xcode sont nécessaires.

```bash
swift test
```

Les tests sur le vrai système utilisent la Corbeille et `launchctl`, puis nettoient derrière eux :

```bash
MACCLEANER_INTEGRATION=1 swift test
```

```bash
Scripts/build-app.sh
```

Pour distribuer l'app, il faut un certificat Developer ID :

```bash
SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=profil Scripts/build-app.sh
```

```bash
open build/macCleaner.app
```
