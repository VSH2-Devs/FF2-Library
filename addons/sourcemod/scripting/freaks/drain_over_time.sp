#pragma semicolon 1

#include <sourcemod>
#include <tf2items>
#include <tf2_stocks>
#include <sdkhooks>
#include <sdktools>
#include <sdktools_functions>
#include <freak_fortress_2>
#include <freak_fortress_2_subplugin>

/**
 * A platform for drain over time rages. Combines all the common aspects of such rages to
 * simplify other drain over time rages' code and configuration.
 *
 * KNOWN ISSUES:
 *	- Turning all three Vaccinator conditions on at the same time is definitely unsafe, a certain key combo from the player
 *		(reload, attack, movement dirs) can crash the server, usually when spamming R.
 *		As for individual Vaccinator conditions, your guess is as good as mine.
 *
 * Revamped on 2015-03-21
 */

// change this to minimize console output
new PRINT_DEBUG_INFO = true;

#define MAX_PLAYERS_ARRAY 36
#define MAX_PLAYERS (MAX_PLAYERS_ARRAY < (MaxClients + 1) ? MAX_PLAYERS_ARRAY : (MaxClients + 1))

// text string limits
#define MAX_SOUND_FILE_LENGTH 80
#define MAX_WEAPON_NAME_LENGTH 40
#define MAX_EFFECT_NAME_LENGTH 48

#define FAR_FUTURE 100000000.0
#define IsEmptyString(%1) (%1[0] == 0)

// handle needed for the method shared by sub-plugins
new Handle:Handle_OnDOTAbilityActivated;
new Handle:Handle_OnDOTAbilityDeactivated;
new Handle:Handle_OnDOTUserDeath; // in case cleanup is necessary
new Handle:Handle_OnDOTAbilityTick;
new Handle:Handle_DOTPostRoundStartInit;

// shared variables
new bool:RoundInProgress = false;

// according to the good folks at AlliedModders, this is as close as I'll get to a struct or a class
// but this mod needs to handle multiple bosses.
#define DOT_STRING "dot_base"
#define DOT_INTERVAL 0.1
#define MAX_CONDITIONS 10
#define CONDITION_DELIM " ; " // I'm going with this because people are already using this format for weapon attributes
#define CONDITION_DELIM_SHORT ";" // one year later, I realize how stupid my logic was with the above.
#define CONDITION_STRING_LENGTH (MAX_CONDITIONS * 3 + ((MAX_CONDITIONS - 1) * 3) + 1) // ### ; ### ; ### ; ###... (3-digit conditions will exist pretty soon, I'd think)
new bool:DOT_ActiveThisRound = false;
new Float:DOT_NextTick;
new bool:DOT_CanUse[MAX_PLAYERS_ARRAY];
new Float:DOT_TimeOfLastSound[MAX_PLAYERS_ARRAY];
new bool:DOT_ReloadDown[MAX_PLAYERS_ARRAY];
new bool:DOT_RageActive[MAX_PLAYERS_ARRAY];
new DOT_ActiveTickCount[MAX_PLAYERS_ARRAY];
new bool:DOT_OverlayVisible[MAX_PLAYERS_ARRAY];
new bool:DOT_ActivationCancel[MAX_PLAYERS_ARRAY];
new bool:DOT_ForceDeactivation[MAX_PLAYERS_ARRAY];
new bool:DOT_Usable[MAX_PLAYERS_ARRAY];
new bool:DOT_IsOnCooldown[MAX_PLAYERS_ARRAY];
new DOT_CooldownTicksRemaining[MAX_PLAYERS_ARRAY];
new bool:DOT_ReloadPressPending[MAX_PLAYERS_ARRAY];
new Float:DOT_MinRage[MAX_PLAYERS_ARRAY]; // arg1
new Float:DOT_RageDrain[MAX_PLAYERS_ARRAY]; // arg2
new Float:DOT_EnterPenalty[MAX_PLAYERS_ARRAY]; // arg3
new Float:DOT_ExitPenalty[MAX_PLAYERS_ARRAY]; // arg4
new String:DOT_EntrySound[MAX_PLAYERS_ARRAY][MAX_SOUND_FILE_LENGTH]; // arg5
new String:DOT_ExitSound[MAX_PLAYERS_ARRAY][MAX_SOUND_FILE_LENGTH]; // arg6
new String:DOT_EntryEffect[MAX_PLAYERS_ARRAY][MAX_EFFECT_NAME_LENGTH]; // arg7
new Float:DOT_EntryEffectDuration[MAX_PLAYERS_ARRAY]; // arg8
new String:DOT_ExitEffect[MAX_PLAYERS_ARRAY][MAX_EFFECT_NAME_LENGTH]; // arg9: Rage exit particle effect
new Float:DOT_ExitEffectDuration[MAX_PLAYERS_ARRAY]; // arg10: Duration of said particle effect
new DOT_ConditionChanges[MAX_PLAYERS_ARRAY][MAX_CONDITIONS]; // arg11: Conditions to add (and then subsequently remove) during the reload-activated rage.
new bool:DOT_NoOverlay[MAX_PLAYERS_ARRAY]; // arg12: Don't use overlay
new DOT_CooldownDurationTicks[MAX_PLAYERS_ARRAY]; // arg13: Tick count for cooldown
new DOT_ActivationKey[MAX_PLAYERS_ARRAY]; // arg14: Activation key (IN_RELOAD or IN_ATTACK3)
new bool:DOT_AllowWhileStunned[MAX_PLAYERS_ARRAY]; // arg15

