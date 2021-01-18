v1.1 (2021-01-17):
-----------
*General Changes:*
* Fix several issues with how bots take damage (e.g. "ouch" on lava w/ flame shield, etc.)
* Enable ai_defaultleader by default, setting all connecting clients to bots unless disabled (easier setup)
* Disable saving AI console variables to config, since they sync across netgames (didn't make much sense)
* Fix SP bot issues - bot now respawns as expected, and no longer bugs out if Player 2 takes control
* Improve teleporting - inherit leader's momentum / orientation, fix goofy 2D mode bugs, teleport more responsively in large bot groups
* Fix some player preferences not being applied if adjusted while AI was in control of the player
* Add "listbots" command to list all active bots (and players) in a nice "tree" format
* Rewrite ai_debug as a more detailed HUD hook (instead of console log spam)
* Add named values to ai_ignore, ai_hurtmode, and ai_statmode (e.g. ai_ignore "All")
* Add simple HUD for bot clients! Shows assorted status info, toggled via ai_showhud
* Fix various issues with bot super forms (and add AI for using super forms)
* Remove grace period from leader when bot takes real damage (e.g. via ai_hurtmode)
* Fix bots sometimes being able to pick up tossed rings when they shouldn't
* Rework ai_defaultleader to allow specifying a random leader (32) and automatically arrange bots into a line
* Prevent bots from keeping a pink Amy shield on hit (so they don't just constantly have one)
* Improve documentation / bothelp command

*AI Behavior Changes:*
* Improve chain-attacking - always use next closest target when switching, regardless of leader's speed
* Allow grabbing monitors as "active" targets, like enemies (can do longer jumps to bop monitors)
* Limit range Tails will attempt to fly-attack targets (unless already flying)
* Use radius, height, and scale (for both bot and target) in calculating max target distances
* Improve Tails carry logic - better chain-carry, avoid snapping leader's camera around on pickup
* Fix issues with slopes and conveyors, including spindashing and thinkfly (up arrow) not working on them
* Improve close-range following and running ahead of leader when we're faster
* Improve pseudo-random behavior across multiple bots in a session (they won't all make the same "random" decision at the same time)
* Fix relentlessly attacking MT_ROSY (oops)
* Fix various Amy issues - avoid excessive friendly shield hammering, fix airhammers not working right
* Allow Fang to jump-attack enemies with his tail bounce, and use this behavior on objects leader pushes against
* Fix freaking out if swinging around on a mace
* Improve "leader is pushing against something" helpmode logic, taking priority over combat
* Fix sometimes respawning before leader was explicitly alive again
* Improve targeting to prefer targets in current momentum direction
* Fix standing around in water and losing time in special stages
* Improve drowning logic to jump out of water when near the water surface, regardless of ability
* Fix needlessly jumping for rings in reverse gravity
* Allow super transformations via thinkfly (stand near bot and jump when golden up arrow is visible)
* Add behaviors for super form abilities
* Fix not always holding jump when crossing a predicted gap
* Add spectator support for non-respawning game modes (can guide bots to next starpost when dead, etc.)
* Ensure AI leaders think before their followers (fixes things like Tails carry between two bots)
* Improve corner waypoint navigation, making it more reliable and reducing number of objects created
* Fix issues with boredom in large groups
* Relax target count requirements for using Armageddon Shield nuke
* Other miscellaneous fixes and performance improvements

v1.0 (2020-11-27):
------------------
* Initial release
