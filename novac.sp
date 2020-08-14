#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <dhooks>

#pragma newdecls required

public Plugin myinfo = 
{
	name = "noVAC",
	author = "vanz",
	version = "0.0.5"
};

// Callback values for callback ValidateAuthTicketResponse_t which is a response to BeginAuthSession
enum EAuthSessionResponse
{
	k_EAuthSessionResponseOK = 0,							// Steam has verified the user is online, the ticket is valid and ticket has not been reused.
	k_EAuthSessionResponseUserNotConnectedToSteam = 1,		// The user in question is not connected to steam
	k_EAuthSessionResponseNoLicenseOrExpired = 2,			// The license has expired.
	k_EAuthSessionResponseVACBanned = 3,					// The user is VAC banned for this game.
	k_EAuthSessionResponseLoggedInElseWhere = 4,			// The user account has logged in elsewhere and the session containing the game instance has been disconnected.
	k_EAuthSessionResponseVACCheckTimedOut = 5,				// VAC has been unable to perform anti-cheat checks on this user
	k_EAuthSessionResponseAuthTicketCanceled = 6,			// The ticket has been canceled by the issuer
	k_EAuthSessionResponseAuthTicketInvalidAlreadyUsed = 7,	// This ticket has already been used, it is not valid.
	k_EAuthSessionResponseAuthTicketInvalid = 8,			// This ticket is not from a user instance currently connected to steam.
	k_EAuthSessionResponsePublisherIssuedBan = 9,			// The user is banned for this game. The ban came via the web api and not VAC
};

enum EDenyReason
{
	k_EDenyInvalidVersion = 1,
	k_EDenyGeneric = 2,
	k_EDenyNotLoggedOn = 3,
	k_EDenyNoLicense = 4,
	k_EDenyCheater = 5,
	k_EDenyLoggedInElseWhere = 6,
	k_EDenyUnknownText = 7,
	k_EDenyIncompatibleAnticheat = 8,
	k_EDenyMemoryCorruption = 9,
	k_EDenyIncompatibleSoftware = 10,
	k_EDenySteamConnectionLost = 11,
	k_EDenySteamConnectionError = 12,
	k_EDenySteamResponseTimedOut = 13,
	k_EDenySteamValidationStalled = 14,
};

enum struct mem_patch
{
	Address addr;
	int len;
	char patch[256];
	char orig[256];

	bool Init(GameData conf, const char[] key, Address addr)
	{
		int offset, pos, curPos;
		char byte[16], bytes[512];
		
		if (this.len)
			return false;
		
		if (!conf.GetKeyValue(key, bytes, sizeof(bytes)))
			return false;
		
		offset = conf.GetOffset(key);
		
		if (offset == -1)
			offset = 0;
		
		this.addr = addr + view_as<Address>(offset);
		
		StrCat(bytes, sizeof(bytes), " ");
		
		while ((pos = SplitString(bytes[curPos], " ", byte, sizeof(byte))) != -1)
		{
			curPos += pos;
			
			TrimString(byte);
			
			if (byte[0])
			{
				this.patch[this.len] = StringToInt(byte, 16);
				this.orig[this.len] = LoadFromAddress(this.addr + view_as<Address>(this.len), NumberType_Int8);
				this.len++;
			}
		}
		
		return true;
	}
	
	void Apply()
	{
		for (int i = 0; i < this.len; i++)
			StoreToAddress(this.addr + view_as<Address>(i), this.patch[i], NumberType_Int8);
	}
	
	void Restore()
	{
		for (int i = 0; i < this.len; i++)
			StoreToAddress(this.addr + view_as<Address>(i), this.orig[i], NumberType_Int8);
	}
}

mem_patch g_gameRulesThinkPatch;

ConVar g_CVarMode;

ArrayList g_noVACUsers;

Handle g_detourOnValidateAuthTicketResponse;
Handle g_detourOnGSClientDeny;

Handle g_callOnGSClientApprove;

