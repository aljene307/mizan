# Registre des décisions

Chaque décision indique son contexte, le choix retenu, sa raison et ses sources.
Les points encore ouverts sont marqués **À revoir**.

---

## Étape 0 — Environnement (2026-10-05)

### D-001 · Version de n8n fixée à 2.41.7
- **Choix :** image `n8nio/n8n:2.41.7`, version définie dans `.env` (`N8N_VERSION`).
- **Raison :** c'était la dernière version stable au 2026-10-05 (la 2.42.x était
  encore en pré-version). Fixer la version rend l'environnement reproductible ;
  `latest` changerait sans prévenir.
- **Source :** <https://github.com/n8n-io/n8n/releases>

**Précision — 2.41.6 ou 2.41.7.** Le projet n'a jamais tourné en 2.41.6 :
la 2.41.7 a été retenue dès la première installation. Le choix s'est joué entre
ces deux versions stables de la même branche 2.41 :

| Version | Publiée le | Contenu (notes de version officielles) |
|---|---|---|
| 2.41.6 | 2026-10-02 | Correctif *core* : le task runner continue de tourner après une promesse rejetée non gérée (#40092). |
| 2.41.7 | 2026-10-05 | Correctif *API* : les membres globaux peuvent accorder des droits sur les variables aux clés d'API (#40151). Nouveauté *editor* : affichage de promotions « Gateway credits » sur les nœuds communautaires (#40109). |

- **Pourquoi 2.41.7 :** c'est une version corrective (même branche 2.41, même
  schéma de base). Elle contient le correctif de la 2.41.6 sur le task runner,
  utile puisque les règles métier s'exécuteront dans des nœuds Code. Ses propres
  changements ne touchent ni la base, ni les nœuds utilisés par Mizan.
- **Risque accepté :** la 2.41.7 a été publiée le jour même de l'installation,
  avec peu de recul. En cas de régression, on revient à `N8N_VERSION=2.41.6`
  dans `.env` (même branche, donc retour arrière sans migration de base), puis
  `docker compose up -d`. L'image `runners` suit automatiquement, car elle lit
  la même variable.
- **Sources :** <https://github.com/n8n-io/n8n/releases/tag/n8n%402.41.7>,
  <https://github.com/n8n-io/n8n/releases/tag/n8n%402.41.6>

### D-002 · PostgreSQL 18 avec `PGDATA` explicite
- **Choix :** image `postgres:18`, `PGDATA=/var/lib/postgresql/data`.
- **Raison :** c'est la version utilisée par la documentation n8n. PostgreSQL 18
  a changé son dossier de données par défaut ; sans `PGDATA`, les données
  seraient écrites hors du volume et perdues au redémarrage.
- **Source :** <https://docs.n8n.io/deploy/host-n8n/install-options/install-using-docker-compose.md>
  (section « Use PostgreSQL instead of SQLite »)

### D-003 · Une instance PostgreSQL, deux bases (`n8n` et `mizan`)
- **Choix :** la base `n8n` contient les tables internes de n8n ; la base `mizan`
  contient les données métier et la piste d'audit. La base `mizan` est créée par
  `db/init/01-create-mizan-db.sh` au premier démarrage.
- **Raison :** séparer les tables techniques de n8n des données métier garde le
  schéma métier lisible, exportable et indépendant des mises à jour de n8n, sans
  ajouter de conteneur.

### D-004 · Task runner en mode externe
- **Choix :** conteneur `n8nio/runners` de même version que n8n,
  `N8N_RUNNERS_MODE=external`.
- **Raison :** la documentation présente le task runner comme la seule couche
  d'isolation entre le code des nœuds Code et n8n (identifiants, clé de
  chiffrement). Le mode interne est obsolète et déconseillé dès qu'il y a des
  données sensibles. Les règles métier de Mizan s'exécuteront dans ces nœuds.

**Précision — pourquoi un troisième conteneur.** Le plan initial (cahier des
charges, étape 0) annonçait « n8n + PostgreSQL ». En vérifiant la documentation
de la version installée, on a constaté que n8n 2.x exécute le code des nœuds
Code dans un processus à part, le *task runner*, et que le mode recommandé
place ce runner dans son propre conteneur (`n8nio/runners`). Le conteneur
ajouté n'est donc pas une fonctionnalité de plus : c'est la façon dont n8n 2.x
exécute du JavaScript.

