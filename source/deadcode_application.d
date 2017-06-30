module deadcode_application;

import core.time; // for RPC
import std.algorithm : map, joiner;
import std.array;
import std.conv;
import std.socket; // for RPC
import std.variant;

import deadcode.api : IApplication; // for RPC

import deadcode.core.command;
import deadcode.core.coreevents;
import deadcode.core.event : Event;
import deadcode.core.eventsource : MainEventSource;
import deadcode.core.log;
import deadcode.edit.bufferview : BufferView, BufferViewManager, CopyBuffer;
import deadcode.gui.application;
import deadcode.gui.locations;
import deadcode.gui.style.stylesheet;
import deadcode.gui.window;
import deadcode.io.file;
import deadcode.io.iomanager;
import deadcode.rpc;

import bufferviewgroup;
import deadcode_events;
import deadcode_net;
import deadcode_window;
import extension_loader;
import workqueue;

class DeadcodeApplication : Application
{
    private
    {
        BufferViewManager _bufferViewManager;
        CommandManager _commandManager;
        ExtensionManager!() _extensionManager;
        FileManager _fileManager;
        WorkQueue!(void delegate()) _workQueue;
        Log _log;
     
        // RPC related
        enum MAX_CONNECTIONS = 40;
        DeadcodeNet _net;
        RPCLoop _rpcLoop;
        SocketSet _socketSet;
        socket_t[] _rpcSockets;

        BufferViewGroups _groups;
    }

    final @property
    {
        BufferViewManager bufferViewManager() { return _bufferViewManager; }
        CommandManager commandManager() { return _commandManager; }
        ExtensionManager!() extensionManager() { return _extensionManager; }
        auto ref workQueue() { return _workQueue; }
        Log log() { return _log; }
        DeadcodeNet net() { return _net; }
    }

    this()
    {
        import deadcode.core.ctx;
        import deadcode.event_sdl.sdleventssource;
        import deadcode.platform.clipboard : SDLClipboard;
        import deadcode.edit.copybuffer : IClipboard;
        import std.typecons : wrap;
        
        auto es = new SDLEventSource;
        auto fm = new FileManager;
        fm.add(new LocalFileProtocol());
        string extensionSources = "extensions";
        string extensionBinaries = extensionSources;
        auto clipboard = new SDLClipboard();
        this(es, 
             new BufferViewManager(new CopyBuffer(clipboard.wrap!IClipboard)),
             new CommandManager(),
             new ExtensionManager!()(es.sink(), fm, extensionSources, extensionBinaries),
             fm,
             ctx.get!Log()); 
    }

    this(MainEventSource evSource, BufferViewManager bvMgr, CommandManager cmdMgr, ExtensionManager!() extMgr, FileManager fileMgr, Log l)
    {
        _bufferViewManager = bvMgr;
        _commandManager = cmdMgr;
        _extensionManager = extMgr;
        _fileManager = fileMgr;
        _log = l;
        _socketSet = new SocketSet(MAX_CONNECTIONS + 1);
        super(evSource);
        extensionManager.startWorkerThread();
        extensionManager.beginScanForAllExtensions();
        eventSource.scheduleTimeout(dur!"seconds"(1), Variant("scanExtensions"));
        _groups = new BufferViewGroups;
    
        locationsManager.declare("file:resources/style/*");

        styleSheetManager.onSourceChanged.connectTo((StyleSheet sheet) {
            sheet.load();
        });

    }

    void listen(ushort port, IApplication api)
    {
        assert(_rpcLoop is null);
        
        registerCommandParameterMsgPackHandlers();
        _net = new DeadcodeNet(eventSource.sink);
        _net.start();
        
        _rpcLoop = new RPCLoop;
        _rpcLoop.listen(port);
        log.info("Listening on port %s", port);

        _rpcLoop.onConnected.connectTo( (RPC rpc, bool incoming) {
            log.info("Connect from %s", rpc.transport.toString());
            rpc.publish(api);
        });

        selectAsync(dur!"seconds"(10));
    }

    Window loadWindow()
    {
        auto win = createWindow!DeadcodeWindow("Deadcode");
        import deadcode.gui.label;
        //auto group1 = new Label("Hello world");
        //group1.parent = win;
        //main.name = "
        auto bv = newBufferView();
        bv.insert("This is a buffer view");

        win.setBufferViewGroups(_groups, _bufferViewManager);
        return win;
    }

    BufferView newBufferView()
    {
        auto b = bufferViewManager.create();
        _groups.currentBufferViewGroup.add(b.id);
        return b;
    }

    @property BufferView currentBufferView()
    {
        auto i = _groups.currentBufferViewGroup.currentBufferViewID;
        return bufferViewManager[i];
    }

    @property void currentBufferView(BufferView v)
    {
        _groups.currentBufferViewID = v.id;
    }

    CompletionEntry[] getActiveBufferCompletions(string needle)
    {
        return null;
    }

    void previewBufferView(string name)
    {
        
    }

	void showBuffer(string name)
	{
		auto buf = bufferViewManager[name];
		if (buf is null)
		{
			log.e("Cannot show unknown buffer '%s'", name);
		}
        else
        {
		    showBuffer(buf);
        }
	}

