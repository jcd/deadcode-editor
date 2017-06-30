module api;

import std.algorithm;

import deadcode.api.api;
import deadcode.core.command;
import deadcode.core.log;

import deadcode_events;

class Deadcode : IApplication
{
    import deadcode_application;
    import workqueue;
    private
    {
        DeadcodeApplication _app;

        final @property auto ref workQueue() { return _app.workQueue; }
        final @property DeadcodeApplication app() { return _app; }
    }

    this(DeadcodeApplication app)
    {
        _app = app;
        _app.onUpdate.connectTo(&update);
    }

    final void queueWork(void delegate() dlg)
    {
        workQueue.queueWork(dlg);
    }

    final void update(double timeSinceAppStart, double deltaTime)
    {
        while (workQueue.processOne())
        {
        }
    }

	void runScript(string scriptPath)
	{
		static import std.stdio;
        std.stdio.File file;
		try
        {
			file = std.stdio.File(scriptPath, "r");
		}
        catch (std.exception.ErrnoException e)
		{
            static import core.stdc.errno;
            static import std.conv;
			string msg = std.conv.text(e);
			if (e.errno == core.stdc.errno.ENOENT)
				msg = "No such script file";

			app.log.error("Error opening file : %s %s", scriptPath, msg);
			return;
		}

        static string shortToFullFormCommandLine(string l)
        {
            //assert(0);
            return l;
        }

		bool shortForm = false;
		foreach(line; file.byLine)
		{
			if (line.startsWith("#") || line.startsWith("//"))
			{
				if (line.canFind("mode=short"))
					shortForm = true;
				else if (line.canFind("mode=long"))
					shortForm = false;
			}
			else
			{
				string l = line.idup;
				if (shortForm)
					l = shortToFullFormCommandLine(l);

				if (l is null)
					app.log.warning("Unknown short form command %s", line);
				else
					scheduleCommand(l);
			}
		}
	}

    // IApplication
    void logMessage(LogLevel level, string message)
    {
        app.log.log(level, message);
    }

    void setLogFile(string path) { }
    void bufferViewParamTest(IBufferView b) { }
    
    void addCommand(ICommand c) 
    { 
        app.addCommand(c);
    }
    
    string[] findCommands(string pattern)
    {
        import std.algorithm;
        import std.array;
        return app.commandManager
           .lookupFuzzy(pattern, pattern.length == 0)
           .map!"a.name".array;
    }

    

    void runCommand(string cmd) 
    {
        app.commandManager.parseAndExecute(cmd);
    }

    void scheduleCommand(string cmd)
    { 
        app.eventSource.put(DeadcodeEvents.create!StringCommandEvent(cmd));
    }

    void buildExtension(string name)
    {
        app.extensionManager.buildExtensions([name]);
    }

    void loadExtension(string name)
    {
        app.extensionManager.loadExtensions([name]);
    }

    void unloadExtension(string name)
    {
        app.extensionManager.unloadExtensions([name]);
    }

    void scanExtensions(bool onlyChanged = true)
    {
        if (onlyChanged)
            app.extensionManager.beginScanForChangedExtensions();
        else
            app.extensionManager.beginScanForAllExtensions();
    }

    // void addMenuItem(string commandName, MenuItem menuItem);
    // void addCommandShortcuts(string commandName, Shortcut[] shortcuts);
    void onFileDropped(string path) { }
    void quit() { }
    string hello(string yourName) { return null; }
    void startExtension(string path) { }


    @property ILog log()
    {
        return app.log;
    }

    @property CommandManager commandManager()
    {
        return app.commandManager;
    }

    @property IBufferView previousBuffer() { return null; }
    @property ITextEditor currentTextEditor() { return null; }
    @property IBufferView currentBuffer() { return null; }
    @property void currentBuffer(IBufferView b) { }

    @property string userDataDir() { return null; }
    @property string executableDir() { return null; }

}
