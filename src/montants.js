// Calculs de montants en millimes entiers (1 TND = 1 000 millimes).
// Aucun nombre à virgule flottante dans les calculs : voir docs/decisions.md D-012, D-030.

/**
 * Division entière arrondie à l'entier le plus proche, 0,5 arrondi
 * en s'éloignant de zéro (arrondi arithmétique).
 * @param {bigint} numerateur
 * @param {bigint} denominateur strictement positif
 * @returns {bigint}
 */
export function diviserArrondi(numerateur, denominateur) {
  if (denominateur <= 0n) throw new RangeError('dénominateur strictement positif attendu');
  const signe = numerateur < 0n ? -1n : 1n;
  const absolu = numerateur * signe;
  return signe * ((absolu * 2n + denominateur) / (denominateur * 2n));
}

/**
 * Convertit un montant décimal (nombre ou texte « 1234.5 ») en millimes.
 * Refuse plus de 3 décimales pour ne jamais arrondir en silence.
 * @param {number|string} montant
 * @returns {number} millimes (entier)
 */
export function enMillimes(montant) {
  const texte = typeof montant === 'number' ? montant.toFixed(6) : String(montant).trim();
  const m = /^(-?)(\d+)(?:\.(\d+))?$/.exec(texte);
  if (!m) throw new TypeError(`montant invalide : ${montant}`);
  const decimales = (m[3] ?? '').replace(/0+$/, '');
  if (decimales.length > 3) throw new RangeError(`plus de 3 décimales : ${montant}`);
  const millimes = Number(m[2]) * 1000 + Number(decimales.padEnd(3, '0'));
  return m[1] === '-' ? -millimes : millimes;
}

/**
 * Convertit des millimes en nombre décimal (pour JSON) : 1234500 -> 1234.5
 * @param {number} millimes
 * @returns {number}
 */
export function versDinars(millimes) {
  return Number((millimes / 1000).toFixed(3));
}

/**
 * Montant HT d'une ligne : quantité × prix unitaire, arrondi au millime.
 * @param {number} quantiteMilliemes quantité × 1 000 (ex. 2,5 -> 2500)
 * @param {number} prixUnitaireMillimes
 * @returns {number} millimes
 */
export function montantLigneHt(quantiteMilliemes, prixUnitaireMillimes) {
  return Number(diviserArrondi(BigInt(quantiteMilliemes) * BigInt(prixUnitaireMillimes), 1000n));
}

/**
 * TVA d'un montant HT à un taux en pourcentage (ex. 19 ou 7,5), arrondie au millime.
 * Le taux peut avoir jusqu'à 4 décimales.
 * @param {number} htMillimes
 * @param {number} tauxPourcent
 * @returns {number} millimes
 */
export function montantTva(htMillimes, tauxPourcent) {
  const tauxDixMilliemes = Math.round(tauxPourcent * 10000);
  return Number(diviserArrondi(BigInt(htMillimes) * BigInt(tauxDixMilliemes), 1000000n));
}

/**
 * Formate des millimes pour l'affichage : 1234500 -> « 1 234,500 ».
 * @param {number} millimes
 * @param {{milliers?: string, decimale?: string}} [options]
 * @returns {string}
 */
export function formaterMontant(millimes, { milliers = ' ', decimale = ',' } = {}) {
  const signe = millimes < 0 ? '-' : '';
  const absolu = Math.abs(millimes);
  const entier = String(Math.trunc(absolu / 1000)).replace(/\B(?=(\d{3})+(?!\d))/g, milliers);
  const reste = String(absolu % 1000).padStart(3, '0');
  return `${signe}${entier}${decimale}${reste}`;
}