Sans ce conteneur, deux options restaient, toutes deux moins bonnes :
- **Mode interne** (n8n lance le runner comme processus enfant) : ça marche,
  mais le code d'un nœud Code tourne avec le même utilisateur et sur le même
  système de fichiers que n8n. Un code malveillant ou buggé pourrait lire la
  clé de chiffrement, donc les identifiants enregistrés (token Telegram, clé
  d'API du LLM, mot de passe PostgreSQL). Ce mode est obsolète : n8n affiche un
  avertissement au démarrage et annonce sa suppression.
- **Aucun runner** : les nœuds Code ne s'exécuteraient pas. Or tous les
  contrôles de Mizan (HT/TVA/TTC, matricule fiscal, doublons, RIB) en dépendent.

Ce qu'on perdrait sans lui : l'isolation entre le code métier et les secrets,
la pérennité de la configuration (le mode interne va disparaître), et un
argument d'architecture sur le CV. Le coût est faible : une image de 890 Mo
sur disque et environ 4 Mo de mémoire au repos (mesuré avec `docker stats` le
2026-10-05). Les processus JavaScript et Python ne démarrent qu'à l'exécution
d'un nœud Code, puis s'arrêtent après 15 s d'inactivité.
- **Sources :**
  <https://docs.n8n.io/deploy/host-n8n/configure-n8n/set-up-task-runners.md>,
  <https://docs.n8n.io/deploy/host-n8n/configure-n8n/basic-configuration/use-environment-variables/task-runners.md>

### D-005 · Ports publiés uniquement sur `127.0.0.1`
- **Choix :** `127.0.0.1:5678` (n8n) et `127.0.0.1:5432` (PostgreSQL).
- **Raison :** rien n'est exposé au réseau local. Le port 5432 reste accessible
  depuis la machine pour inspecter la base (psql, DBeaver).

### D-006 · Dossier `data/` monté en lecture seule dans n8n
- **Choix :** `./data` monté sur `/data` en lecture seule (`:ro`), et
  `N8N_RESTRICT_FILE_ACCESS_TO=/data` pour limiter les nœuds de fichiers à ce dossier.
- **Raison :** n8n lit les factures et les relevés sans pouvoir modifier les
  fichiers sources ni accéder au reste du système de fichiers.
- **À revoir à l'étape 3 :** si le workflow de réception doit déplacer les
  factures traitées (par exemple de `entrant/` vers `traite/`), il faudra un
  montage en écriture, au moins pour ce sous-dossier.
- **Source :** <https://docs.n8n.io/deploy/host-n8n/configure-n8n/basic-configuration/use-environment-variables/security.md>

### D-007 · Fuseau horaire `Africa/Tunis`
- **Choix :** `GENERIC_TIMEZONE` et `TZ` à `Africa/Tunis`.
- **Raison :** les échéances et les déclenchements planifiés suivent l'heure de
  l'entreprise.
- **Source :** <https://docs.n8n.io/deploy/host-n8n/install-options/install-with-docker.md>

### D-008 · Licence MIT
- **Choix :** licence MIT.
- **Raison :** licence permissive et courante, adaptée à un projet de portfolio public.

### D-009 · Fins de ligne LF imposées par `.gitattributes`
- **Choix :** `* text=auto eol=lf`, sauf pour les scripts PowerShell.
- **Raison :** le développement se fait sous Windows, mais les scripts sont
  exécutés par des conteneurs Linux. Avec des fins de ligne CRLF, un script
  shell échoue.

---

## Étape 1 — Modèle de données (2026-10-05)

### D-010 · Migrations gérées avec dbmate (choix A)
- **Options étudiées :** dbmate ; fichiers SQL + script Node maison ; node-pg-migrate.
- **Choix :** dbmate 2.36.0, lancé à la demande depuis Docker (image
  `ghcr.io/amacneil/dbmate`). Les migrations sont dans `db/migrations/`, chacune
  avec une section `-- migrate:up` et une section `-- migrate:down`.
  dbmate enregistre les migrations appliquées dans la table `schema_migrations`
  et régénère `db/schema.sql` après chaque migration.
- **Raison :** le schéma reste en SQL pur, lisible par un lecteur non
  développeur. Rien n'est à installer sous Windows. Chaque migration s'exécute
  dans une transaction et peut être annulée. L'image contient `pg_dump` 18.6,
  compatible avec PostgreSQL 18 (vérifié).
- **Sources :** <https://github.com/amacneil/dbmate>,
  <https://github.com/amacneil/dbmate/releases> (v2.36.0, 2026-09-19)

### D-011 · Noms de tables et de colonnes en français (choix B)
- **Options étudiées :** français ; anglais.
- **Choix :** français, en minuscules, sans accent, en snake_case
  (`factures`, `montant_ht`, `matricule_fiscal`).
- **Raison :** le domaine est la fiscalité tunisienne, dont les termes
  (matricule fiscal, droit de timbre, HT/TTC) se traduisent mal. Le code reste
  cohérent avec la documentation. Un glossaire anglais sera ajouté au README
  pour les lecteurs étrangers.

### D-012 · Montants en `NUMERIC(15,3)`
- **Choix :** tous les montants en `NUMERIC(15,3)` ; quantités et prix
  unitaires en `NUMERIC(18,6)` ; taux en `NUMERIC(7,4)` (en pourcentage).
- **Raison :** le dinar tunisien compte 3 décimales (millimes). Les types à
  virgule flottante produisent des erreurs d'arrondi incompatibles avec un
  contrôle HT + TVA = TTC exact. Les prix unitaires ont plus de décimales pour
  ne pas arrondir avant la multiplication.
- **Source :** ISO 4217, liste officielle tenue par SIX (agence de maintenance) :
  `TND`, code 788, `CcyMnrUnts = 3` —
  <https://www.six-group.com/dam/download/financial-information/data-center/iso-currrency/lists/list-one.xml>

### D-013 · Doublons : index et contrôle plutôt que contrainte d'unicité
- **Choix :** pas de contrainte `UNIQUE` sur (fournisseur, numéro) ni sur
  l'empreinte du fichier, mais deux index qui rendent la recherche rapide. La
  détection se fait par un contrôle (étape 4), qui écrit son résultat dans
  `resultats_controles`.
- **Raison :** cela corrige la proposition initiale. Avec une contrainte
  d'unicité, l'insertion d'un doublon échouerait et la facture reçue ne
  laisserait aucune trace. Or un doublon reçu est un événement à tracer : il
  doit être enregistré, puis marqué « bloquée » avec le détail de l'anomalie.
- **Deux niveaux de détection :** empreinte SHA-256 du fichier (même fichier
  reçu deux fois) et couple (fournisseur, type de document, numéro) (même
  facture dans deux fichiers différents, par exemple un PDF puis un scan).

### D-014 · Historique des RIB fournisseurs
- **Choix :** table `fournisseur_ribs`, une ligne par RIB, avec une période de
  validité (`valide_du`, `valide_au`). Un seul RIB actif par fournisseur à la
  fois (index unique partiel sur `valide_au IS NULL`). Le RIB lu sur la
  facture est stocké à part (`factures.rib_facture`).
- **Raison :** le contrôle « changement de RIB » (étape 4) compare le RIB de
  la facture au RIB actif. Garder l'historique permet de savoir quel RIB
  était valable à une date donnée et qui l'a changé.

### D-015 · Journal d'audit en ajout seul
- **Choix :** la table `journal_audit` n'accepte que des insertions. Un trigger
  refuse tout `UPDATE`, `DELETE` ou `TRUNCATE`, et le rôle applicatif
  `mizan_app` n'a de toute façon que les droits `SELECT` et `INSERT` (D-018).
- **Limite :** le journal est en ajout seul, il n'est pas infalsifiable. Un
  administrateur de la base (rôle propriétaire de la table ou superutilisateur,
  comme `mizan_admin`) peut contourner le trigger : le désactiver
  (`ALTER TABLE … DISABLE TRIGGER`), le supprimer, passer la session en
  `session_replication_role = replica` (les triggers ordinaires ne s'exécutent
  plus) ou modifier directement les fichiers de données. La protection vise les
  erreurs et les modifications par l'application, pas un administrateur
  malveillant.
- **Pistes si un niveau supérieur était requis (hors périmètre) :** chaîner
  les lignes par empreinte (chaque ligne contient le hachage de la précédente)
  pour rendre une modification détectable, ou exporter régulièrement le journal
  vers un stockage externe en écriture unique.

### D-016 · Table des résultats de contrôles
- **Choix :** table `resultats_controles`, une ligne par exécution d'une règle
  sur une facture : code de la règle, version de la règle, résultat (`ok`,
  `anomalie`, `erreur`), gravité (`info`, `avertissement`, `bloquant`),
  message lisible, détail en JSONB (valeurs attendues et constatées),
  horodatage et identifiant de l'exécution n8n.
- **Raison :** le statut d'une facture (conforme, anomalie, bloquée) doit
  pouvoir s'expliquer règle par règle, et le validateur doit voir le détail
  sur Telegram. On conserve l'historique : si une facture est contrôlée de
  nouveau après correction, les deux passages restent visibles.

### D-017 · Factures : type de document, devise, droit de timbre
- **Type de document :** `type_document` vaut `facture` ou `avoir`. Un avoir
  peut référencer la facture qu'il corrige (`facture_origine_id`, facultatif,
  car l'avoir n'indique pas toujours la facture d'origine). Les montants sont
  enregistrés positifs, tels qu'imprimés sur le document : le sens (dette ou
  créance) vient du type de document. Cela évite les erreurs de signe à
  l'extraction.
