// Éléments partagés par les mesures des contrôles sur la vérité terrain
// (eval/evaluer-controles.js, eval/mutations-controles.js) : contextes des
// règles construits depuis data/synthetic, configuration lue en base.
// Lot de développement par défaut ; le lot de test n'est lu que sur demande
// explicite (lireVerites('test')), à l'étape 8 seulement (D-026, D-082).
import { existsSync, readFileSync } from 'node:fs';
import pg from 'pg';
import { normaliserNumero } from '../src/controles/regles.js';
import { enMillimes, diviserArrondi, montantTva } from '../src/montants.js';
import { formeCourteMatricule, normaliserMatricule } from '../src/matricule.js';
import { ribValide } from '../src/rib.js';

export const deps = { enMillimes, diviserArrondi, montantTva, formeCourteMatricule, normaliserMatricule, ribValide };
// Date de référence fixe, pour un rapport reproductible (règle « dates »).
export const DATE_REFERENCE = '2026-10-06';
// Piège → règle prévue pour le détecter, et statut attendu.
export const ATTENDU = Object.freeze({
  erreur_tva: { regle: 'coherence_tva', statut: 'bloquee' },
  ttc_incoherent: { regle: 'coherence_ttc', statut: 'bloquee' },
  rib_modifie: { regle: 'changement_rib', statut: 'bloquee' },
  matricule_invalide: { regle: 'matricule_format', statut: 'bloquee' },
  fournisseur_inconnu: { regle: 'fournisseur_inconnu', statut: 'bloquee' },
  montant_eleve: { regle: 'seuil_validation', statut: 'a_valider' },
  devise_etrangere: { regle: 'devise', statut: 'anomalie' },
  doublon_exact: { regle: 'doublon_fichier', statut: 'bloquee' },
  doublon_rescanne: { regle: 'doublon_numero', statut: 'bloquee' },
});
export const REGLES_DOUBLON = new Set(['doublon_fichier', 'doublon_numero', 'doublon_probable']);
export const alerte = (r) => (r.resultat === 'anomalie' || r.resultat === 'erreur') && r.gravite !== 'info';

/** Configuration fiscale, paramètres de contrôle et catalogue, lus en base (mizan_app, lecture seule). */
export async function lireConfiguration() {
  if (existsSync('.env')) process.loadEnvFile('.env');
  const client = new pg.Client({
    host: 'localhost', port: 5432, user: 'mizan_app', password: process.env.MIZAN_APP_PASSWORD, database: process.env.MIZAN_DB ?? 'mizan',
  });
  await client.connect();
  try {
    const config = (await client.query('SELECT cle, valeur, unite, conditions, a_confirmer, valide_du::text, valide_au::text FROM config_fiscale')).rows;
    const parametres = (await client.query('SELECT parametres_controle_en_vigueur($1::date) AS p', [DATE_REFERENCE])).rows[0].p;
    const regles = (await client.query('SELECT regle, derogeable FROM regles_controle WHERE actif ORDER BY regle')).rows;
    return { config, parametres, regles };
  } finally {
    await client.end();
  }
}

const configA = (config, date) => Object.fromEntries(config
  .filter((c) => c.valide_du <= date && (c.valide_au === null || date < c.valide_au))
  .map((c) => [c.cle, { valeur: Number(c.valeur), unite: c.unite, conditions: c.conditions, a_confirmer: c.a_confirmer }]));

const lots = JSON.parse(readFileSync('data/synthetic/lots.json', 'utf8'));
const referentielJson = JSON.parse(readFileSync('data/synthetic/referentiel/fournisseurs.json', 'utf8'));
export const referentiel = referentielJson.map((f, i) => ({
  id: i + 1, raison_sociale: f.raison_sociale, matricule_fiscal: f.matricule_fiscal, actif: true,
  ribs: [{ rib: f.rib, valide_du: '2026-01-01', valide_au: null }],
}));
/** Vérité terrain d'un lot (« test » : étape 8 seulement, appelé par un script qui l'exige). */
export function lireVerites(lot) {
  if (!['dev', 'test'].includes(lot)) throw new Error(`lot inconnu : ${lot}`);
  return lots[lot].map((d) => JSON.parse(readFileSync(`data/synthetic/${lot}/verite/${d.id}.json`, 'utf8')));
}
export const verites = lireVerites('dev');
// Ordre de réception : celui des identifiants (comme le dépôt des fichiers par nom).
const idNum = (v) => Number(v.id.replace(/\D/g, ''));

function facture(v) {
  const e = v.extraction;
  return {
    id: idNum(v), type_document: e.type_document, numero: e.numero, numero_normalise: normaliserNumero(e.numero),
    date_facture: e.date_facture, date_echeance: e.date_echeance, devise: e.devise,
    montant_ht: e.montant_ht, montant_tva: e.montant_tva, droit_timbre: e.droit_timbre, montant_ttc: e.montant_ttc,
    matricule_fiscal_lu: e.fournisseur.matricule_fiscal, raison_sociale_lue: e.fournisseur.raison_sociale,
    rib_facture: e.fournisseur.rib, fichier_sha256: v.sha256, facture_origine_numero: e.facture_origine_numero,
    fournisseur_id: null, fournisseur_source: null, statut: 'extraite',
  };
}

/**
 * Contexte des règles pour un document de la vérité terrain (comme contexte_controles()).
 * @param {object[]} [lot] documents du même lot (autres factures) : lot de développement par défaut.
 */
export function contexte(v, conf, lot = verites) {
  const f = facture(v);
  return {
    aujourd_hui: DATE_REFERENCE,
    facture: f,
    lignes: v.extraction.lignes.map((l, i) => ({ numero_ligne: i + 1, ...l })),
    extraction: null,
    referentiel,
    autres_factures: lot.filter((o) => o.id !== v.id).map(facture),
    config_fiscale: configA(conf.config, f.date_facture),
    parametres: conf.parametres,
    regles: conf.regles,
  };
}
