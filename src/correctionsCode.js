// Corrections déterministes appliquées par le code à une extraction (D-052).
// Principe : ce qui peut être garanti par le code ne dépend pas du prompt.
// Chaque fonction renvoie de nouvelles données (jamais modifiées sur place)
// et la liste de ce qu'elle a fait, pour la traçabilité.
// Aucune dépendance (fonctions de rib.js et matricule.js reçues en paramètre).

const copie = (d) => JSON.parse(JSON.stringify(d));

/**
 * Retire les séparateurs que le prompt v2 demande de recopier : espaces,
 * points et tirets du RIB ; espaces du matricule fiscal.
 */
function nettoyerIdentifiants(donnees) {
  if (!donnees) return { donnees, corrections: [] };
  const d = copie(donnees);
  const corrections = [];
  const nettoyer = (objet, cle, motif, champ) => {
    if (typeof objet?.[cle] !== 'string') return;
    const nettoye = objet[cle].replace(motif, '');
    if (nettoye !== objet[cle]) { corrections.push(`${champ} : séparateurs retirés`); objet[cle] = nettoye; }
  };
  nettoyer(d.fournisseur, 'rib', /[\s.\-]/g, 'fournisseur.rib');
  nettoyer(d.fournisseur, 'matricule_fiscal', /\s/g, 'fournisseur.matricule_fiscal');
  nettoyer(d.client, 'matricule_fiscal', /\s/g, 'client.matricule_fiscal');
  return { donnees: d, corrections };
}

// Alias de devise explicites (D-052). « D » seul reste ambigu et n'est pas converti.
const ALIAS_DEVISE = Object.freeze({ DT: 'TND', DINAR: 'TND', DINARS: 'TND' });

function convertirDevise(donnees) {
  if (!donnees || typeof donnees.devise !== 'string') return { donnees, corrections: [] };
  const alias = ALIAS_DEVISE[donnees.devise.trim().toUpperCase()];
  if (!alias) return { donnees, corrections: [] };
  return { donnees: { ...copie(donnees), devise: alias }, corrections: [`devise : « ${donnees.devise} » converti en ${alias}`] };
}

