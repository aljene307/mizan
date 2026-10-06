# Contrôles déterministes : mesure sur la vérité terrain (lot de développement)

Logique seule : les règles s'appliquent aux valeurs **imprimées** (vérité terrain), sans OCR ni LLM. 42 documents, 22 règles exécutées sur chacun (vérifié). Date de référence : 2026-10-06. Configuration fiscale, paramètres de contrôle et catalogue lus en base. Nombres bruts.

Paramètres : seuil de validation 20000 TND ; tolérances : TTC 0 millime, TVA 1 millime par ligne, ligne 1 millime.

## 1. Pièges détectés, par type

| Piège | Règle prévue | Attendus | Détectés par la règle prévue | Par une autre règle seulement | Non détectés |
|---|---|---|---|---|---|
| erreur_tva | coherence_tva | 1 | 1 | 0 | 0 |
| ttc_incoherent | coherence_ttc | 1 | 1 | 0 | 0 |
| rib_modifie | changement_rib | 1 | 1 | 0 | 0 |
| matricule_invalide | matricule_format | 1 | 1 | 0 | 0 |
| fournisseur_inconnu | fournisseur_inconnu | 1 | 1 | 0 | 0 |
| montant_eleve | seuil_validation | 1 | 1 | 0 | 0 |
| devise_etrangere | devise | 1 | 1 | 0 | 0 |
| doublon_exact | doublon_fichier | 1 | 1 | 0 | 0 |
| doublon_rescanne | doublon_numero | 1 | 1 | 0 | 0 |
| **Total** | | **9** | **9** | | |

Doublons : la paire est l'unité ; elle compte comme détectée si exactement une des deux factures est marquée : celle **reçue en second** (ordre de dépôt, par nom de fichier). Pour la paire D035/D056, c'est donc D056 qui est bloquée, bien que D035 soit la copie générée.

## 2. Fausses alertes sur les factures sans piège

Factures sans piège : 33. Avec au moins une alerte (avertissement, bloquant ou validation) : **0**.

## 3. Statut final

Statut obtenu = statut attendu : **42 / 42**.

Répartition : a_valider 1, anomalie 1, bloquee 7, conforme 33.

## 4. Détail des factures piégées et des doublons

| Document | Piège | Statut | Alertes (règle : gravité) |
|---|---|---|---|
| D008 | fournisseur_inconnu | bloquee | fournisseur_inconnu : bloquant |
| D010 | ttc_incoherent | bloquee | coherence_ttc : bloquant |
| D011 | matricule_invalide | bloquee | fournisseur_inconnu : bloquant ; matricule_format : bloquant ; matricule_lecture_probable : avertissement |
| D028 | montant_eleve | a_valider | seuil_validation : validation |
| D030 | rib_modifie | bloquee | changement_rib : bloquant |
| D035 | doublon_exact | conforme | — |
| D042 | original de D050 | conforme | — |
| D045 | devise_etrangere | anomalie | devise : avertissement |
| D050 | doublon_rescanne | bloquee | doublon_numero : bloquant |
| D051 | erreur_tva | bloquee | coherence_tva : bloquant |
| D056 | original de D035 | bloquee | doublon_fichier : bloquant ; doublon_numero : bloquant |

## 5. Tolérances d'arrondi utilisées

- Lignes (quantité × prix) : 0 ligne(s) tolérée(s) sur 0 document(s).
- TVA : écart toléré sur 0 document(s).
- Écart de TVA du piège, détecté : D051 : 49000 millimes.

## 6. Résultats « info » (non comptés comme alertes)

Aucun.


## 7. Limites de cette mesure

- Les règles qui dépendent de l'extraction (identifiants absents du texte, plusieurs RIB, signalements) sont **non applicables** ici : elles seront mesurées sur l'extraction réelle, après le workflow.
- Les documents synthétiques sont réguliers ; une facture réelle peut arrondir autrement (voir les tolérances, D-055 B2).
- Les pièges d'injection (D001, D006) n'ont aucun effet sur les valeurs imprimées : ils comptent ici comme des factures sans piège.
