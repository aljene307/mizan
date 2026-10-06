// Comparaison d'une extraction avec la vérité terrain, selon la règle D-050.
// Deux scores : strict (caractère pour caractère, sauf égalité numérique) et
// normalisé (noms, adresses et désignations insensibles à la casse et aux
// espaces multiples). Aucune dépendance.

const CHAMPS_ENTETE = [
  { chemin: 'type_document', type: 'code' },
  { chemin: 'numero', type: 'identifiant' },
  { chemin: 'date_facture', type: 'date' },
  { chemin: 'date_echeance', type: 'date' },
  { chemin: 'devise', type: 'code' },
  { chemin: 'fournisseur.raison_sociale', type: 'texte' },
  { chemin: 'fournisseur.matricule_fiscal', type: 'identifiant' },
  { chemin: 'fournisseur.adresse', type: 'texte' },
  { chemin: 'fournisseur.rib', type: 'identifiant' },
  { chemin: 'client.raison_sociale', type: 'texte' },
  { chemin: 'client.matricule_fiscal', type: 'identifiant' },
  { chemin: 'montant_ht', type: 'nombre' },
  { chemin: 'montant_tva', type: 'nombre' },
  { chemin: 'droit_timbre', type: 'nombre' },
  { chemin: 'montant_ttc', type: 'nombre' },
  { chemin: 'facture_origine_numero', type: 'identifiant' },
];

const CHAMPS_LIGNE = [
  { chemin: 'designation', type: 'texte' },
  { chemin: 'quantite', type: 'nombre' },
  { chemin: 'prix_unitaire_ht', type: 'nombre' },
  { chemin: 'taux_tva', type: 'nombre' },
  { chemin: 'montant_ht', type: 'nombre' },
];

const lireChemin = (objet, chemin) => chemin.split('.').reduce((o, cle) => (o == null ? undefined : o[cle]), objet);

/** Casse et espaces multiples ignorés, accents conservés (D-050). */
function normaliserTexte(texte) {
  return String(texte).normalize('NFC').toLocaleLowerCase('fr').replace(/\s+/g, ' ').trim();
}

/**
 * @param {'code'|'identifiant'|'date'|'nombre'|'texte'} type
 * @returns {{strict: boolean, normalise: boolean}}
 */
function comparerValeur(type, extrait, attendu) {
  const absentE = extrait === null || extrait === undefined;
  const absentA = attendu === null || attendu === undefined;
  if (absentE || absentA) {
    const egal = absentE && absentA;
    return { strict: egal, normalise: egal };
  }
  if (type === 'nombre') {
    const egal = typeof extrait === 'number' && typeof attendu === 'number' && extrait === attendu;
    return { strict: egal, normalise: egal };
  }
  const strict = typeof extrait === 'string' && extrait === attendu;
  if (type !== 'texte') return { strict, normalise: strict };
  return { strict, normalise: typeof extrait === 'string' && normaliserTexte(extrait) === normaliserTexte(attendu) };
}

/**
 * Compare une extraction (ou null si aucune donnée) avec la vérité terrain.
 * @returns {{entete: object[], lignes: {attendues: number, extraites: number, enTrop: number,
 *   exactesStrict: number, exactesNormalise: number, champs: object[]}}}
 */
function comparerExtraction(donnees, verite) {
  // Sans donnée (extraction en erreur), tous les champs sont faux, y compris
  // ceux dont la valeur attendue est null.
  const faux = { strict: false, normalise: false };
  const entete = CHAMPS_ENTETE.map(({ chemin, type }) => {
    const extrait = donnees ? lireChemin(donnees, chemin) : undefined;
    const attendu = lireChemin(verite, chemin);
    return { chemin, type, extrait, attendu, ...(donnees ? comparerValeur(type, extrait, attendu) : faux) };
  });
  const attendues = verite.lignes ?? [];
  const extraites = donnees?.lignes ?? [];
  const champs = [];
  let exactesStrict = 0;
  let exactesNormalise = 0;
  attendues.forEach((ligneAttendue, i) => {
    const ligneExtraite = extraites[i];
    const resultats = CHAMPS_LIGNE.map(({ chemin, type }) => {
      const extrait = ligneExtraite ? ligneExtraite[chemin] : undefined;
      return { chemin: `lignes.${chemin}`, type, extrait, attendu: ligneAttendue[chemin], ...comparerValeur(type, extrait, ligneAttendue[chemin]) };
    });
    champs.push(...resultats);
    if (resultats.every((r) => r.strict)) exactesStrict += 1;
    if (resultats.every((r) => r.normalise)) exactesNormalise += 1;
  });
  return {
    entete,
    lignes: {
      attendues: attendues.length,
      extraites: extraites.length,
      enTrop: Math.max(0, extraites.length - attendues.length),
      exactesStrict,
      exactesNormalise,
      champs,
    },
  };
}

export { CHAMPS_ENTETE, CHAMPS_LIGNE, normaliserTexte, comparerValeur, comparerExtraction };
