@echo off
rem Launches a 2nd instance in GUEST mode (fresh, distinct, non-persisted
rem account), to test multiplayer on ONE PC with two different players:
rem   - window 1: PlayMMO-debug.bat  (your usual account)
rem   - window 2: PlayMMO-guest.bat  (a distinct guest player)
cd /d "%~dp0"
set PEMK_GUEST=1
start "" "Game.exe" debug
