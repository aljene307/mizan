// RIB tunisien : 20 chiffres = banque (2) + agence (3) + compte (13) + clé (2).
// Clé = 97 − ((18 premiers chiffres × 100) mod 97). Sources : docs/decisions.md D-027.

/**
 * Supprime espaces, tirets et points d'un RIB saisi ou lu par OCR.
 * @param {string} texte
 * @returns {string}
 */
export function normaliserRib(texte) {
  return String(texte ?? '').replace(/[\s.\-]/g, '');
}

/**
 * Calcule la clé de contrôle (2 chiffres) à partir des 18 premiers chiffres.
 * @param {string} dixHuitChiffres
 * @returns {string}
 */
export function cleRib(dixHuitChiffres) {
  if (!/^\d{18}$/.test(dixHuitChiffres)) throw new TypeError('18 chiffres attendus');
  const cle = 97n - (BigInt(dixHuitChiffres + '00') % 97n);
  return String(cle).padStart(2, '0');
}

/**
 * Vrai si le texte est un RIB de 20 chiffres dont la clé est correcte.
 * @param {string} texte
 * @returns {boolean}
 */
export function ribValide(texte) {
  const rib = normaliserRib(texte);
  return /^\d{20}$/.test(rib) && cleRib(rib.slice(0, 18)) === rib.slice(18);
}

/**
 * Découpe un RIB valide en ses composantes.
 * @param {string} texte
 * @returns {{banque: string, agence: string, compte: string, cle: string} | null}
 */
export function decomposerRib(texte) {
  const rib = normaliserRib(texte);
  if (!ribValide(rib)) return null;
  return { banque: rib.slice(0, 2), agence: rib.slice(2, 5), compte: rib.slice(5, 18), cle: rib.slice(18) };
}

/**
 * Présentation usuelle en groupes : « 99 123 1234567890123 45 ».
 * @param {string} texte
 * @returns {string}
 */
export function formaterRib(texte) {
  const rib = normaliserRib(texte);
  return `${rib.slice(0, 2)} ${rib.slice(2, 5)} ${rib.slice(5, 18)} ${rib.slice(18)}`;
}
