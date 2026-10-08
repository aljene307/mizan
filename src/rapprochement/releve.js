// Lecture d'un relevé bancaire CSV (D-065, A1) : séparateur « ; », virgule
// décimale, dates JJ/MM/AAAA, en-tête obligatoire. Renvoie les lignes et les
// soldes ; le contrôle d'intégrité des soldes est refait par la base
// (enregistrer_releve). Aucun import (recopié dans un nœud Code, D-041).

const COLONNES_RELEVE = Object.freeze(['date_operation', 'date_valeur', 'libelle', 'reference', 'debit', 'credit', 'solde']);

/** « 3500,000 » → 3500 ; vide → 0 ; refuse tout autre format. */
function lireMontant(texte, ligne, colonne) {
  const t = String(texte ?? '').trim();
  if (t === '') return 0;
  const m = /^(-?)(\d+)(?:,(\d{1,3}))?$/.exec(t.replace(/\s/g, ''));
  if (!m) throw new Error(`ligne ${ligne}, ${colonne} : montant illisible « ${t} »`);
  return Number(`${m[1]}${m[2]}.${(m[3] ?? '').padEnd(3, '0')}`);
}

/** « 05/01/2026 » → « 2026-01-05 » ; vide → null. */
function lireDate(texte, ligne, colonne) {
  const t = String(texte ?? '').trim();
  if (t === '') return null;
  const m = /^(\d{2})\/(\d{2})\/(\d{4})$/.exec(t);
  if (!m) throw new Error(`ligne ${ligne}, ${colonne} : date illisible « ${t} »`);
  const iso = `${m[3]}-${m[2]}-${m[1]}`;
  const d = new Date(`${iso}T00:00:00Z`);
  if (Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== iso) throw new Error(`ligne ${ligne}, ${colonne} : date impossible « ${t} »`);
  return iso;
}

/**
 * @param {string} texte contenu du fichier CSV
 * @returns {{lignes: object[], date_debut: string, date_fin: string, solde_initial: number|null, solde_final: number|null}}
 */
function lireReleveCsv(texte) {
  const lignesBrutes = String(texte ?? '').replace(/^﻿/, '').split(/\r?\n/).filter((l) => l.trim() !== '');
  if (!lignesBrutes.length) throw new Error('relevé vide');
  const entete = lignesBrutes[0].split(';').map((c) => c.trim().toLowerCase());
  if (entete.join(';') !== COLONNES_RELEVE.join(';')) {
    throw new Error(`en-tête inattendu : « ${lignesBrutes[0]} » (attendu : ${COLONNES_RELEVE.join(';')})`);
  }
  const lignes = lignesBrutes.slice(1).map((brute, i) => {
    const numero = i + 1;
    const c = brute.split(';');
    if (c.length !== COLONNES_RELEVE.length) throw new Error(`ligne ${numero} : ${c.length} colonnes au lieu de ${COLONNES_RELEVE.length}`);
    const debit = lireMontant(c[4], numero, 'débit');
    const credit = lireMontant(c[5], numero, 'crédit');
    if (debit < 0 || credit < 0 || (debit > 0 && credit > 0)) throw new Error(`ligne ${numero} : débit et crédit incohérents`);
    return {
      numero_ligne: numero,
      date_operation: lireDate(c[0], numero, 'date d\'opération'),
      date_valeur: lireDate(c[1], numero, 'date de valeur'),
      libelle: c[2].trim(),
      reference: c[3].trim() || null,
      debit, credit,
      solde: c[6].trim() === '' ? null : lireMontant(c[6], numero, 'solde'),
    };
  });
  if (!lignes.length) throw new Error('relevé sans opération');
  if (lignes.some((l) => !l.date_operation)) throw new Error('date d\'opération manquante');
  const premiere = lignes[0];
  // Solde initial déduit de la première ligne (en millimes, sans flottant).
  const millimes = (v) => Math.round(v * 1000);
  const soldeInitial = premiere.solde === null ? null
    : (millimes(premiere.solde) - millimes(premiere.credit) + millimes(premiere.debit)) / 1000;
  const dates = lignes.map((l) => l.date_operation).sort();
  return {
    lignes, date_debut: dates[0], date_fin: dates.at(-1),
    solde_initial: soldeInitial, solde_final: lignes.at(-1).solde,
  };
}

export { COLONNES_RELEVE, lireMontant, lireDate, lireReleveCsv };
