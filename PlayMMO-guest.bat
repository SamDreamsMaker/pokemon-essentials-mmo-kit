@echo off
rem Lance une 2e instance en mode INVITE (compte frais/distinct, non persiste),
rem pour tester le multijoueur sur UN seul PC avec deux joueurs differents :
rem   - fenetre 1 : PlayMMO-debug.bat  (ton compte habituel)
rem   - fenetre 2 : PlayMMO-guest.bat  (un joueur invite distinct)
cd /d "%~dp0"
set POKEMMO_GUEST=1
start "" "Game.exe" debug
