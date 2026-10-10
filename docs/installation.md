# Installation, workflows n8n et commandes

Démarrage rapide et démonstration sans clé : [README](../README.md).

## Prérequis

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (avec Docker Compose v2 ou plus)
- Git
- Node.js 24 ou plus (générateur de données, fonctions de `src/` et tests)

## Démarrage

```powershell
git clone https://github.com/aljene307/mizan.git
cd mizan
node scripts/creer-env.js     # .env avec des secrets aléatoires ; refuse d'écraser un .env existant
docker compose up -d
```

Les mêmes commandes fonctionnent sous macOS et Linux. Ensuite, selon l'usage :
- **extraction réelle :** créer dans n8n le credential « Gemini Mizan » (voir
  « Workflows n8n ») ; `GEMINI_API_KEY` de `.env` ne sert qu'aux scripts de
  mesure ;
- **Telegram :** remplir `TELEGRAM_BOT_TOKEN` dans `.env`, puis relancer
  `docker compose up -d`.

Ouvrir ensuite <http://localhost:5678> et créer le compte propriétaire n8n
(compte local, stocké dans votre base PostgreSQL).

Arrêter : `docker compose down`. Les données sont conservées dans les volumes
Docker ; `docker compose down -v` les supprime définitivement.

## Reconstruire une base propre (démonstration, évaluation)

Une seule commande reconstruit la base `mizan`, **sans clé Gemini ni compte
Telegram** : les extractions enregistrées du lot de développement
(`demo/extractions-dev.json`) sont rejouées par les mêmes fonctions de la base
que les workflows, sans appel au modèle (D-078).

```powershell
npm run reconstruire-base -- --etat demonstration   # 42 factures, relevé rapproché, décisions en attente à montrer
npm run reconstruire-base -- --etat evaluation      # schéma, référentiel, utilisateurs ; aucune facture (évaluation, D-082)
```