- **Devise :** `devise CHAR(3)`, `TND` par défaut, code ISO 4217 contrôlé
  (trois lettres majuscules).
- **Droit de timbre :** colonne `droit_timbre NUMERIC(15,3)`, facultative. Le
  montant attendu vient de `config_fiscale` (D-020), où il est marqué « à
  confirmer ».
- **Cohérence attendue :** HT + TVA + timbre = TTC. Elle n'est **pas** imposée
  par une contrainte SQL, car une facture incohérente doit pouvoir être
  enregistrée puis signalée par un contrôle (étape 4), comme pour D-013.

### D-018 · Rôle applicatif `mizan_app` aux droits limités
- **Choix :** n8n se connectera à la base `mizan` avec le rôle `mizan_app`,
  sans superutilisateur ni propriété des tables. Droits : `SELECT`, `INSERT`
  et `UPDATE` sur les tables métier, sans `DELETE` ; `SELECT` et `INSERT` sur
  `journal_audit` et `resultats_controles` ; `SELECT` seul sur
  `config_fiscale`. Les migrations restent exécutées par `mizan_admin`.
- **Mot de passe :** dans `.env` (`MIZAN_APP_PASSWORD`), jamais dans une
  migration. Le rôle est créé par `db/init/02-create-app-role.sh`, qui
  s'exécute au premier démarrage et peut être relancé à la main
  (il est idempotent).
