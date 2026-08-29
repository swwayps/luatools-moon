-- Explicit public RPC surface consumed by Lumen. Keeping this contract beside
-- the backend makes a LuaTools update self-describing: adding a frontend call
-- no longer also requires an in-lockstep edit to Lumen's compatibility list.
-- Helpers and other globals remain private unless named here.
return {
  "AddCustomApi", "ApplyGameFix", "ApplySettingsChanges", "ApplySpaceFix",
  "CancelAddViaLuaTools", "CancelLuaToolsAutoFix",
  "CancelGameDraft", "CommitGameDraft",
  "CancelApplyFix", "CheckApisForApp", "CheckForFixes", "CheckForUpdatesNow",
  "DeleteLuaToolsForApp", "DismissLoadedApps", "FetchFreeApisNow",
  "GetAddViaLuaToolsStatus", "GetAllApis", "GetApiList", "GetApplyFixStatus",
  "GetFixLaunchOptions", "GetHubcapStats", "GetProtonDBStatus",
  "GetGameDraftStatus", "EnrichGameImportFromDraft",
  "GetGameInstallPath", "GetGamesDatabase", "GetIconDataUrl", "GetInitApisMessage",
  "GetInstalledFixes", "GetInstalledLuaScripts", "GetMorrenusStats",
  "GetSettingsConfig", "GetThemes", "GetTranslations", "GetUnfixStatus",
  "HasLuaToolsForApp", "IsCompatToolForced", "Logger.log",
  "OpenExternalUrl", "OpenGameFolder", "ReadLoadedApps", "ResolveOnlineFix",
  "RemoveApi", "RenameApi", "ReorderApis", "RestartSteam", "ToggleApi", "UnFixGame",
  "SearchSteamGames", "GetSteamAppDetails", "StartAddViaLuaTools",
  "StartAddViaLuaToolsFromUrl", "StartAddViaLuaToolsSmart",
  "StartAddViaLuaToolsSource", "StartGameDraft",
  "GetLuaToolsAuthStatus", "LoginLuaToolsWithCode", "StartLuaToolsDiscordLogin",
  "PollLuaToolsDiscordLogin", "CancelLuaToolsDiscordLogin", "LogoutLuaTools",
  "AdoptLuaToolsSessionValue",
  "GetLuaToolsFixesCatalogue", "GetLuaToolsFixesForGame", "GetLuaToolsAddRecommendation",
  "StartLuaToolsRecommendedAdd", "StartLuaToolsFix",
  "CompleteLuaToolsFixApply",
}