// Entités nommées courantes en français (les autres restent telles quelles).
const ENTITES_NOMMEES = Object.freeze({
  amp: '&', lt: '<', gt: '>', quot: '"', apos: '\'', nbsp: ' ',
  eacute: 'é', egrave: 'è', ecirc: 'ê', euml: 'ë', agrave: 'à', acirc: 'â', ccedil: 'ç',
  icirc: 'î', iuml: 'ï', ocirc: 'ô', ugrave: 'ù', ucirc: 'û', uuml: 'ü', micro: 'µ',
  Eacute: 'É', Egrave: 'È', Ecirc: 'Ê', Agrave: 'À', Ccedil: 'Ç',
});
const ENTITE_BIEN_FORMEE = /&(?:#(\d{1,7})|#x([0-9a-fA-F]{1,6})|([a-zA-Z]+));/g;
// Toute trace d'entité, même malformée (« &#2333dina », sans point-virgule).
const TRACE_ENTITE = /&(?:#x?[0-9a-fA-F]+|[a-zA-Z]+);?/;

/**
 * Décode les entités HTML bien formées dans toutes les chaînes, et SIGNALE
 * l'extraction dès qu'une trace d'entité est présente (même non décodable).
 */
function decoderEntites(donnees) {
  if (!donnees) return { donnees, corrections: [], signalements: [] };
  const corrections = [];
  const signalements = [];
  const parcourir = (valeur, chemin) => {
    if (typeof valeur === 'string') {
      if (!TRACE_ENTITE.test(valeur)) return valeur;
      signalements.push(`${chemin} : entité HTML dans la réponse du modèle (« ${valeur} »)`);
      const decode = valeur.replace(ENTITE_BIEN_FORMEE, (tout, dec, hex, nom) => {
        const code = dec ? Number(dec) : hex ? parseInt(hex, 16) : null;
        if (code !== null) return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : tout;
        return ENTITES_NOMMEES[nom] ?? tout;
      });
      if (decode !== valeur) corrections.push(`${chemin} : entités décodées`);
      return decode;
    }
    if (Array.isArray(valeur)) return valeur.map((v, i) => parcourir(v, `${chemin}/${i}`));
    if (valeur && typeof valeur === 'object') {
      return Object.fromEntries(Object.entries(valeur).map(([k, v]) => [k, parcourir(v, `${chemin}/${k}`)]));
    }
    return valeur;
  };
  const d = parcourir(copie(donnees), '');
  return { donnees: d, corrections, signalements };
}

/**
 * RIB candidats dans le texte source : suites de 20 chiffres sur une même
 * ligne (espaces, points et tirets tolérés) dont la clé RIB est valide.
 * @param {string} texte
 * @param {(rib: string) => boolean} ribValide
 */
function ribCandidats(texte, ribValide) {
  const candidats = new Set();
  for (const ligne of String(texte ?? '').split('\n')) {
    for (const suite of ligne.match(/\d[\d \t.\-]*\d/g) ?? []) {
      const chiffres = suite.replace(/\D/g, '');
      for (let i = 0; i + 20 <= chiffres.length; i += 1) {
        const c = chiffres.slice(i, i + 20);
        if (ribValide(c)) candidats.add(c);
      }
    }
  }
  return [...candidats];
}

/**
 * Récupération du RIB dans le texte source (règle de Mohamed, D-052) :
 * - RIB extrait valide et présent dans le texte : rien à faire ;
 * - sinon, s'il existe UN SEUL candidat valide dans le texte :
 *   - identique au RIB du référentiel pour ce fournisseur → rempli (simple
 *     confirmation d'une valeur connue) ;
 *   - sinon → PROPOSÉ à la personne qui valide, jamais rempli ;
 * - plusieurs candidats (cas d'une consigne injectée) ou aucun : rien.
 * @param {object} donnees
 * @param {string} texteSource
 * @param {string|null} ribReferentiel RIB actif du fournisseur identifié, ou null
 * @param {(rib: string) => boolean} ribValide
 */
function recupererRib(donnees, texteSource, ribReferentiel, ribValide) {
  const vide = { donnees, corrections: [], proposition: null };
  if (!donnees || !texteSource) return vide;
  const extrait = donnees.fournisseur?.rib ?? null;
  const candidats = ribCandidats(texteSource, ribValide);
  if (extrait && ribValide(extrait) && candidats.includes(extrait)) return { ...vide, candidats };
  if (candidats.length !== 1) return { ...vide, candidats };
  const [candidat] = candidats;
  if (ribReferentiel && candidat === ribReferentiel) {
    const d = copie(donnees);
    d.fournisseur.rib = candidat;
    return {
      donnees: d, candidats,
      corrections: [`fournisseur.rib : « ${extrait} » remplacé par ${candidat} (trouvé dans le texte source, identique au référentiel)`],
      proposition: null,
    };
  }
  return { ...vide, candidats, proposition: { champ: 'fournisseur.rib', valeur: candidat, provenance: 'trouvé par le code dans le texte source (clé RIB valide), différent du référentiel ou fournisseur non identifié' } };
}

/**
 * Les quatre corrections, dans l'ordre figé par D-053 : nettoyage des
 * identifiants, alias de devise, entités HTML (avec signalement), RIB retrouvé
 * selon la règle du référentiel (sinon proposé). Un texte source contenant
 * plusieurs RIB valides est signalé (consigne injectée, D-046).
 * @param {object|null} donnees sortie brute du modèle
 * @param {string|null} texteSource texte transmis au modèle
 * @param {Record<string, string>} ribsReferentiel RIB actif par matricule fiscal (forme courte)
 * @param {{ribValide: (rib: string) => boolean, formeCourteMatricule: (m: string) => string|null}} deps
 * @returns {{donnees: object|null, corrections: string[], signalements: string[], propositions: object[]}}
 */
function corrigerExtraction(donnees, texteSource, ribsReferentiel, deps) {
  const corrections = [];
  const signalements = [];
  const propositions = [];
  let d = donnees;
  for (const etape of [nettoyerIdentifiants, convertirDevise, decoderEntites]) {
    const r = etape(d);
    d = r.donnees;
    corrections.push(...r.corrections);
    signalements.push(...(r.signalements ?? []));
  }
  const matricule = deps.formeCourteMatricule(d?.fournisseur?.matricule_fiscal ?? '');
  const ribReferentiel = (matricule && ribsReferentiel?.[matricule]) || null;
  const rib = recupererRib(d, texteSource, ribReferentiel, deps.ribValide);
  d = rib.donnees;
  corrections.push(...rib.corrections);
  if (rib.proposition) propositions.push({ ...rib.proposition, rib_referentiel: ribReferentiel });
  if ((rib.candidats?.length ?? 0) > 1) {
    signalements.push(`fournisseur.rib : ${rib.candidats.length} RIB valides dans le texte source (${rib.candidats.join(', ')})`);
  }
  return { donnees: d, corrections, signalements, propositions };
}

export {
  ALIAS_DEVISE, nettoyerIdentifiants, convertirDevise, decoderEntites, ribCandidats, recupererRib, corrigerExtraction,
};
