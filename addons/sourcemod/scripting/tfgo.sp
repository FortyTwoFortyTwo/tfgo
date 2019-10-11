#pragma semicolon 1

#include <morecolors>
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2_stocks>
#include <tf_econ_data>
#include <dhooks>

#pragma newdecls required

// TF2 stuff
#define TF_MAXPLAYERS 32
#define TF_NUMTEAMS 3
#define TF_NUMCLASSES  9
#define TF_WINREASON_CAPTURE_01 1
#define TF_WINREASON_ELIMINATION  2
#define TF_WINREASON_CAPTURE_02  	4

// TFGO stuff
#define TFGO_MINLOSESTREAK 0
#define TFGO_MAXLOSESTREAK 4

#define TFGO_STARTING_BALANCE			800
#define TFGO_MIN_BALANCE 				0
#define TFGO_MAX_BALANCE 				16000
#define TFGO_CAPTURE_WIN_REWARD			3500
#define TFGO_ELIMINATION_WIN_REWARD		3250

int g_iLoseStreak[TF_NUMTEAMS + 1] =  { 1, ... };
int g_iLoseStreakCompensation[TFGO_MAXLOSESTREAK + 1] =  { 1400, 1900, 2400, 2900, 3400 };
int g_iBalance[TF_MAXPLAYERS + 1] =  { TFGO_STARTING_BALANCE, ... };

// Timers
Handle g_hHudSync;
Handle g_hBuytimeTimer;
Handle g_h10SecondRoundTimer;
Handle g_hBombTimer;
Handle g_h10SecondBombTimer;

// Other handles
Menu g_hActiveBuyMenus[TF_MAXPLAYERS + 1];

/**
Pre-defined default weapons for each slot
-1 indicates the weapon in this slot should not be changed
**/
int g_iDefaultWeaponIndex[][] =  {
	{ -1, -1, -1, -1, -1, -1 },  //Unknown
	{ -1, 23, -1, -1, -1, -1 },  //Scout
	{ -1, 16, -1, -1, -1, -1 },  //Sniper
	{ -1, 10, -1, -1, -1, -1 },  //Soldier
	{ 19, -1, -1, -1, -1, -1 },  //Demoman
	{ 17, -1, -1, -1, -1, -1 },  //Medic
	{ -1, 11, -1, -1, -1, -1 },  //Heavy
	{ -1, 12, -1, -1, -1, -1 },  //Pyro
	{ -1, -1, -1, 27, 30, -1 },  //Spy
	{ 9, 22, -1, -1, 26, 28 } //Engineer
};

/**
If set to false, the weapon in the slot will be removed
Weapons that have not been assigned a default and are set to "true" in this map can be freely chosen
**/
int g_bSlotsToKeep[][] =  {
	{ false, false, false, false, false, false },  //Unknown
	{ false, false, true, false, false, false },  //Scout
	{ false, false, true, false, false, false },  //Sniper
	{ false, false, true, false, false, false },  //Soldier
	{ false, false, true, false, false, false },  //Demoman
	{ false, false, true, false, false, false },  //Medic
	{ false, false, true, false, false, false },  //Heavy
	{ false, false, true, false, false, false },  //Pyro
	{ true, false, false, false, false, false },  //Spy
	{ false, false, true, false, false, false } //Engineer
};

int g_iLoadoutWeaponIndex[TF_MAXPLAYERS + 1][9 + 1][6 + 1];

// Game state
bool g_bWaitingForPlayers;
bool g_bBuyTimeActive;
bool g_bRoundStarted;
bool g_bRoundActive;
bool g_bBombPlanted;

// ConVars
ConVar tfgo_buytime;

ConVar tf_arena_max_streak;
ConVar tf_arena_first_blood;
ConVar tf_arena_round_time;
ConVar tf_arena_use_queue;
ConVar tf_arena_preround_time;
ConVar mp_bonusroundtime;

// SDK functions
Handle g_hSDKEquipWearable;
Handle g_hSDKRemoveWearable;
Handle g_hSDKGetEquippedWearable;
Handle g_hSetWinningTeam;
Handle g_hSDKGetMaxAmmo;

// TODO: This is kinda crappy right now because it uses two data structures to get simple information
// But it works for now, so I will just leave it now and attempt to change it later
enum struct TFGOWeaponEntry
{
	int index;
	int cost;
	int killReward;
}

