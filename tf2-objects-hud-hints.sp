#pragma semicolon 1

#include <sourcemod>
#include <sdktools>

#include <tf2_stocks>

public Plugin myinfo =
{
	name        = "[TF2] HUD hints for buildings",
	author      = "bigmazi",
	description = "Shows an appropriate HUD hint for nearby buildings to players who use specific voice commands",
	version     = "1.0",
	url         = "https://steamcommunity.com/id/bmazi/"
};



// *** Constants ***
// ----------------------------------------------------------------------------

#define CMD_VOICEMENU "voicemenu"

#define SFX_NULL "vo/null.mp3"

#define HINT_OFFSET_Z 70.0

#define DEFAULT_SEEK_RADIUS "1920.0"

#define DEFAULT_HINT_LIFETIME "2.0"
#define MIN_HINT_LIFETIME 0.1
#define MAX_HINT_LIFETIME 10.0

#define VOICEMENU_COOLDOWN 0.5

#define X_MEDIC 0
#define Y_MEDIC 0

#define X_HELP 2
#define Y_HELP 0

#define X_BUILDING_REQUEST 1
#define Y_TELEPORTER 3
#define Y_DISPENSER  4
#define Y_SENTRY     5

enum ReactionToVoiceCommand
{
	Reaction_None             = 0,
	Reaction_HintIfNotHealthy = 1,
	Reaction_HintAlways       = 2,
	
	Reaction_MIN = Reaction_None,
	Reaction_MAX = Reaction_HintAlways
}



// *** Global data ***
// ----------------------------------------------------------------------------

ConVar cv_nReactToMedicCallMode;
ConVar cv_nReactToHelpRequestMode;
ConVar cv_bReactToBuildingRequest;
ConVar cv_flHintLifetime;

float g_seekRadiusSqr;
float g_canShowHintTime[MAXPLAYERS + 1];



// *** Entry points ***
// ----------------------------------------------------------------------------

public void OnPluginStart()
{
	{
		ConVar cvEnabled = CreateBoolConVar("sm_objhints", true,
			"Enable building HUD hints? 0 = no, 1 = yes");
		
		if (cvEnabled.BoolValue)
			AddCommandListener(OnVoicemenuUsed, "voicemenu");
		
		HookConVarChange(cvEnabled, OnPluginToggled);
	}
	
	{
		ConVar cvSeekRadius = CreateConVar(
			"sm_objhints_building_seek_radius",
			DEFAULT_SEEK_RADIUS,
			"Consider a building for a HUD hint only if it's within THIS radius of the player",
			FCVAR_NONE,
			true, 0.0
		);
		
		float value = cvSeekRadius.FloatValue;
		g_seekRadiusSqr = value * value;
		
		HookConVarChange(cvSeekRadius, OnSeekRadiusChanged);
	}
	
	cv_nReactToMedicCallMode = CreateReactionConVar("sm_objhints_handle_medic_cmd", Reaction_HintAlways,
		"How to handle 'MEDIC!' command? 0 = ignore, 1 = make a dispenser hint IF the player has less than max health or is on fire, 2 = ALWAYS make a dispenser hint");
	
	cv_nReactToHelpRequestMode = CreateReactionConVar("sm_objhints_handle_help_cmd", Reaction_HintIfNotHealthy,
		"How to handle 'Help!' command? 0 = ignore, 1 = make a dispenser hint IF the player has less than max health or is on fire, 2 = ALWAYS make a dispenser hint");
		
	cv_bReactToBuildingRequest = CreateBoolConVar("sm_objhints_handle_build_request_cmd", true,
		"Make a HUD hint for an appropriate building type when a player uses 'Need a Teleporter/Dispenser/Sentry here' command? 0 = no, 1 = yes");
	
	cv_flHintLifetime = CreateConVar(
		"sm_objhints_hint_lifetime",
		DEFAULT_HINT_LIFETIME,
		"The hint will stay on the player's HUD for THIS many seconds",
		FCVAR_NONE,
		true, MIN_HINT_LIFETIME,
		true, MAX_HINT_LIFETIME
	);
	
	AutoExecConfig();	
}

public void OnMapStart()
{
	for (int client = 1; client < sizeof(g_canShowHintTime); ++client)
		g_canShowHintTime[client] = 0.0;
}

void OnPluginToggled(ConVar cv, const char[] oldValue, const char[] newValue)
{	
	bool wasEnabled = !!StringToInt(oldValue);
	bool isEnabled  = !!StringToInt(newValue);
	
	if (isEnabled && !wasEnabled)
	{
		AddCommandListener(OnVoicemenuUsed, CMD_VOICEMENU);
	}
	else if (!isEnabled && wasEnabled)
	{
		RemoveCommandListener(OnVoicemenuUsed, CMD_VOICEMENU);
	}
}

void OnSeekRadiusChanged(ConVar cv, const char[] oldValue, const char[] newValue)
{	
	float radius = StringToFloat(newValue);
	g_seekRadiusSqr = radius * radius;
}

