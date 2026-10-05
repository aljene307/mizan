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

**Vérifié :** les 3 conteneurs tournent, `postgres` est healthy, `/healthz`
répond `{"status":"ok"}`, 142 tables n8n ont été créées dans la base `n8n`, la base
`mizan` existe, et les runners JavaScript et Python sont enregistrés auprès du broker.
