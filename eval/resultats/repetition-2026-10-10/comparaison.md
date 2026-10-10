# Répétition générale du 2026-10-10 : comparaison avec les résultats publiés

Lot de développement (42 documents), même protocole que l'évaluation finale
(D-082) : base reconstruite à l'état « évaluation », extraction réelle avec
la configuration figée D-053 (41 appels au modèle et une réutilisation ;
un appel perdu par une exécution interrompue, reprise selon la règle 1),
un seul passage des contrôles, mesures par les mêmes scripts. Résultats
publiés : extraction du 2026-10-06, même configuration. Nombres bruts.

## Stabilité de l'extraction (même configuration, deux exécutions)

Après corrections par le code, données comparées champ par champ :
**36 documents sur 41 identiques**, **1 209 champs sur 1 216 identiques**.
Les 7 champs différents :

- D003 : `fournisseur.raison_sociale` (scan) ;
- D011 : `fournisseur.raison_sociale`, `fournisseur.rib` ;
- D018 : `fournisseur.adresse`, `client.raison_sociale` (entités HTML malformées en 2026-10-06) ;
- D021 : `lignes[0].designation` ;
- D050 : `fournisseur.rib` (scan).

Le modèle tourne à la température 1.0 (recommandation de Google, D-048) :
deux exécutions ne donnent pas exactement les mêmes champs.

## Extraction (après corrections ; publié → répétition)

| Mesure | Publié | Répétition |
|---|---|---|
| Extractions utilisables | 41/41 | 41/41 |
| Champs d'en-tête exacts (normalisé) | 646/656 | 649/656 |
| Lignes exactes (normalisé) | 108/112 | 109/112 |
| Documents entièrement exacts (normalisé) | 31/41 | 33/41 |
| `fournisseur.rib` | 39/41 | 40/41 |
| Sortie brute du modèle : utilisables | 35/41 | 34/41 |

Écarts de quelques champs, dans les deux sens : l'ordre de grandeur de la
variabilité entre deux exécutions.

## Contrôles

| Mesure | Publié | Répétition |
|---|---|---|
| Pièges détectés par la règle prévue | 9/9 | 9/9 |
| Factures sans piège avec une fausse alerte | 2 | 4 |
| Statut obtenu = statut attendu | 40/42 | 38/42 |

Les fausses alertes sont toutes `signalements_extraction` : le modèle a
écrit des **entités HTML** (`M&#233;dina`, `Syst&egrave;mes`) dans sa
réponse brute. Le code les décode (les données sont justes) mais signale
l'extraction, ce qui met la facture « en anomalie » (D-053). Le modèle le
fait sur 2 à 3 documents par exécution, **pas toujours les mêmes** (D011 et
D018 en 2026-10-06 ; D003, D021 et D024 ici). C'est la principale source de
variabilité des statuts ; la piste D-061 (ramener ce signalement à « info »
sur les champs seulement descriptifs) n'est pas appliquée : la configuration
est figée jusqu'à l'évaluation. D050 (doublon rescanné, détecté) reçoit en
plus deux alertes de RIB, dues à une lecture OCR du RIB différente.

## Rapprochement (base sans décision humaine)

| Mesure | Publié | Répétition |
|---|---|---|
| Lignes réglant des factures approuvées : bonnes factures | 25/25 | 21/21 |
| Confirmations automatiques fausses | 0/12 | 0/10 |
| Lignes classées « état de la base » (factures non approuvées) | 3 | 7 |
| Lignes sans facture rangées, fausses alertes | 70, 0 | 70, 0 |

Le nombre de lignes mesurées baisse parce que la base d'évaluation n'a
**aucune décision humaine** (D028 et D005 n'y sont pas validées) et que trois
factures de plus y sont « en anomalie » (entités HTML) : leurs paiements
passent dans « état de la base ». Aucune erreur d'appariement.

## Conclusion

La chaîne complète fonctionne dans les conditions de l'évaluation : base
reconstruite, extraction, contrôles, sauvegarde, trois mesures. Les écarts
avec les résultats publiés viennent de la variabilité du modèle (quelques
champs, et les entités HTML qui changent les statuts) et de l'absence de
décisions humaines ; aucun ne vient des outils. À dire dans le rapport de
l'évaluation : sur 18 documents, cette variabilité peut faire bouger les
statuts d'un ou deux documents d'une exécution à l'autre.