**Avant d'effacer, le script :**
- refuse de tourner si un workflow Mizan est publié dans n8n (le dépublier
  d'abord, le republier après) ;
- affiche ce qu'il va faire, puis demande de taper le nom de la base ;
- sauvegarde la base actuelle dans `sauvegardes/` et relit la sauvegarde (ce
  dossier est ignoré par Git : il contient des données personnelles).

**Ce qui est conservé :** les utilisateurs réels, leur inscription Telegram
et le curseur de lecture du canal. Les comptes fictifs et le référentiel sont
rechargés. Le lot de test n'est jamais lu, et des tests le vérifient.

**L'état « démonstration »** suit le scénario de `demo/scenario.json` :
- il rejoue les deux validations qui fixent les factures approuvées avant le
  relevé ;
- il retrouve ainsi les chiffres publiés du rapprochement (103 opérations,
  12 confirmations automatiques, 13 propositions, 8 signalements) ;
- il laisse en attente une facture au RIB modifié, un doublon, les
  propositions et les signalements, et propose un lot d'ordres.

Les retards et le lot d'ordres dépendent de la date du jour.

**Sauvegarder ou restaurer à la main :**

```powershell
npm run sauvegarder-base                                                            # sauvegarde relue de la base mizan
npm run sauvegarder-base -- --restaurer sauvegardes/<fichier>.dump --dans mizan_restauree   # jamais dans la base de travail
```

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
décrit dans [data/synthetic/README.md](../data/synthetic/README.md).

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
ni modifier le journal d'audit. Le tableau de bord et les questions en langage
naturel lisent avec le rôle `mizan_lecture` : vues du schéma `restitution`
seulement, en session en lecture seule.

## Workflows n8n

Les workflows sont générés dans `workflows/` par
`node scripts/construire-workflows.js`.

Pour les importer dans n8n (menu ⋯ → *Import from File…*) :
1. importer d'abord `extraction-llm.json` (le sous-workflow) ;
2. puis importer `reception-extraction.json` ;
3. puis importer `controles.json` ;
4. puis importer `notifications-telegram.json` et `reponses-telegram.json`,
   et les publier (les autres se lancent à la main) ;
5. puis importer `releve-rapprochement.json`, et déposer le relevé CSV dans
   `data/entrant/releves/` ;
6. puis importer `ordres-paiement.json` et `questions.json`, et publier
   `questions.json` ;
7. créer dans n8n trois credentials (aucune clé n'est dans le dépôt) :
   - « PostgreSQL Mizan (mizan_app) », avec l'utilisateur `mizan_app` ;
   - « PostgreSQL Mizan (lecture) », avec l'utilisateur `mizan_lecture`
     (base `mizan`, hôte `postgres`) ;
   - « Gemini Mizan ».

**Credential de chaque nœud.** Après un import, n8n peut rattacher un autre
credential du même type que celui du fichier (incident du 2026-10-09, D-079).
Vérifier sur chaque nœud :

| Workflow | Nœud | Credential |
|---|---|---|
| Questions (langage naturel) | Lire les données (mizan_lecture) | **PostgreSQL Mizan (lecture)** (le seul nœud qui l'utilise) |
| Questions (langage naturel) | Interpréter (Gemini) | Gemini Mizan |
| Extraction LLM (Gemini) | Appel Gemini | Gemini Mizan |
| test Gemini (une requête) | Le modèle existe-t-il ?, Extraction de test | Gemini Mizan |
| Tous les autres | Tous les nœuds PostgreSQL | **PostgreSQL Mizan (mizan_app)** |

Puis lancer le contrôle. Il compare chaque nœud de chaque workflow (version
publiée et brouillon) au fichier du dépôt :

```powershell
npm run verifier-credentials-n8n
```

Le jeton du bot Telegram n'est **pas** un credential n8n : il se place dans
`.env` (`TELEGRAM_BOT_TOKEN`, sur une seule ligne), et seule la passerelle le
reçoit.

Pour réimporter un workflow existant, vider d'abord son canevas
(Ctrl + A, Suppr). Les factures sont à déposer dans `data/entrant/`, qui est
ignoré par Git.

Préparation de la base et mesures :

```powershell
npm run charger-referentiel          # référentiel fictif (compte administrateur)
npm run charger-utilisateurs-demo    # second utilisateur, fictif (quatre yeux)
npm run evaluer-controles            # contrôles sur la vérité terrain
npm run test:mutations               # test par mutation des contrôles
npm run evaluer-controles-reel       # contrôles sur l'extraction réelle
npm run creer-code-inscription -- --nom "Prénom Nom" --role responsable   # code /start à usage unique (30 min)
npm run simuler-second-responsable   # demandes en attente ; décision du compte fictif (--demande n --approuver méthode | --refuser)
                                     #   annulation d'un rapprochement : --annulation n --approuver | --refuser --justification "…"
npm run evaluer-rapprochement        # rapprochement sur le relevé de développement (n'écrit rien)
npm run exporter-ordres              # liste les lots ; --lot <n> : fichier à signer (sorties/ordres/)
npm run generer-releve-demo          # second relevé de démonstration (data/demo/), d'après les ordres approuvés
npm run construire-tableau-de-bord   # régénère le tableau de bord Grafana
npm run evaluer-questions            # mesure des questions en langage naturel (appelle Gemini)
npm run verifier-credentials-n8n     # credentials rattachés dans n8n conformes au dépôt
```

## Architecture

Conteneurs, réseaux et rôles de la base : [architecture.md](architecture.md).

## Structure du dépôt

```
docker-compose.yml   pile locale
.env.example         variables d'environnement (aucun secret)
docs/                architecture, décisions, journal
db/                  schéma SQL, migrations, données de départ
workflows/           exports JSON des workflows n8n
generateur/          générateur des données synthétiques (Node.js + Playwright)
src/                 fonctions métier (contrôles, rapprochement, questions) et schémas JSON
tests/               tests unitaires de src/
data/synthetic/      factures et relevés générés, avec vérité terrain
eval/                scripts et résultats d'évaluation et de mesure
scripts/             génération des workflows, chargement du référentiel
ocr/                 service OCR (Tesseract)
passerelle-telegram/ passerelle vers l'API Telegram (seule détentrice du jeton)
grafana/             source de données et tableau de bord provisionnés (générés)
```
