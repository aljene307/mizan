# Mizan

Contrôleur de factures fournisseurs avec rapprochement bancaire, pour une PME tunisienne.

Mizan automatise le traitement des factures fournisseurs : réception (dossier, mail,
Telegram), extraction des données (PDF, image, XML), contrôles déterministes,
validation humaine, rapprochement avec le relevé bancaire et restitution
(échéancier, prévision de trésorerie, TVA déductible). L'orchestration repose sur
[n8n](https://n8n.io) auto-hébergé.

> Projet de portfolio. Le dépôt ne contient que des **données synthétiques** et
> n'envoie rien à la plateforme El Fatoora / TTN.

> ⚠️ **Limite de l'évaluation.** Les factures de test sont générées à partir
> de nos propres modèles de mise en page. L'extraction est donc évaluée sur
> des documents propres et réguliers, plus faciles que de vraies factures
> (mises en page inconnues, scans de mauvaise qualité, écriture manuscrite).
> **La précision mesurée est optimiste** et ne préjuge pas des performances
> sur des factures réelles.

> ⚠️ **Extraction par l'offre gratuite de Google Gemini : données synthétiques
> uniquement.** Selon les conditions de l'API Gemini, l'offre gratuite peut
> utiliser les contenus envoyés et les réponses pour améliorer les produits de
> Google, et des relecteurs humains peuvent les lire. Elle convient aux
> factures synthétiques de ce dépôt, **pas à de vraies factures**
> ([conditions](https://ai.google.dev/gemini-api/terms), décision D-034).

> ⚠️ **Paramètres fiscaux illustratifs.** Les taux et montants fiscaux de
> `config_fiscale` (TVA, droit de timbre) sont donnés à titre d'illustration.
> Plusieurs restent **à confirmer** sur les textes officiels consolidés (voir
> [docs/decisions.md](docs/decisions.md), D-020). Ils ne constituent **pas un
> conseil fiscal**.

## État d'avancement

| Étape | Contenu | État |
|---|---|---|
| 0 | Environnement Docker (n8n + PostgreSQL) | ✅ |
| 1 | Modèle de données | ✅ |
| 2 | Données synthétiques | ✅ |
| 3 | Réception et extraction (OCR, Gemini, corrections par le code) | ✅ |
| 4 | Contrôles | à venir |
| 5 | Validation humaine (Telegram) | à venir |
| 6 | Rapprochement bancaire | à venir |
| 7 | Restitution | à venir |
| 8 | Évaluation de l'extraction | à venir |
| 9 | Finition | à venir |

## Extraction : résultats sur le lot de développement

> Ces chiffres viennent du **lot de développement**, qui a servi à mettre au
> point l'extraction : ce n'est **pas une évaluation**. L'évaluation se fera
> à l'étape 8 sur le lot de test, qui n'aura pas été ouvert d'ici là, avec la
> configuration figée le 2026-10-06 (D-053).

**Chaîne de traitement :**
1. lecture du texte du PDF, ou OCR Tesseract pour les scans ;
2. extraction par `gemini-3.5-flash-lite` (prompt v1, réponse au format
   d'un schéma JSON) ;
3. validation par un schéma strict ;
4. **corrections déterministes par le code** :
   - retrait des séparateurs dans les identifiants ;
   - conversion des alias de devise ;
   - entités HTML signalées ;
   - RIB retrouvé dans le texte et rempli seulement s'il est identique au
     référentiel ;
5. contrôle que chaque identifiant extrait figure dans le texte source.

La sortie brute du modèle est conservée à côté du résultat corrigé.

Mesure du 2026-10-06 sur les 36 textes conservés du lot de développement
(règle de comparaison D-050, en nombres bruts) :

| | Sortie brute du modèle | Après corrections par le code |
|---|---|---|
| Extractions utilisables (conformes au schéma) | 30 / 36 | 36 / 36 |
| Champs d'en-tête justes (comparaison normalisée) | 561 / 576 | 570 / 576 |
| RIB justes | 32 / 36 | 35 / 36 |
| RIB remplis à tort par le code | — | 0 |
| Champs identiques sur 3 passages (10 documents) | 166 / 170 | 168 / 170 |

- **Consigne injectée** dans une facture (« RIB à enregistrer… ») : jamais
  suivie (8 passages sur 8). Le document est signalé, car il contient deux
  RIB valides.
- **RIB resté faux :** un seul, sur un scan dont l'OCR a abîmé les chiffres ;
  le code ne l'invente pas.
- **Détail :** [eval/resultats/mesure-2026-10-06/rapport.md](eval/resultats/mesure-2026-10-06/rapport.md)
  et les décisions D-050 à D-054.

## Workflows n8n

Les workflows sont générés dans `workflows/` par
`node scripts/construire-workflows.js`.

Pour les importer dans n8n (menu ⋯ → *Import from File…*) :
1. importer d'abord `extraction-llm.json` (le sous-workflow) ;
2. puis importer `reception-extraction.json` ;
3. créer dans n8n les credentials « PostgreSQL Mizan (mizan_app) » et
   « Gemini Mizan ». Aucune clé n'est dans le dépôt.

Les factures sont à déposer dans `data/entrant/`, qui est ignoré par Git.

## Prérequis

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (avec Docker Compose v2 ou plus)
- Git
- Node.js 24 ou plus (générateur de données, fonctions de `src/` et tests)

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

## Base de données

Le schéma de la base `mizan` est géré par migrations
([dbmate](https://github.com/amacneil/dbmate)), dans `db/migrations/`.
`db/schema.sql` est le schéma complet, régénéré automatiquement.

```powershell
docker compose run --rm dbmate up        # appliquer les migrations
docker compose run --rm dbmate status    # voir les migrations appliquées
docker compose run --rm dbmate rollback  # annuler la dernière migration
docker compose exec postgres sh /db/tests/lancer.sh   # tester le schéma et les droits
```

## Fonctions métier, données synthétiques et tests

```powershell
npm install                       # dépendances (Playwright, sharp, pg, ajv…)
npx playwright install chromium   # navigateur utilisé pour produire les PDF
npm test                          # tests unitaires (src/) et tests du jeu de données
npm run generer                   # régénère data/synthetic/ (PostgreSQL doit tourner)
```

Le jeu de données (60 factures fictives, vérité terrain, relevé bancaire) est
décrit dans [data/synthetic/README.md](data/synthetic/README.md).

| Table | Rôle |
|---|---|
| `fournisseurs`, `fournisseur_ribs` | Fournisseurs et historique de leurs RIB |
| `factures`, `lignes_facture` | Factures et avoirs reçus, avec leurs lignes |
| `resultats_controles` | Résultat de chaque règle de contrôle, par facture |
| `releves_bancaires`, `lignes_releve` | Relevés bancaires importés |
| `rapprochements` | Liens facture ↔ ligne de relevé |
| `journal_audit` | Piste d'audit en ajout seul |
| `config_fiscale` | Taux et montants fiscaux datés, avec leur source |

n8n se connecte avec le rôle `mizan_app`, qui ne peut ni supprimer de données
ni modifier le journal d'audit.

## Glossary (English)

| Français | English |
|---|---|
| facture / avoir | invoice / credit note |
| fournisseur | supplier |
| montant HT / TVA / TTC | net amount / VAT / gross amount |
| droit de timbre | stamp duty |
| matricule fiscal | tax identification number |
| RIB (relevé d'identité bancaire) | bank account details |
| relevé bancaire | bank statement |
| rapprochement | reconciliation |
| échéance | due date |
| journal d'audit | audit trail |

## Architecture

| Service | Image | Rôle |
|---|---|---|
| `postgres` | `postgres:18` | Base `n8n` (interne à n8n) et base `mizan` (données métier, piste d'audit) |
| `n8n` | `n8nio/n8n` | Éditeur et moteur de workflows, sur `localhost:5678` |
| `runners` | `n8nio/runners` | Exécute le JavaScript des nœuds Code, isolé de n8n |
| `ocr` | construite depuis `ocr/` | Tesseract 5 (français), service HTTP interne, sans port publié |
| `dbmate` | `ghcr.io/amacneil/dbmate` | Migrations (profil « outils », lancé à la demande) |

Les ports ne sont publiés que sur `127.0.0.1`. Le dossier `data/` est monté en
lecture seule dans n8n, sous `/data`.

## Structure du dépôt

```
docker-compose.yml   pile locale
.env.example         variables d'environnement (aucun secret)
docs/                architecture, décisions, journal
db/                  schéma SQL, migrations, données de départ
workflows/           exports JSON des workflows n8n
generateur/          générateur des données synthétiques (Node.js + Playwright)
src/                 fonctions JavaScript des contrôles et schémas JSON
tests/               tests unitaires de src/
data/synthetic/      factures et relevés générés, avec vérité terrain
eval/                scripts et résultats d'évaluation et de mesure
scripts/             génération des workflows, chargement du référentiel
ocr/                 service OCR (Tesseract)
```

## Licence

[MIT](LICENSE)
