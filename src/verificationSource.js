// Contrôle déterministe (D-047) : chaque identifiant extrait doit figurer tel
// quel dans le texte source (texte du PDF ou texte reconnu par l'OCR). Un
// identifiant absent signale une extraction suspecte : valeur inventée,
// modifiée, ou reprise d'une consigne injectée.
// Recopié dans un nœud Code (D-041) : aucun import.

// L'identifiant doit apparaître EN ENTIER : des espaces sont tolérés entre
// ses caractères (le texte peut couper un identifiant sur plusieurs blocs) ;
// pour le RIB, aussi des points et des tirets, car le prompt demande les
// chiffres sans séparateurs. Il ne doit être ni précédé ni suivi d'une lettre
// ou d'un chiffre : un identifiant tronqué n'est pas accepté. Sensible à la casse.
const ESPACES = '\\s*';
const SEPARATEURS_RIB = '[\\s.\\-]*';

// Frontières. Texte (numéro, matricule) : seul le caractère immédiatement
// voisin compte — une lettre, un chiffre, ou un caractère de liaison (- / . _)
// collé à une lettre ou un chiffre prolongerait l'identifiant (« FA-2026 »
// dans « FA-2026-0157 »). On ne saute pas les espaces : le mot suivant d'une
// phrase n'est pas la suite de l'identifiant.
// RIB (chiffres) : aucun chiffre ne doit le prolonger, même au-delà des
// séparateurs (un RIB de 18 chiffres suivi de « 65 » n'est pas le RIB imprimé),
// mais sans franchir un retour à la ligne : la ligne suivante peut commencer
// par un chiffre (« 8, rue Ibn Khaldoun… ») sans prolonger le RIB.
const FRONTIERES_TEXTE = {
  avant: '(?<![\\p{L}\\p{N}]|[\\p{L}\\p{N}][\\-/._])',
  apres: '(?![\\p{L}\\p{N}]|[\\-/._][\\p{L}\\p{N}])',
};
const FRONTIERES_RIB = {
  avant: '(?<!\\p{N}[ \\t.\\-]*)',
  apres: '(?![ \\t.\\-]*\\p{N})',
};

const IDENTIFIANTS = [
  { champ: 'numero', lire: (d) => d.numero, entre: ESPACES, frontieres: FRONTIERES_TEXTE },
  { champ: 'fournisseur.matricule_fiscal', lire: (d) => d.fournisseur?.matricule_fiscal, entre: ESPACES, frontieres: FRONTIERES_TEXTE },
  { champ: 'fournisseur.rib', lire: (d) => d.fournisseur?.rib, entre: SEPARATEURS_RIB, frontieres: FRONTIERES_RIB },
  { champ: 'client.matricule_fiscal', lire: (d) => d.client?.matricule_fiscal, entre: ESPACES, frontieres: FRONTIERES_TEXTE },
  { champ: 'facture_origine_numero', lire: (d) => d.facture_origine_numero, entre: ESPACES, frontieres: FRONTIERES_TEXTE },
];

const echapperRegex = (c) => c.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// Expression qui reconnaît la valeur entière, séparateurs tolérés entre ses
// caractères, encadrée par les frontières du champ.
function motif(valeur, entre, frontieres) {
  const caracteres = [...String(valeur).replace(/\s+/g, '')].map(echapperRegex);
  return new RegExp(`${frontieres.avant}${caracteres.join(entre)}${frontieres.apres}`, 'u');
}

/**
 * @param {object} donnees extraction conforme au schéma
 * @param {string} texteSource texte transmis au LLM
 * @returns {{champ: string, valeur: string, present: boolean}[]} identifiants non nuls vérifiés
 */
function verifierIdentifiantsDansSource(donnees, texteSource) {
  const resultats = [];
  for (const { champ, lire, entre, frontieres } of IDENTIFIANTS) {
    const valeur = lire(donnees ?? {});
    if (valeur === null || valeur === undefined || String(valeur).trim() === '') continue;
    resultats.push({ champ, valeur: String(valeur), present: motif(valeur, entre, frontieres).test(String(texteSource ?? '')) });
  }
  return resultats;
}

/**
 * Identifiants absents du texte source (alertes à enregistrer).
 * @returns {string[]}
 */
function alertesSource(verifications) {
  return verifications.filter((v) => !v.present).map((v) => `${v.champ} « ${v.valeur} » absent du texte source`);
}

export { verifierIdentifiantsDansSource, alertesSource };