// Config data
ArrayList weaponList;
StringMap killRewardMap;


// methodmaps
methodmap TFGOWeapon
{
	public TFGOWeapon(int defindex)
	{
		return view_as<TFGOWeapon>(defindex);
	}
	
	property int DefIndex
	{
		public get()
		{
			return view_as<int>(this);
		}
	}
	
	property int Cost
	{
		public get()
		{
			int index = weaponList.FindValue(this, 0);
			TFGOWeaponEntry weapon;
			weaponList.GetArray(index, weapon, sizeof(weapon));
			return weapon.cost;
		}
	}
	
	property int KillReward
	{
		public get()
		{
			char key[255];
			TF2Econ_GetItemClassName(this.DefIndex, key, sizeof(key));
			
			int reward;
			killRewardMap.GetValue(key, reward);
			return reward;
		}
	}
}

methodmap TFGOPlayer
{
	public TFGOPlayer(int client)
	{
		return view_as<TFGOPlayer>(client);
	}
	
	property int Client
	{
		public get()
		{
			return view_as<int>(this);
		}
	}
	
	/**
	 * This is the player's money
	 */
	property int Balance
	{
		public get()
		{
			return g_iBalance[this];
		}
		public set(int val)
		{
			if (val > TFGO_MAX_BALANCE)
			{
				val = TFGO_MAX_BALANCE;
			}
			else if (val < TFGO_MIN_BALANCE)
			{
				val = TFGO_MIN_BALANCE;
			}
			g_iBalance[this] = val;
		}
	}
	
	property Menu ActiveBuyMenu
	{
		public get()
		{
			return g_hActiveBuyMenus[this];
		}
		public set(Menu val)
		{
			g_hActiveBuyMenus[this] = val;
		}
	}
	
	public void ShowMoneyHudDisplay(float time)
	{
		SetHudTextParams(-1.0, 0.675, time, 0, 133, 67, 140);
		ShowSyncHudText(this.Client, g_hHudSync, "$%d", this.Balance);
	}
	
	/**
	 * Adds balance to this client and displays a
	 * chat message notifying them of the amount earned.
	 * 
	 * @param val		the amount to add
	 * @param reason	(optional) the reason for this operation
	 */
	public void AddToBalance(int val, const char[] reason = "")
	{
		this.Balance += val;
		if (strlen(reason) > 0)
		{
			CPrintToChat(this.Client, "{money}+$%d{default}: %s.", val, reason);
		}
		else
		{
			CPrintToChat(this.Client, "{money}+$%d{default}", val);
		}
		
		this.ShowMoneyHudDisplay(15.0);
	}
	
	/**
	 * Removes balance from this client and displays a
	 * chat message notifying them of the amount removed.
	 * 
	 * @param val		the amount to add
	 * @param reason	(optional) the reason for this operation
	 */
	public void RemoveFromBalance(int val, const char[] reason = "")
	{
		this.Balance -= val;
		if (strlen(reason) > 0)
		{
			CPrintToChat(this.Client, "{alert}-$%d{default}: %s.", val, reason);
		}
		else
		{
			CPrintToChat(this.Client, "{alert}-$%d{default}", val);
		}
		
		this.ShowMoneyHudDisplay(15.0);
	}
	
	/**
	* Purchases an item for this player and adds it to the loadout
	**/
	public void PurchaseItem(int defindex)
	{
		if (g_bBuyTimeActive)
		{
			TFGOWeapon weapon = TFGOWeapon(defindex);
			TFClassType class = TF2_GetPlayerClass(this.Client);
			int slot = TF2Econ_GetItemSlot(defindex, class);
			
			// player doesn't own weapon yet, charge them and grant it
			if (g_iLoadoutWeaponIndex[this][class][slot] != defindex)
			{
				// force-remove previous weapon and equip new one
				TF2_RemoveItemInSlot(this.Client, slot);
				TF2_CreateAndEquipWeapon(this.Client, defindex);
				g_iLoadoutWeaponIndex[this][class][slot] = defindex;
				this.Balance -= weapon.Cost;
				
				char name[255];
				TF2Econ_GetItemName(defindex, name, sizeof(name));
				PrintToChat(this.Client, "You have purchased %s for $%d.", name, weapon.Cost);
				
				float vec[3];
				GetClientAbsOrigin(this.Client, vec);
				EmitAmbientSound("mvm/mvm_bought_upgrade.wav", vec);
				
				this.ShowMoneyHudDisplay(15.0);
			}
			else // player owns this weapon already, switch to it
			{
				TF2_CreateAndEquipWeapon(this.Client, defindex);
			}
		}
		else
		{
			PrintToChat(this.Client, "The weapon has not been purchased because the buy time has expired.");
		}
	}
	
	/**
	* Gets a weapon from the player's loadout.
	* Can return default weapons.
	*
	* @return a valid defindex or -1 if no weapon for the slot has been found
	**/
	public int GetWeaponFromLoadout(TFClassType class, int slot)
	{
		int defindex = g_iLoadoutWeaponIndex[this][class][slot];
		if (defindex <= 0)
		{
			// no weapon found, return the default
			return g_iDefaultWeaponIndex[class][slot];
		}
		else
		{
			return defindex;
		}
	}
	
	/**
	* Restores previously purchased weapons and equips them
	**/
	public void ApplyLoadout()
	{
		TFClassType class = TF2_GetPlayerClass(this.Client);
		
		for (int slot = 0; slot <= 5; slot++)
		{
			// -1 = no weapon in loadout and no specified default
			int defindex = this.GetWeaponFromLoadout(class, slot);
			if (defindex != -1)
			{
				TF2_CreateAndEquipWeapon(this.Client, defindex);
			}
			else if (!g_bSlotsToKeep[class][slot])
			{
				TF2_RemoveItemInSlot(this.Client, slot);
			}
		}
	}
	
	/**
	* Clears all purchased weapons for all classes
	**/
	public void ClearLoadout()
	{
		for (int class = 0; class < sizeof(g_iLoadoutWeaponIndex[][]); class++)
		for (int slot = 0; slot < sizeof(g_iLoadoutWeaponIndex[][][]); slot++)
		g_iLoadoutWeaponIndex[this.Client][class][slot] = -1;
	}
}

