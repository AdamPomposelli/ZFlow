# ZFlow — charte graphique

ZFlow appartient à la suite **Zippytal**. La charte part du logo de l'agence et
n'en dévie que là où le produit l'exige. Un utilisateur qui connaît un outil
Zippytal doit reconnaître celui-ci sans qu'on le lui dise.

## Le repère

La construction est celle de Zippytal : deux carrés arrondis en noir profond
ancrés aux angles opposés, un trait violet qui court entre eux.

**Une seule chose change** : le trait. Le Z de Zippytal est droit ; celui de
ZFlow s'incurve. Le produit transforme la parole en texte, et la ligne doit
bouger. C'est la totalité de la différenciation, et c'est délibéré : un
deuxième écart rendrait la parenté illisible.

```
Zippytal   M12 8h14L6 24h14                     (droit)
ZFlow      M12 8H26C22 14 10 18 6 24H20         (incurvé)
```

Fichiers dans `logo/` :

| Fichier | Usage |
|---|---|
| `zflow-mark.svg` | partout par défaut |
| `zflow-mark-mono.svg` | barre de menus, gravure, fond contraint — hérite de `currentColor` |
| `zflow-lockup.svg` | repère + mot, pour un en-tête ou un pied de page |
| `zflow-appicon.svg` | source de l'icône macOS |

### Règles

- **Ne jamais redessiner le trait.** Il est calibré pour rester lisible à 16 px.
- **Ne jamais séparer les carrés du trait.** Les trois éléments sont le logo.
- L'espace libre minimal autour du repère vaut **une largeur de carré** (8 unités
  sur la grille de 32). Dans le lockup, l'écart entre repère et mot vaut la même
  chose ; ne pas le refermer.
- Taille minimale : **16 px**. En dessous, utiliser un seul carré violet.
- Le repère ne se pose pas sur le violet de la marque : les carrés disparaissent.
  Fond clair, ou version mono.

## Couleurs

| Rôle | Valeur | Notes |
|---|---|---|
| Accent | `#6D28D9` | le violet Zippytal, repris tel quel |
| Accent tenu | `#5B21B6` | survol et état pressé |
| Accent posé | `#EDE7FD` | fonds de sélection, pastilles |
| Encre | `#171717` | texte principal, carrés du repère |
| Encre secondaire | `#6B6A66` | descriptions |
| Encre tertiaire | `#9B9A95` | légendes, unités |
| Surface | `#FFFFFF` | panneau de contenu |
| Surface posée | `#F5F4F1` | cartes, barre latérale |
| Positif | `#1F7A5C` | « sur ce Mac », réussite |
| Attention | `#B8860B` | piste muette, dégradation |
| Danger | `#B3261E` | erreurs, suppression |

Les neutres sont chauds, pas gris. C'est ce qui donne l'aspect papier de
l'interface et ce qui distingue ZFlow d'un utilitaire système.

**Le violet ne sert qu'à une chose : ce que l'utilisateur a choisi ou ce qui se
passe maintenant.** Un violet appliqué à la décoration détruit sa fonction.

## Typographie

| Rôle | Police | Détail |
|---|---|---|
| Titres de page, grands chiffres | **Newsreader** | 500, serif de transition |
| Interface | **Inter** | 400/500/600 |
| Transcriptions, modèles, chemins | monospace système | `ui-monospace, SF Mono, Menlo` |

Un chiffre lu comme une donnée est en Newsreader ; un chiffre lu comme une
étiquette est en Inter. Toute colonne de nombres est en `tabular-nums`.

## Voix

- On écrit à l'utilisateur, pas sur le produit. « Regarder ce sur quoi je
  travaille », pas « inférence de contexte ».
- On dit où vont les données quand c'est le sujet, et on ne le dit qu'une fois.
- Un chiffre s'accompagne de ce qui le fonde, à portée de survol.
- Pas de point d'exclamation. Pas de félicitations.

## Jetons

`tokens/zflow-tokens.css` est la source pour l'interface ; `zflow-tokens.json`
la même chose pour tout le reste. L'interface Electron importe le CSS : les
valeurs ci-dessus ne sont pas recopiées à la main.
