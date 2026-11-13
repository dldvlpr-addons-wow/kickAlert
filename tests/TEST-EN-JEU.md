# Recette en jeu : issues #1 à #4

Guide de test manuel des issues GitHub #1 à #4 (codées le 2026-11-13, pas encore testées en jeu).
Placé dans `tests/` : le packager l'exclut (`.pkgmeta`), il n'est pas livré aux joueurs.

## Avant de commencer

1. Hors jeu, sur le nouveau poste : `bash tests/run.sh` (paquet `lua5.1` requis). Attendu : `tout est vert.`
2. Copier l'addon dans le client (copie, pas lien symbolique), sans `tests/` ni `.git/` :
   - Windows : `robocopy . "<client>\Interface\AddOns\KickAlert" /MIR /XD tests .git .github .claude`
   - macOS / Linux : `rsync -a --delete --exclude tests/ --exclude .git/ --exclude .github/ --exclude .claude/ ./ "<client>/Interface/AddOns/KickAlert/"`
3. En jeu : `/console scriptErrors 1`, puis `/reload`.
4. Noter le build : `/dump GetBuildInfo()`.

Clients à couvrir, dans l'ordre de priorité : WoW Forever, puis un client Classic (Era ou Anniversary), puis retail si disponible.
Pour chaque test, noter OK / KO, le client et le build.

## #1 `/ka spell` refuse un sort invalide

Personnage avec un interrupt (voleur, guerrier, mage…).

| # | Action | Résultat attendu |
|---|---|---|
| 1.1 | `/ka status` | Ligne `interrupt: <nom> (<id>)`, sans `(forced)` |
| 1.2 | `/ka spell 99999` | Message « Unknown spell for this character: 99999. Setting unchanged. » |
| 1.3 | `/ka status` | Même interrupt qu'en 1.1, toujours sans `(forced)` |
| 1.4 | `/ka spell abc` | Même message d'erreur avec `abc` |
| 1.5 | `/ka spell 2139.5` puis `/ka spell -5` | Message d'erreur dans les deux cas |
| 1.6 | `/ka spell <id de ton interrupt>` (id lu en 1.1) | « Interrupt forced: <nom> » ; `/ka status` affiche `(forced)` |
| 1.7 | `/ka spell` (sans argument) | « Interrupt detected automatically. » ; `/ka status` sans `(forced)` |
| 1.8 | `/ka spell auto` | Même résultat que 1.7 |

### Point le plus important : sort du familier (démoniste)

Démoniste avec son chasseur corrompu invoqué (Spell Lock, id `19647`).

| # | Action | Résultat attendu |
|---|---|---|
| 1.9 | `/ka status` | Interrupt détecté : Spell Lock (19647) |
| 1.10 | `/ka spell 19647` | « Interrupt forced: Spell Lock », pas de message d'erreur |
| 1.11 | Renvoyer le familier, `/ka spell auto` puis `/ka status` | Noter le résultat (détecté ou « none detected ») |

Si 1.10 échoue, relever l'API brute et la transmettre à l'agent `wow-api` :

- Forever / retail : `/dump C_SpellBook.IsSpellKnown(19647, Enum.SpellBookSpellBank.Pet)`
- Classic : `/dump IsSpellKnown(19647, true)`

Noter la sortie exacte, le build, et si le familier était invoqué.

## #2 Son libre injouable signalé

`/ka` pour ouvrir le panneau, colonne de droite, section « Sound ».

| # | Action | Résultat attendu |
|---|---|---|
| 2.1 | Champ « Or SOUNDKIT id / file », saisir `Interface\AddOns\X\nope.ogg`, Entrée | Message « Sound could not be played on this client… » dans le chat |
| 2.2 | Saisir `999999999`, Entrée | Même message |
| 2.3 | Saisir `8959` (SOUNDKIT RAID_WARNING), Entrée | Le son joue, aucun message |
| 2.4 | Choisir de nouveau un preset (bouton cyclique « Sound ») | Le son joue, aucun message |

## #3 Interrupt affiché dans le panneau

| # | Action | Résultat attendu |
|---|---|---|
| 3.1 | Personnage avec interrupt, ouvrir `/ka` | Sous « Trigger » : `interrupt: <nom> (<id>)`, rien d'autre |
| 3.2 | `/ka spell <id>` (1.6), fermer puis rouvrir le panneau | La ligne affiche `(forced)` |
| 3.3 | `/ka spell auto`, rouvrir | `(forced)` disparaît |
| 3.4 | Personnage sans interrupt (prêtre Sacré, paladin Sacré, druide Restauration, ou bas niveau sans le sort) | `interrupt: none detected` en rouge, suivi de « No interrupt known for this character: no alert will fire. /ka spell <id> forces one. » |
| 3.5 | Vérifier la mise en page en 3.1 et 3.4 | Le texte ne chevauche pas les cases à cocher en dessous |
| 3.6 | Se connecter avec ce personnage | Aucun message au login |

Le panneau ne se met pas à jour pendant qu'il est ouvert : il faut le rouvrir (comportement normal, comme les autres réglages).

## #4 Mot et contour des nameplates

Section « KICK on nameplates » du panneau (absente sur un client sans nameplates d'unité).
Il faut un mob hostile qui incante un sort interruptible, sans le cibler.

| # | Action | Résultat attendu |
|---|---|---|
| 4.1 | Champ « Displayed word » de la section nameplates : saisir `STOP`, Entrée | Sur un mob qui incante : `STOP` au-dessus de sa nameplate |
| 4.2 | Bouton « Outline » de la section : passer sur « None », puis « Thick » | Le contour du mot change, pas d'erreur Lua |
| 4.3 | Vider le champ du mot, Entrée | `KICK` réapparaît au-dessus de la nameplate |
| 4.4 | Vérifier que le texte central (section « Text ») n'a pas changé | Le mot et le contour du texte central restent les leurs |
| 4.5 | `/reload`, rouvrir le panneau | Mot et contour des nameplates conservés |

## Contrôles en combat (moteur 12.x : Forever, retail)

| # | Action | Résultat attendu |
|---|---|---|
| 5.1 | En combat contre un mob qui incante, kick disponible | Texte, halo, son et KICK sur la nameplate s'affichent comme avant |
| 5.2 | `/ka spell 99999` en combat | Message d'erreur, aucune erreur Lua |
| 5.3 | `/ka status` en combat | Ligne d'interrupt identique à hors combat |

## Après la recette

- Tout est OK : fermer les issues #1 à #4.
- Un KO : noter le numéro de test, le client, le build et l'erreur Lua exacte (copie de la fenêtre d'erreur), puis lancer `/bug` avec ces éléments.
- Supprimer ce fichier une fois la recette faite, ou le garder pour la prochaine version.