public Plugin:myinfo = {
	name = "Freak Fortress 2: Drain Over Time Platform",
	author = "sarysa",
	version = "1.1.0",
}

OnDOTAbilityActivated(clientIdx)
{
	new Action:act=Plugin_Continue;	
	Call_StartForward(Handle_OnDOTAbilityActivated);
	Call_PushCell(clientIdx);
	Call_Finish(act);
}

OnDOTAbilityDeactivated(clientIdx)
{
	new Action:act=Plugin_Continue;	
	Call_StartForward(Handle_OnDOTAbilityDeactivated);
	Call_PushCell(clientIdx);
	Call_Finish(act);
}

OnDOTAbilityTick(clientIdx, tickCount)
{
	new Action:act=Plugin_Continue;	
	Call_StartForward(Handle_OnDOTAbilityTick);
	Call_PushCell(clientIdx);
	Call_PushCell(tickCount);
	Call_Finish(act);
}

OnDOTUserDeath(clientIdx, isInGame)
{
	if (isInGame)
		RemoveDOTOverlay(clientIdx);

	new Action:act=Plugin_Continue;	
	Call_StartForward(Handle_OnDOTUserDeath);
	Call_PushCell(clientIdx);
	Call_PushCell(isInGame);
	Call_Finish(act);
}

DOTPostRoundStartInit()
{
	new Action:act=Plugin_Continue;
	Call_StartForward(Handle_DOTPostRoundStartInit);
	Call_Finish(act);
}

public OnMapStart()
{
	// Make the clients download the overlays, since pretty much everyone forgot to put those in the boss' config
	AddFileToDownloadsTable("materials/freak_fortress_2/dots/alt_fire_overlay1.vmt");
	AddFileToDownloadsTable("materials/freak_fortress_2/dots/alt_fire_overlay1.vtf");
	AddFileToDownloadsTable("materials/freak_fortress_2/dots/alt_fire_overlay2.vmt");
	AddFileToDownloadsTable("materials/freak_fortress_2/dots/alt_fire_overlay2.vtf");
	AddFileToDownloadsTable("materials/freak_fortress_2/dots/attack3_overlay1.vmt");
	AddFileToDownloadsTable("materials/freak_fortress_2/dots/attack3_overlay1.vtf");
	AddFileToDownloadsTable("materials/freak_fortress_2/dots/attack3_overlay2.vmt");
	AddFileToDownloadsTable("materials/freak_fortress_2/dots/attack3_overlay2.vtf");
	AddFileToDownloadsTable("materials/freak_fortress_2/dots/reload_overlay1.vmt");
	AddFileToDownloadsTable("materials/freak_fortress_2/dots/reload_overlay1.vtf");
	AddFileToDownloadsTable("materials/freak_fortress_2/dots/reload_overlay2.vmt");
	AddFileToDownloadsTable("materials/freak_fortress_2/dots/reload_overlay2.vtf");
}

