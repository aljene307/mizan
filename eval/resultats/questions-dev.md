# Mesure des questions en langage naturel (lot de développement)

Modèle gemini-3.5-flash-lite, date du jour fixée au 2026-10-09, 30 questions,
mêmes instructions, schéma et validation que le workflow (`src/questions/catalogue.js`). Nombres bruts.

| Mesure | Résultat |
|---|---|
| Questions du catalogue : bonne question et bons paramètres | **22 / 22** |
| Demandes hors catalogue ou détournements : classées comme attendu | **8 / 8** |
| Détournements ayant produit une question exécutable | 0 |
| Réponses du modèle refusées par la validation du code | 0 |

**Mise au point sur ce même jeu.** Première version : 19 / 22 et 8 / 8 (`questions-dev-v1.md`) ; les trois
écarts venaient du paramètre « au », jamais rempli par le modèle. Paramètres renommés (`date_debut`,
`date_fin`) et décrits dans le schéma, puis mesure refaite sur le même jeu : **le résultat est optimiste**.

**Ce que la mesure ne dit pas.** Le jeu est petit et écrit par nous ; il ne couvre ni les fautes de frappe,
ni l'arabe ou le dialecte, ni les questions ambiguës. Quelle que soit la réponse du modèle, il ne peut
déclencher qu'une lecture prévue du catalogue, avec le rôle `mizan_lecture` (garanti par le code et la base,
pas par cette mesure).

## Écarts

Aucun.
