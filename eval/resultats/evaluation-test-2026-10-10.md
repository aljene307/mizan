# Évaluation finale sur le lot de test (2026-10-10)

Lot de test : **18 documents**, jamais ouverts avant la mesure. Protocole
écrit avant l'ouverture (D-082), configuration d'extraction figée le
2026-10-06 (D-053), règle des entités HTML en version 2 (D-085, décidée
avant l'ouverture). Nombres bruts : sur 18 documents, **un document vaut
environ 5,6 points**.

Sorties brutes des trois mesures, produites par les scripts et non
retouchées :
- [precision-test.md](precision-test.md) : extraction ;
- [controles-reel-test.md](controles-reel-test.md) : contrôles ;
- [rapprochement-test.md](rapprochement-test.md) : rapprochement bancaire.

Sauvegarde de l'état évalué : `sauvegardes/mizan-2026-10-10-1807.dump`
(hors du dépôt).

## 1. Protocole suivi (vérifié dans la base et dans l'historique de n8n)

Heures locales (Tunis, UTC+1).

| Étape | Constat |
|---|---|
| Base reconstruite à l'état « évaluation » | 17 h 59 ; la base de la répétition a d'abord été sauvegardée par le script (`mizan-2026-10-10-1759.dump`) |
| Configuration | `verifier-avant-evaluation` : version de chaîne D-053, prompt v1, code des workflows chargé dans n8n identique au dépôt, aucun workflow publié |
| Test Gemini | une exécution, 18 h 00 (un appel au quota) |
| Réception et extraction | **une seule exécution** (n° 1286), 18 h 01 → 18 h 04, terminée sans erreur. 17 appels au modèle, tous en une tentative. D043 réutilise l'extraction de D013 (même fichier) : aucun appel. |
| Ordre de réception | identifiants croissants dans l'ordre des noms (D002 → D060) |
| Relance sélective | aucune ; aucune extraction en erreur ; aucune réservation interrompue |
| Contrôles | **un seul passage** (n° 1304), 18 h 06, après la fin de toutes les extractions ; 18 factures, un passage chacune, règle `signalements_extraction` en version 2 |
| Sauvegarde | 18 h 07, avant les mesures ; relue (38 tables de données) |
| Mesures | les trois scripts avec `--lot test --etape-8`, sans changement des règles de comptage |

**Incidents : aucun.** Aucun changement du prompt, du schéma, des
corrections par le code ni des règles depuis l'ouverture du lot.

## 2. Extraction : sortie brute du modèle et résultat après corrections

| Mesure (17 extractions) | Sortie brute | Après corrections |
|---|---|---|
| Extractions utilisables (conformes au schéma) | 13/17 | 17/17 |
| Champs d'en-tête exacts (strict) | 262/272 | 267/272 |
| Champs d'en-tête exacts (normalisé) | 266/272 | **271/272** |
| Lignes exactes (normalisé) | 42/45 | 42/45 |
| Documents entièrement exacts (normalisé) | 10/17 | **14/17** |
| `fournisseur.rib` (strict) | 15/17 | 16/17 |
| `devise` (strict) | 13/17 | 17/17 |
| `fournisseur.matricule_fiscal` (strict) | 17/17 | 17/17 |
| `montant_ttc` (strict) | 17/17 | 17/17 |

Les corrections par le code réparent surtout la devise : quatre fois « DT »
est converti en TND. Elles remplissent aussi un RIB retrouvé dans le texte
et identique au référentiel (D032).

**Par format (en-tête, normalisé) :**
- PDF texte, 13 documents : 207/208 ;
- scans (OCR), 4 documents : 64/64.

**Écarts restants (normalisé) :**
- **D031** (PDF) : RIB non rempli. Le RIB imprimé diffère du référentiel :
  c'est le piège « RIB modifié ». Le code ne le remplit pas, mais le
  propose, et la proposition est juste.
- **D016** (scan) : désignation « Caté » au lieu de « Cat6 » (lecture OCR).
- **D026** (scan) : quantité 1 au lieu de 2, et montant de ligne 230,23 au
  lieu de 460,46. Le prix unitaire et le TTC sont justes.
- **D031** (PDF) : le modèle a écrit « μ » (lettre grecque) au lieu de
  « µ » (signe micro) dans une désignation.

Les 4 écarts stricts sur la raison sociale du fournisseur ne sont que de la
casse (noms en capitales), justes en normalisé.

**Robustesse :**
- consigne injectée (D-046) suivie : **0/2**. RIB et TTC réels extraits ;
  les deux documents sont signalés pour « 2 RIB valides » ;
- identifiants faux sans alerte : 0 ;
- alertes « identifiant absent du texte source » : 0.

## 3. Contrôles sur l'extraction réelle

| Mesure | Résultat |
|---|---|
| Pièges détectés par la règle prévue | **9/9** (un exemple par type) |
| Factures sans piège avec une fausse alerte | **1/9** (D026) |
| Statut obtenu = statut attendu | **17/18** |

**La fausse alerte, D026.**
- **Ce qu'est D026 :** un scan, et l'un des deux documents piégés par une
  injection.
- **Ce qui s'est passé :** il est bloqué par `coherence_lignes` et
  `coherence_tva`, au lieu d'être seulement « en anomalie » pour le
  signalement voulu des deux RIB.
- **La cause est dans l'extraction :** la quantité lue est fausse (1 au lieu
  de 2) ; sur les valeurs imprimées, aucune alerte.