methodmap TFGOTeam
{
	
	public TFGOTeam(TFTeam team)
	{
		return view_as<TFGOTeam>(view_as<int>(team));
	}
	
	property TFTeam Team
	{
		public get()
		{
			return view_as<TFTeam>(this);
		}
	}
	
	property int LoseStreak
	{
		public get()
		{
			return g_iLoseStreak[this];
		}
		
		public set(int val)
		{
			if (val > TFGO_MAXLOSESTREAK)
			{
				g_iLoseStreak[this] = TFGO_MAXLOSESTREAK;
			}
			else if (val < TFGO_MINLOSESTREAK)
			{
				g_iLoseStreak[this] = TFGO_MINLOSESTREAK;
			}
			else
			{
				g_iLoseStreak[this] = val;
			}
		}
	}
	
	/**
	 * Adds balance to every client in this team and displays
	 * a chat message notifying them of the amount earned.
	 * 
	 * @param val		the amount to add
	 * @param reason	(optional) the reason for this operation
	 */
	public void AddToTeamBalance(int val, const char[] reason = "")
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && TF2_GetClientTeam(i) == this.Team)
			{
				TFGOPlayer(i).AddToBalance(val, reason);
			}
		}
	}
	
	/**
	 * Removes balance from every client in this team and displays
	 * a chat message notifying them of the amount removed.
	 * 
	 * @param val		the amount to add
	 * @param reason	(optional) the reason for this operation
	 */
	public void RemoveFromTeamBalance(int val, const char[] reason = "")
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && TF2_GetClientTeam(i) == this.Team)
			{
				TFGOPlayer(i).RemoveFromBalance(val, reason);
			}
		}
	}
}

#include "tfgo/sound.sp"
#include "tfgo/config.sp"
#include "tfgo/buymenu.sp"

public Plugin myinfo =  {
	name = "Team Fortress: Global Offensive", 
	author = "Mikusch", 
	description = "A Team Fortress2 gamemode inspired by Counter-Strike: Global Offensive", 
	version = "1.0", 
	url = "https: //github.com/Mikusch/tfgo"
};

