@echo off
rem Launches a 2nd CLIENT in GUEST mode, to test multiplayer on ONE PC with two
rem different players. It reads mmo_config_guest.txt so it can log into a separate
rem account (server-persisted like any other). Start PlayMMO-server.bat first.
rem   - window 1: PlayMMO-debug.bat  (your usual account)
rem   - window 2: PlayMMO-guest.bat  (a distinct second player)
cd /d "%~dp0"
set PEMK_GUEST=1
rem See PlayMMO-debug.bat: enlarge the Ruby VM stack (~16x headroom) so the debug
rem boot + save-state hydration can't hit a boot-stack SystemStackError.
set RUBY_THREAD_VM_STACK_SIZE=16777216
start "" "Game.exe" debug