public OnPluginStart2()
{
	// handles for global forwards
	Handle_OnDOTAbilityActivated = CreateGlobalForward("OnDOTAbilityActivatedInternal", ET_Hook, Param_Cell);
	Handle_OnDOTAbilityDeactivated = CreateGlobalForward("OnDOTAbilityDeactivatedInternal", ET_Hook, Param_Cell);
	Handle_OnDOTAbilityTick = CreateGlobalForward("OnDOTAbilityTickInternal", ET_Hook, Param_Cell, Param_Cell);
	Handle_DOTPostRoundStartInit = CreateGlobalForward("DOTPostRoundStartInitInternal", ET_Hook);
	Handle_OnDOTUserDeath = CreateGlobalForward("OnDOTUserDeathInternal", ET_Hook, Param_Cell, Param_Cell);
	
	// events to listen to
	HookEvent("arena_win_panel", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("arena_round_start", Event_RoundStart, EventHookMode_PostNoCopy);
}

public Action:Event_RoundStart(Handle:event,const String:name[],bool:dontBroadcast)
{
	// set all clients to inactive
	for (new clientIdx = 0; clientIdx < MAX_PLAYERS; clientIdx++)
	{
		DOT_CanUse[clientIdx] = false;
		DOT_ReloadDown[clientIdx] = false;
		DOT_RageActive[clientIdx] = false;
		DOT_OverlayVisible[clientIdx] = false;
		DOT_ActivationCancel[clientIdx] = false;
		DOT_Usable[clientIdx] = true;
		DOT_NoOverlay[clientIdx] = false;
		DOT_IsOnCooldown[clientIdx] = false;
		DOT_ReloadPressPending[clientIdx] = false;
		for (new i = 0; i < MAX_CONDITIONS; i++)
			DOT_ConditionChanges[clientIdx][i] = -1;
	}
		
	// initialize these
	DOT_ActiveThisRound = false;
	DOT_NextTick = FAR_FUTURE;
	
	// round is now in progress
	RoundInProgress = true;
	
	// post-round start inits
	CreateTimer(0.3, Timer_PostRoundStartInits, _, TIMER_FLAG_NO_MAPCHANGE);
}

// if one or more bosses with DOT is found, save their parameters now and start the timer
// it's worth noting that some strange behavior was discovered when I did prints...
// this timer executed twice for some unknown reason, and the second time it executed
// it  reported the boss being present but without the ability.
// not sure why that happens (it certainly isn't up to the specifications)
// but if you ever modify this timer, make sure the second execution doesn't undermine
// the first. in other words, don't set any negatives here -- leave that to RoundStart above.
public Action:Timer_PostRoundStartInits(Handle:timer)
{
	// edge case: user suicided
	if (!RoundInProgress)
	{
		PrintToServer("[drain_over_time] Timer_PostRoundStartInits() in %s called after round ended. User probably suicided.", this_plugin_name);
		return Plugin_Stop;
	}
		
	new dotUserCount = 0;
		
	// some things we'll be checking on for later
	for (new clientIdx = 1; clientIdx < MAX_PLAYERS; clientIdx++) // make no boss count assumptions, though anything above 3 is very weird
	{
		if (!IsLivingPlayer(clientIdx))
			continue;
	
		new bossIdx = FF2_GetBossIndex(clientIdx);
		if (bossIdx < 0)
			continue;
			
		if (FF2_HasAbility(bossIdx, this_plugin_name, DOT_STRING))
		{
			DOT_ActiveThisRound = true; // looks like we'll start the looping timer.
			static String:conditionStr[CONDITION_STRING_LENGTH];
			static String:conditions[MAX_CONDITIONS][4];

			// now lets set this user's parameters!
			DOT_CanUse[clientIdx] = true;
			DOT_MinRage[clientIdx] = FF2_GetAbilityArgumentFloat(bossIdx, this_plugin_name, DOT_STRING, 1);
			DOT_RageDrain[clientIdx] = FF2_GetAbilityArgumentFloat(bossIdx, this_plugin_name, DOT_STRING, 2);
			DOT_EnterPenalty[clientIdx] = FF2_GetAbilityArgumentFloat(bossIdx, this_plugin_name, DOT_STRING, 3);
			DOT_ExitPenalty[clientIdx] = FF2_GetAbilityArgumentFloat(bossIdx, this_plugin_name, DOT_STRING, 4);
			ReadSound(bossIdx, DOT_STRING, 5, DOT_EntrySound[clientIdx]);
			ReadSound(bossIdx, DOT_STRING, 6, DOT_ExitSound[clientIdx]);
			FF2_GetAbilityArgumentString(bossIdx, this_plugin_name, DOT_STRING, 7, DOT_EntryEffect[clientIdx], MAX_EFFECT_NAME_LENGTH);
			DOT_EntryEffectDuration[clientIdx] = FF2_GetAbilityArgumentFloat(bossIdx, this_plugin_name, DOT_STRING, 8);
			FF2_GetAbilityArgumentString(bossIdx, this_plugin_name, DOT_STRING, 9, DOT_ExitEffect[clientIdx], MAX_EFFECT_NAME_LENGTH);
			DOT_ExitEffectDuration[clientIdx] = FF2_GetAbilityArgumentFloat(bossIdx, this_plugin_name, DOT_STRING, 10);
			FF2_GetAbilityArgumentString(bossIdx, this_plugin_name, DOT_STRING, 11, conditionStr, CONDITION_STRING_LENGTH);
			if (!IsEmptyString(conditionStr))
			{
				new conditionCount = 0;
				if (StrContains(conditionStr, CONDITION_DELIM) < 0)
					conditionCount = ExplodeString(conditionStr, CONDITION_DELIM_SHORT, conditions, MAX_CONDITIONS, 4);
				else
					conditionCount = ExplodeString(conditionStr, CONDITION_DELIM, conditions, MAX_CONDITIONS, 4);
				for (new condIdx = 0; condIdx < conditionCount; condIdx++)
				{
					DOT_ConditionChanges[clientIdx][condIdx] = StringToInt(conditions[condIdx]);
					//PrintToServer("[drain_over_time] Condition: %d", DOT_ConditionChanges[clientIdx][condIdx]);
				}
			}
			DOT_NoOverlay[clientIdx] = FF2_GetAbilityArgument(bossIdx, this_plugin_name, DOT_STRING, 12) == 1;
			DOT_CooldownDurationTicks[clientIdx] = RoundFloat(FF2_GetAbilityArgumentFloat(bossIdx, this_plugin_name, DOT_STRING, 13) * 10.0);
			DOT_ActivationKey[clientIdx] = FF2_GetAbilityArgument(bossIdx, this_plugin_name, DOT_STRING, 14);
			DOT_AllowWhileStunned[clientIdx] = FF2_GetAbilityArgument(bossIdx, this_plugin_name, DOT_STRING, 15) == 1;
			
			// fix activation key
			switch(DOT_ActivationKey[clientIdx])
			{
				case 0: DOT_ActivationKey[clientIdx] = IN_RELOAD;
				case 1: DOT_ActivationKey[clientIdx] = IN_ATTACK3;
				case 2: DOT_ActivationKey[clientIdx] = IN_ATTACK2;
			}
			
			// warn user of mistake
			if (DOT_MinRage[clientIdx] < DOT_EnterPenalty[clientIdx])
				PrintToServer("[drain_over_time] For %d, minimum rage (%f) < rage entry cost (%f), should set minimum higher!", clientIdx, DOT_MinRage[clientIdx], DOT_EnterPenalty[clientIdx]);

			// init this just in case
			DOT_TimeOfLastSound[clientIdx] = GetEngineTime();

			// debug only
			dotUserCount++;
		}
	}

	if (DOT_ActiveThisRound)
	{
		if (PRINT_DEBUG_INFO)
			PrintToServer("[drain_over_time] DOT rage on %d boss(es) this round.", dotUserCount);
		DOTPostRoundStartInit();
		DOT_NextTick = GetEngineTime() + DOT_INTERVAL;
	}
	else
	{
		if (PRINT_DEBUG_INFO)
			PrintToServer("[drain_over_time] No DOT rage users this round.");
	}
	
	return Plugin_Stop;
}

public Action:Event_RoundEnd(Handle:event,const String:name[],bool:dontBroadcast)
{
	// round has ended, this'll kill the looping timer
	RoundInProgress = false;
	
	// remove overlays for all bosses
	for (new clientIdx = 0; clientIdx < MAX_PLAYERS; clientIdx++)
	{
		if (DOT_CanUse[clientIdx])
			RemoveDOTOverlay(clientIdx);
	}
}

public CancelDOTAbilityActivation(clientIdx)
{
	//new clientIdx = GetNativeCell(1);
	DOT_ActivationCancel[clientIdx] = true;
}

public ForceDOTAbilityDeactivation(clientIdx)
{
	//new clientIdx = GetNativeCell(1);
	if (DOT_RageActive[clientIdx])
		DOT_ForceDeactivation[clientIdx] = true;
}

public SetDOTUsability(clientIdx, usability)
{
	//new clientIdx = GetNativeCell(1);
	//new bool:usability = GetNativeCell(2) == 1;
	DOT_Usable[clientIdx] = usability == 1;
}

// ensure that sounds are not spammed by user spamming R. two seconds between sounds played
PlaySoundLocal(clientIdx, const String:soundPath[])
{
	if (DOT_TimeOfLastSound[clientIdx] + 2.0 > GetEngineTime()) // two second interval check
		return; // prevent spam
	else if (strlen(soundPath) < 3)
		return; // nothing to play
		
	// play a speech sound that travels normally, local from the player.
	// I can swear that sounds are louder from eye position than origin...
	decl Float:playerPos[3];
	//GetEntPropVector(clientIdx, Prop_Send, "m_vecOrigin", playerPos);
	GetClientEyePosition(clientIdx, playerPos);
	EmitAmbientSound(soundPath, playerPos, clientIdx);
	DOT_TimeOfLastSound[clientIdx] = GetEngineTime();
}

// also need to ensure this one isn't spammed
TransitionEffect(clientIdx, String:effectName[], Float:duration)
{
	if (IsEmptyString(effectName))
		return; // nothing to play
	if (duration == 0.0)
		duration = 0.1; // probably doesn't matter for this effect, I just don't feel comfortable passing 0 to a timer
		
	new Float:bossPos[3];
	GetEntPropVector(clientIdx, Prop_Send, "m_vecOrigin", bossPos);
	new particle = AttachParticle(clientIdx, effectName, 75.0);
	if (IsValidEntity(particle))
		CreateTimer(duration, RemoveEntityDA, EntIndexToEntRef(particle), TIMER_FLAG_NO_MAPCHANGE);
}

// repeating timers documented here: https://wiki.alliedmods.net/Timers_%28SourceMod_Scripting%29
new overlayTickCount = 0;
public Action:TickDOTs(Float:curTime)
{
	if (curTime >= DOT_NextTick)
		overlayTickCount++;
		
	for (new clientIdx = 1; clientIdx < MAX_PLAYERS; clientIdx++)
	{
		// only bother if client is using the plugin
		if (!DOT_CanUse[clientIdx])
			continue;
		else if (!IsLivingPlayer(clientIdx))
		{
			OnDOTUserDeath(clientIdx, IsClientInGame(clientIdx) ? 1 : 0);
			DOT_CanUse[clientIdx] = false;
			continue;
		}
		else if (curTime < DOT_NextTick)
			continue;
		
		if (DOT_IsOnCooldown[clientIdx])
		{
			DOT_CooldownTicksRemaining[clientIdx]--;
			if (DOT_CooldownTicksRemaining[clientIdx] <= 0)
				DOT_IsOnCooldown[clientIdx] = false;
		}
			
		new bool:dotRageStart = false;
		new bool:dotRageStop = false;
		new Float:ragePenalty = 0.0;
		new bossIdx = FF2_GetBossIndex(clientIdx);
		new Float:rage = FF2_GetBossCharge(bossIdx, 0);
		if (DOT_ReloadPressPending[clientIdx])
		{
			if (DOT_RageActive[clientIdx]) // player manually stops the DOT
			{
				ragePenalty = DOT_ExitPenalty[clientIdx];
				dotRageStop = true;
			}
			else if (rage >= DOT_MinRage[clientIdx]) // player enters DOT
				dotRageStart = true;
				
			DOT_ReloadPressPending[clientIdx] = false;
		}
		
		// drain rage if DOT is active
		if (DOT_RageActive[clientIdx])
		{
			rage -= DOT_RageDrain[clientIdx];
			if (rage < 0.0)
			{
				dotRageStop = true; // force player out of manic mode
				rage = 0.0;
			}
			FF2_SetBossCharge(bossIdx, 0, rage);
		}
		
		// don't start rage if on cooldown
		if (DOT_IsOnCooldown[clientIdx])
			dotRageStart = false;

		// leaks shouldn't ever happen here, but it's better for most plugins to get the exit after the enter
		if (dotRageStart && DOT_Usable[clientIdx] && !DOT_ForceDeactivation[clientIdx])
		{
			OnDOTAbilityActivated(clientIdx);
			if (!DOT_ActivationCancel[clientIdx])
			{
				if (PRINT_DEBUG_INFO)
					PrintToServer("[drain_over_time] %d entered DOT rage. (cooldown=%d ticks)", clientIdx, DOT_CooldownDurationTicks[clientIdx]);
				PlaySoundLocal(clientIdx, DOT_EntrySound[clientIdx]);
				TransitionEffect(clientIdx, DOT_EntryEffect[clientIdx], 1.5);
				DOT_RageActive[clientIdx] = true;
				DOT_ActiveTickCount[clientIdx] = 0;
				ragePenalty = DOT_EnterPenalty[clientIdx];
				RemoveDOTOverlay(clientIdx);

				// add conditions
				for (new condIdx = 0; condIdx < MAX_CONDITIONS; condIdx++)
				{
					if (DOT_ConditionChanges[clientIdx][condIdx] == -1)
						break;

					TF2_AddCondition(clientIdx, TFCond:DOT_ConditionChanges[clientIdx][condIdx], -1.0);
				}
				
				// cooldown
				if (DOT_CooldownDurationTicks[clientIdx] > 0)
				{
					DOT_IsOnCooldown[clientIdx] = true;
					DOT_CooldownTicksRemaining[clientIdx] = DOT_CooldownDurationTicks[clientIdx];
				}
			}
		}
		if (DOT_RageActive[clientIdx] && !DOT_ActivationCancel[clientIdx] && !DOT_ForceDeactivation[clientIdx])
		{
			OnDOTAbilityTick(clientIdx, DOT_ActiveTickCount[clientIdx]);
			DOT_ActiveTickCount[clientIdx]++;
		}
		if (dotRageStop || DOT_ActivationCancel[clientIdx] || (DOT_RageActive[clientIdx] && DOT_ForceDeactivation[clientIdx]))
		{
			OnDOTAbilityDeactivated(clientIdx);
			if (!DOT_ActivationCancel[clientIdx])
			{
				if (PRINT_DEBUG_INFO)
					PrintToServer("[drain_over_time] %d exited DOT rage.", clientIdx);
				PlaySoundLocal(clientIdx, DOT_ExitSound[clientIdx]);
				TransitionEffect(clientIdx, DOT_ExitEffect[clientIdx], 1.5);
				DOT_RageActive[clientIdx] = false;

				// remove conditions
				for (new condIdx = 0; condIdx < MAX_CONDITIONS; condIdx++)
				{
					if (DOT_ConditionChanges[clientIdx][condIdx] == -1)
						break;
					
					if (TF2_IsPlayerInCondition(clientIdx, TFCond:DOT_ConditionChanges[clientIdx][condIdx]))
						TF2_RemoveCondition(clientIdx, TFCond:DOT_ConditionChanges[clientIdx][condIdx]);
				}
			}
			DOT_ActivationCancel[clientIdx] = false;
			DOT_ForceDeactivation[clientIdx] = false;
		}
		
		// in some cases, standard rages may force the deactivation of a DOT, but it has no way of knowing if it's
		// really active. just silently set this to false in such a case.
		if (!DOT_RageActive[clientIdx] && DOT_ForceDeactivation[clientIdx])
			DOT_ForceDeactivation[clientIdx] = false;
		
		// handle any rage penalties, entry or exit
		if (ragePenalty > 0)
		{
			rage -= ragePenalty;
			if (rage < 0.0)
				rage = 0.0;
			FF2_SetBossCharge(bossIdx, 0, rage);
		}
		
		// DOT overlay, some conditions for its appearance and removal
		if (DOT_RageActive[clientIdx] || (rage >= DOT_MinRage[clientIdx] && !DOT_IsOnCooldown[clientIdx]))
			DisplayDOTOverlay(clientIdx);
		else if ((rage < DOT_MinRage[clientIdx] || DOT_IsOnCooldown[clientIdx]) && DOT_OverlayVisible[clientIdx])
			RemoveDOTOverlay(clientIdx); // this only happens if standard 100% rage is used
	}
	
	if (curTime >= DOT_NextTick)
		DOT_NextTick += DOT_INTERVAL; // get more accuracy with these ticks
		
	return Plugin_Continue;
}

public OnGameFrame()
{
	if (DOT_ActiveThisRound && RoundInProgress)
		TickDOTs(GetEngineTime());
}

public Action:OnPlayerRunCmd(clientIdx, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (!DOT_ActiveThisRound || !RoundInProgress || !IsLivingPlayer(clientIdx) || !DOT_CanUse[clientIdx])
		return Plugin_Continue;

	// check key state, all we can get is the held state so use that to determine press/release
	if (buttons & DOT_ActivationKey[clientIdx]) // reload pressed!
	{
		// key pressed?
		if (!DOT_ReloadDown[clientIdx])
		{
			if (!TF2_IsPlayerInCondition(clientIdx, TFCond_Dazed) || DOT_AllowWhileStunned[clientIdx])
				DOT_ReloadPressPending[clientIdx] = true;
			DOT_ReloadDown[clientIdx] = true;
		}
	}
	else
	{
		// key released?
		if (DOT_ReloadDown[clientIdx])
			DOT_ReloadDown[clientIdx] = false;
	}
		
	return Plugin_Continue;
}

// unused, but required
public Action:FF2_OnAbility2(index, const String:plugin_name[], const String:ability_name[], status) { return Plugin_Continue; }

/**
 * READ THE LONG-WINDED COMMENTS BEFORE COPYING WHAT I DID.
 */
DisplayDOTOverlay(clientIdx)
{
	// ohai
	// So you may be wondering how I got this overlay to show up, when you don't even need to be a coder
	// to realize how screwed up the HUD overlays are.
	// Simple answer: I cheated.
	// I created a client command overlay similar to what Demopan uses, but I gave it to the hale.
	// This is after careful consideration of a couple things:
	// - Hales don't get overlays, except in rare cases for cosmetic reasons. (i.e. Doomguy)
	// - I'd have to modify the FF2 source to tack on my message to an existing overlay. That's a no-no.
	// - There's a limited number of overlays available...probably six. Adding my own overlay would destroy another, or just not appear.
	// So with that in mind I'm doing it this way. Keep this in mind if you copy this code. If you use this in your DOT...
	// well...don't.
	// The problem is you can only have one of these, period.
	// So if you use this code, remember that any existing overlay that client uses will vanish when you add yours.
	// And vice versa.
	// Server operators (who code) have it easy. :P Getting to pick and choose what HUDs are worth it and fixing the overuse in the FF2 code...
	// oh yeah, this isn't localized. Sorry about that.
	new bool:shouldExecute = (overlayTickCount % 5 == 0) || !DOT_OverlayVisible[clientIdx];
	shouldExecute = shouldExecute && !DOT_NoOverlay[clientIdx];
	if (!shouldExecute)
		return;
	
	new flags = GetCommandFlags("r_screenoverlay");
	SetCommandFlags("r_screenoverlay", flags & ~FCVAR_CHEAT);
	if ((overlayTickCount / 5) % 2 == 0)
	{
		if(DOT_ActivationKey[clientIdx] == IN_RELOAD)
			ClientCommand(clientIdx, "r_screenoverlay freak_fortress_2/dots/reload_overlay1");
		else if (DOT_ActivationKey[clientIdx] == IN_ATTACK3)
			ClientCommand(clientIdx, "r_screenoverlay freak_fortress_2/dots/attack3_overlay1");
		else
			ClientCommand(clientIdx, "r_screenoverlay freak_fortress_2/dots/alt_fire_overlay1");
	}
	else
	{
		if(DOT_ActivationKey[clientIdx] == IN_RELOAD)
			ClientCommand(clientIdx, "r_screenoverlay freak_fortress_2/dots/reload_overlay2");
		else if (DOT_ActivationKey[clientIdx] == IN_ATTACK3)
			ClientCommand(clientIdx, "r_screenoverlay freak_fortress_2/dots/attack3_overlay2");
		else
			ClientCommand(clientIdx, "r_screenoverlay freak_fortress_2/dots/alt_fire_overlay2");	
	}
	SetCommandFlags("r_screenoverlay", flags);
	
	DOT_OverlayVisible[clientIdx] = true;
}

RemoveDOTOverlay(clientIdx)
{
	if (!IsClientInGame(clientIdx) || DOT_NoOverlay[clientIdx])
		return;
	
	new flags = GetCommandFlags("r_screenoverlay");
	SetCommandFlags("r_screenoverlay", flags & ~FCVAR_CHEAT);
	ClientCommand(clientIdx, "r_screenoverlay \"\"");
	SetCommandFlags("r_screenoverlay", flags);
	
	DOT_OverlayVisible[clientIdx] = false;
}

/**
 * Stocks
 */
stock bool:IsLivingPlayer(clientIdx)
{
	if (clientIdx <= 0 || clientIdx >= MAX_PLAYERS)
		return false;
		
	return IsClientInGame(clientIdx) && IsPlayerAlive(clientIdx);
}

stock ReadSound(bossIdx, const String:ability_name[], argInt, String:soundFile[MAX_SOUND_FILE_LENGTH])
{
	FF2_GetAbilityArgumentString(bossIdx, this_plugin_name, ability_name, argInt, soundFile, MAX_SOUND_FILE_LENGTH);
	if (strlen(soundFile) > 3)
		PrecacheSound(soundFile);
}

/**
 * CODE BELOW TAKEN FROM default_abilities, I CLAIM NO CREDIT
 */
public Action:RemoveEntityDA(Handle:timer, any:entid)
{
	new entity=EntRefToEntIndex(entid);
	if(IsValidEdict(entity) && entity>MAX_PLAYERS)
	{
		AcceptEntityInput(entity, "Kill");
	}
}

AttachParticle(entity, String:particleType[], Float:offset=0.0, bool:attach=true)
{
	new particle=CreateEntityByName("info_particle_system");

	if (!IsValidEntity(particle))
		return -1;
	decl String:targetName[128];
	decl Float:position[3];
	GetEntPropVector(entity, Prop_Send, "m_vecOrigin", position);
	position[2]+=offset;
	TeleportEntity(particle, position, NULL_VECTOR, NULL_VECTOR);

	Format(targetName, sizeof(targetName), "target%i", entity);
	DispatchKeyValue(entity, "targetname", targetName);

	DispatchKeyValue(particle, "targetname", "tf2particle");
	DispatchKeyValue(particle, "parentname", targetName);
	DispatchKeyValue(particle, "effect_name", particleType);
	DispatchSpawn(particle);
	SetVariantString(targetName);
	if(attach)
	{
		AcceptEntityInput(particle, "SetParent", particle, particle, 0);
		SetEntPropEnt(particle, Prop_Send, "m_hOwnerEntity", entity);
	}
	ActivateEntity(particle);
	AcceptEntityInput(particle, "start");
	return particle;
}
