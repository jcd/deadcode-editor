module app;

import std.getopt;
import std.range;

import deadcode.api : deadcodeListenPort;
import deadcode.core.ctx;
import deadcode.core.log;

import api;
import deadcode.platform.config;
import deadcode_application;

int main(string[] args)
{
	// Command line options
	string logPath = null;
	string testsOutput = null;
	string[] scripts;
	string[] commands;
	bool noRedirect = false;
	bool continueAfterUnittestsSuccess = false;

	auto helpInformation = getopt(args,
								  "log",		   &logPath,
								  "unittest|u",    &testsOutput,
								  "continueAfterUnittestsSuccess",    &continueAfterUnittestsSuccess,
								  "script|S",      &scripts,
								  "command|c",      &commands,
								  "noredirect|n",  &noRedirect);
	
	if (helpInformation.helpWanted)
	{
		showHelp(helpInformation.options);
		return 0;
	}

	// Show unit test report and exit - unittest are run before entering main
	version (unittest)
	{
		auto res = reportUnittests(testsOutput.length != 0 ? testsOutput : "-");
		if ( ! (continueAfterUnittestsSuccess && res == 0) )
			return res;
	}

    int exitCode = 0;
	try
	{
        if (DeadcodeApplication.sendCommandToExisting("localhost", deadcodeListenPort, args))
            return exitCode;

		ctx.set(new Log(logPath.length == 0 ? paths.userData("log.txt") : logPath));

		auto app = new DeadcodeApplication();
        auto api_ = new Deadcode(app);
        app.listen(deadcodeListenPort, api_);

        setupCommands(app, api_);

        api_.queueWork({
            log.i("Queuing work");
            api_.runCommand("log.info \"Hello 'Sync'\"");
            api_.scheduleCommand("log.info \"Hello 'Async'\"");
            // api.open(args[].dropOne);
        });

        //app.queueWork(() {
        //    import std.range;
        //    app.openFiles(args[].dropOne);
        //});
        //
        //app.queueWork(() {
        //    foreach(s; scripts)
        //        app.runScript(s);
        //});
        //
        //app.queueWork(() {
        //    foreach(c; commands)
        //        app.scheduleCommand(c);
        //});
        //
        auto win = app.loadWindow();
        auto ss = app.styleSheetManager.declare("resources/style/default.stylesheet");
        ss.ensureLoaded();
                
        win.styleSheet = ss;
        
        exitCode = app.run();
	}
	catch (Throwable e)
	{
        exitCode = 1;
		lastChanceLogging(e);
	}

//	import libasync.threads;
	//destroyAsyncThreads(); // This shouldn't be necessary as libasync static ~this() does it. But it has a bug.
	return exitCode;
}

private void showHelp(Option[] opts)
{
	string headerText = "Deadcode text editor - version x.y.z (C) Jonas Drewsen - Boost 1.0 License\n"
		~ "Usage: deadcode [--unittest <output path>] [--nodirect] [--script path] [--command \"cmdAndArgs\"] [paths...]s";

	version (linux)
		defaultGetoptPrinter(headerText, opts);
	else
	{
		import deadcode.platform.dialog;
		import std.array;
		auto app = appender!string;
		defaultGetoptFormatter(app, headerText, opts);
		messageBox("Help on usage", app.data, MessageBoxStyle.modal);	
	}
}

private void setupCommands(DeadcodeApplication app, Deadcode api)
{
    import deadcode.api.api : IApplication;
    import deadcode.api.commandautoregister;
    import poodinis;
    import std.algorithm : any;

    auto context = new shared DependencyContainer();
    context.register!(IApplication,Deadcode).existingInstance(api);
    context.register!(ILog, typeof(app.log)).existingInstance(app.log);

    auto cmds = initCommands(context);
    foreach (cmd; cmds)
    {
        app.addCommand(cmd.command);
    }
}

private int reportUnittests(string testsOutput)
{
	import std.stdio;
	File f =  testsOutput == "-" ? stdout : File(testsOutput, "w");
	import deadcode.test;
	int result = printStats(f, true) ? 0 : 1;
	f.flush();
	return result;
}

// Something terrible has happened if this is called 
private void lastChanceLogging(Throwable e)
{
	import std.string;
	import deadcode.platform.dialog;

	version (linux)
	{
		static import std.stdio;
		std.stdio.writeln("Caught Exception: ", e);
	}

	string s = e.toString();
	s ~= "\n" ~ "Help improve the editor by uploading this backtrace?";

	// Last attempt to log error
	try { log.e(s); } catch (Throwable) { /* pass since this is last chance logging anyway */ }

	int res = messageBox("Caught Exception", e.toString(),
						 MessageBoxStyle.error | MessageBoxStyle.yesNo | MessageBoxStyle.modal);
	
    // Collect crash reports so we can improve code
    if (res)
	{
		import deadcode.core.analytics;
		auto a = ctx.query!Analytics();
		if (a !is null)
			a.addException(e.toString()[0..700], true);
	}
}