Action OnVoicemenuUsed(int client, const char[] command, int argsCount)
{
	if (GetGameTime() <= g_canShowHintTime[client])
		return Plugin_Continue;
	
	if (argsCount != 2)
		return Plugin_Continue;
		
	if (!IsPlayerAlive(client))
		return Plugin_Continue;
	
	int x = GetVoicemenuArg(1);
	int y = GetVoicemenuArg(2);
		
	switch (x) // Assert X_MEDIC != X_HELP != X_BUILDING_REQUEST	
	{
		case X_MEDIC:
		{
			if (y == Y_MEDIC)
			{
				TryHintDispenserEx(client, cv_nReactToMedicCallMode);
			}
		}
		case X_HELP:
		{
			if (y == Y_HELP)
			{
				TryHintDispenserEx(client, cv_nReactToHelpRequestMode);
			}
		}
		case X_BUILDING_REQUEST:
		{
			if (cv_bReactToBuildingRequest.BoolValue)
			{
				switch (y)
				{
					case Y_TELEPORTER: TryHintTeleporter(client);
					case Y_DISPENSER:  TryHintDispenser(client);
					case Y_SENTRY:     TryHintSentry(client);
				}
			}
		}
	}
	
	return Plugin_Continue;
}



// *** Helpers ***
// ----------------------------------------------------------------------------

void TryHintTeleporter(int client) { TryHintBuilding(client, "obj_teleporter", "Teleporter"); }
void TryHintDispenser (int client) { TryHintBuilding(client, "obj_dispenser",  "Dispenser");  }
void TryHintSentry    (int client) { TryHintBuilding(client, "obj_sentrygun",  "Sentry Gun"); }

void TryHintDispenserEx(int client, ConVar cvReactionMode)
{
	ReactionToVoiceCommand mode = GetReactionModeFromConVar(cvReactionMode);
	
	switch (mode)
	{
		case Reaction_HintIfNotHealthy:
		{
			if (!IsClientAtMaxHealth(client) || IsClientBurning(client))
			{
				TryHintDispenser(client);
			}
		}
		case Reaction_HintAlways:
		{
			TryHintDispenser(client);
		}
	}
}

ConVar CreateBoolConVar(const char[] name, bool defaultValue, const char[] description)
{
	return CreateConVar(
		name,
		defaultValue ? "1" : "0",
		description,
		FCVAR_NONE,
		true, 0.0,
		true, 1.0
	);
}

ConVar CreateReactionConVar(const char[] name, ReactionToVoiceCommand defaultValue, const char[] description)
{
	char strValue[2];
	strValue[0] = '0' + view_as<char>(defaultValue);
	strValue[1] = '\0';
	
	float flMin = 1.0 * view_as<int>(Reaction_MIN);
	float flMax = 1.0 * view_as<int>(Reaction_MAX);
	
	return CreateConVar(
		name,
		strValue,
		description,
		FCVAR_NONE,
		true, flMin,
		true, flMax
	);
}

ReactionToVoiceCommand GetReactionModeFromConVar(ConVar cv)
{
	int value = cv.IntValue;
	return view_as<ReactionToVoiceCommand>(value);
}

int GetVoicemenuArg(int argIndex)
{
	char buf[2];
	GetCmdArg(argIndex, buf, sizeof(buf));
	
	return view_as<int>(buf[0]) - view_as<int>('0');
}

void TryHintBuilding(int client, const char[] class, const char caption[16])
{
	int clientTeam = GetClientTeam(client);
	
	float clientPos[3];
	GetClientAbsOrigin(client, clientPos);
	
	float minDistSqr = g_seekRadiusSqr;
	int closestBuilding = 0;
	
	int building = -1;
	
	while ((building = FindEntityByClassname(building, class)) != -1)
	{
		float distSqr;
		
		bool isBetter = GetBuildingTeam(building) == clientTeam
			&& !IsBuildingBlueprint(building)
			&& (distSqr = DistanceToEntitySquared(clientPos, building)) < minDistSqr;
		
		if (isBetter)
		{
			minDistSqr = distSqr;
			closestBuilding = building;
		}
	}
	
	if (closestBuilding)
	{
		ShowNotification(client, closestBuilding, caption);
		g_canShowHintTime[client] = GetGameTime() + VOICEMENU_COOLDOWN;
	}
}

int GetBuildingTeam(int building)
{
	return GetEntProp(building, Prop_Send, "m_iTeamNum");
}

bool IsBuildingBlueprint(int building)
{
	return !!GetEntProp(building, Prop_Send, "m_bPlacing");
}

float DistanceToEntitySquared(const float source[3], int entity)
{
	float vector[3];
	
	GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", vector);
	SubtractVectors(vector, source, vector);
	
	return GetVectorLength(vector, true);
}

void ShowNotification(int client, int entity, const char caption[16])
{
	float pos[3];	
	GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", pos);
	
	Event event = CreateEvent("show_annotation");
 
	event.SetFloat("worldPosX", pos[0]);
	event.SetFloat("worldPosY", pos[1]);
	event.SetFloat("worldPosZ", pos[2] + HINT_OFFSET_Z);
	
	event.SetFloat("worldNormalX", 0.0);
	event.SetFloat("worldNormalY", 0.0);
	event.SetFloat("worldNormalZ", 1.0);
	
	event.SetInt("id", client);
	event.SetInt("visibilityBitfield", 1 << client);	
	
	event.SetString("text", caption);
	event.SetFloat("lifetime", cv_flHintLifetime.FloatValue);
	
	event.SetInt("follow_entindex", 0);
	event.SetBool("show_distance", false);
	event.SetString("play_sound", SFX_NULL);
	event.SetBool("show_effect", false);
	
	event.Fire();
}

bool IsClientAtMaxHealth(int client)
{
	int max = GetClientMaxHealth(client);
	int crr = GetClientHealth(client);
	return crr >= max;
}

int GetClientMaxHealth(int client)
{
	return GetEntProp(GetPlayerResourceEntity(), Prop_Send, "m_iMaxHealth", _, client);
}

bool IsClientBurning(int client)
{
	return TF2_IsPlayerInCondition(client, TFCond_OnFire);
}