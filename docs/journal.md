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

### Validation humaine par Telegram : modèle de données (2026-10-08)
- Vérifié dans n8n 2.41.7 : Telegram Trigger et l'approbation intégrée de
  « Send and Wait » exigent une instance publique en HTTPS ; d'où
  l'interrogation `getUpdates` (A1). Réglages d'enregistrement des
  exécutions relevés dans le code installé (`saveDataSuccessExecution`…).
- Choix A1, B1, C1, D1, E1 et canal interchangeable (D-062).
- Migration n° 18 : adresses par canal (remplace `utilisateurs.telegram_id`),
  codes d'inscription, notifications à jeton, actions en attente,
  événements entrants, bail d'interrogation ; fonctions de canal ; le rôle
  applicatif ne crée plus de décision directement.
- Problème : les fonctions de bail écrivaient dans une table sans droit
  d'écriture pour le rôle applicatif ; passées en `SECURITY DEFINER`.
- Tests : 218 SQL (nouveau fichier `05_canaux.sql`), 173 unitaires,
  17 d'intégration.
- Vérification demandée par Mohamed (D-063) : les 7 fonctions SECURITY
  DEFINER fixaient leur search_path, mais 6 restaient exécutables par
  PUBLIC (droit par défaut de PostgreSQL). Corrigé (migration n° 19) et
  vérifié par des tests qui couvrent aussi les fonctions futures.
- Documentation de l'API Bot consultée : la donnée d'un bouton est limitée
  à 64 octets ; le jeton de notification (64 caractères) ne tenait pas avec
  l'indice : ramené à 32 caractères (UUID v4, 122 bits aléatoires).
- Logique sans canal (`src/decisions/notifications.js` : contenu, actions,
  réponses) et couche Telegram (`src/canaux/telegram.js` : mise à jour →
  événement, présentation HTML échappée, boutons). 22 tests ; 222 SQL,
  195 unitaires au total.
- Constat dans n8n 2.41.7 : ni le nœud Telegram (pas de `getUpdates`) ni
  HTTP Request (pas d'injection du jeton dans l'URL) ne permettent
  l'interrogation avec un jeton gardé dans n8n. D-064 : passerelle Telegram
  interne, seule détentrice du jeton, sur un réseau Docker dédié partagé
  avec n8n seul (secret partagé évalué, non retenu).
- Passerelle (`passerelle-telegram/`) : 10 tests Python dans son image, dont
  le jeton jamais rendu ni journalisé (y compris erreur de Telegram, erreur
  réseau, délai). Sous Windows, deux tests échouaient pour des raisons
  propres à Windows ; exécutés dans le conteneur Linux, comme en service.
- Fonction `donnees_notifications` (migration n° 20) ; workflows
  « Notifications Telegram » (9 nœuds) et « Réponses Telegram » (10 nœuds),
  exécutions réussies non enregistrées, délai 120 s ; scripts
  `creer-code-inscription` et `simuler-second-responsable`.
- Tests : 224 SQL, 210 unitaires, 24/25 d'intégration (le test d'isolement
  attend le redémarrage de la pile avec le nouveau réseau).
- Incident à la mise en service (inscription) : `creer-code-inscription`
  relisait la date d'expiration dans la même instruction SQL que l'insertion
  du code ; une instruction ne voit pas ses propres insertions, la date
  valait NULL et l'affichage échouait après la validation de la
  transaction. Utilisateur n° 126 créé une fois ; code n° 17 créé mais
  jamais affiché (inutilisable : seule l'empreinte est gardée ; il expire
  seul). Test qui reproduit l'erreur ajouté, script corrigé (deux
  instructions). Intégration : 25/25, isolement de la passerelle compris.
- Incident de sécurité à la mise en service : le jeton collé dans `.env`
  contenait une espace ; l'URL invalide a levé une exception que la
  passerelle ne rattrapait pas ; le gestionnaire d'erreurs par défaut de
  Python a écrit la trace complète, jeton compris, dans les journaux du
  conteneur, et la connexion a été coupée (erreur côté n8n). Les tests
  couvraient les erreurs de Telegram, du réseau et les délais, pas une
  erreur imprévue. Le jeton est considéré comme compromis : révocation
  demandée à Mohamed. Correctifs : forme du jeton vérifiée avant usage
  (réponse 503 claire, `jeton_bien_forme` dans /sante) ; toute exception
  rattrapée (type seul rendu) ; gestionnaire d'erreurs du serveur remplacé
  (une ligne masquée, sans trace) ; masquage des morceaux du jeton. Deux
  tests reproduisent l'incident (12 tests Python). Conteneur recréé pour
  effacer ses anciens journaux.
