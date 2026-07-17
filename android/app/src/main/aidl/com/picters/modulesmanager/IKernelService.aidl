package com.picters.modulesmanager;

import com.picters.modulesmanager.IExecCallback;

/**
 * Root command broker, implemented by KernelRootService in a separate root
 * process. Every call is dispatched on the Binder thread pool, so a slow script
 * on one thread never stalls another call — this is what removes the
 * head-of-line blocking the single serialized `su` pipe suffered from.
 */
interface IKernelService {
    /** ABI guard — the app refuses a service build it doesn't recognise. */
    int getApiVersion();

    /**
     * Runs [script] as root and reports the result to [cb]. `oneway`: the
     * caller's Binder transaction returns immediately and the work proceeds on
     * its own thread, so many exec() calls run concurrently. [requestId] is
     * echoed back so the client can match a reply to its request.
     */
    oneway void exec(int requestId, String script, int timeoutMs, IExecCallback cb);
}
