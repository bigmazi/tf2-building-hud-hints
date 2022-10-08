#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>

public Plugin myinfo =
{
	name        = "[TF2] HUD hints for buildings",
	author      = "bigmazi",
	description = "Shows an appropriate HUD hint for nearby buildings to players who use specific voice commands",
	version     = "1.2",
	url         = "https://steamcommunity.com/id/bmazi/"
};



// *** Constants ***
// ----------------------------------------------------------------------------

enum TFCond
{
	TFCond_OnFire = 22
}

enum TFObjectMode
{
	TFObjectMode_None = 0,
	TFObjectMode_Entrance = 0,
	TFObjectMode_Exit = 1
};

enum TFTeam
{
	TFTeam_Unassigned = 0,
	TFTeam_Spectator = 1,
	TFTeam_Red = 2,
	TFTeam_Blue = 3
};

#define CMD_VOICEMENU "voicemenu"

#define SFX_NULL "vo/null.mp3"

#define ANNOTATION_OFFSET_Z 70.0

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

enum HintMethod
{
	HintMethod_Annotation,
	HintMethod_Outline,
	HintMethod_AnnotationAndOutline,
	
	HintMethod_MIN = HintMethod_Annotation,
	HintMethod_MAX = HintMethod_AnnotationAndOutline
}

enum Color
{
	Color_Team,
	Color_White,
	Color_Green,
	Color_Custom,
	
	Color_MIN = Color_Team,
	Color_MAX = Color_Custom
}

#define COLOR_STRING_SIZE 16
#define CAPTION_STRING_SIZE 16

#define OUTLINES_PER_CLIENT 2
#define OUTLINE_INDEX_GENERAL 0
#define OUTLINE_INDEX_TELEPORTER_TIED_END 1



// *** Global data ***
// ----------------------------------------------------------------------------

Handle cookie_bEnabled;
bool g_enabledForClient[MAXPLAYERS + 1] = {true, ...};

ConVar cv_nHintMethod;

ConVar cv_nReactToMedicCallMode;
ConVar cv_nReactToHelpRequestMode;
ConVar cv_bReactToBuildingRequest;

ConVar cv_bShowBothTeleporterEnds;

ConVar cv_nOutlineColor;
ConVar cv_strCustomColor;

ConVar cv_flAnnotationLifetime;
ConVar cv_flOutlineLifetime;

float g_seekRadiusSqr;
float g_canSeekBuildingTime[MAXPLAYERS + 1];

int g_outlineRef[MAXPLAYERS + 1][OUTLINES_PER_CLIENT];

int off_CTFGlow_m_hOwnerEntity;



// *** Entry points ***
// ----------------------------------------------------------------------------