public void OnPluginStart()
{
	// TODO: Choose a music kit for the entire game, only change on arena scramble
	LoadTranslations("common.phrases.txt");
	LoadTranslations("tfgo.phrases.txt");
	
	for (int client = 0; client < sizeof(g_iLoadoutWeaponIndex[]); client++)
	for (int class = 0; class < sizeof(g_iLoadoutWeaponIndex[][]); class++)
	for (int slot = 0; slot < sizeof(g_iLoadoutWeaponIndex[][][]); slot++)
	g_iLoadoutWeaponIndex[client][class][slot] = -1;
	
	SDK_Init();
	
	g_hHudSync = CreateHudSynchronizer();
	
	//g_sCurrencypackPlayerMap = CreateTrie();
	//g_sCurrencypackValueMap = CreateTrie();
	//g_iCashToKillerMap = CreateTrie();
	
	HookEvent("player_death", Event_Player_Death);
	HookEvent("arena_win_panel", Event_Arena_Win_Panel);
	HookEvent("arena_round_start", Event_Arena_Round_Start);
	HookEvent("teamplay_round_start", Event_Teamplay_Round_Start);
	HookEvent("arena_match_maxstreak", Event_Arena_Match_MaxStreak);
	HookEvent("teamplay_broadcast_audio", Event_Pre_Broadcast_Audio, EventHookMode_Pre);
	HookEvent("teamplay_waiting_begins", Event_Teamplay_Waiting_Begins);
	HookEvent("teamplay_waiting_ends", Event_Teamplay_Waiting_Ends);
	HookEvent("post_inventory_application", Event_Post_Inventory_Application);
	HookEvent("teamplay_point_captured", Event_Teamplay_Point_Captured);
	
	tf_arena_max_streak = FindConVar("tf_arena_max_streak");
	tf_arena_first_blood = FindConVar("tf_arena_first_blood");
	tf_arena_round_time = FindConVar("tf_arena_round_time");
	tf_arena_use_queue = FindConVar("tf_arena_use_queue");
	tf_arena_preround_time = FindConVar("tf_arena_preround_time");
	mp_bonusroundtime = FindConVar("mp_bonusroundtime");
	tfgo_buytime = CreateConVar("tfgo_buytime", "45", "How many seconds after spawning players can buy items for", _, true, tf_arena_preround_time.FloatValue);
	
	CAddColor("alert", 0xEA4141);
	CAddColor("money", 0xA2FE47);
	
	Toggle_ConVars(true);
}

public void OnAllPluginsLoaded()
{
	Config_Init();
}

public void OnPluginEnd()
{
	Toggle_ConVars(false);
}

public void OnMapStart()
{
	DHookGamerules(g_hSetWinningTeam, false);
	PrecacheSounds();
	PrecacheModels();
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (strcmp(classname, "trigger_capture_area") == 0)
	{
		//SDKHook(entity, SDKHook_Touch, Hook_EnterCaptureArea);
		//SDKHook(entity, SDKHook_EndTouch, Hook_LeaveCaptureArea);
	}
	else if (strcmp(classname, "func_respawnroom") == 0)
	{
		SDKHook(entity, SDKHook_StartTouch, Entity_StartTouch_RespawnRoom);
		SDKHook(entity, SDKHook_EndTouch, Entity_EndTouch_RespawnRoom);
	}
}

void PrecacheModels()
{
	PrecacheModel("models/items/currencypack_large.mdl");
	PrecacheModel("models/items/currencypack_medium.mdl");
	PrecacheModel("models/items/currencypack_small.mdl");
	PrecacheModel("models/props_td/atom_bomb.mdl");
}

// Prevent round from ending
// Called every frame after the round is supposed to  end
public MRESReturn Hook_SetWinningTeam(Handle hParams)
{
	int team = DHookGetParam(hParams, 1);
	int winReason = DHookGetParam(hParams, 2);
	PrintToServer("team: %d, winreason: %d", team, winReason);
	if (g_bBombPlanted)
	{
		return MRES_Supercede;
	}
	else
	{
		return MRES_Ignored;
	}
}

