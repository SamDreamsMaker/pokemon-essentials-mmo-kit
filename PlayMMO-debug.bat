@echo off
rem Launches Pokemon Essentials MMO Kit in debug mode (loads the PEMK plugin
rem from source and enables the debug menu). Double-click this file twice to test
rem multiplayer locally:
rem   - 1st instance = host (binds port 9998 on 127.0.0.1)
rem   - 2nd instance = client (joins automatically, ROLE=:auto)
cd /d "%~dp0"
start "" "Game.exe" debug
