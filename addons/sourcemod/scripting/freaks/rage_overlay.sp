/*
rage_overlay:	arg0 - slot (def.0)
				arg1 - path to overlay ("root" is \tf\materials\)
				arg2 - duration (def.6)
*/
#pragma semicolon 1

#include <sourcemod>
#include <tf2items>
#include <tf2_stocks>
#include <freak_fortress_2>
#include <freak_fortress_2_subplugin>

#pragma newdecls required

int BossTeam=view_as<int>(TFTeam_Blue);

#define PLUGIN_VERSION "1.9.3"

public Plugin myinfo=
{
	name="Freak Fortress 2: rage_overlay",
	author="Jery0987, RainBolt Dash",
	description="FF2: Ability that covers all living, non-boss team players screens with an image",
	version=PLUGIN_VERSION,
};

public void OnPluginStart2()
{
	HookEvent("teamplay_round_start", OnRoundStart);
}

public Action OnRoundStart(Handle event, const char[] name, bool dontBroadcast)
{
	CreateTimer(0.3, Timer_GetBossTeam, _, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Continue;
}

public Action Timer_GetBossTeam(Handle hTimer)
{
	BossTeam=FF2_GetBossTeam();
	return Plugin_Continue;
}

public Action FF2_OnAbility2(int boss, const char[] plugin_name, const char[] ability_name, int status)
{
	if(!strcmp(ability_name, "rage_overlay"))
	{
		Rage_Overlay(boss, ability_name);
	}
	return Plugin_Continue;
}

void Rage_Overlay(int boss, const char[] ability_name)
{
	char overlay[PLATFORM_MAX_PATH];
	FF2_GetAbilityArgumentString(boss, this_plugin_name, ability_name, 1, overlay, PLATFORM_MAX_PATH);
	Format(overlay, PLATFORM_MAX_PATH, "r_screenoverlay \"%s\"", overlay);
	SetCommandFlags("r_screenoverlay", GetCommandFlags("r_screenoverlay") & ~FCVAR_CHEAT);
	for(int target=1; target<=MaxClients; target++)
	{
		if(IsClientInGame(target) && IsPlayerAlive(target) && GetClientTeam(target)!=BossTeam)
		{
			ClientCommand(target, overlay);
		}
	}

	CreateTimer(FF2_GetAbilityArgumentFloat(boss, this_plugin_name, ability_name, 2, 6.0), Timer_Remove_Overlay, _, TIMER_FLAG_NO_MAPCHANGE);
	SetCommandFlags("r_screenoverlay", GetCommandFlags("r_screenoverlay") & FCVAR_CHEAT);
}

public Action Timer_Remove_Overlay(Handle timer)
{
	SetCommandFlags("r_screenoverlay", GetCommandFlags("r_screenoverlay") & ~FCVAR_CHEAT);
	for(int target=1; target<=MaxClients; target++)
	{
		if(IsClientInGame(target) && IsPlayerAlive(target) && GetClientTeam(target)!=BossTeam)
		{
			ClientCommand(target, "r_screenoverlay off");
		}
	}
	SetCommandFlags("r_screenoverlay", GetCommandFlags("r_screenoverlay") & FCVAR_CHEAT);
	return Plugin_Continue;
}