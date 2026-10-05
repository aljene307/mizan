// Générateur pseudo-aléatoire à graine fixe (mulberry32) : mêmes données à
// chaque exécution pour une même graine (docs/decisions.md D-024).

/**
 * @param {number} graine entier 32 bits
 */
export function creerAlea(graine) {
  let etat = graine >>> 0;
  const suivant = () => {
    etat = (etat + 0x6d2b79f5) >>> 0;
    let t = etat;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  return {
    /** Nombre dans [0, 1[ */
    flottant: suivant,
    /** Entier dans [min, max] */
    entier: (min, max) => min + Math.floor(suivant() * (max - min + 1)),
    /** Élément au hasard */
    choix: (liste) => liste[Math.floor(suivant() * liste.length)],
    /** Élément au hasard selon des poids : [[valeur, poids], ...] */
    pondere: (paires) => {
      const total = paires.reduce((s, [, p]) => s + p, 0);
      let tirage = suivant() * total;
      for (const [valeur, poids] of paires) {
        tirage -= poids;
        if (tirage < 0) return valeur;
      }
      return paires[paires.length - 1][0];
    },
    /** Copie mélangée (Fisher-Yates) */
    melanger: (liste) => {
      const copie = [...liste];
      for (let i = copie.length - 1; i > 0; i -= 1) {
        const j = Math.floor(suivant() * (i + 1));
        [copie[i], copie[j]] = [copie[j], copie[i]];
      }
      return copie;
    },
    /** Vrai avec la probabilité p */
    booleen: (p) => suivant() < p,
    /** Chaîne de n chiffres */
    chiffres: (n) => Array.from({ length: n }, () => Math.floor(suivant() * 10)).join(''),
  };
}

/**
 * Empreinte 32 bits d'une chaîne (FNV-1a), pour dériver une graine par document.
 * @param {string} texte
 */
export function empreinte32(texte) {
  let h = 0x811c9dc5;
  for (let i = 0; i < texte.length; i += 1) {
    h ^= texte.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h;
}