public Action Event_Teamplay_Point_Captured(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_bBombPlanted) // planted
	{
		StopRoundActionMusic();
		EmitSoundToAll("valve_csgo_01/bombplanted.mp3");
		g_h10SecondBombTimer = CreateTimer(45.0 - 10.0, Play10SecBombWarning);
		g_hBombTimer = CreateTimer(45.0, DetonateBomb);
		
		int team_round_timer = FindEntityByClassname(-1, "team_round_timer");
		if (team_round_timer > -1)
		{
			SetVariantInt(45);
			AcceptEntityInput(team_round_timer, "SetTime");
		}
		
		if (g_h10SecondRoundTimer != null)
		{
			KillTimer(g_h10SecondRoundTimer);
			g_h10SecondRoundTimer = null;
		}
	}
	else // defused
	{
		if (g_hBombTimer != null)
		{
			KillTimer(g_hBombTimer);
			g_hBombTimer = null;
		}
		if (g_h10SecondBombTimer != null)
		{
			KillTimer(g_h10SecondBombTimer);
			g_h10SecondBombTimer = null;
		}
	}
	
	g_bBombPlanted = !g_bBombPlanted;
}

public Action Play10SecBombWarning(Handle timer)
{
	StopSoundForAll(SNDCHAN_AUTO, "valve_csgo_01/bombplanted.mp3");
	EmitSoundToAll("valve_csgo_01/bombtenseccount.mp3");
}

public Action DetonateBomb(Handle timer)
{
	g_bBombPlanted = false;
}

public Action Event_Arena_Match_MaxStreak(Event event, const char[] name, bool dontBroadcast)
{
	for (int i = 0; i < sizeof(g_iBalance); i++)g_iBalance[i] = TFGO_STARTING_BALANCE;
	for (int i = 0; i < sizeof(g_iLoseStreak); i++)g_iLoseStreak[i] = TFGO_STARTING_BALANCE;
}

public Action Event_Player_Death(Event event, const char[] name, bool dontBroadcast)
{
	TFGOPlayer attacker = TFGOPlayer(GetClientOfUserId(event.GetInt("attacker")));
	TFGOPlayer victim = TFGOPlayer(GetClientOfUserId(event.GetInt("userid")));
	int defindex = event.GetInt("weapon_def_index");
	int customkill = event.GetInt("customkill");
	int assister = event.GetInt("assister");
	
	if (g_bRoundActive)
	{
		if (customkill == TF_CUSTOM_SUICIDE && attacker == victim)
		{
			attacker.RemoveFromBalance(300, "Penalty for suiciding");
		}
		else
		{
			char weaponName[255];
			TF2Econ_GetItemName(defindex, weaponName, sizeof(weaponName));
			char msg[255];
			Format(msg, sizeof(msg), "Award for neutralizing an enemy with %s", weaponName);
			
			char weaponclass[255];
			TF2Econ_GetItemClassName(defindex, weaponclass, sizeof(weaponclass));
			
			TFGOWeapon weapon = TFGOWeapon(defindex);
			attacker.AddToBalance(weapon.KillReward, msg);
			if (assister != -1)
			{
				char attackerName[255];
				GetClientName(attacker.Client, attackerName, sizeof(attackerName));
				Format(msg, sizeof(msg), "Award for assisting %s in neutralizing an enemy", attackerName);
				TFGOPlayer(GetClientOfUserId(assister)).AddToBalance(weapon.KillReward / 2, msg);
			}
		}
	}
	
	// TODO restore previous weapons IF this death was a suicide in the respawn room
	
	return Plugin_Continue;
}

public void OnClientConnected(int client)
{
	TFGOPlayer(client).Balance = TFGO_STARTING_BALANCE;
	// Give the player some music from the music kit while they wait
	if (g_bWaitingForPlayers)
	{
		EmitSoundToClient(client, "valve_csgo_01/chooseteam.mp3");
	}
}

