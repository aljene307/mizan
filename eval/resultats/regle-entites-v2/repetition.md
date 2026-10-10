# Règle signalements_extraction : version 1 → version 2 (extractions de la répétition générale du 2026-10-10)

Contrôles rejoués en mémoire sur les extractions enregistrées de la base « mizan », sans appel au modèle (D-085). Factures du lot de développement : 42. Nombres bruts.

| Mesure | Version 1 | Version 2 |
|---|---|---|
| Signalements d'entités en avertissement | 3 | 1 |
| Signalements d'entités classés « info » | 0 | 2 |
| Factures sans piège avec une fausse alerte (hors injection) | 4 (D003, D005, D021, D024) | 2 (D003, D005) |

| Facture | Règle v1 | Règle v2 | Statut v1 | Statut v2 |
|---|---|---|---|---|
| D021 | avertissement | info | anomalie | conforme |
| D024 | avertissement | info | anomalie | conforme |

Une « info » ne change pas le statut. Les pièges et les doublons ne sont pas concernés par cette règle.
