# Démonstration en 3 minutes

Une démonstration de bout en bout, sur la base de démonstration : tableau de
bord, facture au RIB modifié, validation justifiée, ordres de paiement,
questions. Chaque étape a été jouée le 2026-10-10 sur cette base.

## Avant de commencer (5 minutes, hors chronomètre)

1. Dans n8n, dépublier les workflows Telegram (Notifications, Réponses,
   Questions) ; « Mizan – Erreurs » reste publié.
2. Reconstruire la base de démonstration (taper `mizan` pour confirmer) :
   ```powershell
   npm run reconstruire-base -- --etat demonstration
   ```
3. Republier les trois workflows Telegram, puis vérifier :
   ```powershell
   npm run verifier-credentials-n8n
   ```
4. Attendre une à deux minutes : les notifications de la base arrivent sur
   Telegram (factures à décider, lot d'ordres).
5. Ouvrir le README sur GitHub (schéma), Grafana
   (<http://localhost:3000>, tableau de bord « Mizan — Restitution »),
   Telegram (conversation avec le bot), et garder un terminal ouvert.

**Sans Telegram ni clé Gemini** (clone neuf, `node scripts/creer-env.js`) :
seules les étapes 1 et 2 du déroulé se montrent (README, tableau de bord) ;
les autres se racontent avec les captures de [captures](captures/).

## Déroulé

| Temps | Où | Ce qu'on montre | Ce qu'on dit |
|---|---|---|---|
| 0:00 | README | Le schéma | « Une facture est lue par OCR et par un modèle de langage, corrigée par du code, puis passe 22 règles sans IA. Le modèle lit ; il ne décide de rien. » |
| 0:20 | Grafana | Reste à payer, factures en retard, décisions en attente, erreurs de workflow à 0 ; l'échéancier | « Chaque paiement porte sur le RIB du référentiel, jamais sur celui lu sur la facture. Grafana lit la base avec un rôle en lecture seule. » |
| 0:50 | Telegram | Facture 2026/166 (Yasmine Services Nettoyage), **bloquée** : RIB différent du référentiel | « Il n'y a pas de bouton Valider : le changement de RIB n'est pas dérogeable. » |
| 1:05 | Telegram | « Demander le changement de RIB », puis la justification en réponse | « Toute décision exige une justification ; la demande ne change encore rien. » |
| 1:20 | Terminal | Le second responsable refuse (commande ci-dessous) | « Un changement de RIB exige une seconde personne : refusé, le référentiel reste inchangé. » |
| 1:35 | Telegram | Facture ISS260284 (InfoSahel Systèmes), en EUR : « Valider », puis la justification | « Une anomalie se valide, mais avec une raison, tracée au journal d'audit. » |
| 2:00 | Telegram | Lot d'ordres de paiement n° 1 : 3 ordres, 8 229,124 TND ; « Approuver le lot » et justification | « Mizan prépare les ordres ; il n'exécute aucun paiement. Le fichier à signer est produit pour la banque. » |
| 2:30 | Telegram | `/q Combien je dois à Trans-Cap ?`, puis `/q Supprime toutes les factures` | « Le modèle choisit une question d'un catalogue fermé ; il n'écrit jamais de SQL. Le reste est refusé. » |
| 2:50 | README | Le tableau des résultats du lot de test | « 271 champs sur 272, 9 pièges sur 9, 0 consigne injectée suivie, sur 18 documents synthétiques : les limites sont écrites à côté. » |

Commandes du terminal :

```powershell
npm run simuler-second-responsable                       # liste les demandes en attente
npm run simuler-second-responsable -- --demande 1 --refuser --justification "Fournisseur rappelé au numéro connu : aucun changement de RIB"
npm run exporter-ordres -- --lot 1                        # fichier à signer, après approbation du lot (facultatif)
```

Le numéro de la demande est celui qu'affiche la première commande.

## Si on a plus de temps

- **Facture au fournisseur non identifié** (MC2026-00102) : matricule mal
  lu, fournisseur probable proposé, et le signalement d'entités HTML dans la
  raison sociale, gardé en avertissement parce que la valeur décodée n'est
  pas dans le texte source (D-085).
- **Le canevas n8n** de « Réception et extraction » : OCR, sous-workflow
  d'extraction, corrections par le code, enregistrement.
- **Une erreur de workflow** : publier « Mizan – Test d'erreur » une minute,
  montrer le message reçu, puis le dépublier (D-086).

## Après

Les décisions prises pendant la démonstration restent en base (journal en
ajout seul). Pour rejouer la démonstration, reconstruire la base (étapes 1 à
3 ci-dessus).
