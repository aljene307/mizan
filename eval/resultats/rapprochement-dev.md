# Rapprochement bancaire : mesure sur le lot de développement

Relevé `data/synthetic/releve/releve-2026-01-01_2026-09-30.csv` (103 opérations). Factures : état actuel de la base, telles que les fournit `contexte_rapprochement` (42 factures du lot de développement ; copies d'essai exclues). Aucun écrit en base. Nombres bruts.

Paramètres : tolérance d'écart 5 TND, fenêtre 180 jours.

## 1. Lignes qui règlent des factures (vérité terrain)

| Cas attendu | Lignes | Bonnes factures proposées | Dont confirmées automatiquement |
|---|---|---|---|
| exact | 20 | 20 | 12 |
| ecart | 1 | 1 | 0 |
| groupe | 1 | 1 | 0 |
| net_avoir | 1 | 1 | 0 |
| partiel | 2 | 2 | 0 |
| **Total** | **25** | **25** | **12** |

Confirmations automatiques **fausses** : **0** (sur 12).

| Ligne | Cas attendu | Mode | Résultat |
|---|---|---|---|
| 8 | exact | virement | proposition exact (auto) |
| 21 | ecart | virement | proposition ecart |
| 26 | exact | cheque | proposition exact |
| 28 | exact | cheque | proposition exact |
| 30 | exact | virement | proposition exact |
| 32 | exact | virement | proposition exact (auto) |
| 35 | groupe | virement | proposition groupe |
| 38 | exact | virement | proposition exact (auto) |
| 47 | net_avoir | virement | proposition net_avoir |
| 49 | exact | virement | proposition exact (auto) |
| 51 | exact | virement | proposition exact |
| 52 | exact | virement | proposition exact |
| 61 | exact | cheque | proposition exact |
| 64 | partiel | virement | proposition partiel |
| 66 | exact | cheque | proposition exact |
| 67 | exact | virement | proposition exact (auto) |
| 69 | exact | virement | proposition exact (auto) |
| 73 | exact | virement | proposition exact (auto) |
| 75 | exact | virement | proposition exact (auto) |
| 78 | partiel | virement | proposition partiel |
| 80 | exact | virement | proposition exact (auto) |
| 84 | exact | cheque | proposition exact |
| 90 | exact | virement | proposition exact (auto) |
| 96 | exact | virement | proposition exact (auto) |
| 100 | exact | virement | proposition exact (auto) |

## 2. Classés à part

**État de la base** (payées selon la vérité terrain, non approuvées aujourd'hui) : 3 ligne(s) ; signalement « payée sans être approuvée » levé : 3.

- ligne 25 : D001 : anomalie → payee_non_approuvee
- ligne 42 : D018 : anomalie → payee_non_approuvee
- ligne 55 : D006 : anomalie → payee_non_approuvee

**Hors périmètre** (factures du lot de test, absentes de la base) : 5 ligne(s) ; signalées « sortie sans facture » : 5. Évaluées à l'étape 8.

## 3. Lignes sans facture (loyer, salaires, frais, encaissements…)

70 lignes ; rangées dans une catégorie : 70 ; **fausses alertes ou propositions** : **0**.

Par catégorie : loyer 9, encaissement_client 27, commission_virement 16, salaires 9, frais_tenue 9.

## 4. Factures impayées (vérité terrain)

11 factures du lot de développement ne sont pas payées dans le relevé ; propositions qui leur affectent un paiement à tort : **0**.

## 5. Volume de notifications pour cet import

1 synthèse ; 13 proposition(s) à confirmer ; 8 signalement(s) ; soit **22 messages** par destinataire responsable (14 pour un validateur, qui ne reçoit pas les signalements). Confirmées automatiquement, sans message : 12.

## 6. Limites

- Un seul relevé synthétique, généré avec des libellés réguliers : un vrai relevé aura des libellés plus variés.
- Aucune retenue à la source n'est simulée (D-065, C1) : l'écart de 2 TND (D015) est un écart générique.
- Le relevé ne montre pas le RIB du bénéficiaire : D-058 sera contrôlé par les ordres de paiement (étape 7).
- Une proposition rejetée n'est pas reproposée ; sa ligne reste à rapprocher à la main (tableau de bord, étape 7).
