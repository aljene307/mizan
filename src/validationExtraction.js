// Validation d'une extraction, sans dépendance : ce fichier est recopié tel
// quel dans un nœud Code de n8n, qui ne peut pas importer de module (D-041).
// 1. validerSchema : interprète le sous-ensemble de JSON Schema (2020-12)
//    utilisé par src/schemas/extraction-facture.schema.json. Un mot-clé
//    inconnu lève une erreur au lieu d'être ignoré en silence.
// 2. verifierCompatibiliteBase : contrôles que le schéma ne peut pas exprimer
//    mais qu'exigent les colonnes PostgreSQL (décimales, ordres de grandeur).

const MOTS_CLES_ANNOTATION = new Set(['$schema', '$id', 'title', 'description']);
const MOTS_CLES_GERES = new Set([
  'type', 'enum', 'pattern', 'minLength', 'format', 'properties', 'required',
  'additionalProperties', 'items', 'minItems', 'minimum', 'maximum', 'exclusiveMinimum',
]);

function typeJson(valeur) {
  if (valeur === null) return 'null';
  if (Array.isArray(valeur)) return 'array';
  if (typeof valeur === 'number') return Number.isInteger(valeur) ? 'integer' : 'number';
  return typeof valeur;
}

function correspondAuType(valeur, attendu) {
  const reel = typeJson(valeur);
  if (attendu === 'number') return reel === 'number' || reel === 'integer';
  return reel === attendu;
}

// Date calendaire réelle au format AAAA-MM-JJ (comme le format « date » d'ajv-formats).
function estDateValide(texte) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(texte);
  if (!m) return false;
  const annee = Number(m[1]);
  const mois = Number(m[2]);
  const jour = Number(m[3]);
  if (mois < 1 || mois > 12 || jour < 1) return false;
  const bissextile = (annee % 4 === 0 && annee % 100 !== 0) || annee % 400 === 0;
  const joursParMois = [31, bissextile ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return jour <= joursParMois[mois - 1];
}

/**
 * Valide une valeur contre un schéma ; renvoie la liste des erreurs (vide si valide).
 * @param {object} schema
 * @param {unknown} valeur
 * @param {string} [chemin]
 * @returns {string[]}
 */
function validerSchema(schema, valeur, chemin = '') {
  for (const cle of Object.keys(schema)) {
    if (!MOTS_CLES_GERES.has(cle) && !MOTS_CLES_ANNOTATION.has(cle)) {
      throw new Error(`mot-clé de schéma non pris en charge : ${cle} (${chemin || '/'})`);
    }
  }
  const ici = chemin || '/';
  const erreurs = [];

  if (schema.type !== undefined) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (!types.some((t) => correspondAuType(valeur, t))) {
      return [`${ici} doit être de type ${types.join(' ou ')}`];
    }
  }
  if (schema.enum !== undefined && !schema.enum.some((v) => v === valeur)) {
    erreurs.push(`${ici} doit valoir ${schema.enum.join(', ')}`);
  }

  if (typeof valeur === 'string') {
    if (schema.minLength !== undefined && [...valeur].length < schema.minLength) {
      erreurs.push(`${ici} doit contenir au moins ${schema.minLength} caractère(s)`);
    }
    if (schema.pattern !== undefined && !new RegExp(schema.pattern, 'u').test(valeur)) {
      erreurs.push(`${ici} ne respecte pas le motif ${schema.pattern}`);
    }
    if (schema.format !== undefined) {
      if (schema.format !== 'date') throw new Error(`format non pris en charge : ${schema.format}`);
      if (!estDateValide(valeur)) erreurs.push(`${ici} doit être une date AAAA-MM-JJ valide`);
    }
  }

  if (typeof valeur === 'number') {
    if (schema.minimum !== undefined && valeur < schema.minimum) erreurs.push(`${ici} doit être ≥ ${schema.minimum}`);
    if (schema.maximum !== undefined && valeur > schema.maximum) erreurs.push(`${ici} doit être ≤ ${schema.maximum}`);
    if (schema.exclusiveMinimum !== undefined && valeur <= schema.exclusiveMinimum) {
      erreurs.push(`${ici} doit être > ${schema.exclusiveMinimum}`);
    }
  }

  if (Array.isArray(valeur)) {
    if (schema.minItems !== undefined && valeur.length < schema.minItems) {
      erreurs.push(`${ici} doit contenir au moins ${schema.minItems} élément(s)`);
    }
    if (schema.items !== undefined) {
      valeur.forEach((element, i) => erreurs.push(...validerSchema(schema.items, element, `${chemin}/${i}`)));
    }
  }

  if (typeJson(valeur) === 'object') {
    const proprietes = schema.properties ?? {};
    for (const requise of schema.required ?? []) {
      if (!Object.hasOwn(valeur, requise)) erreurs.push(`${ici} doit contenir la propriété « ${requise} »`);
    }
    for (const [cle, sousValeur] of Object.entries(valeur)) {
      if (Object.hasOwn(proprietes, cle)) {
        erreurs.push(...validerSchema(proprietes[cle], sousValeur, `${chemin}/${cle}`));
      } else if (schema.additionalProperties === false) {
        erreurs.push(`${ici} contient une propriété non prévue : « ${cle} »`);
      }
    }
  }
  return erreurs;
}