public void OnPluginStart()
{
	off_CTFGlow_m_hOwnerEntity = FindSendPropInfo("CTFGlow", "m_hOwnerEntity");
	
	cookie_bEnabled = RegClientCookie("cookie_objhints", "Toggles building HUD hints", CookieAccess_Protected);
	
	for (int client = 1; client <= MaxClients; ++client)
	{
		if (IsClientInGame(client) && AreClientCookiesCached(client))
		{
			OnClientCookiesCached(client);
		}
	}

	for (int client = 1; client < sizeof(g_outlineRef); ++client)
	{
		for (int outlineIndex = 0; outlineIndex < sizeof(g_outlineRef[]); ++outlineIndex)
		{
			g_outlineRef[client][outlineIndex] = -1;
		}
	}
	
	{
		ConVar cvEnabled = CreateBoolConVar("sm_objhints", true,
			"Enable building HUD hints? 0 = no, 1 = yes");
		
		if (cvEnabled.BoolValue)
			AddCommandListener(OnVoicemenuUsed, CMD_VOICEMENU);
		
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
		
	cv_nHintMethod = CreateHintMethodConVar("sm_objhints_hint_method", HintMethod_AnnotationAndOutline,
		"How exactly should hints appear from the player's point of view?"
		... " 0 = text annotation above building, 1 = outline around builing, 2 = both");
	
	cv_nReactToMedicCallMode = CreateReactionConVar("sm_objhints_handle_medic_cmd", Reaction_HintAlways,
		"How to handle 'MEDIC!' command?"
		... " 0 = ignore, 1 = make a dispenser hint IF the player has less than max health or is on fire,"
		... " 2 = ALWAYS make a dispenser hint");
	
	cv_nReactToHelpRequestMode = CreateReactionConVar("sm_objhints_handle_help_cmd", Reaction_HintIfNotHealthy,
		"How to handle 'Help!' command?"
		... " 0 = ignore, 1 = make a dispenser hint IF the player has less than max health or is on fire,"
		... " 2 = ALWAYS make a dispenser hint");
		
	cv_bReactToBuildingRequest = CreateBoolConVar("sm_objhints_handle_build_request_cmd", true,
		"Make a HUD hint for an appropriate building type when a player uses"
		... " 'Need a Teleporter/Dispenser/Sentry here' command? 0 = no, 1 = yes");
	
	cv_bShowBothTeleporterEnds = CreateBoolConVar("sm_objhints_show_outline_on_both_teleporter_ends", true,
		"Show outline on both teleporter ends? 0 = no, 1 = yes");
	
	cv_nOutlineColor = CreateColorConVar("sm_objhints_outline_color", Color_Team,
		"What color should outline have?"
		... " 0 = match team color, 1 = white, 2 = green, 3 = specify RGBA via 'sm_objhints_outline_color_custom_rgba'");
		
	cv_strCustomColor = CreateConVar(
		"sm_objhints_outline_color_custom_rgba",
		"255 255 255 255",
		"If 'sm_objhints_show_outline_color' is set to '3', THIS value will be used as outline color. Format: \"R G B A\" with decimal literals (0-255)",
		FCVAR_NONE
	);
	
	cv_flAnnotationLifetime = CreateConVar(
		"sm_objhints_lifetime_annotation",
		DEFAULT_HINT_LIFETIME,
		"The annotation will stay on the player's HUD for THIS many seconds",
		FCVAR_NONE,
		true, MIN_HINT_LIFETIME,
		true, MAX_HINT_LIFETIME
	);
	
	cv_flOutlineLifetime = CreateConVar(
		"sm_objhints_lifetime_outline",
		DEFAULT_HINT_LIFETIME,
		"The player will see the outline around the building for THIS many seconds",
		FCVAR_NONE,
		true, MIN_HINT_LIFETIME,
		true, MAX_HINT_LIFETIME
	);
	
	AutoExecConfig(true, "tf2-objects-hud-hints");	
}

public OnPluginEnd()
{
	for (int client = 1; client < sizeof(g_outlineRef); ++client)
	{
		for (int outlineIndex = 0; outlineIndex < sizeof(g_outlineRef[]); ++outlineIndex)
		{
			int ref = g_outlineRef[client][outlineIndex];
			int entity = EntRefToEntIndex(ref);
			
			if (entity != -1)
			{
				RemoveEntity(entity);
			}
		}
	}
}

public void OnMapStart()
{
	for (int client = 1; client < sizeof(g_canSeekBuildingTime); ++client)
		g_canSeekBuildingTime[client] = 0.0;
}

public void OnClientCookiesCached(int client)
{
	char buf[2];
	GetClientCookie(client, cookie_bEnabled, buf, sizeof(buf));
	
	// Will default to 1 if it's the first time the client connects
	bool value = buf[0] != '0';
	
	g_enabledForClient[client] = value;
}

public void OnClientDisconnect(int client)
{
	if (!AreClientCookiesCached(client))
		return;
	
	char value[2];
	value[0] = view_as<char>(g_enabledForClient[client]) + '0';
	value[1] = '\0';
	
	SetClientCookie(client, cookie_bEnabled, value);
}

public Action OnClientSayCommand(int client, const char[] command, const char[] arg)
{	
	Action res;
	
	switch (arg[0])
	{
		case '/': res = Plugin_Stop;
		case '!': res = Plugin_Continue;
		
		default:
			return Plugin_Continue;
	}
	
	bool goodPrefix =
		   (arg[1] == 'h' || arg[1] == 'H')
		&& (arg[2] == 'i' || arg[2] == 'I')
		&& (arg[3] == 'n' || arg[3] == 'N')
		&& (arg[4] == 't' || arg[4] == 'T');
	
	bool goodString = goodPrefix
		&& (!arg[5] || arg[5] == ' '
		|| ((arg[5] == 's' || arg[5] == 'S') && (!arg[6] || arg[6] == ' ')));
	
	if (!goodString)
		return Plugin_Continue;	
	
	if (AreClientCookiesCached(client))
	{		
		g_enabledForClient[client] = !g_enabledForClient[client];
		
		int id = GetClientUserId(client);
		RequestFrame(OnMustReplyToToggleCommand, id);
	}
	else
	{
		int id = GetClientUserId(client);
		RequestFrame(OnMustReplyToToggleCommandFailure, id);
	}
	
	return res;
}

void OnMustReplyToToggleCommand(int id)
{
	int client = GetClientOfUserId(id);
	
	if (client)
	{
		PrintToChat(client, "[SM] Building HUD hints are now %s",
			g_enabledForClient[client] ? "ON" : "OFF");
	}
}

void OnMustReplyToToggleCommandFailure(int id)
{
	int client = GetClientOfUserId(id);
	
	if (client)
	{
		PrintToChat(client, "[SM] Building HUD hints toggling was denied: cookies are not loaded yet");
	}
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
	if (!g_enabledForClient[client])
		return Plugin_Continue;
	
	if (GetGameTime() <= g_canSeekBuildingTime[client])
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

Action OnEntityExpired(Handle timer, int ref)
{
	int entity = EntRefToEntIndex(ref);
	
	if (entity != -1)
		RemoveEntity(entity);
	
	return Plugin_Continue;
}

Action OnOutlineTransmit(int outline, int recipient)
{	
	ForceTransmissionHandling(outline);	
	int owner = GetEntDataEnt2(outline, off_CTFGlow_m_hOwnerEntity);
	
	return recipient == owner
		? Plugin_Continue
		: Plugin_Handled;
}



// *** Helpers ***
// ----------------------------------------------------------------------------

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

void TryHintTeleporter(int client)
{
	int closestTeleporter = FindClosestBuilding(client, "obj_teleporter");
	if (closestTeleporter == -1) return;
	
	char caption[CAPTION_STRING_SIZE];
	GetTeleporterCaption(closestTeleporter, caption);
	
	HintBuilding(client, closestTeleporter, caption);
	
	if (cv_bShowBothTeleporterEnds.BoolValue)
	{
		int closestTeleporterBuilder = GetEntPropEnt(closestTeleporter, Prop_Send, "m_hBuilder");
		
		if (closestTeleporterBuilder != -1)
		{
			for (int teleporter = -1; (teleporter = FindEntityByClassname(teleporter, "obj_teleporter")) != -1;)
			{
				int builder = GetEntPropEnt(teleporter, Prop_Send, "m_hBuilder");
				
				if (builder == closestTeleporterBuilder && teleporter != closestTeleporter)
				{
					if (!IsBuildingBlueprint(teleporter))
						ShowOutline(client, teleporter, OUTLINE_INDEX_TELEPORTER_TIED_END);
					
					break;
				}
			}
		}
	}
}

void ShowAnnotation(int client, int entity, const char caption[CAPTION_STRING_SIZE])
{
	float pos[3];	
	GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", pos);
	
	Event event = CreateEvent("show_annotation");
 
	event.SetFloat("worldPosX", pos[0]);
	event.SetFloat("worldPosY", pos[1]);
	event.SetFloat("worldPosZ", pos[2] + ANNOTATION_OFFSET_Z);
	
	event.SetFloat("worldNormalX", 0.0);
	event.SetFloat("worldNormalY", 0.0);
	event.SetFloat("worldNormalZ", 1.0);
	
	event.SetInt("id", client);
	event.SetInt("visibilityBitfield", 1 << client);
	
	event.SetString("text", caption);
	event.SetFloat("lifetime", cv_flAnnotationLifetime.FloatValue);
	
	event.SetInt("follow_entindex", 0);
	event.SetBool("show_distance", false);
	event.SetString("play_sound", SFX_NULL);
	event.SetBool("show_effect", false);
	
	event.Fire();
}

void ShowOutline(int recipient, int target, int outlineIndex)
{	
	int outline = CreateEntityByName("tf_glow");
	if (outline == -1) return;
	
	{
		int ref = EntIndexToEntRef(outline);
		g_outlineRef[recipient][outlineIndex] = ref;
		CreateTimer(cv_flOutlineLifetime.FloatValue, OnEntityExpired, ref);
	}
	
	ForceTransmissionHandling(outline);
	SDKHook(outline, SDKHook_SetTransmit, OnOutlineTransmit);
	
	char targetName[16];
	Format(targetName, sizeof(targetName), "hintglow%i", target);
	DispatchKeyValue(target, "targetname", targetName);
	
	DispatchKeyValue(outline, "target", targetName);
	
	SetEntDataEnt2(outline, off_CTFGlow_m_hOwnerEntity, recipient, true);
	
	int team = GetClientTeam(recipient);
	SetEntProp(outline, Prop_Send, "m_iTeamNum", team);
	
	char color[COLOR_STRING_SIZE];
	GetOutlineColor(team, color);
	DispatchKeyValue(outline, "GlowColor", color);
	
	DispatchSpawn(outline);
	AcceptEntityInput(outline, "Enable");
}

void TryHintBuilding(int client, const char[] class, const char caption[CAPTION_STRING_SIZE])
{
	int closestBuilding = FindClosestBuilding(client, class);
	
	if (closestBuilding != -1)
		HintBuilding(client, closestBuilding, caption);
}

void HintBuilding(int client, int building, const char caption[CAPTION_STRING_SIZE])
{	
	for (int i = 0; i < OUTLINES_PER_CLIENT; ++i)
	{
		int ref = g_outlineRef[client][i];
		int entity = EntRefToEntIndex(ref);
		
		if (entity != -1)
			RemoveEntity(entity);
	}
	
	HintMethod hintMethod = view_as<HintMethod>(cv_nHintMethod.IntValue);
	
	switch (hintMethod)
	{
		case HintMethod_Annotation:
		{
			ShowAnnotation(client, building, caption);
		}
		case HintMethod_Outline:
		{
			ShowOutline(client, building, OUTLINE_INDEX_GENERAL);
		}
		case HintMethod_AnnotationAndOutline:
		{
			ShowAnnotation(client, building, caption);
			ShowOutline(client, building, OUTLINE_INDEX_GENERAL);
		}
	}
}

int FindClosestBuilding(int client, const char[] class)
{
	g_canSeekBuildingTime[client] = GetGameTime() + VOICEMENU_COOLDOWN;
	
	int clientTeam = GetClientTeam(client);
	
	float clientPos[3];
	GetClientAbsOrigin(client, clientPos);
	
	float minDistSqr = g_seekRadiusSqr;
	int closestBuilding = -1;
	
	for (int building = -1; (building = FindEntityByClassname(building, class)) != -1;)
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
	
	return closestBuilding;
}

void GetTeleporterCaption(int teleporter, char result[CAPTION_STRING_SIZE])
{
	int teleporterMode = GetEntProp(teleporter, Prop_Send, "m_iObjectMode");
	
	switch (view_as<TFObjectMode>(teleporterMode))
	{
		case TFObjectMode_Entrance:
			result = "Entrance";
		
		case TFObjectMode_Exit:
			result = "Exit";
		
		default:
			result = "Teleporter";
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

ConVar CreateHintMethodConVar(const char[] name, HintMethod defaultValue, const char[] description)
{
	char strValue[2];
	strValue[0] = '0' + view_as<char>(defaultValue);
	strValue[1] = '\0';
	
	float flMin = 1.0 * view_as<int>(HintMethod_MIN);
	float flMax = 1.0 * view_as<int>(HintMethod_MAX);
	
	return CreateConVar(
		name,
		strValue,
		description,
		FCVAR_NONE,
		true, flMin,
		true, flMax
	);
}

ConVar CreateColorConVar(const char[] name, Color defaultValue, const char[] description)
{
	char strValue[2];
	strValue[0] = '0' + view_as<char>(defaultValue);
	strValue[1] = '\0';
	
	float flMin = 1.0 * view_as<int>(Color_MIN);
	float flMax = 1.0 * view_as<int>(Color_MAX);
	
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

void GetOutlineColor(int team, char result[COLOR_STRING_SIZE])
{
	Color color = view_as<Color>(cv_nOutlineColor.IntValue);
	
	switch (color)
	{
		case Color_Team:
		{
			result = team == view_as<int>(TFTeam_Red)
				? "255 64 64 255"
				: "153 204 255 255";
		}
		case Color_White:
		{
			result = "255 255 255 255";
		}
		case Color_Green:
		{
			result = "153 255 153 255";
		}
		case Color_Custom:
		{
			GetConVarString(cv_strCustomColor, result, COLOR_STRING_SIZE);
			result[COLOR_STRING_SIZE - 1] = '\0';
		}
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
	return IsPlayerInCondition(client, TFCond_OnFire);
}

void ForceTransmissionHandling(int entity)
{
	int flags = GetEdictFlags(entity);
	int newFlags = ~(~flags | FL_EDICT_ALWAYS | FL_EDICT_DONTSEND | FL_EDICT_PVSCHECK);
	SetEdictFlags(entity, newFlags);
}

bool IsPlayerInCondition(int client, TFCond cond)
{
	int iCond = view_as<int>(cond);
	switch (iCond / 32)
	{
		case 0:
		{
			int bit = 1 << iCond;
			if ((GetEntProp(client, Prop_Send, "m_nPlayerCond") & bit) == bit)
			{
				return true;
			}

			if ((GetEntProp(client, Prop_Send, "_condition_bits") & bit) == bit)
			{
				return true;
			}
		}
		case 1:
		{
			int bit = (1 << (iCond - 32));
			if ((GetEntProp(client, Prop_Send, "m_nPlayerCondEx") & bit) == bit)
			{
				return true;
			}
		}
		case 2:
		{
			int bit = (1 << (iCond - 64));
			if ((GetEntProp(client, Prop_Send, "m_nPlayerCondEx2") & bit) == bit)
			{
				return true;
			}
		}
		case 3:
		{
			int bit = (1 << (iCond - 96));
			if ((GetEntProp(client, Prop_Send, "m_nPlayerCondEx3") & bit) == bit)
			{
				return true;
			}
		}
		case 4:
		{
			int bit = (1 << (iCond - 128));
			if ((GetEntProp(client, Prop_Send, "m_nPlayerCondEx4") & bit) == bit)
			{
				return true;
			}
		}
		default:
		{
			ThrowError("Invalid TFCond value %d", iCond);
		}
	}

	return false;
}