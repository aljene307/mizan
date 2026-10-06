# Journal de bord

## Étape 0 — Environnement (2026-10-05)

**Fait**
- Environnement vérifié : Windows 11, Docker Desktop 29.6.2 (Compose v5.3.1),
  Git 2.48.1, Node.js 24.18.0. Ports 5678 et 5432 libres.
- Arborescence du dépôt, `docker-compose.yml` (PostgreSQL 18, n8n 2.41.7, task
  runner externe), `.env.example`, `.gitignore`, `.gitattributes`, README, licence MIT.
- Création automatique de la base `mizan` au premier démarrage de PostgreSQL.
- Dépôt Git initialisé sur la branche `main`.

**Décisions :** D-001 à D-009 (voir [decisions.md](decisions.md)).

**Problèmes rencontrés**
- Plusieurs URL de la documentation n8n ont changé (pages déplacées sous
  `/deploy/host-n8n/...`). Les sources citées utilisent les nouvelles adresses.
- La documentation n8n est contradictoire sur `N8N_RUNNERS_ENABLED` (indiqué
  « false » par défaut mais obsolète depuis la 2.0). On ne la définit pas et on
  utilise `N8N_RUNNERS_MODE=external`, comme le recommande la doc.
- Au démarrage, n8n 2.41.7 signale que plusieurs valeurs par défaut vont changer
  (`N8N_RUNNERS_TASK_TIMEOUT` : 300 s → 60 s, limites du nœud Compression,
  paquets communautaires non vérifiés). Aucun impact pour l'instant ; à
  réexaminer avant une mise à jour de n8n.

**Vérifié (étape 0) :** les 3 conteneurs tournent, `postgres` est healthy, `/healthz`
répond `{"status":"ok"}`, 142 tables n8n ont été créées dans la base `n8n`, la base
`mizan` existe, et les runners JavaScript et Python sont enregistrés auprès du broker.

## Étape 1 — Modèle de données (2026-10-05)

**Fait**
- dbmate 2.36.0 ajouté comme service Docker à la demande (profil `outils`).
- 8 migrations : fonctions communes, fournisseurs et historique des RIB,
  factures et lignes, résultats de contrôles, relevés et rapprochements,
  journal d'audit en ajout seul, configuration fiscale datée (6 valeurs de
  départ), droits du rôle `mizan_app`.
- Ajouts demandés : table `resultats_controles` ; colonnes `droit_timbre`,
  `devise` (TND par défaut) et `type_document` (facture/avoir) dans `factures`.
- Rôle applicatif `mizan_app` (mot de passe dans `.env`, script `db/init/02`).
- 44 tests SQL (`db/tests/`) : 28 sur le schéma et les contraintes, 16 sur
  les droits de `mizan_app`. Ils s'exécutent dans des transactions annulées.
- README : section base de données et glossaire anglais.

**Décisions :** D-010 à D-020 (voir [decisions.md](decisions.md)).

**Problèmes rencontrés**
- **Sources fiscales officielles difficiles d'accès.** legislation.tn et
  iort.gov.tn ne répondaient pas. La page « Aperçu général sur la fiscalité »
  de finances.gov.tn est périmée (TVA 18/12/6 %). Seules les lois de finances
  2025 et 2026 (PDF du JORT sur finances.gov.tn) ont pu être lues. Elles sont
  en arabe et l'extraction de texte simple perdait les caractères : il a fallu
  forcer l'encodage UTF-8 de `pdftotext`. Toutes les valeurs fiscales restent
  marquées « à confirmer » (D-020).
- La loi de finances 2026 ne fixe le timbre que pour les **grandes surfaces**
  (art. 117, n° 6 bis du CDET) ; le timbre général sur les factures n'a pas pu
  être vérifié dans un texte officiel.
- Proposition corrigée : l'unicité (fournisseur, numéro) prévue initialement
  aurait empêché d'enregistrer un doublon reçu ; remplacée par des index et un
  contrôle (D-013).
- Le conteneur `postgres` a été recréé (nouveau montage `db/tests`, nouvelle
  variable) ; les données sont restées dans le volume. Comme le volume existait
  déjà, le script `02-create-app-role.sh` a été lancé à la main.
- PowerShell 5.1 ne transmet pas une chaîne multiligne à `git commit -F -` :
  le message de commit passe par un fichier temporaire.