public void OnPluginStart()
{
	g_noVACUsers = new ArrayList();

	GameData conf = new GameData("novac.games");
	
	if (conf == null) 
		SetFailState("Failed to load novac gamedata");

	if (GetEngineVersion() == Engine_Left4Dead)
	{
		if (!(g_detourOnGSClientDeny = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Void, ThisPointer_Address))) 
			SetFailState("Failed to setup detour for CSteam3Server::OnGSClientDeny");
			
		if (!DHookSetFromConf(g_detourOnGSClientDeny, conf, SDKConf_Signature, "CSteam3Server::OnGSClientDeny")) 
			SetFailState("Failed to load CSteam3Server::OnGSClientDeny signature from gamedata");
		
		DHookAddParam(g_detourOnGSClientDeny, HookParamType_Int);

		if (!DHookEnableDetour(g_detourOnGSClientDeny, false, Detour_OnGSClientDeny)) 
			SetFailState("Failed to detour CSteam3Server::OnGSClientDeny");

		StartPrepSDKCall(SDKCall_Raw);
		
		if (!PrepSDKCall_SetFromConf(conf, SDKConf_Signature, "CSteam3Server::OnGSClientApprove"))
			SetFailState("Failed to load CSteam3Server::OnGSClientApprove from gamedata");
		
		PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
		g_callOnGSClientApprove = EndPrepSDKCall();
	}
	else
	{
		if (!(g_detourOnValidateAuthTicketResponse = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Void, ThisPointer_Ignore))) 
			SetFailState("Failed to setup detour for CSteam3Server::OnValidateAuthTicketResponse");
			
		if (!DHookSetFromConf(g_detourOnValidateAuthTicketResponse, conf, SDKConf_Signature, "CSteam3Server::OnValidateAuthTicketResponse")) 
			SetFailState("Failed to load CSteam3Server::OnValidateAuthTicketResponse signature from gamedata");
		
		DHookAddParam(g_detourOnValidateAuthTicketResponse, HookParamType_ObjectPtr);

		if (!DHookEnableDetour(g_detourOnValidateAuthTicketResponse, false, Detour_OnValidateAuthTicketResponse)) 
			SetFailState("Failed to detour CSteam3Server::OnValidateAuthTicketResponse");
	}
	
	if (GetEngineVersion() == Engine_CSGO)
	{
		Address gameRulesThinkAddr = conf.GetAddress("CCSGameRules::Think");
		
		if (!gameRulesThinkAddr) 
			SetFailState("Failed to load CCSGameRules::Think signature from gamedata");

		g_gameRulesThinkPatch.Init(conf, "CCSGameRules::Think_Patch", gameRulesThinkAddr);
		g_gameRulesThinkPatch.Apply();
	}
	
	delete conf;
	
	g_CVarMode = CreateConVar("sm_novac_mode", "0", "0 = Whitelist, 1 = Blacklist", FCVAR_NONE, true, 0.0, true, 1.0);
	
	LoadConfig();
	
	RegServerCmd("sm_novac_reload", Command_ReloadUsers);
}

public void OnPluginEnd()
{
	if (GetEngineVersion() == Engine_CSGO)
		g_gameRulesThinkPatch.Restore();
}

public Action Command_ReloadUsers(int args)
{
	LoadConfig();
	return Plugin_Handled;
}

public MRESReturn Detour_OnValidateAuthTicketResponse(Handle params)
{
	EAuthSessionResponse authSessionResponse = DHookGetParamObjectPtrVar(params, 1, 8, ObjectValueType_Int);
	
	if (authSessionResponse == k_EAuthSessionResponseVACBanned || authSessionResponse == k_EAuthSessionResponsePublisherIssuedBan)
	{
		int accountId = DHookGetParamObjectPtrVar(params, 1, 0, ObjectValueType_Int);

		int userIdx = g_noVACUsers.FindValue(accountId);

		bool allowJoin = g_CVarMode.BoolValue ? userIdx == -1 : userIdx != -1;

		if (allowJoin)
		{
			DHookSetParamObjectPtrVar(params, 1, 8, ObjectValueType_Int, k_EAuthSessionResponseOK);
			return MRES_ChangedHandled;
		}
	}

	return MRES_Ignored;
}

public MRESReturn Detour_OnGSClientDeny(Address thisPtr, Handle params)
{
	Address pGSClientDeny = DHookGetParam(params, 1);

	EDenyReason denyReason = view_as<EDenyReason>(LoadFromAddress(pGSClientDeny + view_as<Address>(0x08), NumberType_Int32));
	
	if (denyReason == k_EDenyCheater)
	{
		int accountId = LoadFromAddress(pGSClientDeny + view_as<Address>(0x00), NumberType_Int32);

		int userIdx = g_noVACUsers.FindValue(accountId);

		bool allowJoin = g_CVarMode.BoolValue ? userIdx == -1 : userIdx != -1;

		if (allowJoin)
		{
			SDKCall(g_callOnGSClientApprove, thisPtr, pGSClientDeny);
			return MRES_Supercede;
		}
	}

	return MRES_Ignored;
}

void LoadConfig()
{
	g_noVACUsers.Clear();

	char path[256];
	BuildPath(Path_SM, path, sizeof(path), "configs/novac_users.txt");
	
	File fileHandle = OpenFile(path, "r");
	
	if (fileHandle != null)
	{
		char line[PLATFORM_MAX_PATH];
	
		while (fileHandle.ReadLine(line, sizeof(line)))
		{
			int pos = StrContains(line, "//");
			
			if (pos != -1)
				line[pos] = '\0';
			
			TrimString(line);
			
			if (!line[0])
				continue;
				
			char steamid[3][16];
			
			if (ExplodeString(line, ":", steamid, sizeof(steamid), sizeof(steamid[])) == 3 && !strncmp(steamid[0], "STEAM_", 6))
			{
				int accountId = (StringToInt(steamid[2]) << 1) | (StringToInt(steamid[1]) & 1);
				g_noVACUsers.Push(accountId);
			}
			else
			{
				LogError("Error in: '%s', bad SteamID: '%s'", path, line);
			}
		}
		
		fileHandle.Close();
	}
}
