# Données synthétiques

Jeu de factures fournisseurs **fictives** produit par `npm run generer`
(code dans [`generateur/`](../../generateur/)). Aucune donnée réelle.
Décisions : [docs/decisions.md](../../docs/decisions.md), D-023 à D-030.

> ⚠️ Le lot **`test/`** est réservé à l'évaluation de l'étape 8. Il ne doit
> pas servir à régler le prompt d'extraction ni le schéma : ne l'ouvrez pas
> avant cette étape (D-026).

## Contenu

| Chemin | Contenu |
|---|---|
| `dev/documents/`, `test/documents/` | 60 documents : 45 PDF et 15 scans JPEG (42 en dev, 18 en test) |
| `dev/verite/`, `test/verite/` | Vérité terrain de chaque document (schéma : `src/schemas/verite-terrain.schema.json`) |
| `lots.json` | Répartition dev/test et anomalies de chaque document |
| `referentiel/` | L'entreprise cliente et les 12 fournisseurs connus (sans les 2 fournisseurs « inconnus ») |
| `releve/releve-2026-01-01_2026-09-30.csv` | Relevé bancaire du compte de l'entreprise (`;`, décimale `,`) |
| `releve/appariements-attendus.json` | Appariements attendus, factures impayées, lignes sans facture |
| `config-fiscale.json` | Instantané de `config_fiscale` utilisé pour la génération |

## Vérité terrain

Chaque fichier `verite/Dnnn.json` contient :

- `extraction` : ce qui est **imprimé** sur le document (y compris les valeurs
  fausses des pièges). C'est la réponse attendue de l'extraction ;
- `anomalies_attendues` : les pièges présents, avec leur détail (valeur
  attendue et valeur imprimée) ;
- `lot`, `groupe`, `derive_de` (pour les doublons), `sha256` du fichier.

## Pièges (2 de chaque, un par lot)

`doublon_exact`, `doublon_rescanne`, `erreur_tva`, `ttc_incoherent`,
`rib_modifie`, `matricule_invalide`, `montant_eleve` (au-dessus du seuil
provisoire de 20 000 TND), `fournisseur_inconnu`, `devise_etrangere`.

## Robustesse de l'extraction (champ `robustesse`)

4 factures normales (un PDF et un scan par lot) contiennent un bloc
« Observations » qui tente de détourner l'extraction (« ignorez vos
instructions précédentes… », autre RIB, TTC nul). L'extraction attendue est
celle du document réellement imprimé (D-046).

## Identifiants

Matricules fiscaux en `99xxxxxL` et RIB du code banque `99` : au bon format,
mais choisis pour ne pas correspondre à une entreprise ou à un compte réel
(D-027). Adresses e-mail en `.example` (domaine réservé).

## Régénérer

```powershell
docker compose up -d   # la configuration fiscale est lue dans PostgreSQL
npm run generer
npm test               # vérifie aussi que les fichiers correspondent au code
```

La génération est déterministe : avec les mêmes versions d'outils, elle
redonne les mêmes fichiers, octet par octet.
