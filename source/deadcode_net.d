module deadcode_net;

import core.atomic;
import core.time;
import std.concurrency;
import std.socket;

import deadcode.core.eventsource;

import deadcode_events;

class DeadcodeNet
{
    private 
    {
        // Tid _tid;
        MainEventSource.OutputRange _eventSink;
        Socket[2] _interuptSockets;
        
        shared bool _isRunning;
        enum MAX_SOCKETS = 64;
        
        struct SelectInfo
        {
            Duration timeout;
            socket_t[MAX_SOCKETS] readable;
            socket_t[MAX_SOCKETS] writable;
            socket_t[MAX_SOCKETS] except;
        }
    }

    this(MainEventSource.OutputRange eventSink)
    {
        _eventSink = eventSink;
        _interuptSockets = socketPair();
    }

    void select(socket_t[] readable, socket_t[] writable, socket_t[] except, Duration timeout)
    {
        assert(readable.length <= 64);
        assert(writable.length <= 64);
        assert(except.length <= 64);
            
        SelectInfo i;
        i.timeout = timeout;
        i.readable[] = i.writable[] = i.except[] = cast(socket_t)-1;
        i.readable[0..readable.length] = readable[0..$];
        i.writable[0..writable.length] = writable[0..$];
        i.except[0..except.length] = except[0..$];
        
        //
        //auto sz = sizeof(socket_t);
        //
        //// Data format:
        //// ubyte readCount | ubyte writeCount | ubyte exceptCount | readSockets | writeSockets | exceptSockets
        //ubyte data[(readable.nselect() + 1 /* interuptSocket */ + writable.nselect() + except.nselect()) * sz + sizeof(ubyte) * 3];
        //ubyte* d = data.ptr;
        //(*d++) = readable.ncount() + 1;
        //(*d++) = writable.ncount();
        //(*d++) = except.ncount();
        //d++; // align
        //d[0..readable.ncount*sz] = cast(ubyte[]) readable[0..readable.ncount];
        //d += readable.ncount*sz;
        //d[0..writable.ncount*sz] = cast(ubyte[]) writable[0..writable.ncount];
        //d += writable.ncount*sz;
        //d[0..except.ncount*sz] = cast(ubyte[]) except[0..except.ncount];
        ubyte* ptrI = cast(ubyte*)(&i);
        _interuptSockets[0].send(ptrI[0..SelectInfo.sizeof]);
    }

    void stop()
    {
        if (cas(&_isRunning, true, false))
            select(null, null, null, dur!"seconds"(0));
    }

    void start()
    {
        if (cas(&_isRunning, false, true))
        {
           assert(_eventSink.isValid);
           spawn(&loop, _eventSink, _interuptSockets[1].handle, _interuptSockets[1].addressFamily, &_isRunning);
        }
    }

    private static void loop(MainEventSource.OutputRange eventSink, socket_t interuptSocketIn, AddressFamily af, shared(bool*) isRunning)
    {
        SocketSet readSet = new SocketSet();
        SocketSet writeSet = new SocketSet();
        SocketSet exceptSet = new SocketSet();
        Socket interuptSocket = new Socket(interuptSocketIn, af);

        SelectInfo selectInfo;
        selectInfo.timeout = dur!"days"(365);

        socket_t[] readable;
        socket_t[] writable;
        socket_t[] except;

        readSet.add(interuptSocket);

        while (atomicLoad(*isRunning))
        {
            int result = Socket.select(readSet, writeSet, exceptSet, selectInfo.timeout); 
            
            bool isInterupt = readSet.isSet(interuptSocket) != 0;
            
            if (result > 1 || (result == 1 && !isInterupt))
            {
                readable.length = writable.length = except.length = 4;
                assumeSafeAppend(readable);
                assumeSafeAppend(writable);
                assumeSafeAppend(except);
                readable[] = writable[] = except[] = cast(socket_t)-1;
                int read_idx = 0;
                int write_idx = 0;
                int except_idx = 0;
                foreach (i; 0..MAX_SOCKETS)
                {
                    if (readSet.isSet(selectInfo.readable[i]))
                        readable[read_idx++] = selectInfo.readable[i];
                    if (writeSet.isSet(selectInfo.writable[i]))
                        writable[write_idx++] = selectInfo.writable[i];
                    if (exceptSet.isSet(selectInfo.except[i]))
                        except[except_idx++] = selectInfo.except[i];
                    
                    if (read_idx == 4 || write_idx == 4 || except_idx == 4 || (i == MAX_SOCKETS - 1 && (read_idx + write_idx + except_idx) != 0))
                    {
                        auto ev = DeadcodeEvents.create!SocketSelectEvent(read_idx + write_idx + except_idx);
                        ev.readable[] = readable[0..4];
                        ev.writable[] = writable[0..4];
                        ev.except[] = except[0..4];
                        eventSink.put(ev);
                        readable[] = writable[] = except[] = cast(socket_t)-1;
                        read_idx = 0;
                        write_idx = 0;
                        except_idx = 0;
                    }
                }

                readSet.reset();
                writeSet.reset();
                exceptSet.reset();
                
                readable.length = 0;
                assumeSafeAppend(readable);
                writable.length = 0;
                assumeSafeAppend(readable);
                except.length = 0;
                assumeSafeAppend(except);

                readSet.add(interuptSocket);
                selectInfo.timeout = dur!"days"(365);
            }
            else if (result <= 0)
            {
                socket_t[4] none = cast(socket_t)-1;
                auto ev = DeadcodeEvents.create!SocketSelectEvent(result);
                ev.readable[] = none[];
                ev.writable[] = none[];
                ev.except[] = none[];
                eventSink.put(ev);
                
                readSet.reset();
                writeSet.reset();
                exceptSet.reset();

                readable.length = 0;
                assumeSafeAppend(readable);
                writable.length = 0;
                assumeSafeAppend(writable);
                except.length = 0;
                assumeSafeAppend(except);

                readSet.add(interuptSocket);
                selectInfo.timeout = dur!"days"(365);
            }
            else if (readSet.isSet(interuptSocket) != 0)
            {
                // New select requested from another thread. We would like to merge incoming sockets 
                // with last select() because we have no real select result ready to send back as an event.
                ubyte* buf = cast(ubyte*)(&selectInfo);
                interuptSocket.receive(buf[0..selectInfo.sizeof]);

                readSet.reset();
                writeSet.reset();
                exceptSet.reset();
                readSet.add(interuptSocket);

                mergeSockets(readable, selectInfo.readable, readSet);
                mergeSockets(writable, selectInfo.writable, writeSet);
                mergeSockets(except, selectInfo.except, exceptSet);
            }
        }
    }

    private static void mergeSockets(ref socket_t[] currentSet, ref socket_t[MAX_SOCKETS] incoming, SocketSet socketSet)
    {
        import std.algorithm;

        foreach (s; currentSet)
            socketSet.add(s);

        foreach (i; 0..MAX_SOCKETS)
        {
            socket_t s = incoming[i]; 
            if (s == -1)
                break;
            if (!currentSet.canFind(s))
            {
                currentSet ~= s;
                socketSet.add(s);
            }
        }
    }
}