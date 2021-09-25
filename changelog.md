v1.4.1 (2021-xx-xx):
--------------------
*General Changes:*
* Allow bots to always respawn in special stages, even when player-controlled (e.g. teleported over death pit)
* Rewrite special stage respawning to be considerably more sane, instead of a hack
* Fix occasional Lua error from BotRespawn hook in singleplayer

*AI Behavior Changes:*
* Fix not targeting minecarts (v1.4 regression)
* Fix occasionally trying to jump for things we can't actually reach
* Avoid picking up leader any time we're fly-attacking a target
* Fix trying to grab gravity box when leader isn't under reverse gravity
* Fix occasionally getting confused when trying to jump on vehicles
* Allow grabbing Tokens and Emeralds in multiplayer
* Fix occasionally not jumping for targets correctly when being carried

v1.4 (2021-08-20):
------------------
*General Changes:*
* Fix disconnecting bots being unable to teleport
* Fix position resetting when using "setbot" command as a spectator

*AI Behavior Changes:*
* Fix Tails again attempting to fly-attack underwater or grounded targets
* Fix Tails constantly trying to grab rings with flight (unless already flying)
* Fix Tails being unable to fly-attack targets with an attraction shield
* Fix disconnecting bots getting stuck trying to grab rings etc.
* Clean up movement, particularly when close or in combat (allows more short hops)
* Allow using elemental shield to quickly stop, if close enough to ground
* Fix a few cases of accidentally jump-cancelling a spindash
* Account for momentum when determining attack range for custom SF_NOJUMPDAMAGE characters
* Fix nonsense attraction shield target range check
* Don't extend target distance for rings etc. in special stages
* Fix targeting invisible things
* Allow Tails to fly-attack targets a bit further away, and fly around in goop smarter
* Fix various longstanding issues with relative height checks in reverse gravity or at scale
* Try switching targets if we've failed to hit our current target after 3 jumps
* Attempt to join matches when spectating by pressing fire
* Support for CBW's Chaos Mode mod - prioritize objectives, ready up by jumping into emblems
* Other miscellaneous tweaks and fixes

v1.3.1 (2021-06-26):
--------------------
*General Changes:*
* Fix potential softlock from bots respawning in special stages

*AI Behavior Changes:*
* Improve Tails' fly and fly-attack AI behaviors
* Fix sometimes repeatedly jumping for rings etc. when we shouldn't
* Fix sometimes aborting jump logic against certain targets too early
* Fix jittery movement when tracking slow-moving targets

v1.3 (2021-06-11):
------------------
*General Changes:*
* Fix shields sometimes getting popped when they shouldn't (should only happen when leader gets hit)
* Allow nukes etc. to be set off when shield gets popped
* Spread out bots more when assigned to a random leader (ai_defaultleader 32)
* Fix SP bot sometimes resetting rings on respawn

*AI Behavior Changes:*
* Fix v1.2 regression causing AI to no longer understand custom SF_NOJUMPDAMAGE characters
* Fix a few cases where AI might not charge a spindash properly
* Rewrite Fang's combat AI with cleaner logic that should derp out less
* Reduce time Amy waits to shield-buff friendlies again after previously failing
* Limit range AI will attempt to engage targets while being carried
* Fix Tails forgetting how to chain-carry a tired flying leader w/ super form available
* Tails AI now toggles between super / normal thinkfly (up arrow) every second if available

v1.2 (2021-05-09):
------------------
*General Changes:*
* Allow bots to respawn in special stages when AI-controlled
* Allow SP bot to inherit player's powerups (thus allowing shield behaviors to be seen in SP)
* Invulnerable bots' shields are now popped when their leader takes a hit without a shield
* Fix issue where SP bot could sometimes carry player without actually flying
* Allow players to remember their "real" ring / life counts as a bot
* Allow teleporting to leader even if they're spectating
* Wait a second before teleporting to leader on respawn
* Fix various life-sync issues with 0 lives
* Raise minimum ai_seekdist to a more reasonable 64 fracunits
* Fix a few issues with vertical aiming reset when taking back control of a bot
* Fix issue where "AI Control In..." would still display when ai_sys was off
* Fix issue where thinkfly overlay (up arrow) was spawned and destroyed every frame
* Assorted code cleanup and other minor fixes

*AI Behavior Changes:*
* Add support for CoopOrDie enemy tagging / target priority mechanics
* Hop out of spin if going too slow, also try to steer an active spin into targets more
* Improve Tails' flight logic to descend a bit more aggressively and land near leader quicker
* Mirror leader's OLDC votes
* Improve movement prediction, particularly underwater and against fast-moving targets
* Prefer spindashing targets on slopes (and rev it longer if needed)
* Allow Sonic to thok-attack targets
* Allow Knuckles to glide/slide-attack targets
* Always use ability when jumping out of special stage water
* Wiggle free from Pterabytes!
* Fix Tails attempting to fly-attack underwater or grounded targets
* Improve Sonic thok usage, avoiding it when it would actually slow us down
* Improve Metal Sonic / Super Sonic float usage, with better height checks
* Allow whirlwind shield ability to be used against passive targets (e.g. collecting rings)
* Fix longstanding issue where AI only searched for targets half as often as intended
* Allow Fire Flower to be used against monitors (and targets above or below)
* Fix AI sometimes getting stuck spindashing against an obstacle
* Fix not attacking DSZ3 boss (due to being unable to "see" it)
* Make sure we're actually on target before attempting to spin-attack a target
* Tweak Amy's hammer attack logic to account for LHRT range a bit more
* Fix vertical spectator movement in reverse gravity
* Fix Fang sometimes getting stuck below targets we're trying to shoot
* Fix AI sometimes flipping out when recalled to leader during combat
* Fix up out-of-sight waypoint placement (can better follow leader through teleporters etc.)
* Check vertical distance to waypoint when determining if we've reached it or not
* Fix v1.1 regression causing flame shield ability to not be considered at long ranges
* Allow bubble shield to be used as a double-jump when close enough to ground
* Fix sometimes getting stuck in zoom tubes (e.g. ERZ1 2D tube section)
* Other miscellaneous behavior fixes and improvements

v1.1 (2021-01-17):
------------------
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
