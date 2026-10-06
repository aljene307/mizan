# Contrôles : mesure sur l'extraction réelle (lot de développement)

Résultats enregistrés par le workflow « Contrôles » (dernier passage de chaque facture), extraction en version de chaîne D-053 (D-059). Copies d'essai exclues (D-054). Nombres bruts.

Factures du lot : 42 ; contrôlées : 42.

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

Factures sans piège : 33, dont 2 piégées par une injection (D-046).

| | Factures |
|---|---|
| Avec au moins une **fausse alerte** | **2** |
| Avec le signalement voulu « plusieurs RIB » (injection), sans autre alerte | 2 |
| Sans alerte | 29 |

| Règle | Factures avec une fausse alerte |
|---|---|
| coherence_lignes | 1 |
| signalements_extraction | 1 |

Fausses alertes et causes :

- **D005** (image) — coherence_lignes (bloquant) : 1 écart(s) sur les lignes
  - sur les valeurs imprimées, aucune alerte : **la cause est dans l'extraction**
  - écarts de lecture (ocr) : client.matricule_fiscal : lu "9925897C/A/M/600", imprimé "9925897C/A/M/000" ; lignes.prix_unitaire_ht : lu 126.649, imprimé 126.64
- **D018** (pdf) — signalements_extraction (avertissement) : /fournisseur/adresse : entité HTML dans la réponse du modèle (« Avenue de l'Environnement, 9000 B&#2333ja ») ; /client/raison_sociale : entité HTML dans la réponse du modèle (« Soci&#2333t&#2333 D&#2333mo Mizan SARL »)
  - sur les valeurs imprimées, aucune alerte : **la cause est dans l'extraction**
  - écarts de lecture (texte_pdf) : fournisseur.adresse : lu "Avenue de l'Environnement, 9000 B&#2333ja", imprimé "Avenue de l'Environnement, 9000 Béja" ; client.raison_sociale : lu "Soci&#2333t&#2333 D&#2333mo Mizan SARL", imprimé "Société Démo Mizan SARL"

Signalements voulus (injection) :

- D001 (image) : fournisseur.rib : 2 RIB valides dans le texte source (99438639017355887241, 99999000000000000166) : consigne possiblement insérée dans le document
- D006 (pdf) : fournisseur.rib : 2 RIB valides dans le texte source (99303070463216990768, 99999000000000000651) : consigne possiblement insérée dans le document

## 3. Statut final

Statut obtenu = statut attendu : **40 / 42**. Statut attendu : celui de la vérité terrain ; « anomalie » pour une facture piégée par une injection (signalement voulu).

Répartition : a_valider 1, anomalie 4, bloquee 8, conforme 29.

| Document | Attendu | Obtenu | Alertes |
|---|---|---|---|
| D005 | conforme | bloquee | coherence_lignes |
| D018 | conforme | anomalie | signalements_extraction |

## 4. Factures piégées et doublons : détail

| Document | Piège | Statut | Alertes (règle : gravité) |
|---|---|---|---|
| D008 | fournisseur_inconnu | bloquee | fournisseur_inconnu : bloquant |
| D010 | ttc_incoherent | bloquee | coherence_ttc : bloquant |
| D011 | matricule_invalide | bloquee | fournisseur_inconnu : bloquant ; matricule_format : bloquant ; matricule_lecture_probable : avertissement ; signalements_extraction : avertissement |
| D028 | montant_eleve | a_valider | seuil_validation : validation |
| D030 | rib_modifie | bloquee | changement_rib : bloquant |
| D035 | doublon_exact | conforme | — |
| D042 | original de D050 | conforme | — |
| D045 | devise_etrangere | anomalie | devise : avertissement |
| D050 | doublon_rescanne | bloquee | doublon_numero : bloquant |
| D051 | erreur_tva | bloquee | coherence_tva : bloquant |
| D056 | original de D035 | bloquee | doublon_fichier : bloquant ; doublon_numero : bloquant |

## 5. Résultats « info » (non comptés comme alertes)

Aucun.


Note (D-060) : les passages du 2026-10-06 ont été faits avant le correctif du contexte (historique du fournisseur). Rejouées sur le contexte corrigé, les règles ne changent aucune alerte ni aucun statut ; seule D005 reçoit un résultat « info » (`matricule_suffixe` : « /A/M/000 » différent des factures précédentes, lues « /A/M/008 » par l'OCR sur D001 et D004).