	void showBuffer(BufferView buf)
	{
		// auto w = setBufferVisible(buf);
		// w.editor.setKeyboardFocusWidget();
		// currentBuffer = buf;
	}

    private void selectAsync(Duration d)
    {
        if (_rpcLoop is null)
            return;

        _rpcSockets.length = 0;
        assumeSafeAppend(_rpcSockets);

        if (_rpcLoop.addSockets(_rpcSockets))
        {
            _net.select(_rpcSockets, null, null, d); 
        }
    }

    void addCommand(ICommand cmd)
    {
        commandManager.add(cmd);

        auto proxy = cast(RPCProxyBase)cmd;
        if (proxy !is null)
        {
            log.info("RPC command added: %s", cmd.name);
            
            // copy to closure so we can log the name in onKilled
            // without going through RPCProxy call to get the name of the
            // (at that point) unreachable command object.
            auto commandName = cmd.name; 
            
            // This is a RPC proxy. Lets make sure to remove command on rpc disconnect.
            proxy.rpc.onKilled.connectTo((RPC) {
                log.info("Removing RPC command: %s", commandName);
                commandManager.remove(cmd);
            });
        }
    }

    override protected void handleEvent(Event ev)
    {
        import deadcode_events;
        super.handleEvent(ev);
        
        if (ev.type == DeadcodeEvents.stringCommand)
        {
            auto cmdEvent = cast(StringCommandEvent)ev;
            commandManager.parseAndExecute(cmdEvent.commandString);
            ev.markUsed();
        }
        else if (ev.type == DeadcodeEvents.socketSelect)
        {
            auto e = cast(SocketSelectEvent)ev;

            _socketSet.reset();
            foreach (s; e.readable)
                _socketSet.add(s);

            try
                _rpcLoop.processSockets(_socketSet);
            catch (Exception e)
            {
                log.info("caught exception");
                string estr = e.toString();
                log.info("caught exception " ~ estr);
            }
            ev.markUsed();
            selectAsync(dur!"seconds"(10));
        }
        else if (ev.type == DeadcodeEvents.log)
        {
            auto e = cast(LogEvent)ev;
            log.log(e.level, e.message);
            ev.markUsed();
        }
        else if (ev.type == DeadcodeEvents.extensionPresence)
        {
            auto e = cast(ExtensionPresenceEvent)ev;
            foreach (a; e.added)
            {
                log.info("Extension found %s", a.name);
                handleExtensionChange(a);
            }
            foreach (a; e.modified)
            {
                log.info("Extension modified %s", a.name);
                handleExtensionChange(a);
            }
            foreach (a; e.removed)
                log.info("Extension removed %s", a.name);
            ev.markUsed();
        }
        else if (ev.type == DeadcodeEvents.extensionBuildFinished)
        {
            auto e = cast(ExtensionBuildFinishedEvent)ev;
            if (e.exitCode == 0)
            {
                // scan to pick up changed executable
                extensionManager.beginScanForChangedExtensions();
            }
            ev.markUsed();
        }
        else if (ev.type == CoreEvents.timeout)
        {
            auto e = cast(TimeoutEvent)ev;
            auto data = e.userData.peek!string;
            if (data !is null && *data == "scanExtensions")
            {
                extensionManager.beginScanForChangedExtensions();
                foreach (l; locationsManager)
                    l.scan();
                eventSource.scheduleTimeout(dur!"seconds"(1), Variant("scanExtensions"));
            }
            ev.markUsed();
        }
    }

    private void handleExtensionChange(ExtensionInfo info)
    {
        // Want to know:
        // 0, new .d file or dirty .d file => build
        // 1, existing .d file and up2date exe => load (if not disabled)
        // 2, new build .exe file => unload, load
        // 3. disabled .exe file => unload
        
        // case 0
        if (info.needsRebuild())
        {
            extensionManager.unloadExtensions([info.name]);
            extensionManager.buildExtensions([info.name]);
        }
        // case 1
        else if (info.isEnabled && info.hasBinary && !info.currentBuildFails)
        {
            extensionManager.loadExtensions([info.name]);
        }
        // case 3
        else if (!info.isEnabled)
        {
            extensionManager.unloadExtensions([info.name]);
        }
    }

    static bool sendCommandToExisting(string host, ushort port, string[] args)
    {
        auto client = new RPCLoop;
        bool didConnect = false;

        client.onConnected.connectTo( (RPC rpc, bool incoming) {
            didConnect = true;
            IApplication api = rpc.createReference!IApplication();

            class TestClientCommand : Command
            {
                override void execute(CommandParameter[] data)
                {
                    api.log.info("Hello from client");
                }
            }

            auto cmd = new TestClientCommand;
            api.addCommand(cmd);
            api.runCommand(args[1]);
            //api.log(LogLevel.info, args[1]);
            rpc.kill();
        });

        try
            client.connect(host, port);
        catch (SocketOSException)
            return false;

        while (client.select() != 0) {}
        return didConnect;
    }
}
