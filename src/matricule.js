// Matricule fiscal tunisien.
// Forme courte officielle : 7 chiffres + 1 lettre clé (cahier des charges TEJ,
// ministère des Finances, § 7.1.1.2 : motif \d{7}[A-Z]).
// Forme complète imprimée sur les factures : NNNNNNNL/T/C/EEE (code TVA,
// catégorie, établissement) — sources secondaires uniquement.
// La lettre clé n'est pas vérifiée : aucun algorithme officiel trouvé (D-027).

const FORME_COURTE = /^\d{7}[A-Z]$/;
const FORME_COMPLETE = /^(\d{7}[A-Z])\/?([A-Z])\/?([A-Z])\/?(\d{3})$/;

/**
 * Majuscules, sans espaces.
 * @param {string} texte
 * @returns {string}
 */
export function normaliserMatricule(texte) {
  return String(texte ?? '').toUpperCase().replace(/\s/g, '');
}

/**
 * Renvoie la forme courte officielle (8 caractères) d'un matricule écrit sous
 * forme courte ou complète, ou null si le format n'est pas reconnu.
 * @param {string} texte
 * @returns {string | null}
 */
export function formeCourteMatricule(texte) {
  const m = normaliserMatricule(texte);
  if (FORME_COURTE.test(m)) return m;
  const complet = FORME_COMPLETE.exec(m);
  return complet ? complet[1] : null;
}

/**
 * Vrai si le format est reconnu (forme courte ou complète).
 * @param {string} texte
 * @returns {boolean}
 */
export function matriculeFormatValide(texte) {
  return formeCourteMatricule(texte) !== null;
}
