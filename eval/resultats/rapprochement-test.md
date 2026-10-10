# Rapprochement bancaire : mesure sur le lot de test

Relevé `data/synthetic/releve/releve-2026-01-01_2026-09-30.csv` (103 opérations). Factures : état actuel de la base, telles que les fournit `contexte_rapprochement` (18 factures du lot de test ; copies d'essai exclues). Aucun écrit en base. Nombres bruts.

Paramètres : tolérance d'écart 5 TND, fenêtre 180 jours.

## 1. Lignes qui règlent des factures (vérité terrain)

| Cas attendu | Lignes | Bonnes factures proposées | Dont confirmées automatiquement |
|---|---|---|---|
| exact | 2 | 2 | 2 |
| net_avoir | 1 | 1 | 0 |
| **Total** | **3** | **3** | **2** |

Confirmations automatiques **fausses** : **0** (sur 2).

| Ligne | Cas attendu | Mode | Résultat |
|---|---|---|---|
| 22 | exact | virement | proposition exact (auto) |
| 36 | net_avoir | virement | proposition net_avoir |
| 44 | exact | virement | proposition exact (auto) |

## 2. Classés à part

**État de la base** (payées selon la vérité terrain, non approuvées aujourd'hui) : 2 ligne(s) ; signalement « payée sans être approuvée » levé : 2.

- ligne 3 : D026 : bloquee → payee_non_approuvee
- ligne 23 : D047 : anomalie → payee_non_approuvee

**Hors périmètre** (factures du lot de développement, absentes de la base d'évaluation) : 28 ligne(s) ; signalées « sortie sans facture » : 28. Mesurées sur le lot de développement.

## 3. Lignes sans facture (loyer, salaires, frais, encaissements…)

70 lignes ; rangées dans une catégorie : 70 ; **fausses alertes ou propositions** : **0**.

Par catégorie : loyer 9, encaissement_client 27, commission_virement 16, salaires 9, frais_tenue 9.

## 4. Factures impayées (vérité terrain)

10 factures du lot de test ne sont pas payées dans le relevé ; propositions qui leur affectent un paiement à tort : **0**.

## 5. Volume de notifications pour cet import

1 synthèse ; 1 proposition(s) à confirmer ; 30 signalement(s) ; soit **32 messages** par destinataire responsable (2 pour un validateur, qui ne reçoit pas les signalements). Confirmées automatiquement, sans message : 2.

## 6. Limites

- Un seul relevé synthétique, généré avec des libellés réguliers : un vrai relevé aura des libellés plus variés.
- Aucune retenue à la source n'est simulée (D-065, C1) : l'écart de 2 TND (D015) est un écart générique.
- Le relevé ne montre pas le RIB du bénéficiaire : on vérifie qu'un ordre de paiement approuvé existe (D-072), pas le compte crédité.
- Base d'évaluation sans décision humaine (D-082) : seules les factures « conformes » sont approuvées ; les paiements des autres sont classés « état de la base ».
- Échantillon très petit : quelques lignes du relevé seulement règlent des factures du lot de test.
