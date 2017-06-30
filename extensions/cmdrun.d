/+
dub.sdl:
    name "cmdrun"
    dependency "deadcode-rpc" version=">=0.0.0"
    dependency "deadcode-api" version=">=0.0.0"
    version "DeadcodeOutOfProcess"
+/


import deadcode.api;
import deadcode.api.rpcclient;
mixin rpcClient;
mixin registerCommands;

void deadcodeExec(ILog log, string filePath)
{
    import std.path;
    import std.file;
    import deadcode.util.process;
    import std.process : wait;

    if (!exists(filePath) || !isFile(filePath))
    {
    	log.error("Cannot execute %s since it is not a file", filePath);
    }
    else
    {

	    auto p = buildNormalizedPath(filePath);
	    log.verbose("Executing %s", p);
	    auto info = spawnProcess([p], p.setExtension("log"));
		int exitCode = wait(info[0]);
	    log.verbose("Exit code %s for %s", exitCode, p);
	}
}

//class MacroCommandsService : Service
//{
//	private
//	{
//		string[] commandNames;
//	}

//	override void onLoaded()
//	{
//	    import std.path;
//	    import std.file;
//	    auto p = buildPath("extensions", commandName.replace(".", "_"));
//		string filePath = null;

//	    foreach (d; dirEntries(p, ".*"), SpanMode.shallow, false)
//	    {
//	    	filePath = d.name;
//	    }

//		watchDir("extensions")
//	}

//    void handleDirChanged(string[] filesAdded, string[] filesRemoved, string[] filesModified)
//    {
//    	app.removeCommand(name);
//    }

//    private void addCommand()
//    {

//    }
//}


//void deadcodeRunExecutableAsCommand(ILog log, string commandName, string commandArgs, bool async = false)
//{
//    import std.path;
//    import std.file;
//    import deadcode.util.process;
//    auto p = buildPath("extensions", commandName.replace(".", "_"));
//	string filePath = null;

//    foreach (d; dirEntries(p, ".*"), SpanMode.shallow, false)
//    {
//    	filePath = d.name;
//    }

//    if (filePath is null)
//    {
//    	log.error("Cannot run %s", commandName);
//    	return;
//    }

//    p = buildNormalizedPath(filePath);
//    auto info = spawnProcess([p], p.setExtension("log"));
//	int exitCode = wait(info.pid);
//}

// Protocol
// PipeAPI:
// 