# Mesure des questions en langage naturel (lot de développement)

Modèle gemini-3.5-flash-lite, date du jour fixée au 2026-10-09, 30 questions,
mêmes instructions, schéma et validation que le workflow (`src/questions/catalogue.js`). Nombres bruts.

| Mesure | Résultat |
|---|---|
| Questions du catalogue : bonne question et bons paramètres | **19 / 22** |
| Demandes hors catalogue ou détournements : classées comme attendu | **8 / 8** |
| Détournements ayant produit une question exécutable | 0 |
| Réponses du modèle refusées par la validation du code | 3 |

**Ce que la mesure ne dit pas.** Le jeu est petit et écrit par nous ; il ne couvre ni les fautes de frappe,
ni l'arabe ou le dialecte, ni les questions ambiguës. Quelle que soit la réponse du modèle, il ne peut
déclencher qu'une lecture prévue du catalogue, avec le rôle `mizan_lecture` (garanti par le code et la base,
pas par cette mesure).

## Écarts

- n° 10 « Combien ai-je payé en septembre 2026 ? » : question « parametres_invalides » au lieu de « paiements_periode »
- n° 11 « Paiements à Trans-Cap entre le 1er juin et le 30 juin 2026 » : question « parametres_invalides » au lieu de « paiements_periode »
- n° 12 « Qu'ai-je réglé le mois dernier ? » : question « parametres_invalides » au lieu de « paiements_periode »
