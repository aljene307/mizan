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