// Nombre de décimales d'un nombre JSON (null si notation exponentielle).
function nombreDecimales(nombre) {
  const texte = String(nombre);
  if (/e/i.test(texte)) return null;
  const point = texte.indexOf('.');
  return point === -1 ? 0 : texte.length - point - 1;
}

/**
 * Contrôles imposés par les colonnes PostgreSQL : NUMERIC(15,3) pour les
 * montants, NUMERIC(18,6) pour quantités et prix, NUMERIC(7,4) pour les taux.
 * À n'appeler que sur une extraction conforme au schéma.
 * @param {object} donnees
 * @returns {string[]}
 */
function verifierCompatibiliteBase(donnees) {
  const erreurs = [];
  const verifier = (valeur, chemin, decimalesMax, limite) => {
    if (valeur === null || valeur === undefined) return;
    const decimales = nombreDecimales(valeur);
    if (decimales === null || decimales > decimalesMax) {
      erreurs.push(`${chemin} a plus de ${decimalesMax} décimales`);
    }
    if (Math.abs(valeur) >= limite) erreurs.push(`${chemin} dépasse la capacité de la colonne`);
  };
  for (const champ of ['montant_ht', 'montant_tva', 'droit_timbre', 'montant_ttc']) {
    verifier(donnees[champ], `/${champ}`, 3, 1e12);
  }
  (donnees.lignes ?? []).forEach((ligne, i) => {
    verifier(ligne.quantite, `/lignes/${i}/quantite`, 6, 1e12);
    verifier(ligne.prix_unitaire_ht, `/lignes/${i}/prix_unitaire_ht`, 6, 1e12);
    verifier(ligne.taux_tva, `/lignes/${i}/taux_tva`, 4, 1e3);
    verifier(ligne.montant_ht, `/lignes/${i}/montant_ht`, 3, 1e12);
  });
  return erreurs;
}

/**
 * Validation complète : schéma strict, puis compatibilité avec la base.
 * @param {object} schema
 * @param {unknown} donnees
 * @returns {{valide: boolean, erreurs: string[]}}
 */
function validerExtraction(schema, donnees) {
  const erreursSchema = validerSchema(schema, donnees);
  const erreurs = erreursSchema.length ? erreursSchema : verifierCompatibiliteBase(donnees);
  return { valide: erreurs.length === 0, erreurs };
}

export { validerSchema, verifierCompatibiliteBase, validerExtraction, estDateValide };