- Mise en service : inscription réussie, 16 notifications envoyées.
  Observation de Mohamed : « Accès réservé » (ancien /start sans code)
  affiché APRÈS « Inscription réussie ». La base montre que les événements
  ont été traités dans l'ordre d'arrivée ; la cause est l'envoi : le nœud
  HTTP Request lance les requêtes de tous les éléments en même temps
  (HttpRequestV3 : promesses lancées puis attendues ensemble). Correctif :
  boucle « Loop Over Items » (une réponse à la fois, en attendant la fin de
  la précédente) ; notifications espacées d'une seconde (rythme conseillé
  par Telegram). Tests ajoutés.
- Constat sur les notifications envoyées : « Valider malgré l'anomalie »
  proposé pour D008 et D011 (fournisseur non rattaché), validation que la
  base refuserait (D-021). Le bouton n'est plus proposé sans fournisseur
  rattaché et numéro ; vérification ajoutée au test existant. 212 tests unitaires.
- Démonstration par Telegram (Mohamed) : D028 validée, D005 validée par
  dérogation, D056 rejetée, D030 : demande de changement de RIB refusée par
  le second responsable fictif (quatre yeux, canal « simulation »), RIB du
  référentiel inchangé, facture rejetée ; trois boutons périmés refusés.
  Tous les événements traités dans l'ordre, chaque décision justifiée et
  tracée au journal.
- Recherche de l'ancien jeton (révoqué), sans l'afficher : ses deux
  morceaux secrets absents du dossier (fichiers ignorés compris), de tout
  l'historique Git, de la base mizan, de la base de n8n et des journaux des
  conteneurs. Seul l'identifiant numérique du bot (public, inchangé par la
  révocation) apparaît : dans `.env` (ignoré) et dans 14 exécutions
  enregistrées par n8n (réponses de Telegram).
- README : validation humaine par Telegram (protection, architecture,
  démonstration, limites), avertissement sur les données transmises à
  Telegram, passerelle dans l'architecture. Étape validée par Mohamed ;
  commit et push.

### Rapprochement bancaire : modèle de données (2026-10-08)
- Commit `b628ca6` poussé (validation humaine par Telegram).
- Choix (D-065) ; estimation du volume de notifications sur le lot de
  développement : 1 synthèse et 21 messages par import. D056, rejetée comme
  doublon mais payée, sera rapprochée de D035 (même numéro, approuvée).
- Migration n° 21 : catégories d'opérations, solde par ligne et contrôle
  d'intégrité, propositions et affectations, signalements, décisions
  humaines tracées, contexte d'appariement, vue de la situation de
  paiement ; le rôle applicatif n'écrit plus directement relevé ni
  rapprochement.
- Défaut repéré avant les tests : la vue soustrayait deux fois l'avoir d'un
  paiement net ; corrigée (réglé = règlements, avoir compris).
- Tests SQL rendus indépendants des données réelles (inscription de
  Mohamed, bail détenu par le workflow actif, refus de la démonstration).
- Tests : 247 SQL (nouveau fichier `06_rapprochement.sql`), 212 unitaires,
  25 d'intégration.
- Migration n° 22 : le canal porte le rapprochement (propositions,
  signalements, synthèse). Piège retrouvé dans un test : une instruction
  SQL ne voit pas les effets des fonctions qu'elle appelle (même cause que
  le défaut du code d'inscription). 257 tests SQL.
- Logique : lecture du CSV (`src/rapprochement/releve.js`), appariement
  (`src/rapprochement/appariement.js`), notifications de rapprochement ;
  237 tests unitaires.
