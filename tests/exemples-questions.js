// Paramètres d'exemple de chaque question du catalogue (D-068, B2), partagés
// par les tests unitaires et d'intégration.
export const EXEMPLES_PARAMETRES = Object.freeze({
  factures_en_retard: {}, tresorerie_prevue: {}, a_traiter: {}, ordres_en_cours: {},
  du_a_un_fournisseur: { fournisseur: 'Trans-Cap' }, echeances_a_venir: { jours: '14' },
  paiements_periode: { date_debut: '2026-09-01', date_fin: '2026-09-30' }, tva_du_mois: { mois: '2026-03' }, etat_facture: { numero: 'ISS260302' },
});