- **Raison :** principe du moindre privilège. Même si un workflow est mal
  écrit, il ne peut ni effacer une facture ni réécrire le journal d'audit.

### D-019 · Structure de la configuration fiscale
- **Choix :** table `config_fiscale` : clé (`tva.taux_normal`…), valeur,
  unité, période de validité (`valide_du`, `valide_au`), conditions
  d'application en JSONB, libellé et URL de la source, indicateur
  `a_confirmer`, note. Une contrainte d'exclusion (extension `btree_gist`)
  interdit deux valeurs pour la même clé sur des périodes qui se chevauchent.
- **Raison :** les taux changent avec les lois de finances. Une facture doit
  être contrôlée avec la règle en vigueur **à sa date**, pas avec celle
  d'aujourd'hui. La source et l'indicateur `a_confirmer` sont stockés à côté
  de la valeur, si bien qu'un contrôle peut signaler qu'il s'appuie sur une
  valeur non confirmée.
- **Valeurs de départ :** insérées par une migration, pour que chaque
  changement de taux laisse une trace datée dans l'historique Git.

### D-020 · Valeurs fiscales de départ et leurs sources
Recherche menée le 2026-10-05. **Limite rencontrée :** les portails officiels
qui publient les codes consolidés (legislation.tn, iort.gov.tn) ne répondaient
pas depuis notre réseau. La page « Aperçu général sur la fiscalité » de
finances.gov.tn est **périmée** : elle donne une TVA à 18 %, 12 % et 6 %,
alors que les lois de finances récentes mentionnent 19 % et 7 %. Elle n'a
donc pas été retenue. Les seuls textes officiels consultés en entier sont les
deux dernières lois de finances, publiées au JORT et téléchargées depuis
finances.gov.tn (PDF signé par l'Imprimerie officielle) :
- LF 2025 : loi n° 2024-48 du 9 décembre 2024, JORT n° 149 du 10 décembre 2024 —
  <https://www.finances.gov.tn/sites/default/files/2024-12/LF2025.pdf>
- LF 2026 : loi n° 2025-17 du 12 décembre 2025, JORT n° 148 du 12 décembre 2025 —
  <https://www.finances.gov.tn/sites/default/files/2026-01/115725.pdf>

| Clé | Valeur | Source | Statut |
|---|---|---|---|
| `tva.taux_normal` | 19 % | Code de la TVA, art. 7 (texte consolidé non consulté). Le taux de 19 % figure dans la LF 2025, art. 40 (TVA à l'importation de lait en poudre « portée à 19 % »). | **À confirmer** sur le texte consolidé de l'art. 7 |
| `tva.taux_intermediaire` | 13 % | Sources secondaires concordantes uniquement (aucun texte officiel consulté) | **À confirmer** |
| `tva.taux_reduit` | 7 % | Code de la TVA, art. 7 (texte consolidé non consulté). Le taux de 7 % figure dans la LF 2026, art. 46 (TVA « réduite à 7 % » sur des intrants). | **À confirmer** sur le texte consolidé de l'art. 7 |
| `timbre.facture` | 1,000 TND par facture | Code des droits d'enregistrement et de timbre, art. 117 (texte consolidé non consulté) ; montant cité par des sources secondaires | **À confirmer** |
| `timbre.facture.grande_surface.50_100` | 1,500 TND (facture de 50 à 100 TND) | LF 2026, art. 20, point 6 : ajoute le n° 6 bis au § I de l'art. 117 du CDET (JORT n° 148, p. 4233) | Montant **confirmé** ; date d'effet supposée au 1er janvier 2026, **à confirmer** |
| `timbre.facture.grande_surface.plus_100` | 2,000 TND (facture de plus de 100 TND) | Idem | Idem |

Les bornes de montant de chaque tranche sont aussi stockées dans la colonne
`conditions`, pour que le contrôle de l'étape 4 les lise sans les déduire du
nom de la clé.

**Non retenu à ce stade :**
- **Retenue à la source** sur les achats : le Code de l'IRPP et de l'IS
  (art. 52) n'a pas pu être consulté ; les sources secondaires se
  contredisent sur l'assiette (HT ou TTC) et sur les taux. Aucune valeur n'est
  saisie. À rechercher avant l'étape 6, car une retenue explique un écart entre
  le TTC et le montant payé.
- **Exonération de timbre pour les avoirs :** affirmée par une source
  secondaire, non vérifiée. À traiter à l'étape 4.
- **Taux de 13 %** : la liste des opérations concernées n'est pas reprise. La
  table ne stocke que les taux ; savoir quel taux s'applique à quel bien
  relève de la facture elle-même.

### D-021 · Filet de sécurité : index unique partiel sur les factures approuvées
- **Demande :** garantir qu'on ne puisse jamais approuver deux fois la même
  facture, même si le contrôle des doublons de l'étape 4 a un bug, sans
  revenir sur D-013 (un doublon reçu doit pouvoir être enregistré).
- **Faisabilité avec les statuts actuels :** oui, à trois conditions.
  1. **« Approuvée » recouvre deux statuts : `conforme` et `validee`.** Selon
     le cahier des charges, la validation humaine n'intervient qu'en cas
     d'anomalie ou au-delà d'un seuil. Une facture sans anomalie et sous le
     seuil passe donc en `conforme` sans jamais devenir `validee`. Un index
     limité à `validee` ne la protégerait pas. Les statuts `bloquee`,
     `rejetee`, `anomalie`, etc. restent hors de l'index : un doublon peut
     être enregistré puis bloqué, et une facture rejetée puis renvoyée
     corrigée peut être approuvée.
  2. **Une facture approuvée doit avoir un fournisseur et un numéro.** Pour un
     index unique, deux valeurs NULL ne sont jamais égales : une facture sans
     fournisseur échapperait au filet. Une contrainte `CHECK` l'impose.
  3. **Le numéro est comparé sous une forme normalisée** (majuscules, espaces
     supprimés), via la fonction `normaliser_numero_facture`, pour qu'un
     « f-0 01 » lu par OCR soit reconnu comme « F-001 ». La normalisation
     reste volontairement prudente : supprimer aussi les tirets ou les
     barres ferait se confondre des numéros réellement différents
     (« 12-3 » et « 1-23 »), et un faux doublon bloquerait une facture
     légitime. Les rapprochements plus fins relèvent du contrôle de l'étape 4.
- **Choix :** index `factures_approuvees_uk` sur
  (`fournisseur_id`, `type_document`, `normaliser_numero_facture(numero)`)
  `WHERE statut IN ('conforme', 'validee')`, plus la contrainte
  `factures_approuvee_identifiee_ck`. Migration `20261005120800`.
- **Effet en cas de bug du contrôle :** l'`UPDATE` qui ferait passer le
  doublon en `conforme` ou `validee` échoue (code 23505). Le workflow n8n
  s'arrête en erreur au lieu d'approuver la facture : l'erreur est visible et
  la facture reste dans son état précédent.
- **Limite :** le filet ne couvre que le même fournisseur. Une même facture
  rattachée par erreur à deux fournisseurs différents n'est pas détectée par
  l'index. C'est un cas pour le contrôle de l'étape 4.
- **Tests :** 7 tests ajoutés à `db/tests/01_schema_admin.sql`.

### D-022 · Timbre « grandes surfaces » : conservé, mais inutilisé par défaut
- **Constat :** le n° 6 bis de l'art. 117 du CDET (LF 2026, art. 20) vise les
  factures **émises par** les grandes surfaces commerciales. Les factures
  fournisseurs d'une PME n'en relèvent a priori pas, sauf si le fournisseur
  est lui-même une grande surface.
- **Choix :** les deux valeurs restent dans `config_fiscale`, car elles sont
  sourcées et décrivent une règle réelle. **Aucun contrôle ne les utilise**
  tant qu'une justification n'a pas été écrite ici : quel contrôle, dans quel
  cas, et comment on sait que le fournisseur est une grande surface (aucune
  colonne ne le dit aujourd'hui).
- **Conséquence pour l'étape 4 :** le contrôle du timbre ne lira que la clé
  `timbre.facture`.

### D-023 · Factures synthétiques datées de 2026
- **Choix :** toutes les factures synthétiques (étape 2) ont une date de
  facture comprise entre le 1er janvier et le 31 décembre 2026.
- **Raison :** la configuration fiscale n'est valide qu'à partir du
  1er janvier 2026 (D-020). Une facture datée de 2025 n'aurait aucun taux
  applicable, et les contrôles signaleraient une erreur de configuration au
  lieu de tester la facture.

---

## Étape 2 — Données synthétiques (2026-10-05)

### D-024 · Générateur : Node.js + Playwright (choix A)
- **Options étudiées :** Node.js + Playwright ; Python + ReportLab + Pillow ;
  Node.js + pdfkit.
- **Choix :** modèles HTML/CSS rendus par Chromium (Playwright) en PDF et en
  PNG. `sharp` imite un scan (rotation, flou, bruit, compression JPEG).
  Les polices sont des paquets `@fontsource` (licence OFL) intégrés aux
  modèles, pas des polices du système.
- **Raison :** un même modèle produit le PDF et l'image, les mises en page
  sont faciles à varier, et le projet reste en un seul langage. Embarquer
  les polices rend le rendu identique sous Windows et sous Linux.
- **Reproductibilité :** un générateur pseudo-aléatoire à graine fixe
  (`mulberry32`) produit les mêmes données à chaque exécution. Chromium écrit
  la date du rendu dans chaque PDF ; le générateur la remplace par une date
  fixe de même longueur (`figerDatesPdf`). Vérifié le 2026-10-05 : deux
  générations successives donnent les 126 mêmes fichiers, octet par octet.
  **Limite :** cette identité vaut pour une même version de Chromium, de
  sharp et des polices. Une mise à jour de ces outils peut changer les
  octets (et donc les empreintes SHA-256) sans changer le contenu ; ce qui
  fait foi reste la vérité terrain JSON, déterministe et testée.

### D-025 · Contenu du jeu : 60 documents, 9 types de pièges
- **Volume :** 60 documents au lieu d'environ 50. Chaque type de piège
  doit figurer **dans les deux lots** (D-026), ce qui en impose au moins
  deux exemplaires.
- **Pièges (2 exemplaires chacun, un par lot) :**

  | Code | Description |
  |---|---|
  | `doublon_exact` | Le même fichier, renvoyé sous un autre nom |
  | `doublon_rescanne` | La même facture, reçue en image (scan) |
  | `erreur_tva` | Montant de TVA différent de la somme HT × taux |
  | `ttc_incoherent` | HT + TVA + timbre ≠ TTC |
  | `rib_modifie` | RIB imprimé différent du RIB connu du fournisseur |
  | `matricule_invalide` | Matricule fiscal hors format |
  | `montant_eleve` | TTC au-dessus du seuil de validation (D-028) |
  | `fournisseur_inconnu` | Fournisseur absent du référentiel |
  | `devise_etrangere` | Facture en EUR |

- **Avoirs :** 2 (un par lot), chacun lié à une facture du même lot.
- **Formats :** environ 45 PDF natifs et 15 images imitant un scan. Aucun XML
  (format TEIF non disponible).
- **Relevé bancaire :** un CSV couvrant du 1er janvier au 30 septembre 2026
  (séparateur `;`, décimale `,`, 3 décimales), avec la liste des
  appariements attendus. Il contient des paiements exacts, un paiement en
  deux fois, un virement groupé, une facture payée nette de son avoir, des
  impayés, des frais bancaires et des opérations sans rapport (salaires).
  Les factures piégées pour doublon ne sont payées qu'une fois ; celles dont
  le RIB a été modifié ne sont pas payées ; celles en EUR non plus.
- **Mention « Document fictif – données synthétiques »** en pied de chaque
  document, en petit corps.

### D-026 · Deux lots fixes : développement (70 %) et test (30 %)
- **Choix :** 42 documents de développement et 18 de test, chacun dans son
  propre dossier (`data/synthetic/dev/` et `data/synthetic/test/`). La
  répartition est fixée par le générateur et listée dans
  `data/synthetic/lots.json`.
- **Règles de répartition :**
  - chaque type de piège est présent dans les deux lots ;
  - un document et ses dérivés (doublon, scan, avoir) restent **dans le même
    lot**. Sinon, un document de test serait la quasi-copie d'un document de
    développement, et le score de l'étape 8 serait faussé (fuite de données).
- **Règle d'usage :** le lot de test ne sert **jamais** à régler le prompt
  d'extraction ni le schéma (étapes 3 à 7). Il est réservé à l'évaluation de
  l'étape 8. On ne l'ouvre pas pour « voir pourquoi ça échoue » avant cette
  étape.
- **Relevé bancaire :** non découpé. Le rapprochement (étape 6) est
  déterministe et n'a pas de paramètre appris sur les données.

### D-027 · Identifiants au bon format mais non attribuables
Objectif : passer les contrôles de format sans pouvoir correspondre à une
vraie entreprise ou à un vrai compte.

**Matricule fiscal**
- **Format retenu :** 7 chiffres suivis d'une lettre clé (`\d{7}[A-Z]`),
  d'après le cahier des charges technique TEJ du ministère des Finances
  (juin 2024, § 7.1.1.2). Copie consultée :
  <https://jibaya.tn/wp-content/uploads/2024/05/TEJ-CCT-RS-V2.pdf>
  (document de <https://tej.finances.gov.tn>). Sur les factures, la forme
  complète `NNNNNNNL/A/M/000` (code TVA, catégorie, établissement) est
  imprimée ; elle ne vient que de sources secondaires
  ([facturetunisie.pro](https://facturetunisie.pro/matricule-fiscal-tunisie)).
  La vérité terrain stocke la forme courte officielle et la forme imprimée.
- **Méthode « non attribuable » :** tous les numéros commencent par `99`
  (plage 9900000–9999999). Hypothèse : les numéros sont attribués de façon
  séquentielle et cette plage haute est loin des numéros en service.
  **Limite :** l'hypothèse ne peut pas être vérifiée sans accès au
  répertoire fiscal.
- **Lettre clé :** un algorithme de calcul (modulo 23) circule dans des
  sources secondaires, mais aucune source officielle ne le confirme. Le
  générateur choisit donc la lettre au hasard (hors I, O et U), et le
  contrôle de l'étape 4 ne vérifiera que le format, pas la clé, tant que
  l'algorithme n'est pas confirmé.

**RIB**
- **Structure :** 20 chiffres = banque (2) + agence (3) + compte (13) +
  clé (2). Source : registre IBAN ISO 13616 tenu par SWIFT (entrée TN, données
  fournies par l'association professionnelle des banques, mise à jour de
  mai 2016), consulté via <https://ibanapi.com/iban-registry/TN> (le PDF de
  swift.com a refusé le téléchargement).
- **Clé :** `clé = 97 − ((18 premiers chiffres × 100) mod 97)`. Algorithme
  relevé dans une bibliothèque libre
  ([TNRIB](https://github.com/McZen-Technologies/TNRIB)), puis **vérifié** sur
  l'exemple du registre IBAN (`TN59 1000 6035 1835 9847 8831` : la clé
  calculée vaut 31, comme imprimé). Cohérence supplémentaire : avec cette
  clé, tout IBAN tunisien a pour chiffres de contrôle 59, ce que montre le
  registre.
- **Méthode « non attribuable » :** code banque **`99`**. Il est absent des
  listes de codes en service consultées : 25 codes de 01 à 86 dans TNRIB
  (complétés par [thebanker.tn](https://www.thebanker.tn/p/listes-des-banques-tunisiennes.html)).
  **Limite :** la liste officielle de la BCT n'a pas été consultée. Si le
  code 99 était attribué un jour, la probabilité qu'un numéro de compte
  tiré au hasard sur 13 chiffres existe resterait très faible, mais pas
  nulle.
- **Le RIB de l'entreprise cliente** (relevé bancaire) suit la même règle.

**Noms :** raisons sociales inventées. Combinées à la mention « Document
fictif » et aux identifiants non attribuables, aucun document ne peut être
confondu avec une vraie facture.

### D-028 · Seuil de validation provisoire : 20 000 TND TTC
- **Contexte :** le piège `montant_eleve` a besoin d'un seuil. Le seuil
  définitif relève de l'étape 5 (paramètre métier, stocké en base).
- **Choix provisoire :** 20 000 TND TTC. Les factures normales restent sous
  15 000 TND ; les factures piégées dépassent 40 000 TND. Les étiquettes
  restent donc justes pour **tout seuil compris entre 15 000 et 40 000 TND**.
  Hors de cette plage, il faudra régénérer les données.

### D-029 · Conventions du générateur sans portée fiscale
Les choix suivants décrivent ce que le générateur imprime. Ce ne sont **pas**
des affirmations fiscales :
- les avoirs ne portent pas de droit de timbre (exonération non vérifiée,
  voir D-020) ;
- les factures en EUR ne portent pas de timbre ; leur TVA est calculée au
  taux normal de `config_fiscale`. Leur traitement fiscal réel est hors
  périmètre : le piège sert seulement à vérifier que le système repère une
  devise autre que TND ;
- le montant HT de chaque ligne est arrondi au millime (0,5 arrondi vers le
  haut) ; la TVA est calculée **par taux**, sur le total HT des lignes à ce
  taux, puis arrondie au millime. En EUR, tout est arrondi au centime ;
- le taux de TVA attribué à chaque article du catalogue est **arbitraire**.
  Il sert à produire des factures à plusieurs taux et ne dit pas quel taux
  s'applique réellement à ce bien ou service ;
- les prix des catalogues sont inventés.

### D-030 · Fonctions partagées placées dans `src/`
- **Choix :** les fonctions sur les montants (calcul en millimes entiers),
  le RIB (clé, validité) et le matricule fiscal (format) sont écrites dès
  maintenant dans `src/`, avec leurs tests dans `tests/`. Le générateur les
  importe, et les contrôles de l'étape 4 les réutiliseront.
- **Raison :** le générateur et les contrôles appliquent exactement la même
  règle. Une donnée « valide » pour l'un l'est donc pour l'autre.
- **Calcul en millimes :** les montants sont manipulés en entiers (1 TND =
  1 000 millimes), jamais en nombres à virgule flottante.
- **Schémas JSON** dans `src/schemas/` : `extraction-facture.schema.json`
  (champs lus sur un document, strict : tous les champs obligatoires, aucun
  champ en plus, `null` si absent) et `verite-terrain.schema.json`, qui
  l'englobe. Le premier servira à valider la sortie du LLM à l'étape 3.

### D-031 · Évaluation : afficher les nombres bruts, pas seulement des pourcentages
- **Contexte :** le lot de test ne contient que 18 documents (D-026). Sur un si
  petit échantillon, un pourcentage seul est trompeur : un document de plus ou
  de moins fait varier le score d'environ 5,6 points.
- **Règle pour l'étape 8 :** chaque résultat affiche le nombre brut à côté du
  pourcentage, par exemple « 17/18 (94,4 %) ». Cela vaut par champ, par
  format (PDF, scan) et par type de piège. Pour les champs comptés ligne par
  ligne (lignes de facture), on affiche aussi le dénominateur réel.
- **Raison :** le lecteur voit la taille de l'échantillon et ne
  surinterprète pas un écart de quelques points.