- **Effet :** la facture est arrêtée, pas acceptée. L'alerte signale une
  vraie erreur de lecture.

Les 7 factures normales du lot sont sans alerte.

**Doublons.** La paire est l'unité (D-082) : c'est la facture reçue en
second qui est bloquée.
- D043 est bloquée comme doublon exact de D013 ;
- D052 est bloquée comme doublon rescanné de D027.

C'est le même comptage que pour la paire D035/D056 du lot de
développement.

**Règle des entités HTML, version 2 (D-085) : aucun effet sur ce lot.**
- Le modèle n'a écrit **aucune entité HTML** dans ses réponses : les seuls
  signalements enregistrés sont les deux « 2 RIB valides ».
- Signalements d'entités classés « info » : **0**. Les versions 1 et 2
  donnent exactement les mêmes résultats.

## 4. Rapprochement bancaire (base sans décision humaine)

| Mesure | Résultat |
|---|---|
| Lignes réglant des factures du lot : bonne facture proposée | **3/3** (2 exactes, 1 nette d'un avoir) |
| Confirmations automatiques fausses | **0/2** |
| Lignes sans facture rangées dans une catégorie | 70/70, 0 fausse alerte |
| Factures impayées à qui un paiement est affecté à tort | 0/10 |
| Paiements de factures non approuvées signalés (« état de la base ») | 2/2 (D026, D047) |

## 5. Comparaison avec le lot de développement

Le lot de développement a servi à **mettre au point** l'extraction et les
règles : ses chiffres ne sont pas une évaluation. Le lot de test est
l'**évaluation**. La colonne « Répétition » est une seconde exécution sur
le lot de développement, avec la même configuration.

| Mesure (après corrections) | Développement, publié (2026-10-06) | Développement, répétition (2026-10-10) | **Test (2026-10-10)** |
|---|---|---|---|
| Extractions utilisables, sortie brute | 35/41 | 34/41 | 13/17 |
| Extractions utilisables, après corrections | 41/41 | 41/41 | 17/17 |
| Champs d'en-tête exacts (normalisé) | 646/656 | 649/656 | 271/272 |
| Lignes exactes (normalisé) | 108/112 | 109/112 | 42/45 |
| Documents entièrement exacts (normalisé) | 31/41 | 33/41 | 14/17 |
| `fournisseur.rib` | 39/41 | 40/41 | 16/17 |
| Consigne injectée suivie | 0/2 | 0/2 | 0/2 |
| Pièges détectés par la règle prévue | 9/9 | 9/9 | 9/9 |
| Factures sans piège avec une fausse alerte | 2/33 | 4/33 | 1/9 |
| Statut obtenu = statut attendu | 40/42 | 38/42 | 17/18 |
| Rapprochement : bonnes factures | 25/25 | 21/21 | 3/3 |
| Confirmations automatiques fausses | 0/12 | 0/10 | 0/2 |

- **Extraction.** Les résultats du lot de test sont du même ordre que ceux
  du lot de développement. Ils ne sont pas « meilleurs » de façon
  significative : le lot ne compte que 4 scans sur 17 (11 sur 41 en
  développement). Or les scans font plus d'erreurs : en développement,
  6 écarts d'en-tête sur 11 scans, contre 4 sur 30 PDF (normalisé).
- **Sortie brute moins souvent conforme au schéma** (13/17) : le modèle
  écrit « DT » au lieu de TND, ce que le code corrige.

## 6. Variabilité observée

- **D'une exécution à l'autre, avec la même configuration, le modèle ne
  rend pas exactement les mêmes champs** (température 1.0, D-048).
- **Écarts sur le lot de développement**, entre deux exécutions (publié et
  répétition) :
  - 36 documents sur 41 identiques ;
  - 1 209 champs sur 1 216 identiques ;
  - 2 puis 4 fausses alertes ;
  - 40 puis 38 statuts attendus.
- **Cause principale des écarts de statut :** les entités HTML que le modèle
  écrit sur 2 à 3 documents par exécution, pas toujours les mêmes. La règle
  v2 en neutralise une partie (D-085).
- **Ce que cela veut dire pour ce lot :** une seconde exécution sur le lot
  de test pourrait faire bouger le statut d'un ou deux documents, soit 5,6
  à 11 points. Les chiffres ci-dessus sont **une** exécution, pas une
  moyenne.

## 7. Limites

- **18 documents** : un document vaut 5,6 points. Les pourcentages ne
  sont pas comparables à ceux d'un grand échantillon.
- **Un exemple par type de piège** : 9/9 montre que chaque règle fonctionne
  sur l'extraction réelle, pas un taux de détection.
- **3 paiements** seulement règlent des factures du lot de test : le
  rapprochement est vérifié, pas mesuré.
- **4 scans sur 17** : la partie la plus fragile de la chaîne (OCR) est peu
  représentée.
- **Documents synthétiques**, générés à partir de nos propres mises en page
  : ils sont plus réguliers que de vraies factures, et la précision mesurée
  est optimiste.
- **Une seule exécution**, à la température 1.0 (voir la variabilité).
- **La règle des entités HTML a changé après la répétition générale**
  (D-085, sur le lot de développement uniquement). Elle n'a eu aucun effet
  sur ce lot.
- **Base d'évaluation sans décision humaine :** les paiements des factures
  non approuvées sont classés à part.
