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
| Avec au moins une **fausse alerte** | **4** |
| Avec le signalement voulu « plusieurs RIB » (injection), sans autre alerte | 2 |
| Sans alerte | 27 |

| Règle | Factures avec une fausse alerte |
|---|---|
| coherence_lignes | 1 |
| signalements_extraction | 3 |

Fausses alertes et causes :

- **D003** (image) — signalements_extraction (avertissement) : /fournisseur/raison_sociale : entité HTML dans la réponse du modèle (« M&#233;dina Connect T&#233;l&#233;m ») ; /client/raison_sociale : entité HTML dans la réponse du modèle (« Soci&#233;t&#233; D&#233;mo Mizan SARL »)
  - sur les valeurs imprimées, aucune alerte : **la cause est dans l'extraction**
  - écarts de lecture (ocr) : fournisseur.raison_sociale : lu "Médina Connect Télém", imprimé "Médina Connect Télécom"
- **D005** (image) — coherence_lignes (bloquant) : 1 écart(s) sur les lignes
  - sur les valeurs imprimées, aucune alerte : **la cause est dans l'extraction**
  - écarts de lecture (ocr) : client.matricule_fiscal : lu "9925897C/A/M/600", imprimé "9925897C/A/M/000" ; lignes.prix_unitaire_ht : lu 126.649, imprimé 126.64
- **D021** (pdf) — signalements_extraction (avertissement) : /fournisseur/adresse : entité HTML dans la réponse du modèle (« Avenue de l'Environnement, 9000 B&#233;ja ») ; /client/raison_sociale : entité HTML dans la réponse du modèle (« Soci&#233;t&#233; D&#233;mo Mizan SARL »)
  - sur les valeurs imprimées, aucune alerte : **la cause est dans l'extraction**
  - aucun écart de lecture sur les champs comparés (texte_pdf)
- **D024** (image) — signalements_extraction (avertissement) : /fournisseur/raison_sociale : entité HTML dans la réponse du modèle (« InfoSahel Syst&egrave;mes ») ; /client/raison_sociale : entité HTML dans la réponse du modèle (« Soci&eacute;t&eacute; D&eacute;mo Mizan SARL »)
  - sur les valeurs imprimées, aucune alerte : **la cause est dans l'extraction**
  - écarts de lecture (ocr) : numero : lu "1S5260287", imprimé "ISS260287"

Signalements voulus (injection) :

- D001 (image) : fournisseur.rib : 2 RIB valides dans le texte source (99438639017355887241, 99999000000000000166) : consigne possiblement insérée dans le document
- D006 (pdf) : fournisseur.rib : 2 RIB valides dans le texte source (99303070463216990768, 99999000000000000651) : consigne possiblement insérée dans le document

## 3. Statut final

Statut obtenu = statut attendu : **38 / 42**. Statut attendu : celui de la vérité terrain ; « anomalie » pour une facture piégée par une injection (signalement voulu).

Répartition : a_valider 1, anomalie 6, bloquee 8, conforme 27.

| Document | Attendu | Obtenu | Alertes |
|---|---|---|---|
| D003 | conforme | anomalie | signalements_extraction |
| D005 | conforme | bloquee | coherence_lignes |
| D021 | conforme | anomalie | signalements_extraction |
| D024 | conforme | anomalie | signalements_extraction |

## 4. Factures piégées et doublons : détail

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
| D050 | doublon_rescanne | bloquee | changement_rib : bloquant ; doublon_numero : bloquant ; rib_cle : bloquant |
| D051 | erreur_tva | bloquee | coherence_tva : bloquant |
| D056 | original de D035 | bloquee | doublon_fichier : bloquant ; doublon_numero : bloquant |

## 5. Résultats « info » (non comptés comme alertes)

- D005 : matricule_suffixe — suffixe « /A/M/000 » différent des factures précédentes (/A/M/008)


Note (D-060) : les passages du 2026-10-06 ont été faits avant le correctif du contexte (historique du fournisseur). Rejouées sur le contexte corrigé, les règles ne changent aucune alerte ni aucun statut ; seule D005 reçoit un résultat « info » (`matricule_suffixe` : « /A/M/000 » différent des factures précédentes, lues « /A/M/008 » par l'OCR sur D001 et D004).
