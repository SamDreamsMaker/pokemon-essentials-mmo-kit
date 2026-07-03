@echo off
rem Launches Pokemon Essentials MMO Kit in debug mode (loads the PEMK plugin
rem from source and enables the debug menu). Double-click this file twice to test
rem multiplayer locally:
rem   - 1st instance = host (binds port 9998 on 127.0.0.1)
rem   - 2nd instance = client (joins automatically, ROLE=:auto)
cd /d "%~dp0"
rem Enlarge the Ruby VM stack (mkxp-z honours this env var): the debug boot +
rem save-state hydration is stack-heavy and could intermittently hit a boot-stack
rem SystemStackError on the small default VM stack. 16 MiB = ~16x headroom
rem (measured: ~10,900 -> ~174,700 max recursion frames).
set RUBY_THREAD_VM_STACK_SIZE=16777216
start "" "Game.exe" debug