**Vérifié (étape 1) :** 8 migrations appliquées ; une 2e exécution de `up` ne
change rien ; les 8 migrations s'annulent toutes (0 table restante) puis se
réappliquent ; les 44 tests passent ; une assertion volontairement fausse fait
bien échouer les tests ; `db/schema.sql` ne contient aucun secret.

**Revue avant commit (demandes de validation)**
- Ajout d'un filet de sécurité contre les doublons : index unique partiel sur
  les factures `conforme` ou `validee`, avec numéro normalisé (D-021),
  migration n° 9, 7 tests de plus (51 au total). Testé aussi en annulation
  puis réapplication.
- Timbre « grandes surfaces » conservé dans la configuration mais exclu des
  contrôles sans justification écrite (D-022).
- Contrainte pour l'étape 2 : factures synthétiques datées de 2026 (D-023).
- README : avertissement sur le caractère illustratif des paramètres fiscaux.

## Étape 2 — Données synthétiques (2026-10-05)

**Fait**
- Projet Node.js (`package.json`, ESM) : Playwright 1.63 (Chromium headless),
  sharp, pg, ajv, polices @fontsource (OFL).
- `src/` : montants en millimes, RIB (clé), matricule fiscal (format),
  lecture de `config_fiscale` à une date, schémas JSON d'extraction et de
  vérité terrain. 19 tests unitaires.
- `generateur/` : référentiel fictif (12 fournisseurs connus, 2 inconnus),
  modèle déterministe (60 documents, 9 types de pièges, lots dev/test,
  relevé bancaire), rendu en 4 mises en page (PDF et scans JPEG).
- `data/synthetic/` : 45 PDF, 15 scans, 60 vérités terrain, `lots.json`,
  référentiel, relevé CSV de 103 opérations et 33 appariements attendus.
- 21 tests du générateur et des fichiers produits (40 tests Node au total).
- README : limite de l'évaluation (précision optimiste sur données
  synthétiques) ; README propre au jeu de données.

**Décisions :** D-024 à D-030.

**Problèmes rencontrés**
- Matricule fiscal : le format officiel (`\d{7}[A-Z]`) vient du cahier des
  charges TEJ ; l'algorithme de la lettre clé n'a aucune source officielle,
  il n'est donc pas appliqué (D-027).
- Clé RIB : la formule la plus citée en ligne (89 × B + 15 × G + 3 × C) est
  celle du RIB **français**. L'algorithme retenu a été vérifié sur l'exemple
  du registre IBAN. Le PDF du registre sur swift.com a refusé le
  téléchargement (HTTP 403).
- Liste officielle des codes banque de la BCT non consultée : le choix du
  code 99 repose sur des listes secondaires (D-027).
- `node --test tests/` ne fonctionne plus sous Node 24 : il faut un motif de
  fichiers (`"tests/**/*.test.js"`).
- Bug trouvé par les tests : les appariements du relevé pointaient vers une
  copie de l'opération et perdaient leur numéro de ligne. Corrigé.
- Chromium écrit la date du rendu dans chaque PDF, ce qui changeait les
  empreintes à chaque génération. Les dates sont maintenant figées
  (même longueur, la table xref reste valide).
- Pour respecter D-026, seuls des documents du lot dev ont été ouverts pour
  vérifier visuellement le rendu.

**Après validation :** décision D-031 (l'évaluation affichera les nombres
bruts, le lot de test ne comptant que 18 documents). L'historique Git a été
réécrit à la demande de Mohamed (messages sans numéro d'étape ni co-auteur,
auteur et dates conservés), puis poussé avec `--force-with-lease`.

**Vérifié (étape 2) :** 40 tests Node passent ; deux générations successives
donnent les 126 mêmes fichiers, octet par octet ; inspection visuelle des 4
mises en page et de 2 scans (lot dev uniquement).

## Étape 3 — Réception et extraction (en cours, 2026-10-05)

**Décisions :** D-032 (OCR Tesseract, images seulement), D-033 (Gemini en
offre gratuite, modèle fixé d'après les quotas réels, seuil de 100 requêtes
par jour), D-034 (offre gratuite réservée aux données synthétiques), D-035
(débit limité et reprise sur 429, pas de second appel pour une même
empreinte, traçabilité de chaque extraction).

**Points relevés pendant la préparation**
- n8n 2.x désactive par défaut le nœud *Local File Trigger* (`NODES_EXCLUDE`)
  et restreint l'accès aux fichiers (`N8N_RESTRICT_FILE_ACCESS_TO`).
