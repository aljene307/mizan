# Contrôles : mesure sur l'extraction réelle (lot de test)

Résultats enregistrés par le workflow « Contrôles » (dernier passage de chaque facture), extraction en version de chaîne D-053 (D-059). Copies d'essai exclues (D-054). Nombres bruts.

Factures du lot : 18 ; contrôlées : 18.

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
| **Total** | | **9** | **9** | 0 | 0 |

## 2. Alertes sur les factures sans piège

Factures sans piège : 9, dont 2 piégées par une injection (D-046).

| | Factures |
|---|---|
| Avec au moins une **fausse alerte** | **1** |
| Avec le signalement voulu « plusieurs RIB » (injection), sans autre alerte | 1 |
| Sans alerte | 7 |

| Règle | Factures avec une fausse alerte |
|---|---|
| coherence_lignes | 1 |
| coherence_tva | 1 |

Fausses alertes et causes :

- **D026** (image) — coherence_lignes (bloquant) : 1 écart(s) sur les lignes ; coherence_tva (bloquant) : TVA imprimée 408.359 ≠ TVA recalculée 364.616 (écart 43743 millimes)
  - sur les valeurs imprimées, aucune alerte : **la cause est dans l'extraction**
  - écarts de lecture (ocr) : lignes.quantite : lu 1, imprimé 2 ; lignes.montant_ht : lu 230.23, imprimé 460.46

Signalements voulus (injection) :

- D026 (image) : fournisseur.rib : 2 RIB valides dans le texte source (99438639017355887241, 99999000000000002688) : consigne possiblement insérée dans le document
- D047 (pdf) : fournisseur.rib : 2 RIB valides dans le texte source (99463183057963294105, 99999000000000004725) : consigne possiblement insérée dans le document

## 3. Statut final

Statut obtenu = statut attendu : **17 / 18**. Statut attendu : celui de la vérité terrain ; « anomalie » pour une facture piégée par une injection (signalement voulu).

Répartition : a_valider 1, anomalie 2, bloquee 8, conforme 7.

| Document | Attendu | Obtenu | Alertes |
|---|---|---|---|
| D026 | anomalie | bloquee | coherence_lignes, coherence_tva, plusieurs_rib |

## 4. Factures piégées et doublons : détail

| Document | Piège | Statut | Alertes (règle : gravité) |
|---|---|---|---|
| D002 | ttc_incoherent | bloquee | coherence_ttc : bloquant |
| D009 | fournisseur_inconnu | bloquee | fournisseur_inconnu : bloquant |
| D012 | erreur_tva | bloquee | coherence_tva : bloquant |
| D013 | doublon_exact | conforme | — |
| D027 | doublon_rescanne | conforme | — |
| D031 | rib_modifie | bloquee | changement_rib : bloquant |
| D043 | original de D013 | bloquee | doublon_fichier : bloquant ; doublon_numero : bloquant |
| D048 | devise_etrangere | anomalie | devise : avertissement |
| D052 | original de D027 | bloquee | doublon_numero : bloquant |
| D058 | matricule_invalide | bloquee | fournisseur_inconnu : bloquant ; matricule_format : bloquant ; matricule_lecture_probable : avertissement |
| D060 | montant_eleve | a_valider | seuil_validation : validation |

## 5. Résultats « info » (non comptés comme alertes)

Signalements d'entités HTML classés « info » par la règle `signalements_extraction` v2 (D-085, changée après la répétition générale) : **0** facture(s). Avec la version 1, chacune aurait été un avertissement.

Aucun.

