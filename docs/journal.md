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