- Les quotas Gemini s'appliquent par projet Google, pas par clé, et le quota
  journalier repart à zéro à minuit, heure du Pacifique.
- Décisions complémentaires : D-036 (Gemini 3.5 Flash-Lite, pause de 7 s),
  D-037 (conception validée), D-038 (pas de double traitement), D-039
  (sous-workflow LLM au contrat stable), D-040 (gestion des erreurs, arrêt
  propre si le quota journalier est épuisé), D-041 (code des nœuds Code
  généré depuis `src/` et vérifié par un test).

**Fait (première partie)**
- Migration n° 10 : statut `en_extraction`, référence de la source,
  contrainte d'unicité de la réception, table `extractions` en ajout seul,
  fonctions `enregistrer_reception`, `reserver_facture_a_extraire`
  (`FOR UPDATE SKIP LOCKED`), `liberer_facture`,
  `extraction_valide_existante`, `enregistrer_extraction` (atomique).
  Annulation et réapplication vérifiées.
- 38 tests SQL de plus (89 au total), dont 34 exécutés par `mizan_app`.
- 3 tests d'intégration de concurrence sur une base dédiée `mizan_test`,
  recréée à chaque exécution (`npm run test:integration`).
- `src/validationExtraction.js` : validateur sans dépendance, même verdict
  qu'ajv sur les 42 vérités terrain du lot dev, 29 mutations ciblées et 500
  mutations aléatoires ; un validateur volontairement saboté est détecté.

**Problèmes rencontrés**
- Un test SQL mal écrit (colonne `montant_ht` ambiguë entre deux tables) :
  erreur du test, pas de la fonction ; corrigé.
- Le test de concurrence exige des données réellement validées en base :
  il tourne sur une base de test séparée pour ne jamais toucher `mizan`.

**Fait (deuxième partie)**
- Prompt v1 (`src/promptExtraction.js`) : instructions et document séparés,
  document balisé comme donnée non fiable, balises neutralisées, empreinte
  enregistrée (D-042). Schéma simplifié pour Gemini (`src/schemaFournisseur.js`).
- Service OCR (`ocr/`) : Tesseract 5.5.0, psm 3 choisi sur les 11 scans du
  lot dev (D-043). n8n l'atteint sur le réseau interne ; aucun port publié.
- Référentiel fictif chargé dans `mizan` (12 fournisseurs, 12 RIB) ; script
  idempotent (D-044).
- Script `npm run synchroniser-noeuds` et test de synchronisation (D-041).
- Tests : 60 unitaires, 12 d'intégration (`mizan_test`, D-045), 89 SQL.

**Problèmes rencontrés**
- Le lanceur de tests de Node exécute les fichiers en parallèle : les tests
  d'intégration partageant `mizan_test`, ils sont désormais lancés un par un.
