@echo off
rem Launches a 2nd instance in GUEST mode (fresh, distinct, non-persisted
rem account), to test multiplayer on ONE PC with two different players:
rem   - window 1: PlayMMO-debug.bat  (your usual account)
rem   - window 2: PlayMMO-guest.bat  (a distinct guest player)
cd /d "%~dp0"
set PEMK_GUEST=1
rem See PlayMMO-debug.bat: enlarge the Ruby VM stack (~16x headroom) so the debug
rem boot + save-state hydration can't hit a boot-stack SystemStackError.
set RUBY_THREAD_VM_STACK_SIZE=16777216
start "" "Game.exe" debug
