// Dates ISO (AAAA-MM-JJ) manipulées en UTC pour éviter les effets de fuseau.

/** @param {string} iso */
const versDate = (iso) => new Date(`${iso}T00:00:00Z`);
/** @param {Date} d */
const versIso = (d) => d.toISOString().slice(0, 10);

/**
 * @param {string} iso
 * @param {number} jours
 */
export function ajouterJours(iso, jours) {
  const d = versDate(iso);
  d.setUTCDate(d.getUTCDate() + jours);
  return versIso(d);
}

/**
 * Nombre de jours de a à b (b − a).
 * @param {string} a
 * @param {string} b
 */
export function ecartJours(a, b) {
  return Math.round((versDate(b) - versDate(a)) / 86400000);
}

/** @param {string} a @param {string} b */
export const minDate = (a, b) => (a <= b ? a : b);
/** @param {string} a @param {string} b */
export const maxDate = (a, b) => (a >= b ? a : b);

const MOIS = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet',
  'août', 'septembre', 'octobre', 'novembre', 'décembre'];

/**
 * @param {string} iso
 * @param {'jj/mm/aaaa'|'long'|'iso'|'jj-mm-aaaa'} style
 */
export function formaterDate(iso, style) {
  const [a, m, j] = iso.split('-');
  switch (style) {
    case 'long': return `${Number(j)} ${MOIS[Number(m) - 1]} ${a}`;
    case 'iso': return iso;
    case 'jj-mm-aaaa': return `${j}-${m}-${a}`;
    default: return `${j}/${m}/${a}`;
  }
}

/** @param {string} iso */
export const nomMois = (iso) => MOIS[Number(iso.slice(5, 7)) - 1];