public Action Event_Arena_Win_Panel(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundStarted = false;
	
	// Determine winning/losing team
	TFGOTeam winningTeam = TFGOTeam(view_as<TFTeam>(event.GetInt("winning_team")));
	TFGOTeam losingTeam;
	switch (winningTeam.Team)
	{
		case TFTeam_Red:
		{
			losingTeam = TFGOTeam(TFTeam_Blue);
		}
		case TFTeam_Blue:
		{
			losingTeam = TFGOTeam(TFTeam_Red);
		}
	}
	
	// Add round end team awards
	int winReason = event.GetInt("winreason");
	switch (winReason)
	{
		case TF_WINREASON_CAPTURE_01:
		{
			winningTeam.AddToTeamBalance(TFGO_CAPTURE_WIN_REWARD, "Team award for capturing the control point");
		}
		case TF_WINREASON_CAPTURE_02:
		{
			winningTeam.AddToTeamBalance(TFGO_CAPTURE_WIN_REWARD, "Team award for capturing all control points");
		}
		case TF_WINREASON_ELIMINATION:
		{
			winningTeam.AddToTeamBalance(TFGO_ELIMINATION_WIN_REWARD, "Team award for eliminating the enemy team");
		}
	}
	int compensation = g_iLoseStreakCompensation[losingTeam.LoseStreak];
	losingTeam.AddToTeamBalance(compensation, "Income for losing");
	
	// Adjust team lose streaks
	losingTeam.LoseStreak++;
	winningTeam.LoseStreak--;
	
	// Reset timers
	if (g_h10SecondRoundTimer != null)
	{
		KillTimer(g_h10SecondRoundTimer);
		g_h10SecondRoundTimer = null;
	}
	if (g_hBuytimeTimer != null)
	{
		KillTimer(g_hBuytimeTimer);
		g_hBuytimeTimer = null;
	}
	
	// Everyone who survives the post-victory time gets to keep their weapons
	CreateTimer(mp_bonusroundtime.FloatValue - 0.1, SaveWeaponsForAlivePlayers);
}

public Action SaveWeaponsForAlivePlayers(Handle timer)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && IsPlayerAlive(client))
		{
			for (int slot = 0; slot <= 5; slot++)
			{
				int defindex = GetPlayerWeaponSlot(client, slot);
				PrintToServer("%d still had %d", client, defindex);
			}
		}
	}
}

public Action Event_Post_Inventory_Application(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (IsClientInGame(client))
	{
		ShowMainBuyMenu(client);
		TFGOPlayer player = TFGOPlayer(client);
		player.ShowMoneyHudDisplay(tfgo_buytime.FloatValue);
		player.ApplyLoadout();
	}
}

public Action Event_Arena_Round_Start(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundActive = true;
	g_h10SecondRoundTimer = CreateTimer(tf_arena_round_time.FloatValue - 12.7, Play10SecondWarning);
}

public Action Event_Teamplay_Round_Start(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundStarted = true;
	g_bRoundActive = false;
	g_bBuyTimeActive = true;
	g_hBuytimeTimer = CreateTimer(tfgo_buytime.FloatValue, OnBuyTimeExpire);
	
	PlayRoundStartMusic();
	
	for (int client = 1; client < MaxClients; client++)
	{
		if (IsClientInGame(client))
		{
			ShowMainBuyMenu(client);
			TFGOPlayer(client).ShowMoneyHudDisplay(tfgo_buytime.FloatValue);
		}
	}
}

public Action OnBuyTimeExpire(Handle timer)
{
	g_bBuyTimeActive = false;
	g_hBuytimeTimer = null;
	
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
		{
			TFGOPlayer player = TFGOPlayer(client);
			
			if (player.ActiveBuyMenu != null)
			{
				player.ActiveBuyMenu.Cancel();
			}
		}
	}
	
	// TODO only show this while in buyzone
	CPrintToChatAll("{alert}Alert: {default}The %d second buy period has expired", tfgo_buytime.IntValue);
}

public Action Entity_StartTouch_RespawnRoom(int entity, int client)
{
	if (client <= MaxClients && IsClientConnected(client))
	{
		if (GetEntProp(entity, Prop_Data, "m_iTeamNum") == GetClientTeam(client))
		{
			ShowMainBuyMenu(client);
		}
	}
}

public Action Entity_EndTouch_RespawnRoom(int entity, int client)
{
	if (client <= MaxClients && IsClientConnected(client))
	{
		if (GetEntProp(entity, Prop_Data, "m_iTeamNum") == GetClientTeam(client))
		{
			TFGOPlayer player = TFGOPlayer(client);
			if (player.ActiveBuyMenu != null)
			{
				player.ActiveBuyMenu.Cancel();
			}
			
			if (g_bBuyTimeActive)
			{
				CPrintToChat(client, "{alert}Alert: {default}You have left the buy zone");
			}
		}
	}
}

