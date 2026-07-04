@echo off
rem Launches Pokemon Essentials MMO Kit in debug mode (loads the PEMK plugin
rem from source and enables the debug menu). This is a CLIENT: it connects to the
rem dedicated server (start it first with PlayMMO-server.bat). For two players on
rem one PC, run this plus PlayMMO-guest.bat and create two different accounts.
cd /d "%~dp0"
rem Enlarge the Ruby VM stack (mkxp-z honours this env var): the debug boot +
rem save-state hydration is stack-heavy and could intermittently hit a boot-stack
rem SystemStackError on the small default VM stack. 16 MiB = ~16x headroom
rem (measured: ~10,900 -> ~174,700 max recursion frames).
set RUBY_THREAD_VM_STACK_SIZE=16777216
start "" "Game.exe" debug
