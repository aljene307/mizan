# Contrôles : test par mutation sur la vérité terrain (lot de développement)

Sans LLM. Chaque mutation est appliquée, une à une, aux 33 factures sans piège ; on compare les alertes à celles de la même facture non modifiée. **Détecté** : la règle prévue lève une alerte nouvelle. **Accepté** : aucune alerte nouvelle, quelle que soit la règle.

Tolérances (table parametres_controle) : TTC 0 millime ; TVA 1 millime par ligne au taux ; ligne 1 millime. Date de référence : 2026-10-06. Nombres bruts.

| Erreur | Cas | Attendu | Conformes | Autres règles déclenchées (factures) |
|---|---|---|---|---|
| TVA | écart égal à la tolérance (1 millime par ligne) | accepté | 33 / 33 | — |
| TVA | tolérance + 1 millime | détecté par coherence_tva | 33 / 33 | — |
| TVA | TVA + 1,000 TND | détecté par coherence_tva | 33 / 33 | — |
| TTC | écart égal à la tolérance (0 millime) | accepté | 33 / 33 | — |
| TTC | tolérance + 1 millime | détecté par coherence_ttc | 33 / 33 | — |
| TTC | TTC − 1,000 TND | détecté par coherence_ttc | 33 / 33 | — |
| Ligne | écart égal à la tolérance (1 millime), HT et TTC ajustés | accepté | 33 / 33 | — |
| Ligne | tolérance + 1 millime, HT et TTC ajustés | détecté par coherence_lignes | 33 / 33 | — |
| Ligne | montant de ligne + 1,000 TND, HT non ajusté | détecté par coherence_lignes | 33 / 33 | coherence_tva (33) |
| RIB | autre RIB valide, inconnu du référentiel | détecté par changement_rib | 33 / 33 | — |
| RIB | RIB valide d'un autre fournisseur du référentiel | détecté par changement_rib | 33 / 33 | incoherence_identite (33) |
| Matricule | un chiffre supprimé | détecté par matricule_format | 33 / 33 | fournisseur_inconnu (33), matricule_lecture_probable (33) |
| Matricule | lettre clé supprimée | détecté par matricule_format | 33 / 33 | fournisseur_inconnu (33), matricule_lecture_probable (33) |
| Matricule | un chiffre remplacé (format valide, matricule inconnu) | détecté par fournisseur_inconnu | 33 / 33 | matricule_lecture_probable (33), avoir_origine (1) |
| Date | échéance la veille de la date de facture | détecté par dates | 33 / 33 | — |
| Date | échéance le jour de la facture (limite) | accepté | 33 / 33 | — |
| Date | date de facture au lendemain de la date de référence | détecté par dates | 33 / 33 | — |
| Date | date de facture égale à la date de référence (limite) | accepté | 33 / 33 | — |

**Total : 594 / 594 mutations conformes à l'attendu.**

« Autres règles déclenchées » : alertes nouvelles levées en plus de la règle prévue (par exemple, un RIB d'un autre fournisseur révèle aussi une incohérence d'identité). Elles ne comptent pas comme des échecs pour une mutation « détecté ».
