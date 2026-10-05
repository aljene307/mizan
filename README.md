# Mizan

Contrôleur de factures fournisseurs avec rapprochement bancaire, pour une PME tunisienne.

Mizan automatise le traitement des factures fournisseurs : réception (dossier, mail,
Telegram), extraction des données (PDF, image, XML), contrôles déterministes,
validation humaine, rapprochement avec le relevé bancaire et restitution
(échéancier, prévision de trésorerie, TVA déductible). L'orchestration repose sur
[n8n](https://n8n.io) auto-hébergé.

> Projet de portfolio. Le dépôt ne contient que des **données synthétiques** et
> n'envoie rien à la plateforme El Fatoora / TTN.

## État d'avancement

| Étape | Contenu | État |
|---|---|---|
| 0 | Environnement Docker (n8n + PostgreSQL) | ✅ |
| 1 | Modèle de données | à venir |
| 2 | Données synthétiques | à venir |
| 3 | Réception et extraction | à venir |
| 4 | Contrôles | à venir |
| 5 | Validation humaine (Telegram) | à venir |
| 6 | Rapprochement bancaire | à venir |
| 7 | Restitution | à venir |
| 8 | Évaluation de l'extraction | à venir |
| 9 | Finition | à venir |

## Prérequis

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (avec Docker Compose v2 ou plus)
- Git
- Node.js 24 ou plus (pour les tests de `src/`, à partir de l'étape 4)

## Démarrage

```powershell
git clone <url-du-depot> mizan
cd mizan
Copy-Item .env.example .env   # puis remplacer chaque « change-me » par un secret
docker compose up -d
```

Ouvrir ensuite <http://localhost:5678> et créer le compte propriétaire n8n
(compte local, stocké dans votre base PostgreSQL).

Arrêter : `docker compose down`. Les données sont conservées dans les volumes
Docker ; `docker compose down -v` les supprime définitivement.

## Architecture (étape 0)

| Service | Image | Rôle |
|---|---|---|
| `postgres` | `postgres:18` | Base `n8n` (interne à n8n) et base `mizan` (données métier, piste d'audit) |
| `n8n` | `n8nio/n8n` | Éditeur et moteur de workflows, sur `localhost:5678` |
| `runners` | `n8nio/runners` | Exécute le JavaScript des nœuds Code, isolé de n8n |

Les ports ne sont publiés que sur `127.0.0.1`. Le dossier `data/` est monté en
lecture seule dans n8n, sous `/data`.

## Structure du dépôt

```
docker-compose.yml   pile locale
.env.example         variables d'environnement (aucun secret)
docs/                architecture, décisions, journal
db/                  schéma SQL, migrations, données de départ
workflows/           exports JSON des workflows n8n
src/                 fonctions JavaScript des contrôles
tests/               tests unitaires de src/
data/synthetic/      factures et relevés générés, avec vérité terrain
eval/                script et résultats d'évaluation
```

## Licence

[MIT](LICENSE)