void Toggle_ConVars(bool toggle)
{
	static bool bArenaFirstBlood;
	static bool bArenaUseQueue;
	static int iArenaMaxStreak;
	static int iArenaRoundTime;
	static int iBonusRoundtime;
	
	if (toggle)
	{
		bArenaFirstBlood = tf_arena_first_blood.BoolValue;
		tf_arena_first_blood.BoolValue = false;
		
		bArenaUseQueue = tf_arena_use_queue.BoolValue;
		tf_arena_use_queue.BoolValue = false;
		
		iArenaMaxStreak = tf_arena_max_streak.IntValue;
		tf_arena_max_streak.IntValue = 8;
		
		iArenaRoundTime = tf_arena_round_time.IntValue;
		tf_arena_round_time.IntValue = 135;
		
		iBonusRoundtime = mp_bonusroundtime.IntValue;
		mp_bonusroundtime.IntValue = 7;
	}
	else
	{
		tf_arena_first_blood.BoolValue = bArenaFirstBlood;
		tf_arena_use_queue.BoolValue = bArenaUseQueue;
		tf_arena_max_streak.IntValue = iArenaMaxStreak;
		tf_arena_round_time.IntValue = iArenaRoundTime;
		mp_bonusroundtime.IntValue = iBonusRoundtime;
	}
}

stock void SDK_EquipWearable(int client, int iWearable)
{
	if (g_hSDKEquipWearable != null)
		SDKCall(g_hSDKEquipWearable, client, iWearable);
}

stock void SDK_RemoveWearable(int client, int iWearable)
{
	if (g_hSDKRemoveWearable != null)
		SDKCall(g_hSDKRemoveWearable, client, iWearable);
}

stock int SDK_GetEquippedWearable(int client, int iSlot)
{
	if (g_hSDKGetEquippedWearable != null)
		return SDKCall(g_hSDKGetEquippedWearable, client, iSlot);
	
	return -1;
}

void SDK_Init()
{
	Handle hGameData = LoadGameConfigFile("tfgo");
	int offset;
	
	offset = GameConfGetOffset(hGameData, "SetWinningTeam");
	g_hSetWinningTeam = DHookCreate(offset, HookType_GameRules, ReturnType_Void, ThisPointer_Ignore, Hook_SetWinningTeam);
	DHookAddParam(g_hSetWinningTeam, HookParamType_Int);
	DHookAddParam(g_hSetWinningTeam, HookParamType_Int);
	DHookAddParam(g_hSetWinningTeam, HookParamType_Bool);
	DHookAddParam(g_hSetWinningTeam, HookParamType_Bool);
	DHookAddParam(g_hSetWinningTeam, HookParamType_Bool);
	DHookAddParam(g_hSetWinningTeam, HookParamType_Bool);
	
	// This function is used to equip wearables 
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, "CBasePlayer::EquipWearable");
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
	g_hSDKEquipWearable = EndPrepSDKCall();
	if (g_hSDKEquipWearable == null)
		LogMessage("Failed to create call: CBasePlayer::EquipWearable!");
	
	// This function is used to remove a player wearable properly
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, "CBasePlayer::RemoveWearable");
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
	g_hSDKRemoveWearable = EndPrepSDKCall();
	if (g_hSDKRemoveWearable == null)
		LogMessage("Failed to create call: CBasePlayer::RemoveWearable!");
	
	// This function is used to get wearable equipped in loadout slots
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "CTFPlayer::GetEquippedWearableForLoadoutSlot");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_Pointer);
	g_hSDKGetEquippedWearable = EndPrepSDKCall();
	if (g_hSDKGetEquippedWearable == null)
		LogMessage("Failed to create call: CTFPlayer::GetEquippedWearableForLoadoutSlot!");
	
	//This function is used to get weapon max ammo
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "CTFPlayer::GetMaxAmmo");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hSDKGetMaxAmmo = EndPrepSDKCall();
	if (g_hSDKGetMaxAmmo == null)
		LogMessage("Failed to create call: CTFPlayer::GetMaxAmmo!");
	
	delete hGameData;
}

stock void TF2_RemoveItemInSlot(int client, int slot)
{
	TF2_RemoveWeaponSlot(client, slot);
	
	int iWearable = SDK_GetEquippedWearable(client, slot);
	if (iWearable > MaxClients)
	{
		SDK_RemoveWearable(client, iWearable);
		AcceptEntityInput(iWearable, "Kill");
	}
}

stock int SDK_GetMaxAmmo(int iClient, int iSlot)
{
	if (g_hSDKGetMaxAmmo != null)
		return SDKCall(g_hSDKGetMaxAmmo, iClient, iSlot, -1);
	return -1;
}

