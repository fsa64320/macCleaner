# macCleaner

Utilitaire d'entretien pour macOS 14+, en SwiftUI, inspiré des fonctions de CleanMyMac.
C'est une réimplémentation indépendante : il ne contient ni code, ni assets, ni textes, ni base de règles de MacPaw.

## Fonctions

- Tableau de bord : disque, mémoire, charge processeur.
- Entretien rapide : caches et journaux, en une passe.
- Nettoyage : caches, Xcode, préférences cassées, corbeilles, résidus d'outils IA, modèles locaux, pièces jointes Mail.
- Encombrement : gros fichiers, doublons, vieux téléchargements.
- Outils de développement : dépendances de projets inactifs, caches de paquets et images Docker inutilisées.
- Outils en ligne de commande : outils Homebrew, npm et uv, retirés avec leurs dépendances exclusives. La suppression est définitive et sa commande de réinstallation reste dans l'Historique.
- Carte du disque : treemap navigable.
- Désinstallation et restes d'applications.
- Agents de démarrage et tâches de maintenance.
- Confidentialité : historique, cookies et sessions des navigateurs, permissions accordées (consultation seule). Mots de passe et favoris ne sont jamais proposés.
- Mises à jour : détection via Homebrew, flux Sparkle et App Store. Seul Homebrew installe depuis l'app.
- Surveillance : menu bar, alerte de disque faible et analyse planifiée, sans suppression automatique.
- E-mail et cloud : gros messages Gmail et Outlook, gros fichiers Google Drive, OneDrive et Dropbox, envoyés à la corbeille du service.
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

## E-mail et cloud

**Sur ce Mac** fonctionne sans connexion : les gros fichiers d'iCloud Drive, Google Drive, OneDrive ou Dropbox déjà téléchargés peuvent perdre leur copie locale et restent dans le cloud.

**Se connecter à…** ouvre la page du service dans une fenêtre sécurisée. L'utilisateur s'y identifie lui-même, et les jetons restent dans le trousseau.
Ce bouton a besoin des identifiants de l'application OAuth du build, à créer une seule fois avec l'adresse de redirection `http://localhost:53682/callback` :

```bash
cp Config/OAuthClients.example.json Config/OAuthClients.json
```

Renseignez ce fichier, ignoré par Git, puis relancez `Scripts/build-app.sh`.

| Service | Où créer l'application | Droits demandés |
|---|---|---|
| Gmail, Google Drive | Google Cloud Console, client « Bureau » | `gmail.modify`, `drive` |
| Outlook, OneDrive | Microsoft Entra, client public | `Mail.ReadWrite`, `Files.ReadWrite`, `offline_access` |
| Dropbox | App Console, avec PKCE | `files.metadata.read`, `files.content.write` |

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
