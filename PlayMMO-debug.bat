@echo off
rem Lance Pokemon Essentials MMO Kit en mode debug (charge le plugin PokeMMO
rem depuis les sources et donne acces au menu debug). Double-clique ce fichier
rem DEUX fois pour tester le multijoueur en local :
rem   - 1re instance = hote (bind du port 9998 sur 127.0.0.1)
rem   - 2e instance  = client (rejoint automatiquement, ROLE=:auto)
cd /d "%~dp0"
start "" "Game.exe" debug