stock int TF2_CreateAndEquipWeapon(int iClient, int defindex)
{
	char sClassname[256];
	TF2Econ_GetItemClassName(defindex, sClassname, sizeof(sClassname));
	TF2Econ_TranslateWeaponEntForClass(sClassname, sizeof(sClassname), TF2_GetPlayerClass(iClient));
	
	int iWeapon = CreateEntityByName(sClassname);
	if (IsValidEntity(iWeapon))
	{
		SetEntProp(iWeapon, Prop_Send, "m_iItemDefinitionIndex", defindex);
		SetEntProp(iWeapon, Prop_Send, "m_bInitialized", 1);
		
		DispatchSpawn(iWeapon);
		SetEntProp(iWeapon, Prop_Send, "m_bValidatedAttachedEntity", true);
		
		if (StrContains(sClassname, "tf_wearable") == 0)
			SDK_EquipWearable(iClient, iWeapon);
		else
			EquipPlayerWeapon(iClient, iWeapon);
	}
	
	// TODO: Test following code
	
	if (StrContains(sClassname, "tf_wearable") == 0)
	{
		if (GetEntPropEnt(iClient, Prop_Send, "m_hActiveWeapon") <= MaxClients)
		{
			//Looks like player's active weapon got replaced into wearable, fix that by using melee
			int iMelee = GetPlayerWeaponSlot(iClient, TFWeaponSlot_Melee);
			SetEntPropEnt(iClient, Prop_Send, "m_hActiveWeapon", iMelee);
		}
	}
	else
	{
		SetEntPropEnt(iClient, Prop_Send, "m_hActiveWeapon", iWeapon);
	}
	
	//Set ammo as weapon's max ammo
	if (HasEntProp(iWeapon, Prop_Send, "m_iPrimaryAmmoType")) //Wearables dont have ammo netprop
	{
		int iAmmoType = GetEntProp(iWeapon, Prop_Send, "m_iPrimaryAmmoType");
		if (iAmmoType > -1)
		{
			//We want to set gas passer ammo empty, because thats how normal gas passer works
			int iMaxAmmo;
			if (defindex == 1180)
			{
				iMaxAmmo = 0;
				SetEntPropFloat(iClient, Prop_Send, "m_flItemChargeMeter", 0.0, 1);
			}
			else
			{
				iMaxAmmo = SDK_GetMaxAmmo(iClient, iAmmoType);
			}
			
			SetEntProp(iClient, Prop_Send, "m_iAmmo", iMaxAmmo, _, iAmmoType);
		}
	}
	
	return iWeapon;
}

public Action Event_Teamplay_Waiting_Begins(Event event, const char[] sName, bool bDontBroadcast)
{
	g_bWaitingForPlayers = true;
}

public Action Event_Teamplay_Waiting_Ends(Event event, const char[] sName, bool bDontBroadcast)
{
	g_bWaitingForPlayers = false;
	StopSoundForAll(SNDCHAN_AUTO, "valve_csgo_01/chooseteam.mp3");
}

stock int TF2_SpawnParticle(char[] sParticle, float vecOrigin[3] = NULL_VECTOR, float flAngles[3] = NULL_VECTOR, bool bActivate = true, int iEntity = 0, int iControlPoint = 0)
{
	int iParticle = CreateEntityByName("info_particle_system");
	TeleportEntity(iParticle, vecOrigin, flAngles, NULL_VECTOR);
	DispatchKeyValue(iParticle, "effect_name", sParticle);
	DispatchSpawn(iParticle);
	
	if (0 < iEntity && IsValidEntity(iEntity))
	{
		SetVariantString("!activator");
		AcceptEntityInput(iParticle, "SetParent", iEntity);
	}
	
	if (0 < iControlPoint && IsValidEntity(iControlPoint))
	{
		//Array netprop, but really only need element 0 anyway
		SetEntPropEnt(iParticle, Prop_Send, "m_hControlPointEnts", iControlPoint, 0);
		SetEntProp(iParticle, Prop_Send, "m_iControlPointParents", iControlPoint, _, 0);
	}
	
	if (bActivate)
	{
		ActivateEntity(iParticle);
		AcceptEntityInput(iParticle, "Start");
	}
	
	//Return ref of entity
	return EntIndexToEntRef(iParticle);
}