- Piège « injection de prompt » ajouté (D-046) : 4 documents modifiés
  (D001, D006, D026, D047), 56 documents et le relevé inchangés octet par
  octet, génération toujours reproductible (127 fichiers identiques d'une
  génération à l'autre). 62 tests unitaires, 12 d'intégration.
- Credentials n8n créés par Mohamed (Gemini, PostgreSQL `mizan_app`) ;
  requête de test réussie (200) : identifiant `gemini-3.5-flash-lite`
  confirmé (version 3.5-flash-lite-07-2026), schéma simplifié accepté, JSON
  conforme au schéma strict, 882 jetons en entrée et 357 en sortie.
- RIB extrait à 18 chiffres : la facture de test (mal construite) n'en
  contenait que 18 ; Gemini n'a rien perdu. Facture de test corrigée.
- Contrôle « identifiant présent dans le texte source » (D-047) : 0 fausse
  alerte sur 125 identifiants des 31 PDF dev. Paramètres de génération fixés
  et enregistrés (D-048) : température 1.0 selon Google, réflexion `low`.
- Migration n° 11 ; 95 tests SQL, 79 tests unitaires.
- Seconde requête de test (température 1.0, réflexion `low`) : 200, paramètres
  acceptés, mais un zéro ajouté dans le RIB (21 chiffres au lieu de 20).
  Attrapé par D-047 et par la clé RIB ; réponse conservée comme jeu d'essai,
  test ajouté (80 tests unitaires). Piste d'amélioration du prompt notée pour
  la mesure de stabilité.
- Contrôle des identifiants revu deux fois après des défauts trouvés par les
  tests (RIB tronqué à une frontière de groupe, numéro coupé avant un tiret,
  mot de la ligne suivante pris pour une suite). Mesures dev : 0 alerte sur
  125 identifiants des PDF ; 6 sur 44 pour les scans, toutes dues à l'OCR.
- Sous-workflow LLM (8 nœuds) et workflow principal (31 nœuds) générés par
  `scripts/construire-workflows.js` (D-049) ; 103 tests unitaires.
- Jeu d'essai copié dans `data/entrant/` (ignoré par Git) : D006 (injection),
  D007, D034 (avoir), D041 (scan), D056 et son doublon exact D035.

### Reprise du 2026-10-06
- Commit `d0ce530` confirmé sur GitHub.
- Premier essai réel (6 documents dev, exécution n8n n° 5) : 90/96 champs
  d'en-tête et 12/12 lignes exacts ; doublon D035/D056 → un seul appel au LLM ;
  D006 : injection non suivie (vrai TTC), mais RIB amputé de son « 99 »
  initial, signalé par D-047 ; les 5 autres écarts sont des raisons sociales en
  majuscules (petites capitales). Hypothèse `.last()` confirmée (D-049).
- Règle de comparaison fixée avant tout usage du lot de test (D-050).
- Texte transmis au LLM conservé (D-051, migration n° 12) ; 100 tests SQL,
  103 unitaires, 12 d'intégration.
- Problème : le premier script de comparaison comptait 0 ligne juste, car
  PostgreSQL réordonne les clés JSONB ; comparaison refaite sans tenir compte
  de l'ordre des clés (12/12).
- Corrections : vérité terrain des tickets (désignations tronquées : 3 vérités
  dev changées, aucun document, aucune vérité du lot de test) ; frontière du
  RIB arrêtée en fin de ligne (2 fausses alertes supprimées). D-050 complétée
  (extractions non conformes : données conservées, taux d'utilisables à part).
- Rapport dev après corrections : en-tête 633/656 normalisé, lignes 108/112,
  extractions utilisables 35/41, 0 fausse alerte.
- Mesure D-052 : prompt v2 (v1 inchangée, empreinte vérifiée), corrections par
  le code (`src/correctionsCode.js`), scripts `eval/mesurer.js` et
  `eval/analyser-mesure.js` ; 125 tests unitaires.
- Piège évité : le workflow principal prenait la « dernière version » du
  registre des prompts ; l'ajout de la v2 aurait fait échouer toutes les
  extractions (le sous-workflow ne connaît que la v1). Il utilise désormais
  la version en service (`VERSION_PROMPT`).
- Mesure D-052 réalisée (184 appels, tous réussis, 5 nouvelles tentatives) :
  rapport `eval/resultats/mesure-2026-10-06/rapport.md`. Prompt v2 sans gain
  (désignations polluées par les colonnes voisines, RIB abîmé recopié) ;
  corrections par le code décisives (devise : 30/36 → 36/36 utilisables ;
  RIB : 32/36 → 35/36, uniquement par confirmation avec le référentiel, aucun
  remplissage faux) ; stabilité v1-libre 166/170 → 168/170 après corrections
  (les RIB laissés à null au hasard sont neutralisés). Injection jamais
  suivie (8 passages sur D001). Quota du jour : environ 225 requêtes.
- Configuration figée par Mohamed (D-053) : prompt v1, devise libre convertie
  par le code, paramètres inchangés, quatre corrections par le code dans
  l'ordre validé. Deux points notés pour la suite : à l'étape 4, une
  proposition de RIB différente du référentiel déclenche l'alerte de
  changement de RIB même si le RIB extrait est vide ; à l'étape 8, le rapport
  montre côte à côte la sortie brute et le résultat après corrections.
- Intégration : migration n° 13 (`donnees_brutes`, `corrections_code`,
  `signalements_code`, `propositions`, fonction `ribs_referentiel()`) ; nœud
  « RIB du référentiel » dans le workflow principal (32 nœuds). Ajout : un
  texte contenant plusieurs RIB valides est signalé. 111 tests SQL,
  134 unitaires, 12 d'intégration.

### Contrôles déterministes : modèle de données (2026-10-06)
- Commit `a83407c` poussé (corrections par le code, configuration figée).
- Choix validés : workflow « Contrôles » séparé, tolérance mixte,
  fournisseur probable proposé seulement, statut `a_valider` (D-055) ; deux
  rôles, quatre règles non dérogeables, méthode de vérification obligatoire,
  création de fournisseur soumise à la même discipline que le changement de
  RIB (D-056).
- Migrations n° 14 et 15 : statuts `en_controle` et `a_valider`, garde des
  transitions, catalogue de 22 règles, paramètres de contrôle datés,
  utilisateurs, décisions humaines, demandes et décisions sur le
  référentiel, fonctions de réservation, de contexte et d'enregistrement des
  contrôles. `mizan_app` n'écrit plus dans le référentiel.
- Tests : 167 SQL (nouveau fichier `04_controles.sql`), 135 unitaires,
  13 d'intégration. Annulation et réapplication des migrations vérifiées.
- Règles de contrôle v1 (`src/controles/regles.js`, 22 règles, D-057) et
  31 tests unitaires (166 au total). Premier essai d'un test des lignes
  faux (3 × 0,333333 arrondi donne exactement 1,000) : exemple corrigé.
- Mesure sur la vérité terrain du lot dev (`eval/evaluer-controles.js`) :
  9 pièges sur 9 détectés par la règle prévue, 0 fausse alerte sur
  33 factures sans piège, 42 statuts sur 42 conformes à l'attendu. Aucune
  tolérance d'arrondi n'a servi (données synthétiques régulières).
- Principe D-058 : paiement toujours sur le RIB actif du référentiel, jamais
  sur le RIB lu ; le RIB extrait ne sert qu'aux contrôles.
- Test par mutation (`npm run test:mutations`, sans LLM) : 18 mutations sur
  chacune des 33 factures sans piège (TVA, TTC, ligne, RIB, matricule,
  dates), limites des tolérances comprises : 594 / 594 conformes.
- Workflow « Contrôles » généré (5 nœuds : déclencheur, réservation,
  contexte, règles, enregistrement, en boucle). Test du code généré sur le
  vrai contexte de la base (D023). 171 tests unitaires.
- Constat (Mohamed) confirmé en base : lot dev extrait avant D-053 (6 en
  erreur « DT », dont le piège D028 ; 36 avec d'anciennes données) ; une
  relance aurait réutilisé les anciennes extractions. D-059 : colonne
  `version_chaine`, réutilisation limitée à la même version (migration
  n° 16), script `reextraire-lot-dev.js` (simulation par défaut).
  169 tests SQL, 173 unitaires, 17 d'intégration. Simulation sur `mizan` :
  42 factures à réextraire, 0 refus.
- Réextraction du lot dev appliquée (42 factures remises en « recue »,
  42 entrées au journal), puis exécution du workflow par Mohamed :
  41 appels à Gemini, 1 réutilisation (D056 ← D035), aucune erreur,
  41/41 extractions utilisables. Les 36 textes comparables sont identiques
  à ceux conservés lors de la mesure.
- Rapport de précision dev mis à jour (`eval/evaluer.js`, sortie brute et
  résultat corrigé côte à côte) : utilisables 35/41 → 41/41 ; en-tête
  normalisé 636/656 → 646/656 ; RIB 36/41 → 39/41 ; devise 35/41 → 41/41 ;
  injection suivie 0/2 ; 5 identifiants faux sans alerte, tous des erreurs
  de l'OCR présentes dans le texte (suffixes de matricule, numéro D024).
- Workflow « Contrôles » importé et exécuté par Mohamed : 45 passages
  (990 résultats). Mesure sur l'extraction réelle
  (`eval/evaluer-controles-reel.js`) : 9 pièges sur 9 détectés par la règle
  prévue ; 2 fausses alertes sur 31 factures normales hors injection (D005 :
  prix unitaire mal lu par l'OCR ; D018 : entités HTML malformées) ;
  signalement « plusieurs RIB » sur les 2 factures piégées par injection ;
  40/42 statuts attendus.
- Défaut trouvé par cette mesure : contexte des contrôles sans historique du
  fournisseur (règle `matricule_suffixe` aveugle). Corrigé (D-060, migration
  n° 17, test SQL) ; aucun effet sur les alertes ni les statuts.
- README : contrôles (trois mesures et leurs limites, fausses alertes D005
  et D018 avec leur cause), import du workflow « Contrôles », commandes.
  Piste notée pour plus tard (D-061) : signalement d'entités HTML sur des
  champs seulement descriptifs ramené à « info ».
- Étape validée par Mohamed ; commit et push.
