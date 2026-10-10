// Construit le tableau de bord Grafana (D-068, A1) : grafana/dashboards/mizan-restitution.json.
// Une seule source de données, « mizan-lecture » (rôle mizan_lecture, D-070) ;
// les requêtes ne lisent que les vues du schéma restitution (search_path du
// rôle). Requête SQL : clés du type SQLQuery de Grafana 13.2.3
// (packages/grafana-sql/src/types.ts : rawSql, format, rawQuery, editorMode ;
// EditorMode.Code = 'code', @grafana/plugin-ui).
// Usage : node scripts/construire-tableau-de-bord.js
import { writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export const SOURCE = Object.freeze({ type: 'grafana-postgresql-datasource', uid: 'mizan-lecture' });
const TND = { unit: 'suffix: TND', decimals: 3 };

let prochainId = 0;
const requete = (rawSql, format = 'table') => ({ refId: 'A', datasource: SOURCE, rawSql: rawSql.trim(), format, rawQuery: true, editorMode: 'code' });
// montants : colonnes affichées en TND au millime (les autres colonnes numériques restent brutes).
const panneau = (type, titre, [x, y, w, h], sql, { description, unites = {}, options = {}, montants = [] } = {}) => {
  prochainId += 1;
  return {
    id: prochainId, type, title: titre, description, gridPos: { x, y, w, h }, datasource: SOURCE,
    targets: sql ? [requete(sql)] : [],
    fieldConfig: {
      defaults: { ...unites },
      overrides: montants.map((nom) => ({ matcher: { id: 'byName', options: nom },
        properties: [{ id: 'unit', value: TND.unit }, { id: 'decimals', value: TND.decimals }] })),
    },
    options,
  };
};
// Chiffre clé sans couleur de seuil (un seuil arbitraire n'aurait pas de sens ici).
const STAT = { colorMode: 'none', graphMode: 'none' };

export function tableauDeBord() {
  prochainId = 0;
  const panels = [
    panneau('text', 'À lire', [0, 0, 24, 3], null, { options: { mode: 'markdown', content:
      '**Données synthétiques.** Paiements toujours sur le RIB du référentiel (D-058). '
      + 'Trésorerie : sorties connues seulement (factures approuvées en TND), sans encaissements ni salaires prévus. '
      + 'TVA : montants **figurant sur les factures** approuvées, **pas la TVA déductible** (règles fiscales non codées, D-020).' } }),
    panneau('stat', 'Reste à payer (TND)', [0, 3, 5, 4], `
SELECT coalesce(sum(reste_a_payer - paiement_propose), 0) AS "Reste à payer" FROM echeancier WHERE devise = 'TND'`, { unites: TND, options: STAT,
      description: 'Factures approuvées en TND, hors paiements déjà au relevé en attente de confirmation.' }),
    panneau('stat', 'Factures en retard', [5, 3, 5, 4], `
SELECT count(*) AS "En retard" FROM echeancier WHERE en_retard`, { options: STAT }),
    panneau('stat', 'Paiements au relevé à confirmer', [10, 3, 5, 4], `
SELECT count(*) AS "Paiement proposé" FROM echeancier WHERE etat = 'paiement_propose'`, { options: STAT }),
    panneau('stat', 'Décisions en attente', [15, 3, 4, 4], `
SELECT count(*) AS "À traiter" FROM a_traiter`, { options: STAT }),
    panneau('stat', 'Solde du dernier relevé (TND)', [19, 3, 5, 4], `
SELECT solde_final AS "Solde" FROM releves WHERE devise = 'TND' ORDER BY date_fin DESC, releve_id DESC LIMIT 1`, { unites: TND, options: STAT }),
    panneau('table', 'Échéancier', [0, 7, 14, 10], `
SELECT numero AS "Facture", fournisseur AS "Fournisseur", to_char(date_echeance, 'YYYY-MM-DD') AS "Échéance",
       reste_a_payer AS "Reste à payer", paiement_propose AS "Au relevé, à confirmer",
       etat AS "État", jours_de_retard AS "Jours de retard", rib_paiement AS "RIB de paiement (référentiel)"
FROM echeancier ORDER BY en_retard DESC, date_echeance NULLS LAST, numero`, { montants: ['Reste à payer', 'Au relevé, à confirmer'] }),
    panneau('table', 'Trésorerie prévue par semaine', [14, 7, 10, 10], `
SELECT to_char(semaine, 'YYYY-MM-DD') AS "Semaine du", factures AS "Factures", sorties_prevues AS "Sorties prévues",
       solde_prevu_fin_semaine AS "Solde prévu en fin de semaine"
FROM tresorerie_prevue ORDER BY semaine`, { montants: ['Sorties prévues', 'Solde prévu en fin de semaine'],
      description: 'Dernier solde du relevé, moins les échéances des factures approuvées en TND. Ni encaissements, ni salaires, ni loyer prévus.' }),
    panneau('table', 'À traiter', [0, 17, 12, 9], `
SELECT type AS "Type", objet AS "Objet", fournisseur AS "Fournisseur", montant AS "Montant", detail AS "Détail",
       to_char(depuis, 'YYYY-MM-DD') AS "Depuis"
FROM a_traiter ORDER BY depuis`, { montants: ['Montant'] }),
    panneau('table', 'Ordres de paiement', [12, 17, 12, 9], `
SELECT lot_id AS "Lot", statut_lot AS "Statut du lot", numero AS "Facture", beneficiaire AS "Bénéficiaire",
       montant AS "Montant", reste_a_executer AS "Reste à exécuter", rib_paiement AS "RIB (référentiel)"
FROM ordres_paiement ORDER BY lot_id DESC, ordre_id`, { montants: ['Montant', 'Reste à exécuter'] }),
    panneau('barchart', 'TVA figurant sur les factures approuvées, par mois (TND)', [0, 26, 12, 9], `
SELECT to_char(mois, 'YYYY-MM') AS "Mois",
       sum(montant_tva) FILTER (WHERE type_document = 'facture') AS "TVA des factures",
       coalesce(sum(montant_tva) FILTER (WHERE type_document = 'avoir'), 0) AS "TVA des avoirs"
FROM tva_factures WHERE devise = 'TND' GROUP BY mois ORDER BY mois`, { unites: TND,
      description: 'Montants imprimés sur les documents approuvés. Ce n\'est pas la TVA déductible : la déductibilité relève des textes officiels (D-020, D-068).' }),
    panneau('table', 'Derniers paiements confirmés', [12, 26, 12, 9], `
SELECT to_char(date_operation, 'YYYY-MM-DD') AS "Date", numero AS "Facture", fournisseur AS "Fournisseur", montant AS "Montant",
       cas AS "Cas", methode AS "Méthode"
FROM paiements ORDER BY "Date" DESC, numero LIMIT 20`, { montants: ['Montant'] }),
  ];
  return {
    uid: 'mizan-restitution', title: 'Mizan — Restitution', tags: ['mizan'], editable: false,
    timezone: 'browser', refresh: '5m', time: { from: 'now-30d', to: 'now' },
    schemaVersion: 39, version: 1, panels,
  };
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  writeFileSync('grafana/dashboards/mizan-restitution.json', `${JSON.stringify(tableauDeBord(), null, 2)}\n`);
  console.log('grafana/dashboards/mizan-restitution.json écrit.');
}
