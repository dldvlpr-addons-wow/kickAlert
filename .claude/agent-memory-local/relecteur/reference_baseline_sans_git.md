---
name: reference-baseline-sans-git
description: Comment obtenir la version d'avant modification de KickAlert sans git (interdit par l'utilisateur) : diff contre la copie déployée dans le client WoW
metadata:
  type: reference
---

Git est interdit, même en lecture (règle globale de l'utilisateur). Pour relire un diff de KickAlert, comparer
avec la copie déployée : `C:/World of Warcraft/_classic_beta_/Interface/AddOns/KickAlert/` (même arborescence, sans tests/).
`diff "<copie>/Fichier.lua" "C:/Users/ludov/wowadd/kickAlert/Fichier.lua"`.

**Why:** sans diff, impossible de juger « comportement identique » sur un refactor ; la copie déployée correspondait
au dernier commit lors de la revue du 2026-10-13 (dette GetSpellTexture / UNIT_CAST_EVENTS / StyleLabel).

**How to apply:** vérifier d'abord la date de la copie (`ls -la`) : elle peut être périmée ou déjà contenir des
modifications en cours si l'utilisateur a recopié l'addon. Un diff qui ne montre que les changements annoncés confirme la base.
Suite hors jeu : `bash tests/run.sh` (191 ok en classic, 193 en retail, 4 variantes).
