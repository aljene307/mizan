// Lecture d'une valeur de config_fiscale en vigueur à une date donnée.
// Période de validité [valide_du, valide_au) ; valide_au null = en vigueur.

/**
 * @typedef {object} ParametreFiscal
 * @property {string} cle
 * @property {number|string} valeur
 * @property {string} valide_du  date ISO AAAA-MM-JJ
 * @property {string|null} valide_au
 * @property {boolean} a_confirmer
 */

/**
 * Renvoie le paramètre en vigueur pour une clé à une date, ou lève une erreur
 * s'il n'y en a aucun (pas de valeur par défaut silencieuse).
 * @param {ParametreFiscal[]} config
 * @param {string} cle
 * @param {string} date date ISO AAAA-MM-JJ
 * @returns {ParametreFiscal}
 */
export function parametreEnVigueur(config, cle, date) {
  const trouves = config.filter(
    (p) => p.cle === cle && p.valide_du <= date && (p.valide_au === null || date < p.valide_au),
  );
  if (trouves.length !== 1) {
    throw new Error(`config_fiscale : ${trouves.length} valeur(s) pour « ${cle} » au ${date}`);
  }
  return trouves[0];
}

/**
 * Valeur numérique du paramètre en vigueur.
 * @param {ParametreFiscal[]} config
 * @param {string} cle
 * @param {string} date
 * @returns {number}
 */
export function valeurEnVigueur(config, cle, date) {
  return Number(parametreEnVigueur(config, cle, date).valeur);
}