- Mesure (`eval/evaluer-rapprochement.js`) : premier passage, 2 lignes
  manquées (D024) à cause d'un numéro mal lu par l'OCR ; ajout d'une
  tolérance d'un caractère, qui a produit 3 faux rapprochements entre
  factures consécutives d'un même fournisseur ; remplacée par les seules
  confusions lettre ↔ chiffre. Défaut du script de mesure corrigé (doublon
  exact : même empreinte, lien par le nom de fichier). Résultat : 25/25
  justes, 12 automatiques, 0 automatique faux, 0 fausse alerte.
- Workflows : « Import et rapprochement du relevé » (10 nœuds, nouveau ;
  Extract From File 1.1 en texte, relevé lu dans data/entrant/releves/,
  empreinte calculée par la base, rien d'enregistré sans nouveauté) ;
  « Notifications Telegram » étendu aux propositions, signalements et
  synthèses. Paramètres du nœud d'extraction relevés dans le code installé
  (`keepSource`, `destinationKey`). 245 tests unitaires.
- Mise en service et démonstration (Mohamed) : relevé importé
  (103 opérations, 70 rangées, 12 automatiques, 13 propositions,
  8 signalements, 22 messages). Écarts au plan constatés en base et
  signalés : justification d'acompte saisie sur le solde de D024 (L78),
  chèque de D023 non confirmé, test du bouton périmé sans trace ; puis
  repris par Mohamed (acompte L64 et chèque L26 confirmés, deux
  « notification_perimee »).
- Défaut de conception révélé : D023 et D024 « en retard » alors que leur
  paiement attendait une confirmation. Vue `situation_paiement` : état
  « paiement proposé » (migration n° 23, D-066), test ajouté. Tests SQL
  isolés des données réelles du relevé.
- Piste notée (D-067) : rectifier une justification par une écriture
  rectificative liée à la décision d'origine.
- README : rapprochement (règles, mesure, démonstration, limites).
  258 tests SQL, 245 unitaires. Étape validée ; commit.

## 2026-10-08 — Restitution : choix, rôle de lecture et vues

- Proposition présentée, choix de Mohamed : A1 (Grafana), B2 (catalogue de
  questions), C-a1, C-b1, D1, contrôle des ordres à partir d'une date de
  mise en service, second relevé de démo (D-068).
- Scénario de démonstration corrigé : une facture au RIB modifié ne peut
  pas être validée (`changement_rib` non dérogeable). Chemins actuels et
  chemin manquant « RIB imprimé écarté » décrits, proposition notée sans
  la construire (D-069). Sécurité de Grafana (D-070) ; serveur MCP estimé,
  non construit (D-071).
- Migration n° 24 : schéma `restitution` (échéancier, paiements, trésorerie
  prévue, TVA figurant sur les factures, à traiter) et rôle `mizan_lecture`
  (vues seules, session en lecture seule, délais, 5 connexions). Le schéma
  `public` n'est plus ouvert à PUBLIC ; `mizan_app` garde son droit
  explicite. Script `db/init/03-create-lecture-role.sh`, mot de passe dans
  `.env` (`MIZAN_LECTURE_PASSWORD`).
- Constats en écrivant les tests : écrire dans une vue non modifiable est
  refusé avant le contrôle des droits (55000) ; la lecture seule de session
  peut être levée par le rôle lui-même, ce sont les droits qui protègent
  (vérifié par une vraie connexion). Sur la vraie base, la trésorerie
  comptait les factures dont le paiement est déjà au relevé : corrigé, test
  ajouté.
- Tests : 285 SQL (nouveau fichier `07_restitution.sql` et contrôles de
  connexion dans `lancer.sh`), 245 unitaires, 25 d'intégration.

## 2026-10-09 — Ordres de paiement et « sortie sans ordre »

- Rôle de lecture, vues et scénario corrigé validés par Mohamed.
- Migration n° 25 : lots et ordres de paiement (RIB copié du référentiel),
  décision du responsable avec revérification (MZ051), contrôle « sortie
  sans ordre » par déclencheur sur les règlements confirmés, à partir de la
  mise en service (2026-10-01) ; vues `restitution.ordres_paiement` et
  `restitution.releves`.
- Migration n° 26 : le canal porte les lots (objet `lot_paiement`, actions
  approuver / refuser, péremption) ; générée par remplacements vérifiés des
  fonctions de la migration n° 22.
- Workflow « Ordres de paiement » (lundi 8 h ou manuel) ; notification du lot
  (`notificationLot`) ; scripts `exporter-ordres` et `generer-releve-demo`,
  en lecture seule par `mizan_lecture`.
- Constats : le test des codes d'action lisait une migration nommée en dur,
  il lit désormais la plus récente qui définit `creer_notification` ; une
  vue renvoyait `0` au lieu de `0.000` (type fixé) ; le retour arrière d'une
  migration modifiée après son application échouait (vue absente) :
  `DROP VIEW IF EXISTS`.
- Tests : 316 SQL (nouveau fichier `08_ordres.sql`), 251 unitaires
  (nouveau `ordres.test.js`), 25 d'intégration.
- Démonstration (Mohamed) : lot n° 2 approuvé sur Telegram, export réussi.
  Deux défauts signalés :
  1. Instructions qui supposaient le lot n° 1. Le numéro 1 a été pris par un
     lot créé puis annulé dans la transaction d'un test SQL : une séquence
     d'identité n'est jamais remise en arrière par un ROLLBACK. L'export
     affiche désormais les lots disponibles si le numéro est inconnu.
  2. `generer-releve-demo` : « function parametres_controle_en_vigueur(date)
     does not exist ». Cause : la vue `ordres_en_cours` appelait
     `parametre_controle()`, qui s'exécute avec le chemin de recherche du
     LECTEUR ; pour `mizan_lecture` (restitution seule, public fermé), la
     fonction interne est introuvable. Les tests SQL ne l'avaient pas vu :
     `SET ROLE` n'applique pas les réglages de connexion du rôle, et la
     colonne concernée n'y était pas lue. Correctif : migration n° 27, la vue
     lit la table des paramètres. Tests ajoutés : aucune vue atteinte depuis
     la restitution n'appelle de fonction de la base ; chaque vue lue en
     entier par une vraie connexion (`lancer.sh`) ; scripts exécutés pour de
     vrai en `mizan_lecture` sur `mizan_test`, puis relevé importé et
     apparié (test d'intégration, vérifié en échec sans le correctif).
- Tests : 324 SQL, 251 unitaires, 28 d'intégration.

## 2026-10-09 — Rapprochement manuel d'une ligne rejetée

- Base vérifiée après la démonstration des ordres : relevé de démo importé,
  3 paiements d'ordres confirmés automatiquement sans signalement,
  TCL-00346 payée hors ordre et signalée, commissions rangées, ordres du
  lot n° 2 entièrement exécutés.
- Migration n° 28 : vue `lignes_a_rapprocher`, fonctions
  `rapprocher_manuellement`, `signaler_ligne_sans_facture`,
  `facture_par_numero` ; « à traiter » complété. Migration n° 29 (générée) :
  objet de notification `ligne_a_rapprocher`, trois actions, péremption,
  candidates fournies par la base (D-073).
- Notification `notificationLigneARapprocher` (5 candidates, fournisseur
  du libellé d'abord) ; consigne de réponse « numéro puis justification » ;
  le nœud de préparation reçoit aussi `src/rapprochement/appariement.js`.
- Constats en écrivant les tests : la base refuse deux factures approuvées
  de même numéro chez un même fournisseur (l'ambiguïté ne vient que de deux
  fournisseurs) ; un attendu de test erroné corrigé (ordre des candidates) ;
  la restitution se lit en `mizan_lecture`, pas en `mizan_app`.
- Tests : 347 SQL (nouveau `09_rapprochement_manuel.sql`), 253 unitaires,
  28 d'intégration.

## 2026-10-09 — Tableau de bord Grafana

- Base vérifiée après la démonstration du rapprochement manuel : rejet de
  la proposition de la ligne 66, refus MZ045 pour un numéro inexistant (rien
  appliqué), rapprochement manuel avec ISS260302 (paiement partiel). Selon
  la vérité terrain, ce chèque réglait MC2026-00089 (la proposition
  rejetée) : MC2026-00089 apparaît désormais en retard. Aucun moyen
  d'annuler un rapprochement confirmé : noté (D-075).
- Grafana 13.2.3 (port 3000 vérifié libre, publié sur 127.0.0.1), réglages
  de sécurité de D-070, source unique `mizan_lecture` provisionnée, tableau
  de bord généré (D-074). Paramètres relevés dans la documentation et le
  code source officiels.
- Constats : une écriture par Grafana est arrêtée par la session en lecture
  seule (25006) avant les droits ; première capture d'écran : montants
  arrondis, dates avec heure, couleurs de seuil sans objet, trésorerie
  illisible en graphique (échelles trop différentes) ; corrigés.
- Tests : 256 unitaires, 33 d'intégration (dont 5 pour Grafana).

## 2026-10-09 — Questions en langage naturel

- Grafana confirmé par Mohamed (connexion, tableau de bord, 401 sans
  identification). Commandes données désormais compatibles avec Windows
  PowerShell 5.1. Dossier `screenshots/` ignoré par Git (captures relues et
  sélectionnées à la clôture de l'étape).
- Propositions faites, en attente de décision : annulation d'un
  rapprochement par contre-passation (D-075 : coût, risque de double
  paiement, déclenchement par `/annuler`) ; reconstruction d'un état de
  démonstration par script, en rejouant les extractions enregistrées.
- Questions (D-076) : catalogue de 9 questions, commande `/q`, file en base
  (migration n° 30), workflow « Questions (langage naturel) » (10 nœuds,
  credential de lecture). Mesure : 19 / 22 puis 22 / 22 après correction du
  paramètre « au », 8 / 8 détournements ; mise au point sur le même jeu.
- Constats : `evenements_entrants` limitait les types d'événement ;
  apostrophe d'un nom de nœud dans le code généré (test de compilation de
  tous les nœuds ajouté) ; un fichier d'exemples partagé évite de relancer
  les tests unitaires depuis les tests d'intégration.
- Tests : 361 SQL (nouveau `10_questions.sql`), 269 unitaires,
  36 d'intégration.

## 2026-10-10 — Clôture de la restitution

- Questions vérifiées en base après la démonstration de Mohamed : 3
  questions répondues en moins d'une minute (factures en retard, état d'une
  facture, tentative de suppression classée « hors catalogue »).
- Incident de credentials au réimport (D-079) : tableau des credentials par
  nœud dans le README et contrôle `npm run verifier-credentials-n8n` (base
  interne de n8n, versions publiée et brouillon ; test qui rejoue
  l'incident). Installation actuelle conforme : 12 versions contrôlées.
- Choix de Mohamed consignés : annulation d'un rapprochement à deux
  personnes, facture exclue des lots tant que la ligne n'est pas retraitée
  (inconvénient noté : paiement légitime retardé) (D-077) ; reconstruction
  de l'état de démonstration par script, sans LLM ni Telegram (D-078).
- README : section « Restitution » (tableau de bord, ordres de paiement,
  rapprochement manuel, questions), limites de chaque mesure, imports et
  credentials, commandes. Captures d'écran relues à part, avant tout commit.

## 2026-10-10 — Après la clôture de la restitution

- Commit a5f09cb poussé sur `main`.
- Captures d'écran : aucune n'est commitée. Elles seront toutes refaites en
  une fois à l'étape de finition, sur la base reconstruite (D-078), pour être
  cohérentes avec le README. Captures à prévoir :
  1. le tableau de bord Grafana ;
  2. une notification de facture sur Telegram ;
  3. une validation (bouton, justification, confirmation) ;
  4. un refus sur changement de RIB (règle non dérogeable) ;
  5. un lot d'ordres de paiement ;
  6. un signalement (par exemple « sortie sans ordre ») ;
  7. une question en langage naturel et sa réponse ;
  8. un refus « hors catalogue ».
- Protection de l'annulation validée par Mohamed (D-077), avec les deux
  aménagements : facture visible dans l'échéancier et dans « à traiter »
  avec le motif du blocage ; blocage levé dès que la ligne est de nouveau
  rapprochée ou signalée « aucune facture ».

## 2026-10-10 — Annulation d'un rapprochement

- Plan validé par Mohamed (a1, b1, virement groupé explicite, script de
  simulation, découpage des fonctions du canal reporté à la finition).
- Migration n° 31 (modèle : état `annule`, demandes et décisions à quatre
  yeux, ligne de nouveau « à rapprocher », facture bloquée pour les ordres) ;
  migration n° 32 (canal, générée : commande `/annuler`, choix et demande
  d'annulation, détail des rapprochements avec toutes les factures).
- Incident trouvé en lançant les tests : le pool de Grafana occupait les 5
  connexions de `mizan_lecture`, bloquant le workflow « Questions » ; pool
  de Grafana limité à 2, limite du rôle portée à 10 (migration n° 33), test.
- Constats en écrivant les tests : `notifications_a_preparer` s'exécute avec
  les droits de `mizan_app` (droit de lecture ajouté) ; le retour arrière de
  la migration du modèle impose un ordre strict entre vues dépendantes.
- Tests : 397 SQL (nouveau `11_annulation.sql`), 276 unitaires,
  38 d'intégration.
- Démonstration (Mohamed) : annulation n° 17 approuvée par le compte fictif
  (décision n° 15), mais pas de message « Paiement à rapprocher à la main ».
  Diagnostic en base : rapprochement bien annulé, ligne 66 bien « à
  rapprocher », aucune candidate à notifier : la notification n° 291 de la
  veille (après le rejet, valable jusqu'au 2026-10-16) faisait croire la
  ligne déjà notifiée. Correctif (migration n° 34) : la notification doit
  dater d'après le moment où la ligne est redevenue à rapprocher ; une
  notification antérieure est périmée. Notification n° 400 envoyée aussitôt.
  Premier essai de comparaison strict écarté : il périmait les notifications
  créées dans la même transaction que la décision (tests SQL).
- Tests : 401 SQL, 276 unitaires, 38 d'intégration.
- Démonstration (Mohamed), dernière étape : « Autre facture » avec
  MC2026-00089 refusé, et le bot affichait le message technique de la base.
  Vérifié : rien d'appliqué (ligne 66 toujours à rapprocher, aucune nouvelle
  proposition). Causes : contrainte d'unicité (facture, ligne) du premier
  modèle, qui comptait le lien rejeté de la veille ; refus inattendus
  renvoyés tels quels. Correctifs (migration n° 35) : unicité sur les liens
  actifs seulement ; erreur interne tracée au journal, message lisible avec
  référence. Test qui rejoue le cas complet (rejet, autre facture, annulation,
  rapprochement avec la facture rejetée), vérifié en échec sans correctif.
- Tests : 410 SQL, 276 unitaires, 38 d'intégration.

## 2026-10-10 — Reconstruction : sauvegarde, export des extractions

- Annulation démontrée et commitée (65033bc, poussé). Plan de la
  reconstruction validé : a1, b1, c1 (D-078).
- Sauvegarde de la base de Mohamed : `sauvegardes/mizan-2026-10-10-1301.dump`
  (ignoré par Git), relue, puis restaurée dans `mizan_restauree` : contenu
  identique. Test d'intégration de restauration ajouté.
- Export des extractions du lot de développement (`demo/extractions-dev.json`,
  42 documents, version D-053) ; lecture protégée du lot de test ; tests.
  Constat : les documents du lot de test s'appellent aussi « D… ».
- Lot de test autonome confirmé depuis `lots.json` ; l'ordre d'arrivée des
  documents dérivés pèsera sur la mesure des contrôles (D-081, à trancher).
- Tests : 279 unitaires, 40 d'intégration.
- Protocole du lot de développement relevé dans les scripts et la base :
  extractions D-053 du 2026-10-06 (21 h 39 à 21 h 45), un seul passage des
  contrôles à 22 h 02 ; paire de doublons comptée comme unité ; avoir
  retrouvé quel que soit l'ordre. Ma première analyse de D-081 (3 erreurs
  dues à l'ordre d'arrivée) était fausse : corrigée. Protocole complet de
  l'étape 8 écrit avant toute ouverture du lot de test (D-082).
- Script de reconstruction (D-083) : rejoue en 7 secondes ; base séparée
  comparée à celle de Mohamed facture par facture (seuls écarts : D030 et
  D056 laissées en attente, info D005 annoncée par D-060) ; rapprochement
  103/70/12/13/8 et lot d'ordres identiques.
- Tests : 281 unitaires, 44 d'intégration.
- Ordre de dépôt du lot de test confirmé par Mohamed : ordre des noms (D-082).
  Pas d'essai séparé du script de reconstruction : sa première utilisation
  réelle sera l'évaluation finale. Base de comparaison `mizan_reconstruite`
  supprimée (`mizan_restauree` l'avait déjà été par Mohamed).
