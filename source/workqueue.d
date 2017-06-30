module workqueue;

struct WorkQueue(WorkerType)
{
    import deadcode.util.queue;
    private
    {
        shared RWQueue!WorkerType _queue;
    }

    void queueWork(WorkerType work)
    {
        _queue.push(work);
    }

    @property bool empty() const
    {
        return _queue.empty;
    }

    bool processOne()
    {
        bool didWork = false;
        if (!empty)
        {
            auto w = _queue.pop();
            w();
            didWork = true;
        }
        return didWork;
    }
}
